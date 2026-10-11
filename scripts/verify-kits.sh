#!/usr/bin/env bash
#
# Kit-level acceptance checks.
#
# `sbx kit validate` only checks syntax -- it reports VALID for a kit whose
# `extends` target resolves to nothing. These cases assert the resolved artifact
# instead, and that the ai-memory block duplicated across kits has not drifted.
#
# Kits come in families keyed on the spec's `extends:` (claude or codex). Most
# cases are per family; the ai-memory block is byte-compared within a family,
# and only the invariants that must match are compared across families.
#
# Usage: scripts/verify-kits.sh

set -uo pipefail

cd "$(dirname "$0")/.."

# Discovered rather than listed: a hardcoded pair is how two kits ended up
# carrying the shared ai-memory block with nothing checking it. A new kit is
# covered the moment its spec lands. `agent/*` matches agent/claude/,
# agent/codex/ and any agent/<target>/ kit next to them.
KITS=()
for spec in agent/*/spec.yaml; do
	KITS+=("$(dirname "$spec")")
done

pass=0
fail=0

# spec_text <kit>
#
# The spec as one whitespace-normalised line. Assertions about command content
# have to survive a reformat: these specs are Prettier-formatted, and Prettier
# splits a long flow sequence across lines, which silently broke every check
# that matched the single-line form.
spec_text() {
	tr -s ' \n\t' ' ' <"$1/spec.yaml"
}

# family_of <kit> -- the `extends:` value: claude or codex.
family_of() {
	awk '/^extends:/ { print $2; exit }' "$1/spec.yaml"
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
		grep -qF "\"$host\"" "$1/spec.yaml" || missing="$missing $host"
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

	# Guards the failure mode that left the investigator on the stock claude
	# image: a kit that resolves without the custom template silently loses
	# ai-memory entirely.
	check "$kit resolves to the custom template" \
		'jarvis-engineer:claude' "$inspected"

	check "$kit declares the memory volume + startup steps" \
		'9 startup' "$inspected"

	# The image bakes the plugins, but `sbx create` rewrites
	# ~/.claude/settings.json and drops the keys that load them, so a kit
	# without this step hands the agent a sandbox with every plugin disabled.
	check "$kit restores the baked plugin settings" \
		'restore-claude-plugins' "$(spec_text "$kit")"

	# Like the plugin keys, `statusLine` lives only in settings.json, which
	# `sbx create` rewrites -- a kit without this step shows the stock status
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
		"$(grep -qE '\-e MYSQL_(PASS|USER)=' "$kit/spec.yaml" && echo LEAKED || echo CLEAN)"

	check "$kit degrades when credentials are absent" \
		'skipping registration' "$(spec_text "$kit")"

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

	check "$kit resolves to the Codex template" \
		'jarvis-engineer:codex' "$inspected"

	check "$kit declares the memory volume + startup steps" \
		'8 startup' "$inspected"

	# The built-in codex kit's entrypoint is already
	# `codex --dangerously-bypass-approvals-and-sandbox` (spike S9), and
	# `command` is appended to it: repeating the flag there would make codex
	# reject the command line, and overriding the entrypoint would drop it.
	check "$kit keeps the inherited no-approval entrypoint" \
		'CLEAN' \
		"$(grep -qE 'entrypoint:|dangerously-bypass-approvals-and-sandbox' "$kit/spec.yaml" && echo OVERRIDDEN || echo CLEAN)"

	# hook-mode pretrust (spike S7): only ai-memory's hooks are trusted, by
	# trust-codex-hooks. A blanket bypass would also run any other hook.
	check "$kit does not bypass hook trust" \
		'CLEAN' \
		"$(grep -q -- '--dangerously-bypass-hook-trust' "$kit/spec.yaml" && echo BYPASS || echo CLEAN)"

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
		"$(grep -qE 'claude mcp|restore-claude-plugins|jarvis-statusline|claude-code' "$kit/spec.yaml" \
			&& echo CLAUDE || echo CLEAN)"

	# Model credentials are injected by sbx's proxy; a key in the spec would be
	# a secret in a committed file.
	check "$kit declares no OpenAI API key" \
		'CLEAN' \
		"$(grep -q 'OPENAI_API_KEY' "$kit/spec.yaml" && echo KEY || echo CLEAN)"

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
		"$(grep -qE 'MYSQL_(PASS|USER) *=' "$kit/spec.yaml" && echo LEAKED || echo CLEAN)"

	check "$kit degrades when credentials are absent" \
		'skipping registration' "$text"

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

	check "$kit validates" 'VALID' "$(sbx kit validate "$kit" 2>&1)"

	check "$kit declares the base network allowlist" \
		'COMPLETE' "$(missing_base "$kit")"

	# Nothing in a kit leaves the sandbox over loopback, so a bare localhost
	# rule only widens the allowlist for no caller.
	check "$kit carries no bare localhost rule" \
		'CLEAN' \
		"$(grep -qE '^[[:space:]]*-[[:space:]]*"localhost"[[:space:]]*$' "$kit/spec.yaml" \
			&& echo REDUNDANT || echo CLEAN)"

	check "$kit cannot abort the startup chain" \
		'CLEAN' \
		"$(grep -q 'exit 0' "$kit/spec.yaml" && echo CLEAN || echo RISK)"

	check "$kit gates the agent on server readiness" \
		'server not ready after 30s' "$(spec_text "$kit")"

	check "$kit runs the serve subcommand" \
		'"ai-memory", "serve", "--transport", "http", "--bind", "127.0.0.1:49374"' \
		"$(spec_text "$kit")"

	check "$kit backgrounds the server" 'background: true' "$(spec_text "$kit")"

	check "$kit chowns the volume to the agent uid" \
		'chown 1000:1000 /var/lib/ai-memory' "$(spec_text "$kit")"

	check "$kit points the store at the volume" \
		'AI_MEMORY_DATA_DIR: /var/lib/ai-memory' "$(spec_text "$kit")"

	# `environment.variables` does no host-env interpolation, so a "$VAR" value
	# arrives as that literal text. Credentials must come from `sbx create
	# --env-file .env`, never from the spec.
	check "$kit declares no un-interpolated env placeholders" \
		'CLEAN' \
		"$(sed -n '/^environment:/,/^volumes:/p' "$kit/spec.yaml" \
			| grep -qE '^[[:space:]]+[A-Z_]+:[[:space:]]*\$' \
			&& echo LITERAL || echo CLEAN)"
}

for kit in "${KITS[@]}"; do
	common_cases "$kit"
	case "$(family_of "$kit")" in
	claude) claude_cases "$kit" "$(sbx kit inspect "$kit" 2>&1)" ;;
	codex) codex_cases "$kit" "$(sbx kit inspect "$kit" 2>&1)" ;;
	*)
		printf 'FAIL %s extends %s, which is neither claude nor codex\n' "$kit" "$(family_of "$kit")"
		fail=$((fail + 1))
		;;
	esac
done

# The shared block is duplicated by necessity; assert the copies agree.
# Normalised the same way as spec_text: indentation and line breaks are the
# formatter's business, so only a real difference in content counts as drift.
#
# This deliberately does NOT filter MYSQL_/IS_SANDBOX lines. It used to, and
# that exemption is what hid three kits declaring `MYSQL_USER: $MYSQL_USER` in
# `environment.variables` -- v2 does no host-env interpolation there, so the
# container received the literal string "$MYSQL_USER". Non-empty literal
# credentials defeat the `[ -z "$MYSQL_USER" ]` guard in the startup step, so
# the MySQL MCP server registered against a garbage user instead of skipping.
shared_block() {
	sed -n '/^environment:/,$p' "$1/spec.yaml" |
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

# invariants <kit> -- what must be identical in every family: the store, the
# volume, the server address, the readiness gate, the volume hand-over, and no
# MYSQL_* in `environment` (Claude and Codex wire MySQL differently, so the
# blocks themselves cannot be byte-compared).
invariants() {
	printf 'data dir: %s\n' "$(grep -o 'AI_MEMORY_DATA_DIR: [^ ]*' "$1/spec.yaml")"
	printf 'volume: %s\n' "$(sed -n '/^volumes:/,/^[a-z]/p' "$1/spec.yaml" | grep -vE '^\s*#|^[a-z]' | tr -s ' \n\t' ' ')"
	printf 'bind: %s\n' "$(spec_text "$1" | grep -o '"--bind", "[^"]*"')"
	printf 'readiness: %s\n' "$(spec_text "$1" | grep -o 'server not ready after [0-9]*s')"
	printf 'chown: %s\n' "$(spec_text "$1" | grep -o 'chown 1000:1000 [^"]*')"
	printf 'mysql in environment: %s\n' \
		"$(sed -n '/^environment:/,/^[a-z]/p' "$1/spec.yaml" | grep -q 'MYSQL_' && echo yes || echo no)"
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
