# One Dockerfile for both agents' sandbox templates. Build with
# `make build claude|codex`, which passes --target and AGENT together.
#
# `common` holds what both images install; `claude` and `codex` add what only
# one of them needs. The two bases differ, so Docker builds `common` once per
# agent: what is shared is the source of those layers, not their cache.
#
# AGENT defaults to `missing` rather than to an agent: a build that forgets it
# lands on the base-missing stage below and fails there, instead of silently
# building on the wrong base. A blank default would do the same but makes
# BuildKit warn InvalidDefaultArgInFrom on every build.
ARG AGENT=missing

# The `-docker` flavour of each base template is the supported way to give an
# agent a working Docker Engine: it ships dockerd/containerd, puts the agent in
# the `docker` group, and carries the `com.docker.sandboxes.start-docker=true`
# label that makes sbx run the sandbox privileged and launch dockerd itself
# (logging to /var/log/dockerd.log) before the agent starts. The plain
# `claude-code` flavour has the docker CLI but no daemon, so every docker
# command fails with "dial unix /var/run/docker.sock: no such file".
#
# The daemon is nested inside the sandbox -- it is not the host's. Nothing here
# exposes the host socket, and images/containers the agent creates live and die
# with the sandbox.
#
# The codex base already carries node, npm and the codex CLI under
# /usr/local/share/npm-global (spike S10).
FROM docker/sandbox-templates:claude-code-docker AS base-claude
FROM docker/sandbox-templates:codex-docker AS base-codex

FROM base-claude AS base-missing
# The classic builder (DOCKER_BUILDKIT=0) builds every stage up to --target,
# so this must fail only when AGENT really was not passed.
ARG AGENT
RUN test "${AGENT}" != missing \
  || { echo "AGENT build arg is required; use: make build claude|codex" >&2; exit 1; }

FROM base-${AGENT} AS common

USER root

# Pin the release so template rebuilds are reproducible. Bump deliberately.
ARG AI_MEMORY_VERSION=3.1.0

# golangci-lint v2 understands the repository's version: "2" configuration
# format. Its installer selects the appropriate pre-built binary for the image
# architecture, which keeps both amd64 and arm64 templates supported.
ARG GOLANGCI_LINT_VERSION=2.13.2

# Go tooling installed with `go install`. `latest` because the versions could
# not be resolved when these were added; pin each to a release (build with
# --build-arg, or edit here) to make rebuilds reproducible.
ARG GOVULNCHECK_VERSION=latest
ARG GOTESTSUM_VERSION=latest
ARG DELVE_VERSION=latest
ARG MOCKGEN_VERSION=latest
ARG SWAG_VERSION=latest
ARG GOIMPORTS_VERSION=latest

# mise is a build-time tool only: it resolves the correct release asset for the
# target architecture (these base images are amd64 + arm64) and verifies the
# published .sha256. Redirect it out of $HOME -- /root is mode 0700, so anything
# installed there is unreachable by the agent user the sandbox actually runs as.
ENV MISE_INSTALL_PATH=/usr/local/bin/mise \
  MISE_DATA_DIR=/opt/mise \
  MISE_CONFIG_DIR=/opt/mise \
  MISE_YES=1

RUN curl -fsSL https://mise.run/bash | sh

# Expose ai-memory on the image's existing PATH and drop its bundled hooks at
# the path `install-hooks --hooks-dir` already defaults to, so the kit's startup
# steps need no extra flags.
# The binary is copied rather than symlinked on purpose: `install-hooks` resolves
# its own executable through any symlink and writes that absolute path into
# ~/.claude/settings.json (or ~/.codex/hooks.json). Symlinking would bake the
# version-pinned mise path ("/opt/mise/installs/.../3.1.0/ai-memory") into the
# agent's hook config, which breaks the moment AI_MEMORY_VERSION is bumped.
RUN mise use -g "github:akitaonrails/ai-memory@${AI_MEMORY_VERSION}" \
  && src="$(mise where "github:akitaonrails/ai-memory@${AI_MEMORY_VERSION}")" \
  && install -m 0755 "$src/ai-memory" /usr/local/bin/ai-memory \
  && mkdir -p /usr/local/share/ai-memory \
  && cp -R "$src/hooks" /usr/local/share/ai-memory/hooks \
  && chmod -R a+rX /usr/local/share/ai-memory/hooks

