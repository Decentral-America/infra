#!/usr/bin/env bash
# First-boot installer of the matcher CI runner host (run once by cloud-init runcmd).
# Idempotent: safe to re-run by hand (sudo bash /opt/matcher-ci/install.sh).
# Every download is pinned by version AND sha256 (or by a pinned apt signing-key fingerprint).
set -euo pipefail
exec > >(tee -a /var/log/matcher-ci-install.log) 2>&1
echo "=== matcher-ci install $(date -u +%FT%TZ)"

# shellcheck disable=SC1091
source /etc/matcher-ci/config.env
export DEBIAN_FRONTEND=noninteractive

SYSBOX_VERSION=0.7.1
SYSBOX_SHA256=9d6d5484f980d0a17f86c492c1262015c2afb66280bdb97215b79fde6a0261c5
NODE_EXPORTER_VERSION=1.12.1
NODE_EXPORTER_SHA256=b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63
DOCKER_APT_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

# 1. Host firewall first (inbound SSH/metrics allowlists, job egress filter).
apt-get update -q
apt-get install -y -q nftables
/opt/matcher-ci/mci-lib.sh render-nft > /etc/matcher-ci/matcher-ci.nft
nft -c -f /etc/matcher-ci/matcher-ci.nft
systemctl daemon-reload
systemctl enable --now matcher-ci-firewall.service

# 2. Base packages, security updates, unattended security upgrades (config in /etc/apt/apt.conf.d).
apt-get -y -q -o Dpkg::Options::=--force-confold upgrade
apt-get install -y -q --no-install-recommends ca-certificates curl gnupg jq zstd openssl unattended-upgrades apt-listchanges
systemctl enable --now unattended-upgrades.service
sysctl --system >/dev/null
systemctl restart ssh.service || systemctl restart sshd.service

# 3. Docker Engine from Docker's apt repository (signing key fingerprint pinned).
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.asc
gpg --show-keys --with-colons /tmp/docker.asc | grep -q "^fpr:::::::::${DOCKER_APT_KEY_FPR}:" \
  || { echo "Docker apt key fingerprint mismatch"; exit 1; }
install -m 0644 /tmp/docker.asc /etc/apt/keyrings/docker.asc
# shellcheck disable=SC1091
. /etc/os-release
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin
systemctl enable --now docker.service

# 4. Sysbox: every job's container gets its own Docker daemon without --privileged and without the host socket.
if ! dpkg -s sysbox-ce 2>/dev/null | grep -q "^Version: ${SYSBOX_VERSION}"; then
  curl -fsSL -o /tmp/sysbox.deb "https://github.com/nestybox/sysbox/releases/download/v${SYSBOX_VERSION}/sysbox-ce_${SYSBOX_VERSION}.linux_amd64.deb"
  echo "${SYSBOX_SHA256}  /tmp/sysbox.deb" | sha256sum -c -
  apt-get install -y -q /tmp/sysbox.deb
fi
systemctl is-active --quiet sysbox.service
docker info --format '{{json .Runtimes}}' | jq -e 'has("sysbox-runc")' >/dev/null

# 5. node_exporter (scraped by the VPS Prometheus; the textfile collector carries the runner metrics).
if ! /usr/local/bin/node_exporter --version 2>/dev/null | grep -q "version ${NODE_EXPORTER_VERSION}"; then
  t="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"
  curl -fsSL -o /tmp/ne.tgz "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${t}.tar.gz"
  echo "${NODE_EXPORTER_SHA256}  /tmp/ne.tgz" | sha256sum -c -
  tar -xzf /tmp/ne.tgz -C /tmp "${t}/node_exporter"
  install -m 0755 "/tmp/${t}/node_exporter" /usr/local/bin/node_exporter
fi
id node_exporter >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
install -d -m 0755 /var/lib/node_exporter/textfile
install -d -m 0700 /var/lib/matcher-ci /run/matcher-ci
systemctl enable --now node-exporter.service

# 6. The runner image (actions/runner pinned + sha256-verified, Docker inside), then the supervisor units.
/opt/matcher-ci/mci-image-build.sh
systemctl daemon-reload
systemctl enable --now matcher-ci-image.timer matcher-ci-heartbeat.timer
for i in $(seq 1 "${MCI_SLOTS}"); do systemctl enable --now "matcher-ci-slot@${i}.service"; done
systemctl start matcher-ci-heartbeat.service || true

touch /var/lib/matcher-ci/installed
echo "=== matcher-ci install done $(date -u +%FT%TZ)"
