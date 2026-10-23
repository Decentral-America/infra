# Runner image for the matcher CI host. One container of it per job, under sysbox-runc: the job gets its
# own Docker daemon (dex-it testcontainers, service containers, image builds) without --privileged and
# without the host's Docker socket.
FROM ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac

ARG RUNNER_VERSION
ARG RUNNER_SHA256
ARG BUILD_DATE
ENV DEBIAN_FRONTEND=noninteractive

# BUILD_DATE busts the layer cache daily so `apt-get upgrade` picks up security fixes.
RUN echo "build ${BUILD_DATE}" \
 && apt-get update -q \
 && apt-get -y -q upgrade \
 && apt-get install -y -q --no-install-recommends \
      ca-certificates curl gnupg git git-lfs jq zstd unzip zip xz-utils sudo python3 python3-yaml \
      iptables iproute2 procps lsb-release tzdata locales openssh-client rsync file fakeroot \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | grep -q '^fpr:::::::::9DC858229FC7DD38854AE2D88D81803C0EBFCD88:' \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list \
 && apt-get update -q \
 && apt-get install -y -q --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
 && locale-gen en_US.UTF-8 \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8

# Parity with GitHub's ubuntu-24.04 image where matcher's workflows rely on it: Apache Maven on PATH
# (setup-dcc-jvm-deps builds the crypto package with `mvn`), and a /usr/local/bin the job user can install
# tools into (the oasdiff installer writes there without sudo).
ARG MAVEN_VERSION=3.9.11
ARG MAVEN_SHA512=bcfe4fe305c962ace56ac7b5fc7a08b87d5abd8b7e89027ab251069faebee516b0ded8961445d6d91ec1985dfe30f8153268843c89aa392733d1a3ec956c9978
RUN curl -fsSL -o /tmp/maven.tgz "https://repo1.maven.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
 && echo "${MAVEN_SHA512}  /tmp/maven.tgz" | sha512sum -c - \
 && tar -xzf /tmp/maven.tgz -C /opt && rm /tmp/maven.tgz \
 && ln -s "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/bin/mvn

RUN useradd -m -u 1001 -s /bin/bash runner \
 && usermod -aG docker runner \
 && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner && chmod 0440 /etc/sudoers.d/runner \
 && chown runner:runner /usr/local/bin

WORKDIR /home/runner/actions-runner
RUN curl -fsSL -o /tmp/runner.tgz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
 && echo "${RUNNER_SHA256}  /tmp/runner.tgz" | sha256sum -c - \
 && tar -xzf /tmp/runner.tgz && rm /tmp/runner.tgz \
 && ./bin/installdependencies.sh \
 && rm -rf /var/lib/apt/lists/* \
 && chown -R runner:runner /home/runner

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
