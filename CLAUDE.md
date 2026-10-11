# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

`jarvis-engineer` builds Docker sandbox **template images** for running an engineer agent from one
set of content, in two kits: `agent/claude/` for Claude Code and `agent/codex/` for Codex. Both carry an
orchestrator persona plus seven sub-agents — coder, refactorer, reviewer, expert, investigator,
planner, and architect — and an `sbx` sandbox spec (`spec.yaml`) that provisions the sandbox:
network allowlist, an `ai-memory` MCP server on a persistent volume, and a read-only MySQL MCP
server reached on the host. The Claude kit adds three specialized reviewers (security, code,
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
- `make verify-kits` — static acceptance checks against every `agent/*/spec.yaml` (`scripts/verify-kits.sh`)
- `make sync` — regenerate both kits' content from `shared/` (`scripts/sync-agents.sh`)
- `make verify-sync` — generator tests, then fail if the committed kit content differs from `shared/`
- `make verify-make` — tests for the Makefile's agent dispatch (`scripts/test-make-dispatch.sh`); it
  uses `make -n` and stub `docker`/`sbx`, so it needs neither
- `make verify` — `verify-sync`, `verify-make`, `verify-kits`, then `verify-image` for both agents
- `make template claude|codex` — build + verify the image, then save/load it into `sbx` as a
  reusable template
- `make sandbox claude|codex [SANDBOX=name]` — (re)create a named sandbox from the agent's kit
  (`agent/claude/` or `agent/codex/`; default names `jarvis-engineer` / `jarvis-engineer-codex`), reading
  MySQL credentials from `.env`, then run `scripts/verify-sandbox-claude.sh` /
  `scripts/verify-sandbox-codex.sh` against it
- `make verify-sandbox claude|codex [SANDBOX=name]` — live checks against an already-running sandbox
- `make clean` — remove the build tarballs

`sandbox` starts with `sbx rm --force` on the target name, so pass a throwaway `SANDBOX=` to check a
change without replacing a sandbox you work in.

Running the verify scripts directly:

- `./scripts/verify-image-claude.sh [image]` — needs `docker`, `jq`
- `./scripts/verify-image-codex.sh [image]` — needs `docker`
- `./scripts/verify-kits.sh` — needs the `sbx` CLI (runs `sbx kit validate` / `sbx kit inspect` per kit)
- `./scripts/sync-agents.sh [--check] [--root DIR]` — needs only bash and POSIX tools
- `./scripts/test-sync-agents.sh [filter]` — the generator's acceptance tests, same needs
- `./scripts/test-make-dispatch.sh` — the Makefile dispatch tests, needs only `make` and bash
- `./scripts/verify-sandbox-claude.sh <sandbox-name>` / `./scripts/verify-sandbox-codex.sh <sandbox-name>`
  — need a live `sbx` sandbox and `sbx exec`

`.dockerignore` excludes `scripts/` and then re-includes only the scripts the images install
(`install-claude-plugins.sh`, `restore-claude-plugins.sh`, `jarvis-statusline.sh`,
`trust-codex-hooks.js`); a new script the `Dockerfile` `COPY`s fails the build with "not found" until it
is listed there too.

Under Claude Code's macOS Seatbelt sandbox, writes into `agent/claude/files/home/.claude/` are denied, so
`make sync` has to run outside it; the generator exits 2 (it used to report success) when it
cannot write a kit path.

`.env` (git-ignored) holds `MYSQL_HOST`/`MYSQL_PORT`/`MYSQL_USER`/`MYSQL_PASS` and is only ever
passed with `--env-file .env` at `sbx create` time — never baked into the image or written into a
kit spec.

## Architecture

### Image (`Dockerfile`, targets `claude` and `codex`)

One multi-stage `Dockerfile` builds both images. `ARG AGENT` selects the base:
`base-claude` is `docker/sandbox-templates:claude-code-docker` (a real nested Docker daemon, not just
the CLI), `base-codex` is `docker/sandbox-templates:codex-docker` (node, npm and the `codex` CLI
already installed). The `common` stage is `FROM base-${AGENT}`; the `claude` and `codex` stages are
`FROM common` and add the agent-specific layers. `make build <agent>` passes `--target` and `AGENT`
together, and each final stage fails if the two disagree. `AGENT` has no default, so a bare
`docker build .` fails rather than guessing a base. The bases differ, so Docker builds `common` once
per agent: the layers are shared in source, not in cache. The version ARGs
(`AI_MEMORY_VERSION`, `GOLANGCI_LINT_VERSION`, `MCP_SERVER_MYSQL_VERSION`) are declared once, in
`common`, and the verify scripts read them from there.

The `common` stage installs, as root:

- a version-pinned `ai-memory` binary (via `mise`, `AI_MEMORY_VERSION`) to `/usr/local/bin/ai-memory`
  — copied rather than symlinked so the path baked into `~/.claude/settings.json` (or
  `~/.codex/hooks.json`) survives a later version bump — plus its hook bundle
- `@benborla29/mcp-server-mysql` globally
- `golangci-lint`

The `claude` stage adds:

- the Claude Code plugins listed in `config.json`, baked via `scripts/install-claude-plugins.sh`,
  run as the `agent` user (uid 1000) so `installPath` entries in the plugin cache are readable by
  the sandbox's actual runtime user
- a snapshot of the two settings keys that install writes (`enabledPlugins`,
  `extraKnownMarketplaces`) in `/usr/local/share/jarvis-engineer/plugin-settings.json`, and
  `scripts/restore-claude-plugins.sh` as `/usr/local/bin/restore-claude-plugins`. This
  exists because `sbx create` writes `~/.claude/settings.json` from scratch (permissions, model):
  the plugin _cache_ under `~/.claude/plugins` survives from the image, but the settings keys that
  load it do not, so without the restore step every baked plugin comes up `"enabled": false`.
  The snapshot is taken from the resolved settings rather than derived from `config.json`, because
  a marketplace's _name_ comes from its own manifest, not from its repo path
  (`mattpocock/skills` resolves to the marketplace `mattpocock`).
- `scripts/jarvis-statusline.sh` as `/usr/local/bin/jarvis-statusline`. It both renders
  the status line (`ROLE | Model | directory | branch`) and, with `--install`, points
  `~/.claude/settings.json` at itself. `statusLine` is settings-only state, so like the plugin
  keys it is lost on every `sbx create` and has to be re-registered by a startup step; the script
  it points at must therefore live outside `$HOME`.

Every install is asserted at build time (not just "exit 0"), and again by `verify-image-claude.sh`,
because a sandbox's `~/.claude` is recreated fresh on every `sbx create` — anything installed by
hand outside the image is lost, so "does it survive a fresh sandbox" is the real bar.

### Codex target

The `codex` stage adds only `scripts/trust-codex-hooks.js`, installed as
`/usr/local/bin/trust-codex-hooks`. Codex runs
a hook only after its exact definition is trusted (a per-handler hash under `[hooks.state]` in
`~/.codex/config.toml`), and sbx recreates `~/.codex` per sandbox. The helper asks the installed
Codex's app-server for the current hashes (`hooks/list`) and trusts only ai-memory's handlers in
`~/.codex/hooks.json` through `config/batchWrite`, the call Codex's own review UI makes. A handler
counts as ai-memory's only if its whole command matches ai-memory's form (a command that merely
starts like it, e.g. with `; ...` appended, is not trusted). No hash is baked in, so upgrades do not
break it silently; any other hook still goes through Codex's review. It lets go of the app-server
after use, so a server that ignores SIGTERM cannot hang sandbox startup. Nothing Claude-specific
(plugins, status line) is built into this target.

### Kit (`agent/claude/spec.yaml` + `agent/claude/files/home/`)

The kit extends the built-in `claude` sandbox, points `sandbox.image` at
`jarvis-engineer:claude`, and appends the orchestrator persona as the system prompt
(`--append-system-prompt-file /home/agent/ROLE.md`). The ten sub-agents are Claude Code
sub-agents in `files/home/.claude/agents/`, the always-on rules are in `.claude/rules/`, and the
skills in `.claude/skills/`.

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
  `jarvis-expert`, `jarvis-architect`) **by prompt only**. The spec grants one unrestricted tool
  set; nothing at the sandbox layer stops those agents from editing files. Treat "read-only" in a
  description as intent, not a guarantee. The three specialized reviewers carry
  `disallowedTools: Write, Edit, NotebookEdit, Agent`, which removes those tools but keeps `Bash`
  (they need `git diff` and tests), so they can still write through a shell.

