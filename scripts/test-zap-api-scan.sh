#!/usr/bin/env bash
#
# Acceptance tests for scripts/zap-api-scan.sh, the REST client of a ZAP daemon
# that runs on the user's host.
#
# curl and sleep are stubs on PATH. The stub curl logs every call, one line
# each, to $STUB_LOG as
#   op=<component>.<type>.<op> method=<M> url=<url> hdr=[<header>]... body=[<k=v>]...
# with `-H @file` header lines and `name@file` body values resolved, and logs
# its raw argv to $STUB_ARGV, so a test can show that a secret travels in a
# header file or a body file but never on the command line. It answers from
# $STUB_FIXTURES/<op>.json (default {"Result":"OK"}); <op>.seq answers one line
# per call (the last line repeats); <op>.exit makes curl exit with that code;
# <op>.exit.seq gives one curl exit code per call (0 answers normally);
# <op>.http sets the HTTP status (default 200); <op>.kill sends TERM to the
# script on the first call. Calls to a non-ZAP URL (the local reachability
# check) use the op name `local`. fileDownload answers from report.json or
# report.html by the requested file name. The stub sleep only logs.
#
# Nothing talks to a real ZAP, so these tests cannot show that ZAP reaches the
# API, that the sbx proxy forwards the headers, or what real alerts look like.
# The report.json fixture is hand-built from the shape the ADR observed, not a
# captured 2.17.0 report.
#
# Usage: scripts/test-zap-api-scan.sh

set -uo pipefail

cd "$(dirname "$0")/.."
repo="$(pwd)"
script="$repo/scripts/zap-api-scan.sh"

command -v jq >/dev/null 2>&1 || {
	echo "test-zap-api-scan: jq is required (the script under test needs it)" >&2
	exit 1
}

# A sandbox that has ZAP configured exports these; the cases below must not
# inherit them.
unset ZAP_URL ZAP_API_KEY ZAP_TARGET_HOST SANDBOX_NAME

work="$(mktemp -d "${TMPDIR:-/tmp}/zap-api-scan-test.XXXXXX")"
work="$(cd "$work" && pwd)"
trap 'rm -rf "$work"' EXIT

mkdir "$work/bin" "$work/fx" "$work/files" "$work/nocurl" "$work/nojq"

cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$STUB_ARGV"
method=GET outfile='' wfmt='' url='' hdr='' body=''
while [ $# -gt 0 ]; do
	case "$1" in
	-o) outfile="$2"; shift ;;
	-w) wfmt="$2"; shift ;;
	-X) method="$2"; shift ;;
	--max-time | --noproxy) shift ;;
	-H)
		if [ "${2#@}" != "$2" ]; then
			while IFS= read -r line || [ -n "$line" ]; do hdr="$hdr[$line]"; done <"${2#@}"
		else
			hdr="$hdr[$2]"
		fi
		shift
		;;
	-d | --data | --data-urlencode)
		[ "$method" = GET ] && method=POST
		v="$2"
		case "$v" in
		*=*) ;;
		*@*) v="${v%%@*}=$(cat "${v#*@}")" ;;
		esac
		[ -n "$v" ] && body="$body[$v]"
		shift
		;;
	-*) ;;
	*) url="$1" ;;
	esac
	shift
done
op=local
case "$url" in
*/JSON/*/*/*/ | */OTHER/*/*/*/)
	p="${url%/}"
	o="${p##*/}"; p="${p%/*}"
	t="${p##*/}"; p="${p%/*}"
	c="${p##*/}"
	op="$c.$t.$o"
	;;
esac
printf 'op=%s method=%s url=%s hdr=%s body=%s\n' "$op" "$method" "$url" "$hdr" "$body" >>"$STUB_LOG"
fx="$STUB_FIXTURES"
if [ -f "$fx/$op.kill" ]; then
	rm -f "$fx/$op.kill"
	kill -TERM "$PPID"
fi
if [ -f "$fx/$op.exit" ]; then
	echo "curl: stub failure" >&2
	exit "$(cat "$fx/$op.exit")"
fi
if [ -f "$fx/$op.exit.seq" ]; then
	n=$(($(cat "$fx/.xcount.$op" 2>/dev/null || echo 0) + 1))
	echo "$n" >"$fx/.xcount.$op"
	x="$(sed -n "${n}p" "$fx/$op.exit.seq")"
	if [ -n "$x" ] && [ "$x" != 0 ]; then
		echo "curl: stub failure" >&2
		exit "$x"
	fi
fi
if [ "$op" = core.other.fileDownload ]; then
	case "$body" in
	*.json]*) reply="$(cat "$fx/report.json")" ;;
	*) reply="$(cat "$fx/report.html")" ;;
	esac
elif [ -f "$fx/$op.seq" ]; then
	n=$(($(cat "$fx/.count.$op" 2>/dev/null || echo 0) + 1))
	echo "$n" >"$fx/.count.$op"
	reply="$(sed -n "${n}p" "$fx/$op.seq")"
	[ -n "$reply" ] || reply="$(sed -n '$p' "$fx/$op.seq")"
elif [ -f "$fx/$op.json" ]; then
	reply="$(cat "$fx/$op.json")"
else
	reply='{"Result":"OK"}'
fi
code=200
[ -f "$fx/$op.http" ] && code="$(cat "$fx/$op.http")"
if [ -n "$outfile" ]; then
	printf '%s\n' "$reply" >"$outfile"
