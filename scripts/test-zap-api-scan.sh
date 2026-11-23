#!/usr/bin/env bash
#
# Acceptance tests for scripts/zap-api-scan.sh.
#
# docker is a stub on PATH: `docker info` exits $STUB_INFO_EXIT (default 0) and
# `docker run` logs its argv and exits $STUB_EXIT (default 0). Nothing is pulled
# or scanned, so these tests cannot show that ZAP reaches a host API or what the
# reports contain; that needs a live Docker daemon.
#
# Usage: scripts/test-zap-api-scan.sh

set -uo pipefail

cd "$(dirname "$0")/.."
repo="$(pwd)"
script="$repo/scripts/zap-api-scan.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/zap-api-scan.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir "$work/bin" "$work/empty" "$work/fixtures"
cat >"$work/bin/docker" <<'EOF'
#!/bin/sh
case "$1" in
info)
	echo "info" >>"$STUB_LOG"
	exit "${STUB_INFO_EXIT:-0}"
	;;
run)
	echo "$*" >>"$STUB_LOG"
	exit "${STUB_EXIT:-0}"
	;;
esac
exit 99
EOF
chmod +x "$work/bin/docker"
printf '{}\n' >"$work/fixtures/openapi.json"
printf '10020\tFAIL\n' >"$work/fixtures/rules.conf"
fixtures="$(cd "$work/fixtures" && pwd)"

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

# zap <script args...> -- runs the script under /bin/bash (3.2 on macOS) in a
# fresh working directory ($ZAP_CWD overrides it), with the stub docker on PATH.
# Sets: out (stdout+stderr), status, calls (every stub call, one per line),
# cwd (the working directory).
zap() {
	cwd="${ZAP_CWD:-$work/cwd}"
	if [[ -z "${ZAP_CWD:-}" ]]; then
		rm -rf "$cwd"
		mkdir "$cwd"
	fi
	cwd="$(cd "$cwd" && pwd)"
	: >"$work/calls"
	out="$(cd "$cwd" && STUB_LOG="$work/calls" PATH="$work/bin:$PATH" /bin/bash "$script" "$@" 2>&1)"
	status=$?
	calls="$(cat "$work/calls")"
}

# run_call -- the logged `docker run` argv, empty when docker run was not called.
run_call() {
	grep '^run ' "$work/calls" || true
}

printf '== zap-api-scan ==\n'

