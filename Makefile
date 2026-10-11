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

# Per-agent facts: the kit directory and the default sandbox name.
KIT_claude     := agent/claude
KIT_codex      := agent/codex
SANDBOX_claude := jarvis-engineer
SANDBOX_codex  := jarvis-engineer-codex

IMAGE   := jarvis-engineer:$(AGENT)
TARBALL := $(CURDIR)/jarvis-engineer-$(AGENT).tar
KIT     ?= $(KIT_$(AGENT))
SANDBOX ?= $(SANDBOX_$(AGENT))

.PHONY: help claude codex build template verify-image sandbox verify-sandbox sync verify verify-sync verify-make verify-kits clean

## help: list the targets
help:
	@sed -n 's/^## //p' $(MAKEFILE_LIST)

claude codex:
	@:

## build <agent>: build the sandbox template image jarvis-engineer:<agent>
build:
	docker build --target $(AGENT) --build-arg AGENT=$(AGENT) -t $(IMAGE) .

## template <agent>: load the built image into sbx as a reusable template
template: build verify-image
	docker image save $(IMAGE) -o $(TARBALL)
	sbx template load $(TARBALL)
	rm -f $(TARBALL)

## sandbox <agent>: (re)create SANDBOX from the agent's kit with credentials from .env
#
# --env-file is required: MYSQL_USER/MYSQL_PASS are read from the sandbox
# environment by the MySQL MCP server, and are never written into any config.
# A kind:sandbox kit registers under its spec `name:`, not its directory name,
# and that is the agent argument `sbx create` expects.
KIT_SPEC_NAME = $(shell awk '/^name:/ {print $$2; exit}' $(KIT)/spec.yaml)

sandbox:
	-sbx rm --force $(SANDBOX)
	sbx create --name $(SANDBOX) --env-file .env --kit $(KIT) $(KIT_SPEC_NAME) .
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

## verify-kits: static acceptance checks against every agent/*/spec.yaml
verify-kits:
	./scripts/verify-kits.sh

## verify-sandbox <agent>: live checks against a running sandbox
verify-sandbox:
	./scripts/verify-sandbox-$(AGENT).sh $(SANDBOX)

## clean: remove the build tarballs
clean:
	rm -f $(foreach agent,$(AGENTS),$(CURDIR)/jarvis-engineer-$(agent).tar)
