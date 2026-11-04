#!/usr/bin/env bash
#
# Kit-level acceptance checks.
#
# Every kit is a sandbox-kit v3 workload: a descriptor agent/<family>/<name>.yaml
# whose recipe is the repo Dockerfile. `sbx kit validate` and `sbx kit inspect`
# build the kit (they need its staged build context and a docker-container
# builder); these cases assert the built artifact and the descriptor's content,
# and that the ai-memory block duplicated across kits has not drifted.
#
# Kits come in families keyed on their directory (claude or codex). Most cases
# are per family; the ai-memory block is compared within a family, and only the
# invariants that must match are compared across families.
#
# Usage: scripts/verify-kits.sh

set -uo pipefail

cd "$(dirname "$0")/.."

# Discovered rather than listed: a hardcoded pair is how two kits ended up
# carrying the shared ai-memory block with nothing checking it. A new kit is
# covered the moment its descriptor lands. A descriptor is the .yaml whose first
# line selects the v3 frontend, the same rule scripts/stage-kit.sh applies.
KITS=()
for f in agent/*/*.yaml; do
	[[ "$(head -n 1 "$f")" == '# syntax=docker/sandbox-kit:3' ]] && KITS+=("$(dirname "$f")")
done

# sbx builds kits only with a docker-container builder.
KIT_BUILDER=kit-builder

pass=0
fail=0

# descriptor <kit> -- the kit's v3 descriptor file.
descriptor() {
	local f
	for f in "$1"/*.yaml; do
		[[ "$(head -n 1 "$f")" == '# syntax=docker/sandbox-kit:3' ]] && { printf '%s' "$f"; return; }
	done
}

# spec_text <kit>
#
# The descriptor as one whitespace-normalised line. Assertions about command content
# have to survive a reformat: these specs are Prettier-formatted, and Prettier
# splits a long flow sequence across lines, which silently broke every check
# that matched the single-line form.
spec_text() {
	tr -s ' \n\t' ' ' <"$(descriptor "$1")"
}

# family_of <kit> -- the agent the kit is: its directory, claude or codex.
family_of() {
	basename "$1"
}

# allows <kit> <host> -- whether the descriptor lists that host as an egress
# entry (quoted or not, with or without a trailing comment).
allows() {
	grep -qE "^[[:space:]]*-[[:space:]]*\"?$2\"?[[:space:]]*(#.*)?$" "$(descriptor "$1")"
}

# undeclared_env <kit> -- "DECLARED", or each hook that reads a variable its
# `env:` list does not name, as "<description>: <VAR>". Checked per hook: a
# file-wide grep passes when any one hook declares the name. A hook reads a
# variable it references as $VAR or ${VAR}; one that runs ai-memory also reads
# AI_MEMORY_DATA_DIR and AI_MEMORY_AUTH_TOKEN, which ai-memory reads itself
# (install-mcp and install-hooks write the token into the client config).
undeclared_env() {
	awk '
	function flush(   n, i, v, missing) {
		if (!inhook) return
		n = split("MYSQL_USER POSTGRES_MCP_CONNECTION_STRING GOPRIVATE GOPRIVATE_GIT_TOKEN AI_MEMORY_DATA_DIR AI_MEMORY_AUTH_TOKEN", vars, " ")
		for (i = 1; i <= n; i++) {
			v = vars[i]
			if (index(body, "$" v) || index(body, "${" v) || \
			    (aim && (v == "AI_MEMORY_DATA_DIR" || v == "AI_MEMORY_AUTH_TOKEN")))
				if (index(envs, v) == 0) { print desc ": " v; bad = 1 }
		}
		inhook = 0; body = ""; envs = ""; desc = "?"; aim = 0
	}
	# a hook entry starts at a list item under install: or startup:
	/^            - command/ { flush(); inhook = 1 }
	/^        (install|startup|files):/ || /^    - type:/ { flush() }
	inhook {
		if ($0 ~ /^              env:/) envs = $0
		else if ($0 ~ /^              description:/) desc = substr($0, index($0, ":") + 2)
		else if ($0 !~ /^[[:space:]]*#/) {
			body = body " " $0
			if ($0 ~ /"ai-memory", "/ || $0 ~ /ai-memory (init|install|serve)/) aim = 1
		}
	}
	END { flush(); if (!bad) print "DECLARED" }
	' "$(descriptor "$1")"
}

# startup_registrations <file> -- "NONE", or each agent registration found
# among the startup hooks. Registrations belong to install hooks: those finish
# before the agent first launches, while the published kits document startup
# hooks as fired by a detached dispatcher that can overlap a live session.
startup_registrations() {
	awk '
	/^        startup:/ { on = 1; next }
	/^        (install|files):/ || /^    - type:/ { on = 0 }
	on && $0 !~ /^[[:space:]]*#/ && /install-mcp|install-hooks|mcp add|mcp remove|restore-claude-plugins|jarvis-statusline --install|trust-codex-hooks|mcp_servers\.(mysql|postgres)/ {
		if ($0 ~ /mcp-gateway/) next
		print "STARTUP:" $0; found = 1
	}
	END { if (!found) print "NONE" }
	' "$1"
}

# staged <kit> -- stages the kit's build context and prints its directory.
staged() {
	./scripts/stage-kit.sh "$(family_of "$1")"
}

# The hosts every kit must allow. The permissions block sits *above* the shared
# ai-memory block, so the drift comparison at the bottom of this file (which
# starts at `environment:`) never sees it -- which is how three kits ended up
# carrying a bare `localhost` rule that nothing needed and two kits ended up
# with package-registry egress they never use.
BASE_ALLOW=(
	host.docker.internal
	gateway.docker.internal
	github.com
	api.github.com
	raw.githubusercontent.com
	objects.githubusercontent.com
	proxy.golang.org
	sum.golang.org
	vuln.go.dev
	go.dev
	pkg.go.dev
)

# Per-family additions. Codex adds none: the model endpoint is reached through
# sbx's own proxy (spike S2: model_provider "sandboxd"), not the kit allowlist.
CLAUDE_ALLOW=(code.claude.com)

# The Codex kit's AGENTS.md shares Codex's instruction budget with the
# workspace's own AGENTS.md; sync-agents.sh enforces the same number.
AGENTS_MD_BUDGET=16384

# missing_base <kit> -- "COMPLETE", or the hosts absent from the allowlist.
missing_base() {
	local host missing="" hosts=("${BASE_ALLOW[@]}")
	[[ "$(family_of "$1")" == claude ]] && hosts+=("${CLAUDE_ALLOW[@]}")
	for host in "${hosts[@]}"; do
		allows "$1" "$host" || missing="$missing $host"
	done
	if [[ -n "$missing" ]]; then
		printf 'MISSING:%s' "$missing"
	else
		printf 'COMPLETE'
	fi
}

# role_label <kit> -- the label the kit's status line must render. The unified
# kit is the engineer orchestrator, not an "AGENT"; any other kit keeps the
# label derived from its directory name.
role_label() {
	case "$1" in
	agent/claude) printf 'ENGINEER' ;;
	*) basename "$1" | tr '[:lower:]' '[:upper:]' ;;
	esac
}

# check <name> <expected-substring> <actual>
check() {
	local name="$1" expected="$2" actual="$3"

	if [[ "$actual" == *"$expected"* ]]; then
		printf 'ok   %s\n' "$name"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n     want substring: %s\n     got: %s\n' \
			"$name" "$expected" "${actual:-<empty>}"
		fail=$((fail + 1))
	fi
}

printf '== kit acceptance ==\n'

# The kits' roles, rules and skills are generated from shared/; a hand edit or
# a stale regeneration would ship content that no source describes.
check "generated kit content matches shared/" 'IN SYNC' \
	"$(./scripts/sync-agents.sh --check 2>&1 && echo 'IN SYNC')"

# claude_cases <kit> <inspect output> -- Claude Code family only.
claude_cases() {
	local kit="$1" inspected="$2"

	check "$kit builds as a v3 claude workload" \
		'Schema: v3' "$inspected"

	check "$kit launches claude" 'Binary: claude' "$inspected"

	# The persona is appended by the recipe's Cmd; sbx reports the argv it
	# will launch, so a lost Cmd shows here before any sandbox exists.
	check "$kit appends the role prompt to the launch" \
		'Run Options: --dangerously-skip-permissions --append-system-prompt-file /home/agent/ROLE.md' \
		"$inspected"

	# 3 install and 3 startup hooks restated from the published claude kit,
	# plus this kit's 9 install steps (volume chowns, init, registrations) and
	# 5 startup steps (lock, init, serve, readiness, git helper).
	check "$kit declares the claude hooks and its own" \
		'12 install, 8 startup' "$inspected"

	# A recipe FROM a kit does not inherit its descriptor: without these the
	# sandbox has no Anthropic sign-in and no claude guidance.
	check "$kit restates the published claude credential" \
		'service: anthropic' "$(spec_text "$kit")"

	check "$kit restates the published claude guidance" \
		'contentFile: claude-context.md' "$(spec_text "$kit")"

	# The published claude kit's settings hook replaces settings.json; this one
	# merges, or the baked attribution and plugin keys would be lost at create.
	check "$kit merges into the baked settings.json" \
		'keeping baked keys' "$(spec_text "$kit")"

	check "$kit is built on the published claude kit, pinned by digest" \
		'PINNED' \
		"$(grep -qE '^FROM docker\.io/docker/sbx-kit-claude:[^ ]+@sha256:[0-9a-f]{64} AS base-claude$' Dockerfile && echo PINNED || echo UNPINNED)"

	# Hook environments are deny-by-default in the spec (sbx v0.51.0 does not
	# enforce it yet): a hook that reads a variable it does not declare skips
	# its work the day the runtime starts enforcing.
	check "$kit declares the variables its hooks read" \
		'DECLARED' "$(undeclared_env "$kit")"

	# The image bakes the plugins, but the claude settings hook and the
	# ai-memory hooks rewrite ~/.claude/settings.json, so a kit without this
	# step risks a sandbox with every plugin disabled.
	check "$kit restores the baked plugin settings" \
		'restore-claude-plugins' "$(spec_text "$kit")"

	# Like the plugin keys, `statusLine` lives only in settings.json, which the
	# startup steps rewrite -- a kit without this step shows the stock status
	# line and no role label at all.
	check "$kit registers the role status line" \
		'jarvis-statusline --install' "$(spec_text "$kit")"

	# The label is read from this file at render time. A kit that ships the
	# startup step without it renders the "AGENT" fallback, which looks correct
	# enough to go unnoticed.
	check "$kit ships a role label for the status line" \
		"$(role_label "$kit")" \
		"$(cat "$kit/files/home/.jarvis-role" 2>&1)"

	# The host's MySQL is reachable from the sandbox only under this name;
	# 127.0.0.1 would resolve to the sandbox itself.
	check "$kit points mysql at the host" \
		'-e MYSQL_HOST=host.docker.internal' "$(spec_text "$kit")"

	check "$kit keeps mysql read-only" \
		'-e ALLOW_DELETE_OPERATION=false' "$(spec_text "$kit")"

	# The password must be inherited from the environment, never written into a
	# config file by -e.
	check "$kit does not register mysql credentials via -e" \
		'CLEAN' \
		"$(grep -qE '\-e MYSQL_(PASS|USER)=' "$(descriptor "$kit")" && echo LEAKED || echo CLEAN)"

	check "$kit degrades when credentials are absent" \
		'skipping registration' "$(spec_text "$kit")"

	# postgres-mcp has no read-only switch for the env-var connection, so the
	# write tools are denied in settings instead. Losing either name would
	# leave a read-write server behind a read-only-looking kit.
	check "$kit denies the postgres write tools" \
		'DENIED' \
		"$(for t in postgres_mcp_modify postgres_mcp_bulk_load_csv postgres_mcp_add_connection; do
			grep -q "mcp__postgres__$t" "$(descriptor "$kit")" || { echo "MISSING $t"; exit; }
		done; echo DENIED)"

	# The connection string carries the password: inherit it, never `-e` it.
	check "$kit does not register the postgres connection string via -e" \
		'CLEAN' \
		"$(grep -qE '\-e POSTGRES_MCP_CONNECTION_STRING' "$(descriptor "$kit")" && echo LEAKED || echo CLEAN)"

	check "$kit turns postgres telemetry off" \
		'run --no-telemetry' "$(spec_text "$kit")"

	# Startup steps get a PATH without ~/.local/bin, so a bare `claude` exits
	# 127 -- and a non-zero startup step silently aborts all later steps.
	check "$kit invokes claude by absolute path" \
		'CLAUDE=/home/agent/.local/bin/claude' "$(spec_text "$kit")"
}

# codex_cases <kit> <inspect output> -- Codex family only.
codex_cases() {
	local kit="$1" inspected="$2" text agents_md
	text="$(spec_text "$kit")"
	agents_md="$kit/files/home/.codex/AGENTS.md"

	check "$kit builds as a v3 codex workload" \
		'Schema: v3' "$inspected"

	check "$kit launches codex" 'Binary: codex' "$inspected"

	# 1 install and 2 startup hooks restated from the published codex kit,
	# plus this kit's 8 install steps (volume chowns, init, registrations, hook
	# trust) and 5 startup steps (lock, init, serve, readiness, git helper).
	check "$kit declares the codex hooks and its own" \
		'9 install, 7 startup' "$inspected"

	# A recipe FROM a kit does not inherit its descriptor: without this the
	# sandbox has no OpenAI sign-in.
	check "$kit restates the published codex credential" \
		'service: openai' "$(spec_text "$kit")"

	check "$kit is built on the published codex kit, pinned by digest" \
		'PINNED' \
		"$(grep -qE '^FROM docker\.io/docker/sbx-kit-codex:[^ ]+@sha256:[0-9a-f]{64} AS base-codex$' Dockerfile && echo PINNED || echo UNPINNED)"

	check "$kit declares the variables its hooks read" \
		'DECLARED' "$(undeclared_env "$kit")"

	# The published codex kit's entrypoint is already
	# `codex --dangerously-bypass-approvals-and-sandbox` (spike S9), and the
	# recipe's Cmd is appended to it: repeating the flag there would make codex
	# reject the command line.
	check "$kit keeps the inherited no-approval entrypoint" \
		'CLEAN' \
		"$(sed -n '/^FROM common AS codex$/,$p' Dockerfile | grep -qE '^(ENTRYPOINT|CMD).*dangerously-bypass-approvals-and-sandbox' && echo OVERRIDDEN || echo CLEAN)"

	# hook-mode pretrust (spike S7): only ai-memory's hooks are trusted, by
	# trust-codex-hooks. A blanket bypass would also run any other hook.
	check "$kit does not bypass hook trust" \
		'CLEAN' \
		"$(grep -q -- '--dangerously-bypass-hook-trust' "$(descriptor "$kit")" && echo BYPASS || echo CLEAN)"

	# The ChatGPT account rejects Codex's default model (spike S1-S6).
	check "$kit pins a model the account accepts" \
		'gpt-5.6-terra' "$inspected"

	check "$kit registers the ai-memory MCP server with Codex" \
		'"ai-memory", "install-mcp", "--client", "codex", "--apply"' "$text"

	check "$kit registers ai-memory hooks with Codex" \
		'"ai-memory", "install-hooks", "--agent", "codex", "--apply"' "$text"

	check "$kit trusts the ai-memory hooks it registers" \
		'trust-codex-hooks' "$text"

	check "$kit carries no Claude-only wiring" \
		'CLEAN' \
		"$(grep -qE 'claude mcp|restore-claude-plugins|jarvis-statusline|claude-code' "$(descriptor "$kit")" \
			&& echo CLAUDE || echo CLEAN)"

	# Model credentials are injected by sbx's proxy; a key in the kit would be
	# a secret in a committed file. The credential declares the variable's name,
	# and the install hook writes the proxy sentinel; anything else is a value.
	check "$kit declares no OpenAI API key value" \
		'CLEAN' \
		"$(grep 'OPENAI_API_KEY' "$(descriptor "$kit")" \
			| grep -vE '^[[:space:]]*#|name: OPENAI_API_KEY$|"OPENAI_API_KEY": "proxy-managed"$' \
			| grep -q . && echo KEY || echo CLEAN)"

	check "$kit points mysql at the host" \
		'MYSQL_HOST = "host.docker.internal"' "$text"

	check "$kit keeps mysql read-only" \
		'ALLOW_DELETE_OPERATION = "false"' "$text"

	# Codex passes no environment to stdio MCP servers by default (spike S8);
	# env_vars forwards the credentials by name, so no value is in config.
	check "$kit forwards mysql credentials by name only" \
		'env_vars = ["MYSQL_USER", "MYSQL_PASS"]' "$text"

	check "$kit writes no mysql credential value into config" \
		'CLEAN' \
		"$(grep -qE 'MYSQL_(PASS|USER) *=' "$(descriptor "$kit")" && echo LEAKED || echo CLEAN)"

	check "$kit degrades when credentials are absent" \
		'skipping registration' "$text"

	# Same reasoning as the Claude kit: no read-only switch for the env-var
	# connection, so the write tools are disabled by name.
	check "$kit disables the postgres write tools" \
		'DISABLED' \
		"$(for t in postgres_mcp_modify postgres_mcp_bulk_load_csv postgres_mcp_add_connection; do
			grep -q "disabled_tools = .*\"$t\"" "$(descriptor "$kit")" || { echo "MISSING $t"; exit; }
		done; echo DISABLED)"

	check "$kit forwards the postgres connection string by name only" \
		'env_vars = ["POSTGRES_MCP_CONNECTION_STRING"]' "$text"

	check "$kit writes no postgres connection string value into config" \
		'CLEAN' \
		"$(grep -qE 'POSTGRES_MCP_CONNECTION_STRING *=' "$(descriptor "$kit")" && echo LEAKED || echo CLEAN)"

	check "$kit turns postgres telemetry off" \
		'"run", "--no-telemetry"' "$text"

	check "$kit ships a role label" \
		'PRESENT' \
		"$([[ -s "$kit/files/home/.jarvis-role" ]] && echo PRESENT || echo MISSING)"

	check "$kit AGENTS.md is within the $AGENTS_MD_BUDGET-byte budget" \
		'WITHIN' \
		"$([[ -f "$agents_md" && $(wc -c <"$agents_md") -le $AGENTS_MD_BUDGET ]] && echo WITHIN || echo OVER_OR_MISSING)"
}

# common_cases <kit> -- every family.
common_cases() {
	local kit="$1"

	check "$kit is a v3 workload" \
		'schemaVersion: "3" kind: workload' "$(spec_text "$kit")"

	check "$kit validates" '— valid' \
		"$(BUILDX_BUILDER=$KIT_BUILDER sbx kit validate "$(staged "$kit")" 2>&1)"

	check "$kit declares the base network allowlist" \
		'COMPLETE' "$(missing_base "$kit")"

	# Nothing in a kit leaves the sandbox over loopback, so a bare localhost
	# rule only widens the allowlist for no caller.
	check "$kit carries no bare localhost rule" \
		'CLEAN' \
		"$(allows "$kit" localhost && echo REDUNDANT || echo CLEAN)"

	check "$kit registers the agent's MCP servers and hooks at install, not startup" \
		'NONE' "$(startup_registrations "$(descriptor "$kit")")"

	check "$kit cannot abort the startup chain" \
		'CLEAN' \
		"$(grep -q 'exit 0' "$(descriptor "$kit")" && echo CLEAN || echo RISK)"

	check "$kit gates the agent on server readiness" \
		'server not ready after 30s' "$(spec_text "$kit")"

	check "$kit runs the serve subcommand" \
		'"ai-memory", "serve", "--transport", "http", "--bind", "127.0.0.1:49374"' \
		"$(spec_text "$kit")"

	check "$kit backgrounds the server" 'background: true' "$(spec_text "$kit")"

	check "$kit chowns the volume to the agent uid" \
		'chown 1000:1000 /var/lib/ai-memory' "$(spec_text "$kit")"

	check "$kit declares the memory volume" \
		'path: /var/lib/ai-memory' "$(spec_text "$kit")"

	# A v3 kit sets its environment in the recipe.
	check "$kit points the store at the volume" \
		'AI_MEMORY_DATA_DIR=/var/lib/ai-memory' "$(tr -s ' \n\t' ' ' <Dockerfile)"

	# The Go caches live on a volume so a recreated sandbox keeps them.
	check "$kit chowns the Go cache volume to the agent uid" \
		'chown 1000:1000 /var/lib/go' "$(spec_text "$kit")"

	check "$kit declares the Go cache volume" \
		'path: /var/lib/go,' "$(spec_text "$kit")"

	check "$kit points the Go caches at the volume" \
		'GOMODCACHE=/var/lib/go/mod' "$(tr -s ' \n\t' ' ' <Dockerfile)"

	check "$kit registers the private-module credential helper by variable name" \
		'password=$GOPRIVATE_GIT_TOKEN' "$(spec_text "$kit")"

	# Testcontainers-style tests pull images into the nested Docker daemon.
	check "$kit allows Docker Hub egress for image pulls" \
		'COMPLETE' \
		"$(for h in registry-1.docker.io auth.docker.io production.cloudflare.docker.com; do
			allows "$kit" "$h" || echo "MISSING $h"
		done | grep . || echo COMPLETE)"

	# Credentials come from `sbx create --env-file .env`, never from the kit: a
	# value written into the descriptor or the recipe's ENV is a secret in a
	# committed file.
	check "$kit carries no credential values" \
		'CLEAN' \
		"$(cat "$(descriptor "$kit")" Dockerfile \
			| grep -qE '(MYSQL_(USER|PASS)|POSTGRES_MCP_CONNECTION_STRING|GOPRIVATE_GIT_TOKEN)[:=][[:space:]]*[^][:space:],]' \
			&& echo LEAKED || echo CLEAN)"
}

for kit in "${KITS[@]}"; do
	common_cases "$kit"
	case "$(family_of "$kit")" in
	# sbx pads the inspect columns; squeeze runs of spaces so cases match values.
	claude) claude_cases "$kit" "$(BUILDX_BUILDER=$KIT_BUILDER sbx kit inspect "$(staged "$kit")" 2>&1 | tr -s ' ')" ;;
	codex) codex_cases "$kit" "$(BUILDX_BUILDER=$KIT_BUILDER sbx kit inspect "$(staged "$kit")" 2>&1 | tr -s ' ')" ;;
	*)
		printf 'FAIL %s is in agent/%s, which is neither claude nor codex\n' "$kit" "$(family_of "$kit")"
		fail=$((fail + 1))
		;;
	esac
done

# The shared block is duplicated by necessity; assert the copies agree.
# Normalised the same way as spec_text: indentation and line breaks are the
# formatter's business, so only a real difference in content counts as drift.
#
# The block runs from its marker comment to the end of the descriptor.
shared_block() {
	sed -n '/# --- shared ai-memory block/,$p' "$(descriptor "$1")" |
		grep -vE '^\s*#|^\s*$' |
		tr -s ' \n\t' ' '
}

# With one kit per family this compares nothing; it stays for the next kit of
# a family. Each kit is compared with the first kit of its own family.
for kit in "${KITS[@]}"; do
	reference=""
	for other in "${KITS[@]}"; do
		if [[ "$(family_of "$other")" == "$(family_of "$kit")" ]]; then
			reference="$other"
			break
		fi
	done
	[[ "$reference" == "$kit" ]] && continue
	if [[ "$(shared_block "$reference")" == "$(shared_block "$kit")" ]]; then
		printf 'ok   %s shares the ai-memory block with %s\n' "$kit" "$reference"
		pass=$((pass + 1))
	else
		printf 'FAIL %s has drifted from %s\n' "$kit" "$reference"
		# Normalisation collapses the block onto one line, so diff it word by word
		# rather than emitting two unreadable walls of text.
		diff <(shared_block "$reference" | tr ' ' '\n') \
			<(shared_block "$kit" | tr ' ' '\n') | sed 's/^/     /'
		fail=$((fail + 1))
	fi
done

# invariants <kit> -- what must be identical in every family: the volumes, the
# server address, the readiness gate and the volume hand-over (Claude and Codex
# wire MySQL differently, so the blocks themselves cannot be byte-compared). The
# store location is ENV in the one Dockerfile, so it cannot differ by kit.
invariants() {
	printf 'volume: %s\n' "$(grep -o 'path: /var/lib/[^}]*' "$(descriptor "$1")" | tr -s ' \n\t' ' ')"
	printf 'bind: %s\n' "$(spec_text "$1" | grep -o '"--bind", "[^"]*"')"
	printf 'readiness: %s\n' "$(spec_text "$1" | grep -o 'server not ready after [0-9]*s')"
	printf 'chown: %s\n' "$(spec_text "$1" | grep -o 'chown 1000:1000 [^"]*')"
}

claude_ref="" codex_ref=""
for kit in "${KITS[@]}"; do
	case "$(family_of "$kit")" in
	claude) [[ -z "$claude_ref" ]] && claude_ref="$kit" ;;
	codex) [[ -z "$codex_ref" ]] && codex_ref="$kit" ;;
	esac
done
if [[ -n "$claude_ref" && -n "$codex_ref" ]]; then
	if [[ "$(invariants "$claude_ref")" == "$(invariants "$codex_ref")" ]]; then
		printf 'ok   %s keeps the cross-family invariants of %s\n' "$codex_ref" "$claude_ref"
		pass=$((pass + 1))
	else
		printf 'FAIL %s breaks a cross-family invariant of %s\n' "$codex_ref" "$claude_ref"
		diff <(invariants "$claude_ref") <(invariants "$codex_ref") | sed 's/^/     /'
		fail=$((fail + 1))
	fi
fi

# A Codex kit is the reason this script is family-aware; its absence is a
# regression, not a vacuous pass.
check 'a Codex kit is present' 'PRESENT' "$([[ -n "$codex_ref" ]] && echo PRESENT || echo MISSING)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