RUN curl -sSfL https://golangci-lint.run/install.sh \
  | sh -s -- -b /usr/local/bin "v${GOLANGCI_LINT_VERSION}"

# A C toolchain for Go's cgo. Go turns cgo off when it finds no C compiler on
# PATH, and `go test -race` needs cgo, so without gcc the race detector cannot
# run and the agent reports "-race didn't run because the sandbox has cgo
# disabled". CGO_ENABLED=1 makes a missing compiler a loud build error rather
# than a silent fallback to cgo off.
RUN apt-get update \
  && apt-get install -y --no-install-recommends gcc libc6-dev \
  && rm -rf /var/lib/apt/lists/*
ENV CGO_ENABLED=1

# Go tools the rules and reviewers call: govulncheck (security review), gotestsum,
# dlv, mockgen, swag (Swagger annotations) and goimports. GOBIN puts them on the
# image PATH; the temporary GOPATH/GOMODCACHE keeps the module cache out of the
# image layer.
RUN GOBIN=/usr/local/bin GOPATH=/tmp/gotools GOMODCACHE=/tmp/gotools/mod GOFLAGS=-mod=mod \
  sh -c ' \
  go install "golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}" \
  && go install "gotest.tools/gotestsum@${GOTESTSUM_VERSION}" \
  && go install "github.com/go-delve/delve/cmd/dlv@${DELVE_VERSION}" \
  && go install "go.uber.org/mock/mockgen@${MOCKGEN_VERSION}" \
  && go install "github.com/swaggo/swag/cmd/swag@${SWAG_VERSION}" \
  && go install "golang.org/x/tools/cmd/goimports@${GOIMPORTS_VERSION}"' \
  && rm -rf /tmp/gotools

# Fail the build rather than ship an image whose tools the agent cannot reach.
RUN su agent -s /bin/sh -c 'ai-memory --version' | grep -q "ai-memory ${AI_MEMORY_VERSION}" \
  && golangci-lint version | grep -q "version ${GOLANGCI_LINT_VERSION}" \
  && su agent -s /bin/sh -c 'command -v gcc && go env CGO_ENABLED' | grep -qx 1 \
  && su agent -s /bin/sh -c 'for t in govulncheck gotestsum dlv mockgen swag goimports; do command -v "$t" >/dev/null || exit 1; done' \
  && command -v dockerd >/dev/null \
  && id -nG agent | grep -qw docker

# Install the MCP servers listed in config.json. Last in this stage on purpose:
# editing the file invalidates the layers after the COPY, so keeping them at the
# end means a config change reinstalls only these packages, not the toolchain
# above. Globally, so `npx -y` in a kit's startup step resolves them without a
# registry round trip at sandbox start. The script fails the build on a package
# that did not install or whose `engines.node` the base image does not meet.
# config.json is kept in the image: the Claude stage reads its plugin list from
# the same file.
COPY config.json /usr/local/share/jarvis-engineer/config.json
COPY scripts/install-mcp-packages.sh /usr/local/bin/install-mcp-packages
RUN chmod 0644 /usr/local/share/jarvis-engineer/config.json \
  && chmod 0755 /usr/local/bin/install-mcp-packages \
  && install-mcp-packages


FROM common AS claude

# The target and AGENT must agree: `common` was built on base-${AGENT}, so
# `--target claude` with AGENT=codex would put Claude layers on the Codex base.
ARG AGENT
RUN test "${AGENT}" = claude \
  || { echo "target claude needs --build-arg AGENT=claude (got '${AGENT}'); use: make build claude" >&2; exit 1; }

# Bake the Claude Code plugins into the template. A sandbox gets a fresh
# ~/.claude, so plugins installed by hand are gone the next time one is created
# -- baking them is the only way the skills are there on first prompt.
#
# The list lives in config.json so changing it needs no build flags and no edit
# here. Editing that file invalidates this layer, so a plain `make build claude`
# picks the change up; a rebuild with an unchanged config reuses the cached
# layer and keeps the plugin versions it resolved the first time. There is no
# version pin to bump the way AI_MEMORY_VERSION is -- the plugin CLI always
# takes the marketplace's current tip -- so use `docker build --no-cache-filter`
# on this stage to pull in new releases.
#
# Both files are kept in the image rather than removed after the build: together
# they are how an agent adds a plugin to, or repairs, its own running sandbox.
COPY scripts/install-claude-plugins.sh /usr/local/bin/install-claude-plugins
COPY scripts/restore-claude-plugins.sh /usr/local/bin/restore-claude-plugins

# The status line renderer, and the one-shot that registers it. It has to be
# installed here rather than shipped in a kit's files/: `sbx create` recreates
# ~/.claude, so the registration re-runs per sandbox and the script it points at
# must sit outside $HOME to survive that.
COPY scripts/jarvis-statusline.sh /usr/local/bin/jarvis-statusline

# Runs as the agent, not root: `plugin install` records absolute installPaths in
# ~/.claude/plugins/installed_plugins.json, so installing as root would bake
# /root paths that uid 1000 cannot read -- the same trap mise fell into above.
# `su` alone does not set HOME, so it is passed explicitly.
RUN chmod 0755 /usr/local/bin/install-claude-plugins \
  && chmod 0755 /usr/local/bin/restore-claude-plugins \
  && chmod 0755 /usr/local/bin/jarvis-statusline \
  && su agent -s /bin/sh -c "HOME=/home/agent install-claude-plugins"

# Snapshot the two settings keys the install just wrote. `sbx create` recreates
# ~/.claude/settings.json from scratch, so those keys never reach a sandbox --
# the cache survives but every plugin comes up disabled. The kits' startup steps
# merge this snapshot back with `restore-claude-plugins`, which is why it has to
# live outside $HOME: everything under it is per-sandbox state.
#
# Snapshotted rather than derived from config.json: a marketplace's name comes
# from its own manifest, not its repo path, so only the resolved settings say
# which name each plugin id refers to.
RUN node -e ' \
  const fs = require("fs"); \
  const s = JSON.parse(fs.readFileSync("/home/agent/.claude/settings.json", "utf8")); \
  const keys = ["enabledPlugins", "extraKnownMarketplaces"]; \
  for (const k of keys) { \
  if (!s[k] || Object.keys(s[k]).length === 0) { \
  console.error(`plugin install left ${k} empty`); \
  process.exit(1); \
  } \
  } \
  const out = {}; \
  for (const k of keys) out[k] = s[k]; \
  fs.writeFileSync("/usr/local/share/jarvis-engineer/plugin-settings.json", \
  JSON.stringify(out, null, 2) + "\n"); \
  ' \
  && chmod 0644 /usr/local/share/jarvis-engineer/plugin-settings.json

# Fail the build rather than ship an image whose Claude-only pieces do not work.
RUN su agent -s /bin/sh -c 'test -x /usr/local/share/ai-memory/hooks/claude-code/session-start.sh' \
  && su agent -s /bin/sh -c 'HOME=/home/agent /home/agent/.local/bin/claude plugin list --json' \
  | grep -q '"enabled": true' \
  && su agent -s /bin/sh -c 'HOME=/home/agent restore-claude-plugins' \
  && su agent -s /bin/sh -c 'HOME=/home/agent JARVIS_ROLE=CODER jarvis-statusline </dev/null' \
  | grep -q '^CODER | ' \
  && ! su agent -s /bin/sh -c 'HOME=/home/agent /home/agent/.local/bin/claude plugin list --json' \
  | grep -q '"enabled": false'

USER agent


FROM common AS codex

# See the claude stage: the target and AGENT must agree.
ARG AGENT
RUN test "${AGENT}" = codex \
  || { echo "target codex needs --build-arg AGENT=codex (got '${AGENT}'); use: make build codex" >&2; exit 1; }

# Re-trusts ai-memory's hooks on every sandbox start (Codex runs untrusted
# hooks not at all, and sbx recreates ~/.codex). Outside $HOME for the same
# reason: everything under it is per-sandbox state.
COPY scripts/trust-codex-hooks.js /usr/local/bin/trust-codex-hooks
RUN chmod 0755 /usr/local/bin/trust-codex-hooks

# Fail the build rather than ship an image whose Codex-only pieces do not work.
RUN su agent -s /bin/sh -c 'test -x /usr/local/share/ai-memory/hooks/codex/session-start.sh' \
  && su agent -s /bin/sh -c '/usr/local/share/npm-global/bin/codex --version' \
  && su agent -s /bin/sh -c 'command -v trust-codex-hooks'

USER agent