# --- invalid input exits 64 and never reaches docker ----------------------
refusals=(
	"missing -t|-f openapi"
	"missing -f|-t http://localhost:8080/openapi.json"
	"unsupported -f|-t http://localhost:8080/openapi.json -f wsdl"
	"unknown option|-t http://localhost:8080/openapi.json -f openapi --bogus"
	"non-loopback target|-t https://example.com/openapi.json -f openapi"
	"loopback lookalike host|-t http://localhost.example.com/openapi.json -f openapi"
	"userinfo smuggling a remote host|-t http://localhost@example.com/openapi.json -f openapi"
	"non-loopback -O|-t http://localhost:8080/openapi.json -f openapi -O example.com"
	"graphql with a file target|-t $fixtures/openapi.json -f graphql"
	"openapi file target without -O|-t $fixtures/openapi.json -f openapi"
	"openapi file target with a non-loopback -O|-t $fixtures/openapi.json -f openapi -O http://example.com"
	"soap file target|-t $fixtures/openapi.json -f soap"
	"-O with soap|-t http://localhost:8080/service?wsdl -f soap -O localhost:8080"
	"-O with graphql|-t http://localhost:8080/graphql -f graphql -O localhost:8080"
	"removed --host-network option|-t http://localhost:8080/openapi.json -f openapi --host-network"
)
for entry in "${refusals[@]}"; do
	name="${entry%%|*}"
	# shellcheck disable=SC2086 # the table stores arguments as one word-split string
	zap ${entry#*|}
	expect "rejects $name: exits 64" "status=64" "status=$status"
	expect "rejects $name: prints usage" "Usage:" "$out"
	expect "rejects $name: docker not called" "calls=0" "calls=$(printf '%s' "$calls" | grep -c .)"
done

zap -t http://localhost:8080/openapi.json -f openapi -o "$fixtures/openapi.json"
expect "rejects an out dir that is a file: exits 64" "status=64" "status=$status"
expect "rejects an out dir that is a file: docker run not called" "run=" "run=$(run_call)"

# --- missing files exit 66 ------------------------------------------------
zap -t "$work/nope.json" -f openapi
expect "missing definition file exits 66" "status=66" "status=$status"
expect "missing definition file does not run docker" "run=" "run=$(run_call)"

zap -t http://localhost:8080/openapi.json -f openapi -c "$work/nope.conf"
expect "missing config file exits 66" "status=66" "status=$status"

# --- docker preflight exits 69 --------------------------------------------
out="$(cd "$work" && PATH="$work/empty" /bin/bash "$script" -t http://localhost:8080/openapi.json -f openapi 2>&1)"
status=$?
expect "docker absent from PATH exits 69" "status=69" "status=$status"
expect "docker absent from PATH names docker" "docker" "$out"

STUB_INFO_EXIT=1 zap -t http://localhost:8080/openapi.json -f openapi
expect "unreachable docker daemon exits 69" "status=69" "status=$status"
expect "unreachable docker daemon does not run the scan" "run=" "run=$(run_call)"

# --- URL target -----------------------------------------------------------
zap -t http://localhost:8080/openapi.json -f openapi
expect "URL target exits 0 when the scan passes" "status=0" "status=$status"
expect "scan runs the pinned zap-stable image" " zaproxy/zap-stable:" "$(run_call)"
expect "scan never uses the latest tag" "NO_LATEST" "$(run_call | grep -q 'zap-stable:latest' && echo LATEST || echo NO_LATEST)"
expect "scan removes its container" "run --rm " "$(run_call)"
expect "scan runs zap-api-scan.py with target and format" \
	"zap-api-scan.py -t http://host.docker.internal:8080/openapi.json -f openapi" "$(run_call)"
expect "scan writes an html and a json report" "-r report.html -J report.json" "$(run_call)"
expect "scan allocates no tty when stdout is not a terminal" "NO_TTY" \
	"$(run_call | grep -q '^run --rm -t \|^run -t ' && echo TTY || echo NO_TTY)"
expect "scan checks the daemon first" "info" "$calls"

# --- loopback hosts reach the container through host.docker.internal -------
loopbacks=(
	"localhost|http://localhost:8080/openapi.json|http://host.docker.internal:8080/openapi.json"
	"127.0.0.1|http://127.0.0.1:9000/v1/spec|http://host.docker.internal:9000/v1/spec"
	"[::1]|http://[::1]:8080/openapi.json|http://host.docker.internal:8080/openapi.json"
	"localhost without a port|https://localhost/openapi.json|https://host.docker.internal/openapi.json"
)
for entry in "${loopbacks[@]}"; do
	name="${entry%%|*}"
	rest="${entry#*|}"
	zap -t "${rest%%|*}" -f openapi
	expect "$name target is rewritten for the container" "-t ${rest#*|} " "$(run_call)"
	expect "$name rewrite is announced on stderr" "host.docker.internal" "$out"
	expect "$name target adds the host-gateway mapping" \
		"--add-host=host.docker.internal:host-gateway" "$(run_call)"
done

zap -t http://localhost:8080/openapi.json -f openapi -O localhost:8080
expect "bare -O on loopback is passed with the target's scheme" \
	"-O http://host.docker.internal:8080" "$(run_call)"

zap -t https://localhost:8443/openapi.json -f openapi -O localhost:9443
expect "bare -O takes the scheme from -t" "-O https://host.docker.internal:9443" "$(run_call)"

zap -t http://localhost:8080/openapi.json -f openapi -O host.docker.internal:8080
expect "-O accepts the container's own host alias and adds a scheme" \
	"-O http://host.docker.internal:8080" "$(run_call)"

zap -t http://localhost:8080/openapi.json -f openapi -O https://127.0.0.1:9000
expect "a full -O URL keeps its own scheme and is rewritten" \
	"-O https://host.docker.internal:9000" "$(run_call)"

zap -t http://host.docker.internal:8080/openapi.json -f openapi
expect "a host.docker.internal target is passed unchanged" \
	"-t http://host.docker.internal:8080/openapi.json " "$(run_call)"

# --- spec-named servers never reach a remote host (ZAP follows servers[].url) ---
zap -t http://localhost:8080/openapi.json -f openapi
expect "openapi URL target forces -O to the rewritten origin" \
	"-O http://host.docker.internal:8080" "$(run_call)"

zap -t https://localhost/openapi.json -f openapi
expect "openapi forced -O keeps the target scheme and omits an absent port" \
	"END" "$(run_call | grep -q -- '-O https://host.docker.internal$' && echo END || echo NOT_END)"

zap -t "$fixtures/openapi.json" -f openapi -O localhost:8080
expect "openapi file target with a loopback -O is accepted" \
	"-O http://host.docker.internal:8080" "$(run_call)"

zap -t http://localhost:8080/service?wsdl -f soap
expect "soap URL target is accepted" "-f soap" "$(run_call)"
expect "soap URL target passes no -O (ZAP ignores it)" "NO_O" \
	"$(run_call | grep -qE ' -O ' && echo O || echo NO_O)"
expect "soap URL target warns that the WSDL decides where requests go" "soap:address" "$out"

zap -t http://localhost:8080/openapi.json -f openapi
expect "the default image is pinned by digest" "@sha256:" "$(run_call)"

# --- local definition file ------------------------------------------------
zap -t "$fixtures/openapi.json" -f openapi -O localhost:8080
expect "local file mounts only the file, read-only" \
	"-v $fixtures/openapi.json:/zap/spec/openapi.json:ro" "$(run_call)"
expect "local file does not mount its directory" "NO_DIR_MOUNT" \
	"$(run_call | grep -q -- "-v $fixtures:" && echo DIR_MOUNT || echo NO_DIR_MOUNT)"
expect "local file is passed by its mounted path" "-t /zap/spec/openapi.json " "$(run_call)"

ZAP_CWD="$fixtures" zap -t openapi.json -f openapi -O localhost:8080
expect "bare filename mounts the file by its absolute path" \
	"-v $fixtures/openapi.json:/zap/spec/openapi.json:ro" "$(run_call)"
expect "bare filename does not mount the working directory" "NO_DIR_MOUNT" \
	"$(run_call | grep -q -- "-v $fixtures:" && echo DIR_MOUNT || echo NO_DIR_MOUNT)"
expect "bare filename is passed by its mounted path" "-t /zap/spec/openapi.json " "$(run_call)"

ZAP_CWD="$work" zap -t fixtures/openapi.json -f openapi -O localhost:8080
expect "relative path with a directory mounts the file by its absolute path" \
	"-v $fixtures/openapi.json:/zap/spec/openapi.json:ro" "$(run_call)"

printf '{}\n' >"$fixtures/my spec.json"
zap -t "$fixtures/my spec.json" -f openapi -O localhost:8080
expect "a file name with a space is mounted and passed intact" \
	"-v $fixtures/my spec.json:/zap/spec/my spec.json:ro" "$(run_call)"
expect "a file name with a space is passed by its mounted path" "-t /zap/spec/my spec.json " "$(run_call)"

mkdir "$work/links"
ln -s "$fixtures/openapi.json" "$work/links/linked.json"
zap -t "$work/links/linked.json" -f openapi -O localhost:8080
expect "a symlinked file is mounted by the link path under the link's name" \
	"-v $work/links/linked.json:/zap/spec/linked.json:ro" "$(run_call)"

mkdir "$work/colon:dir"
printf '{}\n' >"$work/colon:dir/openapi.json"
zap -t "$work/colon:dir/openapi.json" -f openapi -O localhost:8080
expect "a definition path containing a colon is rejected: exits 64" "status=64" "status=$status"
expect "a definition path containing a colon is rejected: docker run not called" "run=" "run=$(run_call)"

zap -t http://localhost:8080/openapi.json -f openapi -c "$work/colon:dir/openapi.json"
expect "a config path containing a colon is rejected: exits 64" "status=64" "status=$status"

zap -t http://localhost:8080/openapi.json -f openapi -o "$work/colon:out"
expect "an out dir path containing a colon is rejected: exits 64" "status=64" "status=$status"
expect "an out dir path containing a colon is not created" "dir=no" \
	"dir=$([[ -d "$work/colon:out" ]] && echo yes || echo no)"

mkdir "$work/a:b"
ZAP_CWD="$work/a:b" zap -t http://localhost:8080/openapi.json -f openapi
expect "a working directory containing a colon with the default out dir is rejected: exits 64" \
	"status=64" "status=$status"
expect "a working directory containing a colon with the default out dir: docker run not called" \
	"calls=0" "calls=$(printf '%s' "$calls" | grep -c .)"
expect "a working directory containing a colon with the default out dir: out dir not created" "dir=no" \
	"dir=$([[ -d "$work/a:b/zap-reports" ]] && echo yes || echo no)"

zap -t http://localhost:8080/graphql -f graphql
expect "graphql passes the endpoint URL" "-t http://host.docker.internal:8080/graphql -f graphql" "$(run_call)"
expect "graphql mounts no spec directory" "NO_SPEC" \
	"$(run_call | grep -q '/zap/spec' && echo SPEC || echo NO_SPEC)"

zap -t http://localhost:8080/openapi.json -f openapi -c "$fixtures/rules.conf"
expect "config file mounts only the file, read-only" \
	"-v $fixtures/rules.conf:/zap/config/rules.conf:ro" "$(run_call)"
expect "config file does not mount its directory" "NO_DIR_MOUNT" \
	"$(run_call | grep -q -- "-v $fixtures:" && echo DIR_MOUNT || echo NO_DIR_MOUNT)"
expect "config file is passed by its mounted path" "-c /zap/config/rules.conf" "$(run_call)"

ZAP_CWD="$fixtures" zap -t http://localhost:8080/openapi.json -f openapi -c rules.conf
expect "bare config filename mounts the file by its absolute path" \
	"-v $fixtures/rules.conf:/zap/config/rules.conf:ro" "$(run_call)"

# --- scan mode and report directory ---------------------------------------
zap -t http://localhost:8080/openapi.json -f openapi
expect "default is safe mode" " -S" "$(run_call)"
expect "default does not tolerate warnings" "NO_I" \
	"$(run_call | grep -qE ' -I( |$)' && echo I || echo NO_I)"

zap -t http://localhost:8080/openapi.json -f openapi --active
expect "--active omits safe mode" "NO_S" "$(run_call | grep -qE ' -S( |$)' && echo S || echo NO_S)"
expect "--active still runs the scan" "zap-api-scan.py" "$(run_call)"

zap -t http://localhost:8080/openapi.json -f openapi --no-fail-on-warn
expect "--no-fail-on-warn passes -I" " -I" "$(run_call)"

zap -t http://localhost:8080/openapi.json -f openapi
expect "default out dir is ./zap-reports, mounted rw at /zap/wrk" \
	"-v $cwd/zap-reports:/zap/wrk:rw" "$(run_call)"
expect "default out dir is created" "dir=yes" "dir=$([[ -d "$cwd/zap-reports" ]] && echo yes || echo no)"

zap -t http://localhost:8080/openapi.json -f openapi -o reports/nested
expect "a relative out dir is created and mounted by its absolute path" \
	"-v $cwd/reports/nested:/zap/wrk:rw" "$(run_call)"
expect "a nested out dir is created" "dir=yes" "dir=$([[ -d "$cwd/reports/nested" ]] && echo yes || echo no)"

zap -t http://localhost:8080/openapi.json -f openapi -- -d -D 5
expect "arguments after -- reach ZAP last" "-J report.json -S -O http://host.docker.internal:8080 -d -D 5" "$(run_call)"

ZAP_IMAGE=example.test/zap:custom zap -t http://localhost:8080/openapi.json -f openapi
expect "ZAP_IMAGE overrides the pinned image" " example.test/zap:custom zap-api-scan.py" "$(run_call)"

# --- ZAP's exit code passes through unchanged -----------------------------
for code in 0 1 2 3 125; do
	STUB_EXIT=$code zap -t http://localhost:8080/openapi.json -f openapi
	expect "ZAP exit $code is returned unchanged" "status=$code" "status=$status"
done

# --- --help ---------------------------------------------------------------
zap --help
expect "--help exits 0" "status=0" "status=$status"
expect "--help documents the exit codes" "64" "$out"
expect "--help says the default run can still write data" "even the default run" "$out"
expect "--help no longer calls the default read-only" "NO_PASSIVE_ONLY" \
	"$(printf '%s' "$out" | grep -qi 'passive (baseline) scan only' && echo PASSIVE_ONLY || echo NO_PASSIVE_ONLY)"
expect "--help calls docker never" "calls=0" "calls=$(printf '%s' "$calls" | grep -c .)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
