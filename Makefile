# Test entrypoints. Every target runs tests/run.sh; the Docker targets mount
# the checkout read-only at /app. See tests/README.md.

DOCKER       ?= docker
TEST_IMAGE   ?= sg-migrator-test
DOCKER_TESTS := gnu bash32 bsd ubuntu rhel

.PHONY: test test-native test-docker test-all test-runtime-image $(addprefix test-,$(DOCKER_TESTS))

## test: the suite on this machine (macOS: /bin/bash 3.2 + BSD tools)
test: test-native

test-native:
	tests/run.sh

## test-docker: every Linux target
test-docker: $(addprefix test-,$(DOCKER_TESTS))

## test-all: this machine, then every Linux target
test-all: test-native test-docker

# The migrator's own image (the repo's Dockerfile) under a test tag, so the
# wrapper's stackguardian/migrator:local is left alone.
test-runtime-image:
	$(DOCKER) build -q -t $(TEST_IMAGE):runtime . >/dev/null

test-gnu: test-runtime-image
$(addprefix test-,$(DOCKER_TESTS)): test-%:
	$(DOCKER) build -q -t $(TEST_IMAGE):$* -f tests/docker/Dockerfile.$* --build-arg BASE=$(TEST_IMAGE):runtime tests/docker >/dev/null
	$(DOCKER) run --rm -v "$(CURDIR):/app:ro" -e SG_TEST_TARGET=$* $(TEST_IMAGE):$* /app/tests/run.sh
