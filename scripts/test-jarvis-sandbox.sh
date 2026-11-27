#!/usr/bin/env bash
#
# Acceptance tests for scripts/jarvis-sandbox.sh.
#
# sbx and docker are stubs on PATH: `sbx ls -q` prints $STUB_SBX_LS (the
# sandboxes that "exist") and every other call is logged; `docker` exits 0, so
# the kit builder counts as present. Every case runs with --dry-run and reads
# the `+ ...` lines, so no sandbox is created. The kit is staged for real into
# the git-ignored build/kits/.
#
# Not covered: the branch where `sbx port publish` fails after `sbx create`
# (the sandbox exists but is unpublished, and the script prints the recovery
# command and exits 1). --dry-run never runs the publish, so it cannot fail.
#
# Usage: scripts/test-jarvis-sandbox.sh

set -uo pipefail

cd "$(dirname "$0")/.."
repo="$(pwd)"
script="$repo/scripts/jarvis-sandbox.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/jarvis-sandbox-test.XXXXXX")"
work="$(cd "$work" && pwd)"
trap 'rm -rf "$work"' EXIT

mkdir "$work/bin" "$work/workspace"
cat >"$work/bin/sbx" <<'EOF'
#!/bin/sh
if [ "$1" = ls ]; then
	[ -z "${STUB_SBX_LS:-}" ] || printf '%s\n' "$STUB_SBX_LS"
	exit 0
fi
echo "sbx $*" >>"$STUB_LOG"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' >"$work/bin/docker"
chmod +x "$work/bin/sbx" "$work/bin/docker"
: >"$work/env"

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

# expect_not <name> <unwanted-substring> <actual>
expect_not() {
	if [[ "$3" != *"$2"* ]]; then
		printf 'ok   %s\n' "$1"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n     unwanted substring: %s\n     got: %s\n' "$1" "$2" "$3"
		fail=$((fail + 1))
	fi
}

# launch <args...> -- runs the script under /bin/bash (3.2 on macOS) with
# --dry-run, a throwaway env file and workspace, and the sandbox name probe.
# Sets: out (stdout+stderr), status, plan (the `+ ...` lines, in order).
launch() {
	out="$(STUB_LOG="$work/calls" PATH="$work/bin:$PATH" /bin/bash "$script" claude --dry-run \
		--name probe --env-file "$work/env" "$@" "$work/workspace" 2>&1)"
	status=$?
	plan="$(printf '%s\n' "$out" | grep '^+ ' || true)"
}

# line_of <pattern> -- the line number of the first plan line matching it.
line_of() {
	printf '%s\n' "$plan" | grep -n -- "$1" | head -n 1 | cut -d: -f1
}

printf '== jarvis-sandbox ==\n'

# --- --publish publishes after create, before attach ---------------------
launch
expect "without --publish it creates the sandbox" "sbx create --name probe" "$plan"
expect_not "without --publish nothing is published" "port publish" "$plan"

launch --publish 8080
expect "--publish PORT means PORT:PORT" "+ sbx port publish probe 8080:8080" "$plan"

launch --publish 9000:8080
expect "--publish HOST:PORT is passed as given" "+ sbx port publish probe 9000:8080" "$plan"

launch --publish 8080 --publish 9090:80
expect "repeated --publish makes one call with every spec" "+ sbx port publish probe 8080:8080 9090:80" "$plan"
expect "repeated --publish publishes once" "calls=1" "calls=$(printf '%s\n' "$plan" | grep -c 'port publish')"

launch --publish 8080
create="$(line_of 'sbx create')"
publish="$(line_of 'sbx port publish')"
attach="$(line_of 'sbx run')"
expect "the publish comes after create" "order=ok" "order=$([[ -n "$create" && -n "$publish" && $create -lt $publish ]] && echo ok || echo "create=$create publish=$publish")"
expect "the publish comes before attach" "order=ok" "order=$([[ -n "$publish" && -n "$attach" && $publish -lt $attach ]] && echo ok || echo "publish=$publish attach=$attach")"

launch --publish 08080
expect "a leading zero is decimal, not octal" "+ sbx port publish probe 8080:8080" "$plan"

launch --publish 8080 --detach
expect "--detach still publishes" "+ sbx port publish probe 8080:8080" "$plan"
expect_not "--detach does not attach" "sbx run" "$plan"

STUB_SBX_LS=probe launch --publish 8080 --recreate
expect "--recreate removes the old sandbox" "+ sbx rm --force probe" "$plan"
expect "--recreate publishes on the new one" "+ sbx port publish probe 8080:8080" "$plan"
expect "--recreate publishes after create" "order=ok" "order=$([[ $(line_of 'sbx create') -lt $(line_of 'port publish') ]] && echo ok)"

# --- an existing sandbox is re-attached, and --publish is not applied ------
STUB_SBX_LS=probe launch --publish 8080
expect "an existing sandbox is re-attached" "+ sbx run --name probe" "$plan"
expect_not "an existing sandbox is not published" "port publish" "$plan"
expect "an existing sandbox says --publish was ignored" "--publish ignored" "$out"
expect "the note gives the publish command" "sbx port publish probe 8080:8080" "$out"

# --- invalid values exit 2 before anything runs ---------------------------
for value in abc 0 70000 8080: :8080 127.0.0.1:8080:80 8080/udp '' 123456 8080:0; do
	launch --publish "$value"
	expect "--publish '$value' exits 2" "status=2" "status=$status"
	expect "--publish '$value' prints usage" "Usage: jarvis-sandbox" "$out"
	expect "--publish '$value' names the bad value" "invalid --publish value" "$out"
	expect_not "--publish '$value' creates nothing" "sbx create" "$plan"
done

out="$(STUB_LOG="$work/calls" PATH="$work/bin:$PATH" /bin/bash "$script" claude --dry-run --name probe --publish 2>&1)"
status=$?
expect "--publish without a value exits 2" "status=2" "status=$status"
expect "--publish without a value prints usage" "Usage: jarvis-sandbox" "$out"

launch -h
expect "the usage documents --publish" "--publish PORT|HOST:PORT" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