The kit also ships `files/home/.jarvis-role` (`ENGINEER`), which is the static role label the
status line renders. It is a file rather than an `environment.variables` entry because
`verify-kits.sh` byte-compares that block across the kits of a family, so a per-kit value there
reads as drift.
`$JARVIS_ROLE` overrides it; with neither, the line falls back to `AGENT`.

The network allowlist is a base block that every kit must carry plus `registry.npmjs.org` /
`registry.yarnpkg.com` for dependency resolution; `agent/claude/` carries both. `verify-kits.sh` asserts
the base is complete per kit, because the `permissions:` block sits above the shared block and is
invisible to the drift comparison.

The spec carries a block that every Claude-family kit duplicates verbatim (this is intentional,
not an oversight — `extends` only resolves _built-in_ agents, so pointing it at a local kit for
de-duplication resolves to an empty parent while `sbx kit validate` still reports `VALID`). The
Codex kit carries its own variant of it, described under "Codex kit" below:

- an `AI_MEMORY_DATA_DIR` volume at `/var/lib/ai-memory` (chowned to uid 1000 on install, since
  volumes mount root:root and `/home/agent` itself is reset on every sandbox creation)
- startup steps that clear a stale serve lock, run `ai-memory init`, register the ai-memory MCP
  server + hooks (these must re-run per sandbox since `~/.claude*` doesn't survive from the image),
  and background `ai-memory serve` on `127.0.0.1:49374`, polled until it answers before startup
  continues
- a `restore-claude-plugins` step that merges the image's plugin-settings snapshot back into
  `~/.claude/settings.json`. It runs _after_ `install-hooks` so the last writer of that file is not
  the one that could drop the keys, and it is wrapped to always exit 0
- a `jarvis-statusline --install` step, after `restore-claude-plugins` for the same
  last-writer reason, and wrapped to always exit 0
- MySQL reached directly at `host.docker.internal:3306` — the MCP server dials it itself, and the
  base allowlist's `host.docker.internal` rule covers it. An earlier revision tunnelled this through
  the sandbox's HTTP CONNECT proxy with `socat` on `127.0.0.1:3306`; that step and its
  `localhost:3306` allowlist rule are gone.
- conditional registration of the read-only `mysql` MCP server (`ALLOW_INSERT/UPDATE/DELETE/DDL_OPERATION=false`),
  which no-ops with a warning (never a hard failure — a non-zero startup step silently aborts every
  later step) if `MYSQL_USER` or the `claude` CLI isn't available

`scripts/verify-kits.sh` finds every kit by globbing `agent/*/spec.yaml` and keys its cases on the
spec's `extends:` (the family: `claude` or `codex`). It diffs this shared block within a family, so
drift between copies fails CI-style rather than silently diverging; with one kit per family that
comparison is vacuous for now. Across families it compares only what must match: the
`AI_MEMORY_DATA_DIR` value, the volume, the serve bind address, the readiness text, the chown step,
and no `MYSQL_*` in `environment`.

### Codex kit (`agent/codex/spec.yaml` + `agent/codex/files/home/`)

`extends: codex`, `sandbox.image: jarvis-engineer:codex`. The built-in `codex` kit's
entrypoint is already `codex --dangerously-bypass-approvals-and-sandbox` and the kit's `command` is
appended to it, so the kit adds only `--model gpt-5.6-terra` (Codex's default model is rejected for
ChatGPT-account logins). Do not repeat the bypass flag in `command`. The kit's network allowlist
merges with the built-in one, which already carries the OpenAI and ChatGPT hosts. sbx writes
`~/.codex/config.toml` at creation (model provider `sandboxd`, an MCP gateway), so every startup
step merges into that file rather than replacing it.

Generated content Codex reads: `~/.codex/AGENTS.md` (global instructions: role core, Codex
delegation fragment, rules index), `~/.codex/agents/<name>.toml` (sub-agents),
`~/.agents/skills/` (skills), and `~/.jarvis/rules/*.md` (rules the orchestrator reads on demand;
not `~/.codex/rules`, which Codex uses for exec policy). `files/home/.jarvis-role` is hand-owned and
only presence-checked; Codex has no status line.

Startup steps, in order: clear the serve lock, `ai-memory init`, `install-mcp --client codex`,
`install-hooks --agent codex`, `trust-codex-hooks` (warns, exits 0), background `serve`, the
readiness poll, and MySQL. The MySQL step appends a `[mcp_servers.mysql]` table to `config.toml`
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
any extra, missing or changed file in the owned paths. Everything else in a kit (`spec.yaml`,
`.jarvis-role`, `.claude/settings.json`, `.claude/workflows/`) is hand-owned and never touched.

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
2. `verify-kits.sh` — asserts the _resolved_ kit (`sbx kit inspect`), not just spec syntax, since
   `sbx kit validate` reports `VALID` even when `extends` silently resolves to nothing. Also
   asserts the base network allowlist, that no spec declares `MYSQL_*` in `environment.variables`
   (v2 does no host-env interpolation there, so `MYSQL_USER: $MYSQL_USER` arrives as that literal
   string and defeats the startup step's empty-check), the shared-block drift check, and that the
   generated kit content matches `shared/` (`sync-agents.sh --check`).
3. `verify-sandbox-claude.sh` — live checks against a running sandbox (`sbx exec ... `), for the things
   only observable at runtime: whether the MySQL tunnel actually reaches a real MySQL server (not
   just a stub), whether plugin/MCP/`statusLine` state survives the startup steps rewriting
   `~/.claude/settings.json`, whether nested Docker actually comes up. `verify-sandbox-codex.sh`
   covers the Codex sandbox: generated content in place byte for byte, both MCP servers listed by
   `codex mcp list`, credentials forwarded by name only, sbx's model provider kept, and Codex
   reporting every ai-memory hook trusted. Neither makes a model call; for Codex, confirm once by
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
- `gpt-5.6-terra` in `agent/codex/spec.yaml` is what the current ChatGPT account accepts, not a
  property of the kit; change it there if the account or Codex's model list changes.
