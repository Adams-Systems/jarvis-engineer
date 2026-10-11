#!/usr/bin/env bash
#
# Acceptance tests for the Makefile's agent dispatch: `make <verb> claude|codex`.
#
# Positive cases read `make -n` output, so nothing is built or created. Negative
# cases run make for real with stub docker/sbx binaries on PATH: the stubs record
# every call and fail, so a guard that let a verb through shows up as a call.
#
# Usage: scripts/test-make-dispatch.sh

set -uo pipefail

cd "$(dirname "$0")/.."

# When run through `make verify-make SANDBOX=x`, make exports x to this script
# and the nested make calls below would take it as the default, failing the
# cases that assert default values.
unset MAKEFLAGS MAKEOVERRIDES MFLAGS MAKELEVEL SANDBOX KIT

work="$(mktemp -d "${TMPDIR:-/tmp}/make-dispatch.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir "$work/bin"
for tool in docker sbx; do
	printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 99\n' "$tool" >"$work/bin/$tool"
	chmod +x "$work/bin/$tool"
done

pass=0
fail=0

# expect <name> <expected-substring> <actual>
expect() {
	if [[ "$3" == *"$2"* ]]; then
		printf 'ok   %s\n' "$1"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n     want substring: %s\n     got: %s\n' "$1" "$2" "${3:-<empty>}"
		fail=$((fail + 1))
	fi
}

# dry <make args...> -- the commands make would run, without running them.
dry() {
	make -n "$@" 2>&1
}

# stubbed <make args...> -- runs make for real; docker and sbx are the stubs.
stubbed() {
	: >"$work/calls"
	STUB_LOG="$work/calls" PATH="$work/bin:$PATH" make "$@" 2>&1
}

stub_calls() {
	wc -l <"$work/calls" | tr -d ' '
}

# refuse <name> <make args...> -- must exit 2 with the usage line, having called
# neither docker nor sbx.
refuse() {
	local name="$1" out status
	shift
	out="$(stubbed "$@")"
	status=$?
	expect "$name exits 2" "status=2" "status=$status"
	expect "$name prints the usage line" "usage: make" "$out"
	expect "$name reaches neither docker nor sbx" "calls=0" "calls=$(stub_calls)"
}

printf '== make dispatch ==\n'

# --- the agent selects image, target, kit and sandbox ---------------------
expect "build claude targets the claude stage" \
	"docker build --target claude --build-arg AGENT=claude -t jarvis-engineer:claude ." \
	"$(dry build claude)"
expect "build codex targets the codex stage" \
	"docker build --target codex --build-arg AGENT=codex -t jarvis-engineer:codex ." \
	"$(dry build codex)"
expect "the agent may come before the verb" \
	"docker build --target codex --build-arg AGENT=codex -t jarvis-engineer:codex ." \
	"$(dry codex build)"
expect "verify-image claude runs the claude script on the claude tag" \
	"./scripts/verify-image-claude.sh jarvis-engineer:claude" \
	"$(dry verify-image claude)"
expect "verify-image codex runs the codex script on the codex tag" \
	"./scripts/verify-image-codex.sh jarvis-engineer:codex" \
	"$(dry verify-image codex)"
expect "template claude builds, verifies, saves and loads the claude image" \
	"docker image save jarvis-engineer:claude -o" \
	"$(dry template claude)"
expect "template claude names its tarball after the agent" \
	"jarvis-engineer-claude.tar" \
	"$(dry template claude)"
expect "template claude verifies the image it built" \
	"./scripts/verify-image-claude.sh jarvis-engineer:claude" \
	"$(dry template claude)"
expect "sandbox claude recreates the default sandbox from the claude kit" \
	"sbx create --name jarvis-engineer --env-file .env --kit agent/claude jarvis-engineer ." \
	"$(dry sandbox claude)"
expect "sandbox claude verifies the sandbox it created" \
	"./scripts/verify-sandbox-claude.sh jarvis-engineer" \
	"$(dry sandbox claude)"
expect "sandbox codex recreates the codex sandbox from the codex kit" \
	"sbx create --name jarvis-engineer-codex --env-file .env --kit agent/codex jarvis-engineer-codex ." \
	"$(dry sandbox codex)"
expect "SANDBOX still overrides the default sandbox name" \
	"sbx create --name probe --env-file .env --kit agent/codex jarvis-engineer-codex ." \
	"$(dry sandbox codex SANDBOX=probe)"
expect "SANDBOX override reaches the live verifier" \
	"./scripts/verify-sandbox-codex.sh probe" \
	"$(dry sandbox codex SANDBOX=probe)"
expect "verify-sandbox codex runs the codex verifier on the default sandbox" \
	"./scripts/verify-sandbox-codex.sh jarvis-engineer-codex" \
	"$(dry verify-sandbox codex)"

# --- agent-agnostic verbs name no agent -----------------------------------
expect "verify checks both images" \
	"./scripts/verify-image-claude.sh jarvis-engineer:claude" \
	"$(dry verify)"
expect "verify checks the codex image too" \
	"./scripts/verify-image-codex.sh jarvis-engineer:codex" \
	"$(dry verify)"
expect "verify runs the dispatch tests" \
	"./scripts/test-make-dispatch.sh" \
	"$(dry verify)"
expect "clean removes both tarballs" \
	"jarvis-engineer-codex.tar" \
	"$(dry clean)"
expect "sync needs no agent" \
	"./scripts/sync-agents.sh" \
	"$(dry sync)"

# --- the Makefile runs these scripts directly, so each must be executable ---
for script in verify-image-claude verify-image-codex verify-sandbox-claude verify-sandbox-codex; do
	# find reads the mode bits; `test -x` also honours ACLs and root.
	[[ -n "$(find "scripts/$script.sh" -perm -u+x 2>/dev/null)" ]] && mode=executable || mode=not-executable
	expect "scripts/$script.sh is executable" "mode=executable" "mode=$mode"
done

# --- the agent goal, not an AGENT= override, picks what runs ---------------
expect "AGENT= on the command line cannot redirect the sandbox" \
	"sbx rm --force jarvis-engineer
" \
	"$(dry sandbox claude AGENT=codex)"

# --- an agent verb needs exactly one agent --------------------------------
refuse "build without an agent" build
refuse "template without an agent" template
refuse "verify-image without an agent" verify-image
refuse "sandbox without an agent" sandbox
refuse "verify-sandbox without an agent" verify-sandbox
refuse "build with two agents" build claude codex

# --- bare make lists the verbs instead of building ------------------------
out="$(stubbed)"
status=$?
expect "bare make exits 0" "status=0" "status=$status"
expect "bare make lists the agent verbs" "build <agent>" "$out"
expect "bare make builds nothing" "calls=0" "calls=$(stub_calls)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
