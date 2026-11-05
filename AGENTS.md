# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

`jarvis-engineer` builds Docker sandbox **template images** for running an engineer agent from one
set of content, in two kits: `agent/claude/` for Claude Code and `agent/codex/` for Codex. Both carry an
orchestrator persona plus seven sub-agents — coder, refactorer, reviewer, expert, investigator,
planner, and architect — and an `sbx` kit descriptor (sandbox-kit v3, `agent/<agent>/<kit-name>.yaml`) that provisions the sandbox:
network allowlist, an `ai-memory` MCP server on a persistent volume, a read-only MySQL MCP
server reached on the host, and Microsoft's `postgres-mcp` (read-only by denied tools). The Claude kit adds three specialized reviewers (security, code,
database) that replace `jarvis-reviewer` there; the Codex kit does not have them.

The roles, rules and skills of both kits are generated from `shared/` (see "Source of truth"
below). The design is recorded in `docs/architecture/agent-centralization.md` (ADR) and
`docs/plans/codex-agent-support.md` (plan and spike results).

The Go module (`main.go`) is a separate, much smaller piece: a coder/reviewer iteration loop that
shells out to the `claude` CLI directly (not via `sbx`). See "Known gaps" below — it currently
references files that don't exist in this repo.

## Commands

### Go module

- `go build` — compile
- `go test ./...` — run tests (there are none yet)
- `go vet` — static checks
- `go run main.go <task>` — run the coder/reviewer loop (see Known gaps; not currently functional)

### Docker image / sandbox template (`Makefile`)

Per-agent verbs take the agent as a second goal, `claude` or `codex`; without exactly one the
Makefile stops at parse time with `usage: make <verb> claude|codex`. Bare `make` lists the targets.

- `make build claude|codex` — build `jarvis-engineer:claude` / `jarvis-engineer:codex` (one
  `Dockerfile`, `--target <agent>`)
- `make verify-image claude|codex` — static acceptance checks against the built image
  (`scripts/verify-image-claude.sh` / `scripts/verify-image-codex.sh`)
- `make verify-kits` — acceptance checks against every kit descriptor (`scripts/verify-kits.sh`); it
  stages and builds each kit through `sbx`, so it needs `docker` and `sbx`
- `make sync` — regenerate both kits' content from `shared/` (`scripts/sync-agents.sh`)
- `make verify-sync` — generator tests, then fail if the committed kit content differs from `shared/`
- `make verify-make` — tests for the Makefile's agent dispatch (`scripts/test-make-dispatch.sh`); it
  uses `make -n` and stub `docker`/`sbx`, so it needs neither
- `make verify` — `verify-sync`, `verify-make`, `verify-kits`, then `verify-image` for both agents
- `make template claude|codex` — build + verify the image, then stage the kit and build it into
  `sbx`'s kit cache (`sbx kit inspect`), so a later `make sandbox` with the same sources skips the build
- `make sandbox claude|codex [SANDBOX=name]` — stage the agent's kit into `build/kits/<kit-name>/`
  and (re)create a named sandbox from it (default names `jarvis-engineer` / `jarvis-engineer-codex`),
  reading credentials from `.env`, then run `scripts/verify-sandbox-claude.sh` /
  `scripts/verify-sandbox-codex.sh` against it. It creates the `kit-builder` buildx builder
  (`docker-container` driver) when it is missing
