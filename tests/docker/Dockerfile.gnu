# Linux / GNU userland: the migrator's own runtime image (OpenTofu, jq,
# hcl2json, yajsv, sg-cli) plus the test tools. BASE is built from the repo's
# Dockerfile by the Makefile, so the tests run against exactly what customers
# run in Docker.
ARG BASE=sg-migrator-test:runtime
FROM ${BASE}

ARG BATS_VERSION=1.11.1
RUN apt-get update && apt-get install -y --no-install-recommends shellcheck python3 \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz" | tar -xz -C /tmp \
    && "/tmp/bats-core-${BATS_VERSION}/install.sh" /usr/local \
    && rm -rf "/tmp/bats-core-${BATS_VERSION}"

# Never the host's .sg/cached (macOS binaries); the checkout is mounted read-only.
ENV SG_CACHE_DIR=/tmp/sg-cache
WORKDIR /app
ENTRYPOINT ["/bin/bash"]
