# Agents this repo builds. Verbs that act on one take it as a second goal:
#
#   make template claude
#   make sandbox codex SANDBOX=scratch
AGENTS      := claude codex
AGENT_VERBS := build template verify-image sandbox verify-sandbox

.DEFAULT_GOAL := help

# `claude` and `codex` are empty goals (below); naming one is what selects it.
# `override` so an `AGENT=` on the command line cannot swap the agent the guard
# below validated for another one.
override AGENT := $(firstword $(filter $(AGENTS),$(MAKECMDGOALS)))

# Checked while the Makefile is parsed, so no recipe has started when it fails:
# `sandbox` removes the target sandbox first, and under `make -j` a guard
# prerequisite would race the recipes it is meant to stop.
ifneq ($(filter $(AGENT_VERBS),$(MAKECMDGOALS)),)
ifneq ($(words $(filter $(AGENTS),$(MAKECMDGOALS))),1)
$(error usage: make $(firstword $(filter $(AGENT_VERBS),$(MAKECMDGOALS))) claude|codex (name exactly one agent))
endif
endif

# Per-agent facts: the kit name (the stem of agent/<agent>/<name>.yaml, which
# sbx also takes as the agent name) and the default sandbox name.
KIT_NAME_claude := jarvis-engineer
KIT_NAME_codex  := jarvis-engineer-codex
SANDBOX_claude  := jarvis-engineer
SANDBOX_codex   := jarvis-engineer-codex

IMAGE   := jarvis-engineer:$(AGENT)
SANDBOX ?= $(SANDBOX_$(AGENT))

# sbx builds a local v3 kit from its own directory, which must hold the whole
# build context, and only with a docker-container builder (the docker driver
# cannot export the OCI layout it needs). scripts/stage-kit.sh assembles that
# directory; KIT_BUILDER is the builder sbx is pointed at.
KIT_DIR     := ./build/kits/$(KIT_NAME_$(AGENT))
KIT_BUILDER := kit-builder

.PHONY: help claude codex build template verify-image sandbox verify-sandbox sync verify verify-sync verify-make verify-kits clean

## help: list the targets
help:
	@sed -n 's/^## //p' $(MAKEFILE_LIST)

claude codex:
	@:

## build <agent>: build the sandbox template image jarvis-engineer:<agent>
build:
	docker build --target $(AGENT) --build-arg AGENT=$(AGENT) -t $(IMAGE) .

## template <agent>: build and verify the image, then build the staged kit into sbx's cache
#
# sbx caches a built kit by its source hash, so a later `make sandbox` with the
# same sources creates without rebuilding.
template: build verify-image
	./scripts/stage-kit.sh $(AGENT)
	docker buildx inspect $(KIT_BUILDER) >/dev/null 2>&1 || docker buildx create --name $(KIT_BUILDER) --driver docker-container --bootstrap
	BUILDX_BUILDER=$(KIT_BUILDER) sbx kit inspect $(KIT_DIR)

## sandbox <agent>: (re)create SANDBOX from the agent's staged kit with credentials from .env
#
# --env-file is required: MYSQL_USER/MYSQL_PASS are read from the sandbox
# environment by the MySQL MCP server, and are never written into any config.
# The kit is the first positional argument; --kit is for mixins only.
sandbox:
	-sbx rm --force $(SANDBOX)
	./scripts/stage-kit.sh $(AGENT)
	docker buildx inspect $(KIT_BUILDER) >/dev/null 2>&1 || docker buildx create --name $(KIT_BUILDER) --driver docker-container --bootstrap
	BUILDX_BUILDER=$(KIT_BUILDER) sbx create --name $(SANDBOX) --env-file .env $(KIT_DIR) .
	./scripts/verify-sandbox-$(AGENT).sh $(SANDBOX)

## sync: regenerate the kit content of agent/claude/ and agent/codex/ from shared/
sync:
	./scripts/sync-agents.sh

## verify: static checks (sync, dispatch, kits, both images). Use verify-sandbox <agent> for the live ones.
verify: verify-sync verify-make verify-kits
	for agent in $(AGENTS); do $(MAKE) verify-image $$agent || exit 1; done

## verify-sync: generator tests, then fail if the committed kit content drifted from shared/
verify-sync:
	./scripts/test-sync-agents.sh
	./scripts/sync-agents.sh --check

## verify-make: tests for the Makefile's agent dispatch
verify-make:
	./scripts/test-make-dispatch.sh

## verify-image <agent>: static acceptance checks against the built image
verify-image:
	./scripts/verify-image-$(AGENT).sh $(IMAGE)

## verify-kits: static acceptance checks against every agent kit
verify-kits:
	./scripts/verify-kits.sh

## verify-sandbox <agent>: live checks against a running sandbox
verify-sandbox:
	./scripts/verify-sandbox-$(AGENT).sh $(SANDBOX)

## clean: remove the staged kits
clean:
	rm -rf build/kits