- `make verify-sandbox claude|codex [SANDBOX=name]` — live checks against an already-running sandbox
- `make clean` — remove the staged kits (`build/kits/`)
- `scripts/jarvis-sandbox.sh claude|codex [--name N] [--recreate] [--detach] [--dry-run] [workspace]` —
  the `make sandbox` flow for any other project: stages the kit from this repo, creates
  `jarvis-engineer-<dir>` (`jarvis-engineer-<dir>-codex` for Codex) with the current directory as the
  workspace and attaches. An existing sandbox is re-attached, never replaced, unless `--recreate`. Credentials
  come from this repo's `.env` (or `--env-file` / `$JARVIS_ENV_FILE`). Symlink it onto PATH:
  `ln -s "$PWD/scripts/jarvis-sandbox.sh" ~/.local/bin/jarvis-sandbox` (macOS does not put `~/.local/bin` on
  `PATH`; add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zprofile`)

`sandbox` starts with `sbx rm --force` on the target name, so pass a throwaway `SANDBOX=` to check a
change without replacing a sandbox you work in.

Running the verify scripts directly:

- `./scripts/verify-image-claude.sh [image]` — needs `docker`, `jq`
- `./scripts/verify-image-codex.sh [image]` — needs `docker`
- `./scripts/verify-kits.sh` — needs `docker` and the `sbx` CLI (stages each kit and runs
  `sbx kit validate` / `sbx kit inspect` on it with `BUILDX_BUILDER=kit-builder`)
- `./scripts/stage-kit.sh claude|codex [out-root]` — assemble a kit's build context (default
  `build/kits/`) and print its directory; needs only bash and POSIX tools
- `./scripts/test-stage-kit.sh` — its acceptance tests, same needs
- `./scripts/sync-agents.sh [--check] [--root DIR]` — needs only bash and POSIX tools
- `./scripts/test-sync-agents.sh [filter]` — the generator's acceptance tests, same needs
- `./scripts/test-make-dispatch.sh` — the Makefile dispatch tests, needs only `make` and bash
- `./scripts/verify-sandbox-claude.sh <sandbox-name>` / `./scripts/verify-sandbox-codex.sh <sandbox-name>`
  — need a live `sbx` sandbox and `sbx exec`

`.dockerignore` excludes `scripts/` and then re-includes only the scripts the images install
(`install-agent-skills.sh`, `install-claude-plugins.sh`, `install-mcp-packages.sh`, `restore-claude-plugins.sh`, `jarvis-statusline.sh`,
`trust-codex-hooks.js`); a new script the `Dockerfile` `COPY`s fails the build with "not found" until it
is listed there too. `scripts/stage-kit.sh` reads the same list to decide which scripts go into a
staged kit, so it is the one place to add one. `**/.DS_Store` is excluded because the images `COPY`
the kit homes.

Under Claude Code's macOS Seatbelt sandbox, writes into `agent/claude/files/home/.claude/` are denied, so
`make sync` has to run outside it; the generator exits 2 (it used to report success) when it
cannot write a kit path.

`.env` (git-ignored) holds `MYSQL_HOST`/`MYSQL_PORT`/`MYSQL_USER`/`MYSQL_PASS`. `POSTGRES_MCP_CONNECTION_STRING` (a
`postgresql://` URI with `host.docker.internal` as the host, for a read-only role) enables the
Postgres MCP server; without it that startup step warns and skips. For private Go
modules it can also hold `GOPRIVATE` (and `GONOSUMDB`/`GOFLAGS` if needed) and `GOPRIVATE_GIT_TOKEN`
(a GitHub token); a startup step then registers a git credential helper that reads the token from the
environment, so the token is never written to `~/.gitconfig`. It is only ever
passed with `--env-file .env` at `sbx create` time — never baked into the image or written into a
kit descriptor.

## Architecture

### Image (`Dockerfile`, targets `claude` and `codex`)

One multi-stage `Dockerfile` builds both images. `ARG AGENT` selects the base:
`base-claude` is Docker's published v3 Claude kit `docker.io/docker/sbx-kit-claude:2.1.267` and
`base-codex` its Codex kit `docker.io/docker/sbx-kit-codex:0.155.1`, each pinned by index digest
(sbx refuses unpinned published kits). Both are built on `docker/sandbox-templates:shell-docker`, so
they carry a real nested Docker daemon and the `com.docker.sandboxes.start-docker` label, plus go,
node 22 and the agent CLI (`claude` in `~/.local/bin`, `codex` also under the npm-global prefix), and
set the agent's `ENTRYPOINT`. A recipe built `FROM` a kit does not inherit its descriptor, which is
why each kit descriptor restates the capabilities it still needs (see "Kit" below). The `common` stage is `FROM base-${AGENT}`; the `claude` and `codex` stages are
`FROM common` and add the agent-specific layers. `make build <agent>` passes `--target` and `AGENT`
together, and each final stage fails if the two disagree. `AGENT` defaults to the sentinel
`missing`, whose `base-missing` stage exits 1, so a bare `docker build .` fails rather than guessing
a base (a blank default would make BuildKit warn `InvalidDefaultArgInFrom`). The bases differ, so Docker builds `common` once
per agent: the layers are shared in source, not in cache. The version ARGs
(`AI_MEMORY_VERSION`, `GOLANGCI_LINT_VERSION`) are declared once, in
`common`, and the verify scripts read them from there.

The `common` stage installs, as root:

- a version-pinned `ai-memory` binary (via `mise`, `AI_MEMORY_VERSION`) to `/usr/local/bin/ai-memory`
  — copied rather than symlinked so the path baked into `~/.claude/settings.json` (or
  `~/.codex/hooks.json`) survives a later version bump — plus its hook bundle
- the MCP server packages listed in `config.json` under `mcpServers` (npm specs, pinned with
  `@version` or left on `latest`), installed globally by `scripts/install-mcp-packages.sh` as the
  last step of the stage so a config edit does not rebuild the toolchain layers. The script runs
  `npm install -g --engine-strict` (a package whose `engines.node` the base does not meet fails the
  build) and then asserts each package is on disk. Today: `@benborla29/mcp-server-mysql@2.0.9` and
  `@microsoft/postgres-mcp@0.3.0`. Adding a server here only
  installs it: registering it with the agent is still a startup step in each kit descriptor
- `golangci-lint`
- a C toolchain (`gcc`, `libc6-dev`) with `CGO_ENABLED=1`: Go switches cgo off when it finds no C
  compiler, and `go test -race` needs cgo
- Go tools on `PATH` via `go install`: `govulncheck`, `gotestsum`, `dlv`, `mockgen`, `swag`,
  `goimports`. Their version ARGs are pinned to releases; check a tool's `go.mod` `go` line against the
  base's Go before bumping one
- last, `ENV AI_MEMORY_DATA_DIR=/var/lib/ai-memory`, `GOMODCACHE=/var/lib/go/mod` and
  `GOCACHE=/var/lib/go/cache`: a v3 kit sets its environment in the recipe, and setting them after
  the build steps keeps those steps out of the volume paths

The `claude` stage adds:

- `agent/claude/files/home/` copied into `/home/agent` (uid 1000), first, so the plugin install
  merges its keys into the kit's `settings.json`. A v3 kit has no `files/home` injection; sbx keeps
  the image's home on create, so the image carries the kit content
- `CMD ["--append-system-prompt-file", "/home/agent/ROLE.md"]`, appended to the base's
  `claude --dangerously-skip-permissions` entrypoint (sbx v0.51.0 ignored a lifecycle `interactive`
  tail)

- the Claude Code plugins listed in `config.json`, baked via `scripts/install-claude-plugins.sh`,
  run as the `agent` user (uid 1000) so `installPath` entries in the plugin cache are readable by
  the sandbox's actual runtime user. Each `marketplaces` entry is `owner/repo#<40-hex sha>`: the script
  adds the marketplace, then checks the sha out in its clone before installing (the CLI takes `#ref` only
  as a branch or tag), and the marketplace pins its plugins (external plugin sources carry their own
  `sha`). To upgrade a plugin, bump its marketplace's sha (`git ls-remote <repo> HEAD`) and rebuild
- a snapshot of the two settings keys that install writes (`enabledPlugins`,
  `extraKnownMarketplaces`) in `/usr/local/share/jarvis-engineer/plugin-settings.json`, and
  `scripts/restore-claude-plugins.sh` as `/usr/local/bin/restore-claude-plugins`. Under the v2 kit
  `sbx create` wrote `~/.claude/settings.json` from scratch and every baked plugin came up
  `"enabled": false`. Under v3 the kit's own settings hook merges instead, so the restore step is a
  safety net against the other startup steps that rewrite the file.
- the third-party skills listed in `config.json` under `skills`, baked into `~/.claude/skills` by
  `scripts/install-agent-skills.sh claude-code` (see "Third-party skills" below)
  The snapshot is taken from the resolved settings rather than derived from `config.json`, because
  a marketplace's _name_ comes from its own manifest, not from its repo path
  (`mattpocock/skills` resolves to the marketplace `mattpocock`).
- `scripts/jarvis-statusline.sh` as `/usr/local/bin/jarvis-statusline`. It both renders
  the status line (`ROLE | Model | directory | branch`) and, with `--install`, points
  `~/.claude/settings.json` at itself. `statusLine` is settings-only state, so like the plugin
  keys it is re-registered by a startup step.

Every install is asserted at build time (not just "exit 0"), and again by `verify-image-claude.sh`,
because anything installed by hand inside a sandbox is lost when it is recreated, so "does it
survive a fresh sandbox" is the real bar.

### Codex target

The `codex` stage copies `agent/codex/files/home/` into `/home/agent`, then adds
`scripts/install-agent-skills.sh codex` (third-party skills into `~/.agents/skills`, see below) and
`scripts/trust-codex-hooks.js`, installed as `/usr/local/bin/trust-codex-hooks`, and ends with
`CMD ["--model", "gpt-5.6-terra"]` after the base's `codex --dangerously-bypass-approvals-and-sandbox`
entrypoint. Codex runs a hook only after its exact definition is trusted (a per-handler hash under
`[hooks.state]` in `~/.codex/config.toml`), and the kit's install hook rewrites that file per sandbox. The helper asks the installed
Codex's app-server for the current hashes (`hooks/list`) and trusts only ai-memory's handlers in
`~/.codex/hooks.json` through `config/batchWrite`, the call Codex's own review UI makes. A handler
counts as ai-memory's only if its whole command matches ai-memory's form (a command that merely
starts like it, e.g. with `; ...` appended, is not trusted). No hash is baked in, so upgrades do not
break it silently; any other hook still goes through Codex's review. It lets go of the app-server
after use, so a server that ignores SIGTERM cannot hang sandbox startup. Nothing Claude-specific
(plugins, status line) is built into this target.

### Third-party skills

`config.json`'s `skills` is a list of `skill@source` strings (the shape of `plugin@marketplace`),
e.g. `security-audit@cloudflare/security-audit-skill`. `scripts/install-agent-skills.sh <claude-code|codex>`
runs `npx -y skills add <source> --skill <skill> -g -a <agent> --copy -y` for each entry, as the `agent`
user, in the `claude` and `codex` stages, and then asserts that `<dir>/<skill>/SKILL.md` exists
(`~/.claude/skills` for Claude, `~/.agents/skills` for Codex). Each source is pinned with
`#<sha>` (`security-audit@cloudflare/security-audit-skill#<sha>`; the CLI also takes a tag or branch), so
upgrading a skill means bumping that sha and rebuilding. The `skills` CLI needs Node 22.20 or later. Skills
this repo writes itself belong in `shared/skills/` instead; the two sets never share a name. The baked
`~/.claude/skills` survived `sbx create` in the live Claude check. The Codex kit deliberately does not
restate the published kit's `agent-skills@1`: it mounts the host's shared skills store at
`~/.agents/skills`, which would hide the baked skills.

### Kit (`agent/claude/jarvis-engineer.yaml` + `agent/claude/files/home/`)

The kit is a sandbox-kit v3 workload (`# syntax=docker/sandbox-kit:3`, `schemaVersion: "3"`,
`kind: workload`). sbx v0.51.0 dropped the v2 grammar's `extends: claude` ("is no longer a
built-in agent"), so the kit is no longer a delta on a built-in: its recipe is the repo
`Dockerfile`, built `FROM` the published Claude kit, and its descriptor restates what it still
needs from the published one (marked "from docker/sbx-kit-claude:2.1.267": the network hosts, the
`anthropic` credential, five `~/.claude` volumes, three install and three startup hooks, and the
`agent-context@1` guidance in `agent/claude/claude-context.md`). Re-copy those blocks from
`/usr/share/sandbox/kit/claude/kit.yaml` in the image when the base pin moves. One deliberate
change: the published settings hook replaces `~/.claude/settings.json`; ours merges, so the baked
attribution and plugin keys survive. The orchestrator persona is appended by the image's `Cmd`
(`--append-system-prompt-file /home/agent/ROLE.md`). The ten sub-agents are Claude Code
sub-agents in `files/home/.claude/agents/`, the always-on rules are in `.claude/rules/`, and the
skills in `.claude/skills/`; the image copies `files/home/` into `/home/agent`.

How sbx runs a local v3 kit shapes the layout. It builds the kit itself, from the kit directory as
the whole build context, only with a `docker-container` buildx builder, and a recipe there cannot be
`FROM` a locally built image. So `scripts/stage-kit.sh` assembles `build/kits/jarvis-engineer/`:
the descriptor, the `Dockerfile` plus a final `FROM claude` as `jarvis-engineer.dockerfile`,
`config.json`, the scripts `.dockerignore` re-includes, `agent/claude/files/home/` and the other
files beside the descriptor. The descriptor's `agent` arg passes `AGENT` to the recipe. sbx takes
the agent name from the staged directory's name, and caches a built kit by its source hash. Pass
the kit as the first positional argument of `sbx create`; `--kit` is for mixins only.

Registrations (ai-memory MCP and hooks, plugin restore, status line, MySQL, Postgres) are install
hooks running as `agent`: install hooks finish before the agent first launches, and what they write
under `/home/agent` survives stop/start. Startup keeps only what must run every boot (serve lock,
`ai-memory init`, `ai-memory serve`, the readiness poll, the git credential helper), because the
published kits document startup hooks as fired by a detached dispatcher. Hook rules observed on
sbx v0.51.0 (`docs/plans/sbx-v3-kit-migration.md`, spike results): a failing startup hook stops
every later one, so each step is wrapped to exit 0; hooks see the
`--env-file` values and the image `ENV` whether or not they list them in `env:`, but the spec makes
hook environments deny-by-default, so each step still declares what it reads; the hook `PATH` does
not include `~/.local/bin`.

Review on Claude Code is a fan-out, not one generalist pass. `shared/role/delegation.claude.md`
(appended to `ROLE.md`) tells the orchestrator not to use `jarvis-reviewer`, and carries a shell
probe that picks the reviewers from the diff: `jarvis-security-reviewer` (pinned to `opus`) and
`jarvis-code-reviewer` on every diff that is not docs-only (agent, skill, rule and role markdown
never counts as docs), plus `jarvis-database-reviewer` (preloads `sql-code-review` and
`sql-optimization`) when a changed path or an added or removed line looks like SQL. The probe's
base is the merge-base with the default branch (`origin/HEAD`, then `origin/main`, then
`origin/master`), then with `@{upstream}`, so pushed branch commits are still reviewed; when it
falls back to `HEAD` it says committed changes are not reviewed. The reviewers run in parallel and the
orchestrator merges their findings by owner. The `implement-review-loop` workflow does the same in
JS: a low-effort `general-purpose` agent runs the same probe (base, git's file list, SQL matches),
routing uses git's file list together with the coder's, `parallel()` runs the selected reviewers,
and a round is approved only when every reviewer returns `approved` with no findings (a reviewer
that returns nothing counts as a rejection; a probe that returns nothing runs all three). The
probe text in `delegation.claude.md` and the workflow's `BASE_PROBE`, `SQL_CONTENT_PROBE`,
`SQL_PATH`, `DOCS_PATH` and `INSTRUCTION_PATH` are copies of one rule set: change them together. Its `agentType` values are the frontmatter names (`jarvis-coder`,
`jarvis-security-reviewer`, ...): the workflow resolves them from the Agent tool's registry, which
keys agents by `name`.

Two things about the agent files are worth knowing before editing them:

- `ROLE.md` has no frontmatter: `--append-system-prompt-file` appends it as raw text. The
  frontmatter of `.claude/agents/*.md` is real Claude sub-agent frontmatter (`name`,
  `description`, `model`, `skills`). If you add a `skills:` entry, confirm the skill is actually
  installed by the image.
- Five sub-agents are read-only (`jarvis-reviewer`, `jarvis-investigator`, `jarvis-planner`,
  `jarvis-expert`, `jarvis-architect`) **by prompt only**. The kit grants one unrestricted tool
  set; nothing at the sandbox layer stops those agents from editing files. Treat "read-only" in a
  description as intent, not a guarantee. The three specialized reviewers carry
  `disallowedTools: Write, Edit, NotebookEdit, Agent`, which removes those tools but keeps `Bash`
  (they need `git diff` and tests), so they can still write through a shell.

The kit also ships `files/home/.jarvis-role` (`ENGINEER`), which is the static role label the
status line renders. It is a file rather than an image `ENV` because the `common` stage, and
so its environment, is shared by every kit.
`$JARVIS_ROLE` overrides it; with neither, the line falls back to `AGENT`.

The network allowlist is a base block that every kit must carry (including the Go hosts
`proxy.golang.org`, `sum.golang.org`, `vuln.go.dev`, `go.dev`, `pkg.go.dev`) plus `registry.npmjs.org` /
`registry.yarnpkg.com` and the Docker Hub hosts (image pulls for integration tests) for dependency resolution; `agent/claude/` carries both, in its `network-policy@1` `runtime.allow` list next to the published kit's hosts. `verify-kits.sh` asserts
the base is complete per kit, because the network block sits above the shared block and is
invisible to the drift comparison.

The descriptor carries a block that every Claude-family kit duplicates (this is intentional: a v3
`kind: set` may list only published kit images, so it cannot factor the block into a local shared
kit). The block starts at its `# --- shared ai-memory block` marker; the environment it relies on
is `ENV` in the `Dockerfile`'s `common` stage. The Codex kit carries its own variant of it,
described under "Codex kit" below:

- a `volume@1` at `/var/lib/ai-memory` for `AI_MEMORY_DATA_DIR` (chowned to uid 1000 by an install
  hook, since volumes mount root:root)
- a Go cache volume at `/var/lib/go` (`GOMODCACHE`, `GOCACHE`), chowned the same way, so a recreated
  sandbox keeps downloaded modules and build output
- install hooks, after the published ones (which rewrite `~/.claude.json` and seed
  `~/.claude/settings.json` at create), that run `ai-memory init` and register the ai-memory MCP
  server + hooks; startup hooks that clear a stale serve lock, run `ai-memory init`, and background
  `ai-memory serve` on `127.0.0.1:49374`, polled until it answers before startup continues
- a `restore-claude-plugins` install hook that merges the image's plugin-settings snapshot back into
  `~/.claude/settings.json`. It runs _after_ `install-hooks` so the last writer of that file is not
  the one that could drop the keys, and it is wrapped to always exit 0
- a `jarvis-statusline --install` install hook, after `restore-claude-plugins` for the same
  last-writer reason, and wrapped to always exit 0
- MySQL reached directly at `host.docker.internal:3306` — the MCP server dials it itself, and the
  base allowlist's `host.docker.internal` rule covers it. An earlier revision tunnelled this through
  the sandbox's HTTP CONNECT proxy with `socat` on `127.0.0.1:3306`; that step and its
  `localhost:3306` allowlist rule are gone.
- conditional registration of the read-only `mysql` MCP server (`ALLOW_INSERT/UPDATE/DELETE/DDL_OPERATION=false`),
  which no-ops with a warning (never a hard failure — a failing hook stops every later one) if
  `MYSQL_USER` or the `claude` CLI isn't available
- conditional registration of the `postgres` MCP server, which runs before the MySQL step so MySQL
  stays the last registration step the live verify scripts poll for. postgres-mcp has no documented
  read-only switch for its headless connection (`POSTGRES_MCP_CONNECTION_STRING`; `--access-mode ro`
  exists only for keyring-saved profiles, and the sandbox has no keyring), so the Claude kit merges
  `mcp__postgres__postgres_mcp_{modify,bulk_load_csv,add_connection}` into
  `~/.claude/settings.json` `permissions.deny`, and the Codex kit lists the same tools in
  `disabled_tools`. The connection string carries the password: inherited from the sandbox
  environment (Codex: `env_vars` by name), never `-e`. Use a read-only database role as well; the
  tool denial is a second control, not the only one. `run --no-telemetry` because the sandbox has no
  route for it. The tool names and Codex's `disabled_tools` support are from the docs, not yet seen
  live: `verify-sandbox-*.sh` checks the config, not that the tools are actually gone.

`scripts/verify-kits.sh` finds every kit by its v3 descriptor under `agent/*/` and keys its cases on
the directory (the family: `claude` or `codex`). It diffs this shared block within a family, so
drift between copies fails CI-style rather than silently diverging; with one kit per family that
comparison is vacuous for now. Across families it compares only what must match: the volumes, the
serve bind address, the readiness text and the chown steps.

### Codex kit (`agent/codex/jarvis-engineer-codex.yaml` + `agent/codex/files/home/`)

A v3 workload built the same way, `FROM` the published Codex kit, staged into
`build/kits/jarvis-engineer-codex/`. It restates the published kit's network hosts (OpenAI and
ChatGPT), its `openai` credential, its install hook and two startup hooks, and its legacy
`AGENTS.md` agent-context profile (which lands beside the workspace, not in `~/.codex`). It does not
restate `agent-skills@1` (see "Third-party skills"). The published entrypoint is already
`codex --dangerously-bypass-approvals-and-sandbox` and the image's `Cmd` is appended to it, so the
recipe adds only `--model gpt-5.6-terra` (Codex's default model is rejected for ChatGPT-account
logins). Do not repeat the bypass flag in `Cmd`. The install hook writes `~/.codex/config.toml`
at creation (`model_provider = "sandboxd"` in OAuth mode) and a startup hook appends the MCP
gateway, so every later startup step merges into that file rather than replacing it.

Generated content Codex reads: `~/.codex/AGENTS.md` (global instructions: role core, Codex
delegation fragment, rules index), `~/.codex/agents/<name>.toml` (sub-agents),
`~/.agents/skills/` (skills), and `~/.jarvis/rules/*.md` (rules the orchestrator reads on demand;
not `~/.codex/rules`, which Codex uses for exec policy). `files/home/.jarvis-role` is hand-owned and
only presence-checked; Codex has no status line.

Install hooks, after the published one: the volume chowns, `ai-memory init`,
`install-mcp --client codex`, `install-hooks --agent codex`, `trust-codex-hooks` (warns, exits 0),
Postgres and MySQL. Startup hooks: clear the serve lock, `ai-memory init`, background `serve`, the
readiness poll, and the git credential helper. The MySQL step appends a `[mcp_servers.mysql]` table to `config.toml`
directly, because `codex mcp add` can only set values: Codex passes no environment to stdio MCP
servers by default, and `env_vars = ["MYSQL_USER", "MYSQL_PASS"]` forwards the credentials by
name, so no credential value is ever written into the config. `codex exec` launched from `sbx exec`
waits on stdin forever unless it gets `</dev/null`.

### Source of truth (`shared/`)

`shared/` is the hand-edited source for both kits' content; `scripts/sync-agents.sh` generates
`agent/claude/files/home/{ROLE.md,.claude/agents,.claude/rules,.claude/skills}` and
`agent/codex/files/home/{.codex/AGENTS.md,.codex/agents,.agents/skills,.jarvis/rules}` from it.
Those paths are generated and committed — never hand-edit them. Edit `shared/`, run `make sync`,
and commit both. CI runs `sync-agents.sh --check`, which regenerates into a temp dir and fails on
any extra, missing or changed file in the owned paths. Everything else in a kit (the descriptor,
`claude-context.md`, `.jarvis-role`, `.claude/settings.json`, `.claude/workflows/`) is hand-owned
and never touched.

The repo `.gitignore` negates `/agent/codex/files/home/.agents/`: a user-global ignore of `.agents`
would otherwise keep the generated Codex skills out of the commit and fail `--check` in CI.

- `shared/role/ROLE.md` (target-neutral core) + `shared/role/delegation.claude.md` are
  concatenated, with one blank line between them, into `ROLE.md`.
- `shared/role/ROLE.md` + `shared/role/delegation.codex.md` + a generated rules index (name, first
  `# ` heading, `/home/agent/.jarvis/rules/<name>.md`) → Codex `.codex/AGENTS.md`, which must stay
  within 16 KiB (Codex reads it together with the workspace's own `AGENTS.md`).
- `shared/agents/<role>.md` → `.claude/agents/<role>.md` and `.codex/agents/<name>.toml`.
  Frontmatter is a flat subset only (`key: value`, no nesting, no block scalars) with an allowlist:
  `name`, `description` (required), `rules` (bare rule names; dropped for Claude, which loads every
  rule; inlined for Codex), `claude.model`, `claude.skills`, `claude.disallowedTools` (Claude
  `model:` / `skills:` / `disallowedTools:`), `codex.model_reasoning_effort` (Codex only), and
  `targets: claude` (generator metadata, never emitted: the agent gets its Claude file and no Codex
  TOML; `claude` is the only accepted value). Names are unique across all agents whatever their
  targets. `codex.sandbox_mode` is deliberately not allowed:
  the spike showed Codex does not enforce it per agent under sbx. Anything else is rejected, as are
  quoted values for keys that reach Codex, control characters, duplicate names, and names outside
  `[a-z0-9-]` (the name is the TOML file stem). Neutral sources (`agents/*.md`, `role/ROLE.md`)
  must not mention `.claude/` or `subagent_type`; that includes `targets: claude` agents, so a later
  Codex port needs no body edits.
- Codex TOML: `name`, `description`, the `codex.*` keys, and `developer_instructions` = the body
  plus each declared rule (frontmatter stripped) in declared order, one blank line between parts,
  as a multi-line basic string with `\` and `"""` escaped.
- `shared/rules/*.md` → `.claude/rules/` with a leading frontmatter block (e.g. `golang-idioms.md`'s
  `paths:`) passed through untouched, and → Codex `.jarvis/rules/` with it stripped. Every rule
  needs a `# ` heading for the index.
- `shared/skills/<name>/` → `.claude/skills/<name>/` and `.agents/skills/<name>/`, byte for byte;
  `SKILL.md` may use only `name` and `description`.
- Each generated file except the skills carries a `GENERATED by scripts/sync-agents.sh` marker (a
  `#` comment on line 1 of a TOML file; an HTML comment after the frontmatter when there is one,
  otherwise on line 1). Claude bodies are copied byte-exact; several sources end without a newline
  and must stay that way.

Both scripts must run on macOS bash 3.2 and BSD tools as well as Linux: no `mapfile`, associative
arrays or `${v,,}`; POSIX awk only (no gawk extensions, no `{n}` intervals, no `\s`); no `sed -i`,
no `readlink -f`, no GNU `diff` format flags; `mktemp -d "${TMPDIR:-/tmp}/name.XXXXXX"`.

### Verification tiers

Three tiers, three different things they can prove (each has a Claude and a Codex script where
the targets differ):

1. `verify-image-claude.sh` — runs `docker run` against the built image as uid 1000; asserts tool
   presence, correct baked paths, and that every plugin in `config.json` is installed _and_
   enabled (a plugin can be on disk but not loaded, or installed under the wrong uid and
   unreadable — both pass a naive check and fail this one). `verify-image-codex.sh` does the
   same for the Codex image, plus `trust-codex-hooks` against Codex's own app-server (ai-memory's
   six hooks go from untrusted to trusted, a foreign hook stays untrusted). Both read the tool
   version pins from the one `Dockerfile`.
2. `verify-kits.sh` — stages each kit and builds it through sbx (`sbx kit validate`, then
   `sbx kit inspect`, which reports the binary, the launch argv and the hook counts), so the built
   kit is asserted, not just its syntax. Also asserts the base network allowlist, the pinned base
   digests, the restated published capabilities, that each hook declares the variables it reads,
   that no registration runs at startup (those are install hooks),
   that no credential value is written into a descriptor or the `Dockerfile`, the shared-block
   drift check, and that the generated kit content matches `shared/` (`sync-agents.sh --check`).
3. `verify-sandbox-claude.sh` — live checks against a running sandbox (`sbx exec ... `), for the things
   only observable at runtime: whether the MySQL tunnel actually reaches a real MySQL server (not
   just a stub), whether plugin/MCP/`statusLine` state survives the startup steps rewriting
   `~/.claude/settings.json`, whether nested Docker actually comes up, whether the agent process
   carries the persona flag (read while a TTY session is attached under `script`), and whether a
   stop/start leaves exactly one ai-memory server. `verify-sandbox-codex.sh`
   covers the Codex sandbox: generated content in place byte for byte, both MCP servers listed by
   `codex mcp list`, credentials forwarded by name only, sbx's model provider kept, and Codex
   reporting every ai-memory hook trusted, plus the same launch-argv and restart cases. Neither
   makes a model call; for Codex, confirm once by
   hand (`sbx exec <name> -- sh -c 'codex exec --dangerously-bypass-approvals-and-sandbox
   --skip-git-repo-check -m gpt-5.6-terra "Quote line 2 of your global AGENTS.md, then ask
   jarvis-coder to reply OK" </dev/null'`).

## Known gaps

- `main.go` invokes `claude --append-system-prompt-file roles/CODER.md` / `roles/REVIEWER.md`, but
  there is no `roles/` directory in this repo — the closest equivalents are now
  `shared/agents/coder.md` and `shared/agents/reviewer.md`. `go run main.go` will fail until this
  is reconciled.
- The five read-only sub-agents are prompt-enforced only; see the note under "Kit" above. If the
  `sbx` spec schema grows tool allow/deny support, they should be denied `Edit`/`Write`. The same
  holds on Codex: a sub-agent with `sandbox_mode = "read-only"` still wrote files in the spike.
  The three specialized reviewers deny `Edit`/`Write` through `disallowedTools`, but `Bash` can
  still write (`sed -i`, redirects); closing that needs a PreToolUse hook, which the flat
  frontmatter allowlist cannot express.
- The specialized reviewers are Claude-only (`targets: claude`). Codex still has the single
  `jarvis-reviewer`, and `jarvis-reviewer`'s description still mentions security, so Claude's
  auto-delegation could pick it; only the instruction in `ROLE.md` steers away from it. Whether
  the built-in `security-review` is reachable through the Skill tool inside a sub-agent is
  unverified, and it reviews only `origin/HEAD...`; the security reviewer therefore always runs its
  own checklist on `git diff <base>` plus untracked files and treats `security-review` as an
  optional extra pass.
- The Codex kit has no plugins, no status line and no workflows (`.claude/workflows/` is not
  ported). `trust-codex-hooks` depends on the app-server's `hooks/list` and `config/batchWrite`
  methods; a Codex release that renames them turns memory capture off (the step warns) and turns
  `verify-image-codex.sh` red.
- `gpt-5.6-terra` in the `Dockerfile`'s `codex` stage `CMD` is what the current ChatGPT account
  accepts, not a property of the kit; change it there if the account or Codex's model list changes.
- The restated published capabilities are copies. Bumping a base pin in the `Dockerfile` without
  re-copying them from the new image's `/usr/share/sandbox/kit/<agent>/kit.yaml` (and
  `claude-context.md`) leaves the kit on the old hosts and hooks; nothing checks them against the
  image.
- Hook environments are not yet deny-by-default under sbx v0.51.0 (hooks saw undeclared variables),
  so a missing `env:` entry passes every live check today. `verify-kits.sh` checks the declarations
  statically.
- `sbx kit add` cannot add mixins to a v3 sandbox (Docker's "Use kits" docs); change the kit and
  recreate instead.
- The image `verify-image-*.sh` checks is not the one a sandbox runs. `make build` builds it with
  the local `docker` driver; sbx builds the staged kit again in `kit-builder`, with its own cache,
  and does not hand that image to the local daemon. Every input is pinned now, so the two
  builds should resolve the same versions. `verify-sandbox-*.sh` checks the sandbox's own image only
  for what it asserts live.
