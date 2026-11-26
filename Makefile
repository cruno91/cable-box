# Recipes that pipe to tee use inline "set -o pipefail": macOS make 3.81 ignores .SHELLFLAGS.
SHELL         := /bin/bash

FS42_SHA      := c313f7dd622991a7ef58b46fa7c24d6b11037270
SANDBOX_IMAGE := cablebox/fs42-sandbox:$(shell echo $(FS42_SHA) | cut -c1-7)
NAS_VOLUME    := cablebox-fakenas
EVIDENCE      := .work/evidence
DOCKER_RUN    := docker run --rm --platform linux/arm64 \
	-v $(NAS_VOLUME):/mnt/nas:ro \
	-v $(CURDIR)/test/integration/fs42:/h:ro \
	-v $(CURDIR)/internal/fs42/probe:/probe:ro

.PHONY: sandbox-image-name fs42-image fs42-lock fixtures wp0 wp0-poc wp0-activation wp0-upstream-tests

fs42-image: ## build the pinned FS42 sandbox image (NO_BUILD=1 reuses an existing one)
	@if [ -n "$(NO_BUILD)" ] && docker image inspect $(SANDBOX_IMAGE) >/dev/null 2>&1; then \
	  echo "using existing $(SANDBOX_IMAGE)"; \
	else \
	  docker build --platform linux/arm64 --build-arg FS42_SHA=$(FS42_SHA) -t $(SANDBOX_IMAGE) test/integration/fs42; \
	fi

fs42-lock: ## regenerate requirements.lock from upstream's unpinned requirements.in
	: > test/integration/fs42/requirements.lock
	docker build -q --platform linux/arm64 --build-arg FS42_SHA=$(FS42_SHA) -t $(SANDBOX_IMAGE)-unlocked test/integration/fs42
	set -o pipefail; docker run --rm $(SANDBOX_IMAGE)-unlocked cat /opt/fs42-freeze.txt | grep -vE '^(pip|setuptools|wheel)==' > test/integration/fs42/requirements.lock

sandbox-image-name: ## print the pinned sandbox image tag (used by CI)
	@echo $(SANDBOX_IMAGE)

fixtures: fs42-image ## generate the synthetic NAS volume (idempotent)
	docker volume create $(NAS_VOLUME) >/dev/null
	docker run --rm -v $(NAS_VOLUME):/mnt/nas -v $(CURDIR)/test/integration/fs42:/h:ro $(SANDBOX_IMAGE) bash /h/gen_fixtures.sh /mnt/nas

wp0-upstream-tests: fs42-image ## upstream's own pytest suite at the pinned SHA
	docker run --rm $(SANDBOX_IMAGE) env/bin/python -m pytest -q test

wp0-poc: fixtures ## two-channel shared-symlink proof of concept
	@mkdir -p $(EVIDENCE)/poc
	set -o pipefail; $(DOCKER_RUN) -v $(CURDIR)/$(EVIDENCE)/poc:/evidence $(SANDBOX_IMAGE) bash /h/run_poc.sh 2>$(EVIDENCE)/poc/stderr.txt | tee $(EVIDENCE)/poc/results.txt

wp0-activation: fixtures ## activation and rollback
	@mkdir -p $(EVIDENCE)/activation
	set -o pipefail; $(DOCKER_RUN) -v $(CURDIR)/$(EVIDENCE)/activation:/evidence $(SANDBOX_IMAGE) bash /h/run_activation.sh 2>$(EVIDENCE)/activation/stderr.txt | tee $(EVIDENCE)/activation/results.txt

wp0: wp0-upstream-tests wp0-poc wp0-activation ## all sandbox suites