else
	printf '%s\n' "$reply"
fi
[ -z "$wfmt" ] || printf '%s' "${wfmt//%\{http_code\}/$code}"
exit 0
EOF
cat >"$work/bin/sleep" <<'EOF'
#!/bin/sh
echo "sleep $*" >>"$STUB_LOG.sleep"
EOF
chmod +x "$work/bin/curl" "$work/bin/sleep"
# PATHs that lack one of the two required tools.
cp "$work/bin/curl" "$work/nojq/curl"
ln -s "$(command -v jq)" "$work/nocurl/jq"

printf '{"openapi":"3.0.0"}\n' >"$work/files/openapi.json"
printf '10020\tFAIL\tX-Frame-Options\n' >"$work/files/fail.conf"
printf '10020\tIGNORE\tX-Frame-Options\n10038\tIGNORE\tCSP\n' >"$work/files/ignore.conf"
printf '10020\tINFO\tX-Frame-Options\n10038\tINFO\tCSP\n' >"$work/files/info.conf"
printf '# a comment\n\n10020\tIGNORE\tX-Frame-Options\n' >"$work/files/partial.conf"
printf '10020\tIGNORE\tok\n10038\tLOUD\tbad level\n' >"$work/files/bad.conf"
files="$work/files"

# reset_fixtures -- the happy path: a reachable daemon, an import with no
# failures, one URL in the site, an idle passive queue and two WARN alerts.
reset_fixtures() {
	rm -rf "$work/fx"
	mkdir "$work/fx"
	local fx="$work/fx"
	printf '{"version":"2.17.0"}\n' >"$fx/core.view.version.json"
	printf '{"sites":[]}\n' >"$fx/core.view.sites.json"
	printf '{"rules":[]}\n' >"$fx/replacer.view.rules.json"
	printf '{"importUrl":[]}\n' >"$fx/openapi.action.importUrl.json"
	printf '{"importFile":[]}\n' >"$fx/openapi.action.importFile.json"
	printf '{"Result":"OK"}\n' >"$fx/graphql.action.importUrl.json"
	printf '{"urls":["http://host.docker.internal:8080/pets"]}\n' >"$fx/core.view.urls.json"
	printf '{"recordsToScan":"0"}\n' >"$fx/pscan.view.recordsToScan.json"
	printf '{"scan":"7"}\n' >"$fx/ascan.action.scan.json"
	printf '{"status":"100"}\n' >"$fx/ascan.view.status.json"
	printf '{"zapHomePath":"/home/zap/.ZAP"}\n' >"$fx/core.view.zapHomePath.json"
	printf '{"generate":"/home/zap/.ZAP/transfer/r"}\n' >"$fx/reports.action.generate.json"
	printf '{"Uploaded":"/home/zap/.ZAP/transfer/RUN/openapi.json"}\n' >"$fx/core.other.fileUpload.json"
	cat >"$fx/report.json" <<'JSON'
{"@programName":"ZAP","@version":"2.17.0","site":[{"@name":"http://host.docker.internal:8080","alerts":[
 {"pluginid":"10020","alert":"Missing Anti-clickjacking Header","name":"Missing Anti-clickjacking Header","riskcode":"2","riskdesc":"Medium (Medium)","cweid":"1021","instances":[{"uri":"http://host.docker.internal:8080/pets","method":"GET"}]},
 {"pluginid":"10038","alert":"Content Security Policy (CSP) Header Not Set","name":"Content Security Policy (CSP) Header Not Set","riskcode":"2","riskdesc":"Medium (High)","cweid":"693","instances":[{"uri":"http://host.docker.internal:8080/pets","method":"GET"}]}
]}]}
JSON
	printf '<html>report</html>\n' >"$fx/report.html"
}

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

# zap <script args...> -- runs the script under /bin/bash (3.2 on macOS) in a
# fresh working directory, with the stub curl and sleep on PATH and the fixtures
# as set up since the last call (reset afterwards). ZAP_URL and ZAP_API_KEY
# default to a valid configuration; set them (or ZAP_TARGET_HOST,
# SANDBOX_NAME) as a prefix to override, and list names in UNSET to remove
# them. ZAP_PATH replaces PATH. Sets: out (stdout+stderr), stdout, status,
# calls (the stub curl log), argv (the stub curl argv log), cwd. The script's
# TMPDIR is a fresh $work/tmpdir, so leftovers() shows what a run left behind.
zap() {
	cwd="$work/cwd"
	rm -rf "$cwd"
	mkdir "$cwd"
	: >"$work/calls"
	: >"$work/calls.sleep"
	: >"$work/argv"
	rm -rf "$work/tmpdir"
	mkdir "$work/tmpdir"
	local -a envargs=(-u ZAP_URL -u ZAP_API_KEY -u ZAP_TARGET_HOST -u SANDBOX_NAME)
	local unset_list=" ${UNSET:-} "
	[[ "$unset_list" == *" ZAP_URL "* ]] || envargs+=("ZAP_URL=${ZAP_URL-http://host.docker.internal:8090}")
	[[ "$unset_list" == *" ZAP_API_KEY "* ]] || envargs+=("ZAP_API_KEY=${ZAP_API_KEY-testkey}")
	[[ -z "${ZAP_TARGET_HOST+x}" ]] || envargs+=("ZAP_TARGET_HOST=$ZAP_TARGET_HOST")
	[[ -z "${SANDBOX_NAME+x}" ]] || envargs+=("SANDBOX_NAME=$SANDBOX_NAME")
	envargs+=("TMPDIR=$work/tmpdir")
	envargs+=("STUB_LOG=$work/calls" "STUB_ARGV=$work/argv" "STUB_FIXTURES=$work/fx")
	envargs+=("PATH=${ZAP_PATH:-$work/bin:$PATH}")
	(cd "$cwd" && env "${envargs[@]}" /bin/bash "$script" "$@" >"$work/stdout" 2>"$work/stderr")
	status=$?
	stdout="$(cat "$work/stdout")"
	out="$stdout$(cat "$work/stderr")"
	calls="$(cat "$work/calls")"
	argv="$(cat "$work/argv")"
	reset_fixtures
}

