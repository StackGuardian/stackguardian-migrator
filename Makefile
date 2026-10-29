# Test entrypoints. Every target runs tests/run.sh; the Docker targets mount
# the checkout read-only at /app. See tests/README.md.

DOCKER       ?= docker
TEST_IMAGE   ?= sg-migrator-test
DOCKER_TESTS := gnu bash32 bsd ubuntu rhel

.PHONY: test test-native test-docker test-all test-runtime-image $(addprefix test-,$(DOCKER_TESTS)) test-live live-seed live-clean

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

# Live tests (tests/live/README.md): a real TFC org and a sandbox StackGuardian
# org, credentials from 1Password via op run. Not part of test-all.
# SG_LIVE_ENV holds op:// references only. op run resolves every op:// value in
# the environment, so inherited ones are dropped first.
SG_LIVE_ENV ?= $(HOME)/.config/sg-migrator-test/env.tpl
LIVE_RUN = env $(foreach v,$(shell env | grep '=op://' | cut -d= -f1),-u $(v)) op run --env-file "$(SG_LIVE_ENV)" --

## test-live: the live scenarios (SCENARIOS="all rerun" to pick some)
test-live:
	$(LIVE_RUN) tests/live/run.sh $(SCENARIOS)

## live-seed: create/update the TFC fixture and give its workspaces a state
live-seed:
	cd tests/live/tfc-fixture && $(LIVE_RUN) sh -c 'tofu init -input=false >/dev/null && tofu apply -auto-approve -input=false && ./seed_state.sh'

## live-clean: delete what the live tests created in StackGuardian
live-clean:
	$(LIVE_RUN) tests/live/run.sh clean
