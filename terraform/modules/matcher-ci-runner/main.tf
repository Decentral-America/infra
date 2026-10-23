# ──────────────────────────────────────────────────────────────────────────────
# matcher CI runner host: ONE dedicated Linode that runs ephemeral GitHub Actions
# runners for the PRIVATE Decentral-America/matcher repository only.
#
#   * Repository-level runners (the org is on GitHub Free: no custom runner
#     groups), so no other repository can ever be assigned to them.
#   * Every job gets a fresh sysbox container (`--ephemeral` registration, its
#     own Docker daemon on a per-job volume); the container and the volume are
#     deleted after the job. There is no host Docker socket in any job.
#   * Cloud firewall + host nftables: inbound SSH from var.ssh_allowed_ipv4 and
#     node_exporter :9100 from var.metrics_allowed_ipv4 only; outbound DNS, NTP,
#     HTTP and HTTPS only; jobs cannot reach link-local (metadata) or private
#     ranges.
#   * The SSH host key is generated here and pinned (ssh/known_hosts), never
#     trust-on-first-use.
#   * Stateless: changing anything under files/ replaces the instance through
#     its user_data. The GitHub credential is not in user_data (it never transits
#     Linode); it is pushed over SSH afterwards (runbooks/matcher-ci-runner.md).
# ──────────────────────────────────────────────────────────────────────────────

resource "tls_private_key" "host_ed25519" {
  algorithm = "ED25519"
}

locals {
  repo_url = "https://github.com/${var.github_repository}"

  config_env = <<-EOT
    # Rendered by terraform/modules/matcher-ci-runner. Non-secret.
    MCI_REPO=${var.github_repository}
    MCI_REPO_URL=${local.repo_url}
    MCI_LABELS=${var.runner_label}
    MCI_SLOTS=${var.slots}
    MCI_SLOT_MEMORY=${var.slot_memory}
    MCI_SSH_ALLOWED_V4=${join(",", var.ssh_allowed_ipv4)}
    MCI_METRICS_ALLOWED_V4=${join(",", var.metrics_allowed_ipv4)}
  EOT

  # path on the host => { mode, file under files/ }
  host_files = {
    "/opt/matcher-ci/install.sh"                           = { mode = "0755", src = "install.sh" }
    "/opt/matcher-ci/mci-lib.sh"                           = { mode = "0755", src = "mci-lib.sh" }
    "/opt/matcher-ci/mci-slot.sh"                          = { mode = "0755", src = "mci-slot.sh" }
    "/opt/matcher-ci/mci-heartbeat.sh"                     = { mode = "0755", src = "mci-heartbeat.sh" }
    "/opt/matcher-ci/mci-image-build.sh"                   = { mode = "0755", src = "mci-image-build.sh" }
    "/opt/matcher-ci/mci-verify-clean.sh"                  = { mode = "0755", src = "mci-verify-clean.sh" }
    "/opt/matcher-ci/matcher-ci.nft.tmpl"                  = { mode = "0644", src = "matcher-ci.nft.tmpl" }
    "/opt/matcher-ci/runner-image/Dockerfile"              = { mode = "0644", src = "runner-image/Dockerfile" }
    "/opt/matcher-ci/runner-image/entrypoint.sh"           = { mode = "0755", src = "runner-image/entrypoint.sh" }
    "/etc/systemd/system/matcher-ci-firewall.service"      = { mode = "0644", src = "systemd/matcher-ci-firewall.service" }
    "/etc/systemd/system/matcher-ci-slot@.service"         = { mode = "0644", src = "systemd/matcher-ci-slot@.service" }
    "/etc/systemd/system/matcher-ci-heartbeat.service"     = { mode = "0644", src = "systemd/matcher-ci-heartbeat.service" }
    "/etc/systemd/system/matcher-ci-heartbeat.timer"       = { mode = "0644", src = "systemd/matcher-ci-heartbeat.timer" }
    "/etc/systemd/system/matcher-ci-image.service"         = { mode = "0644", src = "systemd/matcher-ci-image.service" }
    "/etc/systemd/system/matcher-ci-image.timer"           = { mode = "0644", src = "systemd/matcher-ci-image.timer" }
    "/etc/systemd/system/node-exporter.service"            = { mode = "0644", src = "systemd/node-exporter.service" }
    "/etc/docker/daemon.json"                              = { mode = "0644", src = "docker-daemon.json" }
    "/etc/apt/apt.conf.d/52matcher-ci-unattended-upgrades" = { mode = "0644", src = "apt-unattended-upgrades.conf" }
    "/etc/apt/apt.conf.d/20auto-upgrades"                  = { mode = "0644", src = "apt-auto-upgrades.conf" }
    "/etc/ssh/sshd_config.d/10-matcher-ci.conf"            = { mode = "0644", src = "sshd-matcher-ci.conf" }
    "/etc/sysctl.d/60-matcher-ci.conf"                     = { mode = "0644", src = "sysctl-matcher-ci.conf" }
  }

  cloud_config = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    host_key_private = tls_private_key.host_ed25519.private_key_openssh
    host_key_public  = trimspace(tls_private_key.host_ed25519.public_key_openssh)
    ssh_public_key   = var.ssh_public_key
    config_env_b64   = base64encode(local.config_env)
    files = {
      for dst, f in local.host_files : dst => {
        mode    = f.mode
        content = file("${path.module}/files/${f.src}")
      }
    }
  })

  # First public address (Linode private addresses are 192.168.128.0/17; this host has none).
  public_ipv4 = one([for ip in linode_instance.runner.ipv4 : ip if !cidrcontains("192.168.128.0/17", ip)])
}

resource "linode_instance" "runner" {
  label  = var.label
  region = var.region
  type   = var.type
  image  = var.image

  # No root password and no root SSH: the only login is `ops` with var.ssh_public_key.
  # (Omitted root_pass: Linode sets a random one that is never stored.)
  authorized_keys = [var.ssh_public_key]

  # cloud-init reads gzip-compressed user data; base64 is what the Linode API expects.
  metadata {
    user_data = base64gzip(local.cloud_config)
  }

  firewall_id     = linode_firewall.runner.id
  backups_enabled = false
  booted          = true
  tags            = var.tags
}

resource "linode_firewall" "runner" {
  label = "${var.label}-fw"

  inbound_policy  = "DROP"
  outbound_policy = "DROP"

  inbound {
    label    = "allow-ssh-operators"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = var.ssh_allowed_ipv4
  }

  dynamic "inbound" {
    for_each = length(var.metrics_allowed_ipv4) > 0 ? [1] : []
    content {
      label    = "allow-node-exporter-vps"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = "9100"
      ipv4     = var.metrics_allowed_ipv4
    }
  }

  outbound {
    label    = "allow-dns-udp"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "53"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  outbound {
    label    = "allow-dns-tcp"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "53"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  outbound {
    label    = "allow-ntp"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "123"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # GitHub (Actions service, git, caches, artifacts, releases), GHCR, Docker Hub, Maven Central,
  # Adoptium and the Ubuntu/Docker apt mirrors are all HTTP(S).
  outbound {
    label    = "allow-http"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  outbound {
    label    = "allow-https"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "443"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  tags = var.tags
}