# leftovers -- the files the last run left in its TMPDIR, or "none".
leftovers() {
	local left
	left="$(ls -A "$work/tmpdir")"
	printf '%s' "${left:-none}"
}

# count_calls -- the number of stub curl calls the last run made.
count_calls() {
	printf '%s' "$calls" | grep -c . || true
}

# call_of <op> -- the logged lines of one ZAP operation (or `local`).
call_of() {
	printf '%s\n' "$calls" | grep "^op=$1 " || true
}

# ops -- the operations of the last run, in order, one per line.
ops() {
	printf '%s\n' "$calls" | sed -n 's/^op=\([^ ]*\) .*/\1/p'
}

reset_fixtures
url=http://localhost:8080/openapi.json

printf '== zap-api-scan ==\n'

# --- -h works without any configuration ---------------------------------
UNSET="ZAP_URL ZAP_API_KEY" zap -h
expect "-h exits 0 with nothing configured" "status=0" "status=$status"
expect "-h prints the usage line" "Usage: zap-api-scan.sh -t TARGET" "$out"
expect "-h documents exit 78" "78" "$out"
expect "-h makes no curl call" "calls=0" "calls=$(count_calls)"

# --- not configured: one stderr line, exit 78, nothing else ---------------
UNSET=ZAP_URL zap -t "$url" -f openapi
expect "unset ZAP_URL exits 78" "status=78" "status=$status"
expect "unset ZAP_URL says ZAP is not configured" "ZAP is not configured (ZAP_URL is not set); scan skipped." "$out"
expect "unset ZAP_URL points to the skill's host setup" '"Host setup"' "$out"
expect "unset ZAP_URL prints a single line" "lines=1" "lines=$(printf '%s\n' "$out" | grep -c .)"
expect "unset ZAP_URL makes no curl call" "calls=0" "calls=$(count_calls)"
expect "unset ZAP_URL creates no out dir" "outdir=absent" "outdir=$([[ -e "$cwd/zap-reports" ]] && echo present || echo absent)"

UNSET=ZAP_URL zap -t "$work/missing.json" -f soap
expect "unset ZAP_URL is checked before input validation" "status=78" "status=$status"

ZAP_URL='' zap -t "$url" -f openapi
expect "empty ZAP_URL exits 78" "status=78" "status=$status"
expect "empty ZAP_URL says not configured" "ZAP is not configured" "$out"

bad_zap_urls=(
	"non-local host|http://zap.example.com:8090"
	"userinfo|http://user:pw@localhost:8090"
	"path beyond /|http://localhost:8090/JSON"
	"non-http scheme|ftp://localhost:8090"
	"lookalike host|http://localhost.example.com:8090"
)
for entry in "${bad_zap_urls[@]}"; do
	ZAP_URL="${entry#*|}" zap -t "$url" -f openapi
	expect "ZAP_URL with ${entry%%|*} exits 78" "status=78" "status=$status"
	expect "ZAP_URL with ${entry%%|*} makes no curl call" "calls=0" "calls=$(count_calls)"
done
ZAP_URL='http://user:pw@localhost:8090' zap -t "$url" -f openapi
expect_not "an invalid ZAP_URL is not echoed (it may carry credentials)" "pw@" "$out"

good_zap_urls=(
	"https|https://localhost:8090"
	"trailing slash|http://host.docker.internal:8090/"
	"127.0.0.1|http://127.0.0.1:8090"
	"[::1]|http://[::1]:8090"
)
for entry in "${good_zap_urls[@]}"; do
	ZAP_URL="${entry#*|}" zap -t "$url" -f openapi
	expect_not "ZAP_URL with ${entry%%|*} is accepted" "status=78" "status=$status"
done

ZAP_API_KEY='' zap -t "$url" -f openapi
expect "empty ZAP_API_KEY exits 78" "status=78" "status=$status"
expect "empty ZAP_API_KEY names the variable" "ZAP_API_KEY" "$out"
expect "empty ZAP_API_KEY makes no curl call" "calls=0" "calls=$(count_calls)"

UNSET=ZAP_API_KEY zap -t "$url" -f openapi
expect "unset ZAP_API_KEY exits 78" "status=78" "status=$status"

ZAP_API_KEY=$'abc\r\nX-Injected: 1' zap -t "$url" -f openapi
expect "a ZAP_API_KEY with a line break exits 78" "status=78" "status=$status"
expect_not "a rejected ZAP_API_KEY is never echoed" "abc" "$out"

ZAP_TARGET_HOST=example.com zap -t "$url" -f openapi
expect "bad ZAP_TARGET_HOST exits 78" "status=78" "status=$status"
expect "bad ZAP_TARGET_HOST names the variable" "ZAP_TARGET_HOST" "$out"
expect "bad ZAP_TARGET_HOST makes no curl call" "calls=0" "calls=$(count_calls)"

