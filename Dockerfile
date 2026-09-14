# Migrator runtime: bundles all pinned tooling so the flow behaves identically
# on Linux/macOS/Windows hosts (anywhere Docker runs). The repo is bind-mounted
# at /app at runtime; this image only provides the tools on PATH.

# yajsv has no linux/arm64 release asset, so build it from source for the
# image's target architecture.
FROM golang:1.22-bookworm AS yajsv
ARG YAJSV_VERSION=v1.4.1
RUN go install "github.com/neilpa/yajsv@${YAJSV_VERSION}"

FROM debian:bookworm-slim

ARG TERRAFORM_VERSION=1.9.8
ARG JQ_VERSION=1.8.1
ARG HCL2JSON_VERSION=0.6.7

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash curl ca-certificates git unzip tar coreutils \
    && rm -rf /var/lib/apt/lists/*

# terraform (arch from dpkg: amd64/arm64 — works with or without buildx)
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" -o /tmp/tf.zip \
    && unzip /tmp/tf.zip -d /usr/local/bin \
    && rm /tmp/tf.zip

# jq
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-${arch}" -o /usr/local/bin/jq \
    && chmod +x /usr/local/bin/jq

# hcl2json
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/tmccombs/hcl2json/releases/download/v${HCL2JSON_VERSION}/hcl2json_linux_${arch}" -o /usr/local/bin/hcl2json \
    && chmod +x /usr/local/bin/hcl2json

# yajsv (from the build stage above)
COPY --from=yajsv /go/bin/yajsv /usr/local/bin/yajsv

# sg-cli (latest release, Go binary). Assets: sg-cli_<OS>_<ARCH>.tar.gz.
RUN set -eu; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64) arch=x86_64 ;; arm64) arch=arm64 ;; esac; \
    curl -fsSL "https://github.com/StackGuardian/sg-cli/releases/latest/download/sg-cli_Linux_${arch}.tar.gz" -o /tmp/sg-cli.tar.gz; \
    mkdir -p /tmp/sgcli; \
    tar -xzf /tmp/sg-cli.tar.gz -C /tmp/sgcli; \
    realcli="$(find /tmp/sgcli -maxdepth 2 -type f -name sg-cli | head -1)"; \
    test -n "$realcli"; \
    install -m 0755 "$realcli" /usr/local/bin/sg-cli; \
    rm -rf /tmp/sg-cli.tar.gz /tmp/sgcli

WORKDIR /app
ENTRYPOINT ["/bin/bash"]
