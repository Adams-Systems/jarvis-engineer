#!/usr/bin/env bash
#
# Acceptance tests for scripts/stage-kit.sh, which assembles a v3 kit's build
# context. sbx builds a local kit from its own directory only, so a staged kit
# that misses a file the Dockerfile COPYs fails at `sbx create`, minutes into
# the build. These cases catch that statically.
#
# Usage: scripts/test-stage-kit.sh

set -uo pipefail

cd "$(dirname "$0")/.."

work="$(mktemp -d "${TMPDIR:-/tmp}/stage-kit.XXXXXX")"
trap 'rm -rf "$work"' EXIT

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

# stage_cases <agent> <kit-name>
stage_cases() {
	local agent="$1" name="$2" out dir missing src

	out="$(./scripts/stage-kit.sh "$agent" "$work/$agent" 2>&1)"
	dir="$work/$agent/$name"
	expect "$agent: prints the staged kit directory" "$dir" "$out"

	expect "$agent: descriptor is staged under the kit name" \
		'# syntax=docker/sandbox-kit:3' "$(head -n 1 "$dir/$name.yaml" 2>&1)"

	# The frontend builds the recipe's last stage, and the Dockerfile's last
	# stage is codex, so the staged recipe has to end on the agent's stage.
	expect "$agent: recipe ends on the agent stage" \
		"FROM $agent" "$(tail -n 1 "$dir/$name.dockerfile" 2>&1)"

	expect "$agent: recipe is the repo Dockerfile plus that stage" \
		'SAME' "$(sed '$d' "$dir/$name.dockerfile" | sed '$d' | cmp -s - Dockerfile && echo SAME || echo DIFFERENT)"

	# Every COPY source the recipe names must be in the context, except the
	# other agent's kit home: BuildKit builds only the stages the last one needs.
	missing=''
	while IFS= read -r src; do
		[[ -e "$dir/$src" ]] || missing="$missing $src"
	done < <(awk '$1 == "COPY" { for (i = 2; i < NF; i++) if ($i !~ /^--/) print $i }' Dockerfile |
		grep -v '^agent/' ; awk '$1 == "COPY" { for (i = 2; i < NF; i++) if ($i !~ /^--/) print $i }' Dockerfile |
		grep "^agent/$agent/" || true)
	expect "$agent: every COPY source is in the context" 'NONE' "${missing:-NONE}"

	# Files a descriptor names (agent-context@1 contentFile) are read from the
	# context by the frontend, relative to the kit directory.
	for src in "agent/$agent"/*; do
		[[ -f "$src" && "$src" != "agent/$agent/$name.yaml" && "$(basename "$src")" != spec.yaml ]] || continue
		expect "$agent: $(basename "$src") is staged beside the descriptor" \
			'SAME' "$(cmp -s "$src" "$dir/$(basename "$src")" && echo SAME || echo DIFFERENT)"
	done

	expect "$agent: kit home is staged byte for byte" \
		'SAME' "$(diff -r -x .DS_Store "agent/$agent/files/home" "$dir/agent/$agent/files/home" >/dev/null && echo SAME || echo DIFFERENT)"

	expect "$agent: no .DS_Store reaches the context" \
		'0' "$(find "$dir" -name .DS_Store | wc -l | tr -d ' ')"

	# Restaging must not leave a file the source no longer has.
	touch "$dir/stale"
	./scripts/stage-kit.sh "$agent" "$work/$agent" >/dev/null 2>&1
	expect "$agent: restaging starts from an empty directory" \
		'GONE' "$([[ -e "$dir/stale" ]] && echo KEPT || echo GONE)"
}

stage_cases claude jarvis-engineer
stage_cases codex jarvis-engineer-codex

expect 'an unknown agent is refused' \
	'usage: scripts/stage-kit.sh claude|codex' \
	"$(./scripts/stage-kit.sh nope "$work/nope" 2>&1)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