# --- missing tools exit 69 ------------------------------------------------
ZAP_PATH="$work/nocurl" zap -t "$url" -f openapi
expect "curl absent from PATH exits 69" "status=69" "status=$status"
expect "curl absent from PATH names curl" "curl" "$out"

ZAP_PATH="$work/nojq" zap -t "$url" -f openapi
expect "jq absent from PATH exits 69" "status=69" "status=$status"
expect "jq absent from PATH names jq" "jq" "$out"
expect "jq absent from PATH makes no curl call" "calls=0" "calls=$(count_calls)"

# --- invalid input exits 64 and never reaches curl ------------------------
export ZAP_TEST_HDR_EMPTY='' ZAP_TEST_HDR_BAD='no colon here' ZAP_TEST_HDR_CRLF=$'X-Auth: a\r\nX-Injected: b'
export ZAP_TEST_HDR_BADNAME='X Auth: a'
export ZAP_TEST_AUTH='Authorization: Bearer s3cr3t-t0ken' ZAP_TEST_AUTH_CLEANUP='X-Api-Token: cleanup-t0ken'
refusals=(
	"missing -t|-f openapi"
	"missing -f|-t $url"
	"unsupported -f|-t $url -f wsdl"
	"unknown option|-t $url -f openapi --bogus"
	"removed -O|-t $url -f openapi -O localhost:8080"
	"removed -g|-t $url -f openapi -g rules.conf"
	"-- with ZAP_ARGS|-t $url -f openapi -- -z x"
	"a value-taking option at the end|-t $url -f"
	"non-loopback target|-t https://example.com/openapi.json -f openapi"
	"loopback lookalike host|-t http://localhost.example.com/openapi.json -f openapi"
	"userinfo smuggling a remote host|-t http://localhost@example.com/openapi.json -f openapi"
	"host.docker.internal target|-t http://host.docker.internal:8080/openapi.json -f openapi"
	"--host-port 80|-t $url -f openapi --host-port 80"
	"--host-port 443|-t $url -f openapi --host-port 443"
	"--host-port 0|-t $url -f openapi --host-port 0"
	"--host-port 70000|-t $url -f openapi --host-port 70000"
	"--host-port abc|-t $url -f openapi --host-port abc"
	"URL target without a port|-t http://localhost/openapi.json -f openapi"
	"file target without --host-port|-t $files/openapi.json -f openapi"
	"graphql with a file target|-t $files/openapi.json -f graphql --host-port 8080"
	"--timeout 0|-t $url -f openapi --timeout 0"
	"--timeout abc|-t $url -f openapi --timeout abc"
	"--timeout 241|-t $url -f openapi --timeout 241"
	"a bad -c line|-t $url -f openapi -c $files/bad.conf"
	"--header-env naming an unset variable|-t $url -f openapi --header-env ZAP_TEST_HDR_UNSET"
	"--header-env naming an empty variable|-t $url -f openapi --header-env ZAP_TEST_HDR_EMPTY"
	"--header-env value without Name:|-t $url -f openapi --header-env ZAP_TEST_HDR_BAD"
	"--header-env value with CR/LF|-t $url -f openapi --header-env ZAP_TEST_HDR_CRLF"
	"--header-env header name with a space|-t $url -f openapi --header-env ZAP_TEST_HDR_BADNAME"
	"--header-env invalid variable name|-t $url -f openapi --header-env 1BAD"
	"out dir that is a file|-t $url -f openapi -o $files/openapi.json"
)
for entry in "${refusals[@]}"; do
	name="${entry%%|*}"
	# shellcheck disable=SC2086 # the table stores arguments as one word-split string
	zap ${entry#*|}
	expect "rejects $name: exits 64" "status=64" "status=$status"
	expect "rejects $name: prints usage" "Usage:" "$out"
	expect "rejects $name: curl not called" "calls=0" "calls=$(count_calls)"
done

zap -t "$url" -f soap
expect "-f soap exits 64" "status=64" "status=$status"
expect "-f soap explains why SOAP is refused" "SOAP is not supported" "$out"
expect "-f soap cites the ADR finding" "F3" "$out"
expect "-f soap makes no curl call" "calls=0" "calls=$(count_calls)"

zap -t "$url" -f openapi -- -z x
expect "-- says ZAP_ARGS have no meaning" "ZAP_ARGS have no meaning in API mode" "$out"

zap -t "$url" -f openapi -c "$files/bad.conf"
expect "a bad -c line names its line number" "line 2" "$out"

zap -t "$url" -f openapi --header-env ZAP_TEST_HDR_CRLF
expect_not "a rejected --header-env value is never echoed" "X-Injected" "$out"

# --- missing files exit 66 ------------------------------------------------
zap -t "$work/nope.json" -f openapi --host-port 8080
expect "missing definition file exits 66" "status=66" "status=$status"
expect "missing definition file makes no curl call" "calls=0" "calls=$(count_calls)"

zap -t "$url" -f openapi -c "$work/nope.conf"
expect "missing config file exits 66" "status=66" "status=$status"
expect "missing config file makes no curl call" "calls=0" "calls=$(count_calls)"

# --- the daemon unreachable or rejecting the request exits 69 --------------
for code in 7 28 6 56; do
	echo "$code" >"$work/fx/core.view.version.exit"
	zap -t "$url" -f openapi
	expect "curl exit $code on version exits 69" "status=69" "status=$status"
	expect "curl exit $code on version stops before the slate" "deleteAlerts=" "deleteAlerts=$(call_of alert.action.deleteAlerts)"
done
echo 52 >"$work/fx/core.view.version.exit"
zap -t "$url" -f openapi
expect "an empty reply (curl 52) on version exits 69" "status=69" "status=$status"
expect "an empty reply names key, Host header and permitted address" "rejected (key, Host header or permitted address)" "$out"
expect_not "a rejected request never prints the key" "testkey" "$out"
echo 403 >"$work/fx/core.view.version.http"
zap -t "$url" -f openapi
expect "a non-200 version reply exits 69" "status=69" "status=$status"

# --- header hygiene: the key travels only in a header file ----------------
zap -t "$url" -f openapi
expect "a clean run against the stub exits 2 (two WARN alerts)" "status=2" "status=$status"
zap_lines="$(printf '%s\n' "$calls" | grep -v '^op=local ')"
expect "every ZAP call sends Host: zap" "missing=0" "missing=$(printf '%s\n' "$zap_lines" | grep -vc '\[Host: zap\]')"
expect "every ZAP call sends the key header" "missing=0" "missing=$(printf '%s\n' "$zap_lines" | grep -vc '\[X-ZAP-API-Key: testkey\]')"
expect "every ZAP call goes to ZAP_URL" "missing=0" "missing=$(printf '%s\n' "$zap_lines" | grep -vc ' url=http://host.docker.internal:8090/')"
expect "every ZAP call is a POST" "missing=0" "missing=$(printf '%s\n' "$zap_lines" | grep -vc ' method=POST ')"
expect_not "the key never appears in curl's argv" "testkey" "$argv"
expect_not "the key never appears in a URL" "testkey" "$(printf '%s\n' "$calls" | sed 's/ hdr=.*//')"
expect_not "the key is never sent as apikey=" "apikey" "$calls"
expect_not "the key never appears in the output" "testkey" "$out"
expect "the first call is the local reachability check" "local" "$(ops | sed -n 1p)"
expect "the local check targets -t itself" "url=$url " "$(call_of local)"
expect "the second call is the version preflight" "core.view.version" "$(ops | sed -n 2p)"

# --- the slate: this site only, never global state ------------------------
zap -t "$url" -f openapi
expect "the slate deletes this site's alerts before its node" "alert.action.deleteAlerts core.action.deleteSiteNode" "$(ops | tr '\n' ' ')"
expect "deleteAlerts is scoped to SITE" "[baseurl=http://host.docker.internal:8080]" "$(call_of alert.action.deleteAlerts | sed -n 1p)"
expect "deleteSiteNode is scoped to SITE" "[url=http://host.docker.internal:8080]" "$(call_of core.action.deleteSiteNode | sed -n 1p)"
for op in core.action.newSession core.action.loadSession core.action.setMode setOption setScanner; do
	expect_not "never calls $op" "$op" "$(ops)"
done

printf '{"rules":[{"description":"jarvis-zap:http://host.docker.internal:8080:jarvis-old-1-2","enabled":"true"},{"description":"jarvis-zap:http://host.docker.internal:80800:other","enabled":"true"},{"description":"someone else","enabled":"true"}]}\n' >"$work/fx/replacer.view.rules.json"
zap -t "$url" -f openapi
expect "a stale rule of this site is removed" "[description=jarvis-zap:http://host.docker.internal:8080:jarvis-old-1-2]" "$(call_of replacer.action.removeRule)"
expect "only the stale rule of this site is removed" "removed=1" "removed=$(call_of replacer.action.removeRule | grep -c .)"

echo 400 >"$work/fx/core.action.deleteSiteNode.http"
printf '{"code":"url_not_found","message":"URL Not Found in the Scan Tree"}\n' >"$work/fx/core.action.deleteSiteNode.json"
zap -t "$url" -f openapi
expect "a site that is not in the tree yet does not stop the scan" "status=2" "status=$status"

# --- openapi URL import -----------------------------------------------------
zap -t "$url" -f openapi
expect "the URL import sends the definition through the published port" "[url=http://host.docker.internal:8080/openapi.json]" "$(call_of openapi.action.importUrl)"
expect "the URL import forces the host override to SITE" "[hostOverride=http://host.docker.internal:8080]" "$(call_of openapi.action.importUrl)"

zap -t "$url" -f openapi --host-port 9000
expect "--host-port changes the port ZAP uses" "[url=http://host.docker.internal:9000/openapi.json][hostOverride=http://host.docker.internal:9000]" "$(call_of openapi.action.importUrl)"

ZAP_TARGET_HOST=localhost zap -t "$url" -f openapi
expect "ZAP_TARGET_HOST changes the host ZAP uses" "[hostOverride=http://localhost:8080]" "$(call_of openapi.action.importUrl)"

zap -t https://127.0.0.1:8443/v3/api-docs -f openapi
expect "an https target keeps the https scheme" "[url=https://host.docker.internal:8443/v3/api-docs][hostOverride=https://host.docker.internal:8443]" "$(call_of openapi.action.importUrl)"

zap -t 'http://[::1]:8080/spec?format=json' -f openapi
expect "a query string is preserved" "[url=http://host.docker.internal:8080/spec?format=json]" "$(call_of openapi.action.importUrl)"

echo 7 >"$work/fx/local.exit"
zap -t "$url" -f openapi
expect "an API that does not answer locally exits 3" "status=3" "status=$status"
expect "an API that does not answer says to bind 0.0.0.0" "0.0.0.0" "$out"
expect "an API that does not answer stops before ZAP" "calls=1" "calls=$(count_calls)"

# --- openapi file import ----------------------------------------------------
zap -t "$files/openapi.json" -f openapi --host-port 8080
expect "a file target exits like a URL target" "status=2" "status=$status"
expect "a file target skips the local check" "local=" "local=$(call_of local)"
expect "a file target is uploaded through the OTHER endpoint" "url=http://host.docker.internal:8090/OTHER/core/other/fileUpload/" "$(call_of core.other.fileUpload)"
expect "a file target uploads the file's contents" '[fileContents={"openapi":"3.0.0"}]' "$(call_of core.other.fileUpload)"
expect "a file target uploads under a per-run name" "[fileName=jarvis-" "$(call_of core.other.fileUpload)"
expect_not "the file contents are not on curl's argv" '"openapi":"3.0.0"' "$argv"
expect "importFile receives the uploaded path" "[file=/home/zap/.ZAP/transfer/RUN/openapi.json]" "$(call_of openapi.action.importFile)"
expect "importFile targets SITE" "[target=http://host.docker.internal:8080]" "$(call_of openapi.action.importFile)"

printf '{"Result":"OK"}\n' >"$work/fx/core.other.fileUpload.json"
zap -t "$files/openapi.json" -f openapi --host-port 8080
expect "an upload without a path exits 3" "status=3" "status=$status"
expect "an upload without a path mentions api.filexfer" "api.filexfer" "$out"

# --- graphql ----------------------------------------------------------------
zap -t http://localhost:4000/graphql -f graphql
expect "graphql sends endurl through the published port" "[endurl=http://host.docker.internal:4000/graphql]" "$(call_of graphql.action.importUrl)"
expect "graphql makes no openapi import" "openapi=" "openapi=$(call_of openapi.action.importUrl)"

# --- an import that reached nothing exits 3 ---------------------------------
printf '{"importUrl":["Failed to access URL: http://host.docker.internal:8080/openapi.json Connection refused"]}\n' >"$work/fx/openapi.action.importUrl.json"
printf '{"urls":[]}\n' >"$work/fx/core.view.urls.json"
SANDBOX_NAME=my-sbx zap -t "$url" -f openapi --host-port 9000
expect "import failures with no URLs exit 3" "status=3" "status=$status"
expect "import failures print the publish command" "sbx port publish my-sbx 9000:8080" "$out"
expect "import failures stop before the passive wait" "pscan=" "pscan=$(call_of pscan.view.recordsToScan)"
expect "the URL count is read for SITE" "[baseurl=http://host.docker.internal:9000]" "$(call_of core.view.urls)"

printf '{"importUrl":["Failed to access URL: x Connection refused"]}\n' >"$work/fx/openapi.action.importUrl.json"
printf '{"urls":[]}\n' >"$work/fx/core.view.urls.json"
zap -t "$url" -f openapi --host-port 9000
expect "without SANDBOX_NAME the publish command names the hostname (sbx sets it to the sandbox name)" "sbx port publish $(/bin/bash -c 'echo "$HOSTNAME"') 9000:8080" "$out"

printf '{"importUrl":["Failed to access URL: http://host.docker.internal:8080/a 500"]}\n' >"$work/fx/openapi.action.importUrl.json"
zap -t "$url" -f openapi
expect "import failures with some URLs go on" "status=2" "status=$status"

printf '{"sites":["http://host.docker.internal:7000"]}\n{"sites":["http://host.docker.internal:7000","http://host.docker.internal:8080","https://remote.example.com"]}\n' >"$work/fx/core.view.sites.seq"
zap -t "$url" -f openapi
expect "a new site other than SITE during the import exits 3" "status=3" "status=$status"
expect "a new site is named" "https://remote.example.com" "$out"

echo 500 >"$work/fx/openapi.action.importUrl.http"
printf '{"code":"internal_error","message":"boom"}\n' >"$work/fx/openapi.action.importUrl.json"
zap -t "$url" -f openapi
expect "a ZAP API error mid-scan exits 3" "status=3" "status=$status"
expect "a ZAP API error is reported with its code" "internal_error" "$out"

echo 7 >"$work/fx/openapi.action.importUrl.exit"
zap -t "$url" -f openapi
expect "a connection lost mid-scan exits 3" "status=3" "status=$status"

# --- the passive wait is bounded ---------------------------------------------
printf '{"recordsToScan":"4"}\n{"recordsToScan":"2"}\n{"recordsToScan":"0"}\n' >"$work/fx/pscan.view.recordsToScan.seq"
zap -t "$url" -f openapi
expect "the passive wait polls until the queue is empty" "polls=3" "polls=$(call_of pscan.view.recordsToScan | grep -c .)"
expect "the passive wait sleeps between polls" "sleeps=2" "sleeps=$(grep -c . "$work/calls.sleep")"
expect "a drained queue goes on to the result" "status=2" "status=$status"

printf '{"recordsToScan":"5"}\n' >"$work/fx/pscan.view.recordsToScan.seq"
zap -t "$url" -f openapi --timeout 1
expect "a queue that never drains exits 3" "status=3" "status=$status"
expect "the wait is bounded by --timeout (1 min = 30 polls)" "polls=30" "polls=$(call_of pscan.view.recordsToScan | grep -c .)"
expect "a timeout says so" "timed out" "$out"

printf '{"sites":["http://host.docker.internal:7000"]}\n{"sites":["http://host.docker.internal:7000","http://host.docker.internal:9090","https://host.docker.internal:9443","http://host.docker.internal:8080"]}\n' >"$work/fx/core.view.sites.seq"
zap -t "$url" -f openapi
expect "another sandbox's site on ZAP_TARGET_HOST appearing during the import is not drift" "status=2" "status=$status"

printf '{"sites":[]}\n{"sites":["http://localhost:8080"]}\n' >"$work/fx/core.view.sites.seq"
zap -t "$url" -f openapi
expect "a new site on a host other than ZAP_TARGET_HOST exits 3" "status=3" "status=$status"
expect "a new site on another host is named" "http://localhost:8080" "$out"

printf '{"sites":[]}\n{"sites":["http://host.docker.internal.evil.com:80"]}\n' >"$work/fx/core.view.sites.seq"
zap -t "$url" -f openapi
expect "a lookalike of ZAP_TARGET_HOST is drift" "status=3" "status=$status"

# --- reports, scoped to SITE ------------------------------------------------
zap -t "$url" -f openapi
expect "the report is generated in ZAP's transfer dir" "[reportDir=/home/zap/.ZAP/transfer]" "$(call_of reports.action.generate | sed -n 1p)"
expect "the json report is scoped to SITE" "[sites=http://host.docker.internal:8080]" "$(call_of reports.action.generate | grep traditional-json)"
expect "the html report is scoped to SITE" "[sites=http://host.docker.internal:8080]" "$(call_of reports.action.generate | grep traditional-html)"
expect "the report file names carry the run id" "[reportFileName=jarvis-" "$(call_of reports.action.generate | sed -n 1p)"
expect "the reports are downloaded through the OTHER endpoint" "url=http://host.docker.internal:8090/OTHER/core/other/fileDownload/" "$(call_of core.other.fileDownload | sed -n 1p)"
expect "report.json lands in ./zap-reports" '"pluginid":"10020"' "$(cat "$cwd/zap-reports/report.json" 2>/dev/null)"
expect "report.html lands in ./zap-reports" "<html>report</html>" "$(cat "$cwd/zap-reports/report.html" 2>/dev/null)"
expect "the summary names the report directory" "zap-reports" "$stdout"
for op in core.other.jsonreport core.other.htmlreport; do
	expect_not "never uses the session-wide $op" "$op" "$(ops)"
done

zap -t "$url" -f openapi -o out/nested
expect "a nested relative out dir is created" '"pluginid"' "$(cat "$cwd/out/nested/report.json" 2>/dev/null)"

echo 500 >"$work/fx/reports.action.generate.http"
printf '{"code":"internal_error","message":"Cannot write to directory"}\n' >"$work/fx/reports.action.generate.json"
zap -t "$url" -f openapi
expect "a failed report generation exits 3" "status=3" "status=$status"

printf 'not json\n' >"$work/fx/report.json"
zap -t "$url" -f openapi
expect "a report that is not JSON exits 3" "status=3" "status=$status"

# --- exit codes follow the alerts and -c --------------------------------------
codes=(
	"no -c: every alert is a WARN|2|"
	"--no-fail-on-warn|0|--no-fail-on-warn"
	"-c FAIL on a present id|1|-c $files/fail.conf"
	"-c FAIL with --no-fail-on-warn|1|-c $files/fail.conf --no-fail-on-warn"
	"-c IGNORE on every present id|0|-c $files/ignore.conf"
	"-c INFO on every present id|0|-c $files/info.conf"
	"an id not in -c stays a WARN|2|-c $files/partial.conf"
)
for entry in "${codes[@]}"; do
	name="${entry%%|*}"
	rest="${entry#*|}"
	# shellcheck disable=SC2086 # the table stores arguments as one word-split string
	zap -t "$url" -f openapi ${rest#*|}
	expect "$name exits ${rest%%|*}" "status=${rest%%|*}" "status=$status"
done

printf '{"site":[{"@name":"http://host.docker.internal:8080","alerts":[]}]}\n' >"$work/fx/report.json"
zap -t "$url" -f openapi
expect "no alerts exit 0" "status=0" "status=$status"

printf '{"site":[]}\n' >"$work/fx/report.json"
zap -t "$url" -f openapi
expect "a report with no site exits 0" "status=0" "status=$status"

# --- --active ---------------------------------------------------------------
zap -t "$url" -f openapi
expect "the default run starts no active scan" "ascan=" "ascan=$(printf '%s\n' "$(ops)" | grep ascan)"

printf '{"status":"10"}\n{"status":"60"}\n{"status":"100"}\n' >"$work/fx/ascan.view.status.seq"
zap -t "$url" -f openapi --active
expect "--active scans SITE" "[url=http://host.docker.internal:8080]" "$(call_of ascan.action.scan)"
expect "--active scans recursively" "[recurse=true]" "$(call_of ascan.action.scan)"
expect "--active polls the scan it started" "[scanId=7]" "$(call_of ascan.view.status | sed -n 1p)"
expect "--active polls until 100" "polls=3" "polls=$(call_of ascan.view.status | grep -c .)"
expect "--active waits for the passive queue again" "pscan=2" "pscan=$(call_of pscan.view.recordsToScan | grep -c .)"
expect "--active does not stop a finished scan" "stop=" "stop=$(call_of ascan.action.stop)"
expect "--active exits by the alerts" "status=2" "status=$status"

echo 400 >"$work/fx/ascan.action.scan.http"
printf '{"code":"url_not_found","message":"URL Not Found in the Scan Tree"}\n' >"$work/fx/ascan.action.scan.json"
zap -t "$url" -f openapi --active
expect "--active on a site not in the tree exits 3" "status=3" "status=$status"
expect "--active on a site not in the tree says url_not_found" "url_not_found" "$out"

printf '{"status":"20"}\n' >"$work/fx/ascan.view.status.seq"
: >"$work/fx/ascan.view.status.kill"
zap -t "$url" -f openapi --active
expect "TERM during the active scan exits 143" "status=143" "status=$status"
expect "TERM during the active scan stops it" "[scanId=7]" "$(call_of ascan.action.stop)"
expect "TERM during the active scan still cleans the site" "deleteSiteNode" "$(ops | tail -n 1)"

# --- cleanup ------------------------------------------------------------------
zap -t "$url" -f openapi
expect "the trap deletes this site's alerts then its node at exit" "alert.action.deleteAlerts core.action.deleteSiteNode" "$(ops | tail -n 2 | tr '\n' ' ')"
expect "the trap keeps the exit code" "status=2" "status=$status"

printf '{"recordsToScan":"5"}\n' >"$work/fx/pscan.view.recordsToScan.seq"
zap -t "$url" -f openapi --timeout 1
expect "the trap cleans the site after an exit 3" "alert.action.deleteAlerts core.action.deleteSiteNode" "$(ops | tail -n 2 | tr '\n' ' ')"

expect "a clean run leaves no temp files" "left=none" "left=$(leftovers)"

printf '0\n7\n' >"$work/fx/alert.action.deleteAlerts.exit.seq"
zap -t "$url" -f openapi --header-env ZAP_TEST_AUTH_CLEANUP
expect "a connection lost during cleanup keeps the scan's exit code" "status=2" "status=$status"
expect "a connection lost during cleanup still removes the temp dir (key, header value)" "left=none" "left=$(leftovers)"
expect "a connection lost during cleanup still deletes the site node" "deleteSiteNode" "$(ops | tail -n 1)"

echo 7 >"$work/fx/reports.action.generate.exit"
zap -t "$url" -f openapi
expect "a connection lost during report generation exits 3" "status=3" "status=$status"
expect "a connection lost during report generation removes the temp dir" "left=none" "left=$(leftovers)"

printf '0\n7\n' >"$work/fx/alert.action.deleteAlerts.exit.seq"
echo 7 >"$work/fx/reports.action.generate.exit"
zap -t "$url" -f openapi
expect "a failed cleanup after an exit 3 keeps the 3" "status=3" "status=$status"
expect "a failed cleanup after an exit 3 removes the temp dir" "left=none" "left=$(leftovers)"

echo 7 >"$work/fx/alert.action.deleteAlerts.exit"
zap -t "$url" -f openapi
expect "a connection lost during the slate still exits 3" "status=3" "status=$status"

echo 52 >"$work/fx/core.view.version.exit"
zap -t "$url" -f openapi
expect "the trap does not call a daemon that rejected the preflight" "calls=2" "calls=$(count_calls)"

# --- --header-env -------------------------------------------------------------
zap -t "$url" -f openapi --header-env ZAP_TEST_AUTH
rule="$(call_of replacer.action.addRule)"
expect "--header-env adds a replacer rule" "op=replacer.action.addRule" "$rule"
expect "the rule replaces a request header" "[matchType=REQ_HEADER]" "$rule"
expect "the rule matches the header by name, not by regex" "[matchRegex=false]" "$rule"
expect "the rule names the header" "[matchString=Authorization]" "$rule"
expect "the rule is enabled" "[enabled=true]" "$rule"
expect "the rule carries the value" "[replacement=Bearer s3cr3t-t0ken]" "$rule"
expect "the rule is scoped to SITE as a regex" '[url=^http://host\.docker\.internal:8080/]' "$rule"
expect "the rule is described as this site's" "[description=jarvis-zap:http://host.docker.internal:8080:jarvis-" "$rule"
expect "the rule is added before the import" "replacer.action.addRule openapi.action.importUrl" "$(ops | grep -E 'addRule|importUrl' | tr '\n' ' ')"
expect "the rule is removed at exit" "[description=jarvis-zap:http://host.docker.internal:8080:jarvis-" "$(call_of replacer.action.removeRule)"
expect_not "the header value is never on curl's argv" "s3cr3t" "$argv"
expect_not "the header value is never in a URL" "s3cr3t" "$(printf '%s\n' "$calls" | sed 's/ hdr=.*//')"
expect_not "the header value is never in the output" "s3cr3t" "$out"
expect "--header-env still exits by the alerts" "status=2" "status=$status"

printf '{"importUrl":["Failed to access URL: x Connection refused"]}\n' >"$work/fx/openapi.action.importUrl.json"
printf '{"urls":[]}\n' >"$work/fx/core.view.urls.json"
zap -t "$url" -f openapi --header-env ZAP_TEST_AUTH
expect "the rule is removed after a failed scan too" "op=replacer.action.removeRule" "$(call_of replacer.action.removeRule)"
expect "a failed scan with --header-env exits 3" "status=3" "status=$status"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
