#!/usr/bin/env bash
#
# Scan an API running in this sandbox (or on this machine) with OWASP ZAP. ZAP
# itself runs once, as a daemon on the user's host; this script drives it over
# its REST API and writes the reports to a local directory. Nothing runs ZAP here.
#
# Usage: zap-api-scan.sh -t TARGET -f openapi|graphql [options]
#
#   -t, --target URL|FILE  OpenAPI definition URL or local file; the endpoint
#                          URL for graphql. URLs are this machine's view:
#                          localhost, 127.0.0.1 or [::1] only
#   -f, --format FMT       openapi | graphql (required). soap is refused: ZAP has
#                          no host override for a WSDL
#   -o, --out-dir DIR      report directory (default ./zap-reports), created if
#                          missing; receives report.html and report.json
#       --active           also run ZAP's active scan (attack payloads)
#       --no-fail-on-warn  warnings do not set a non-zero exit code
#   -c, --config FILE      rules file, read locally: id<TAB>LEVEL<TAB>name lines,
#                          LEVEL one of IGNORE, INFO, WARN, FAIL; # comments
#       --host-port P      host port the API is published on (sbx port publish
#                          <sandbox> P:<port>); default the port in -t. Required
#                          for a file target. 80 and 443 are refused
#       --timeout MIN      bound for each scan wait, in minutes (default 10, 1-240)
#       --header-env VAR   add the header held in $VAR ("Name: value") to every
#                          scan request; the value is never printed or put in argv
#   -h, --help             print this text
#
# Environment (from .env, passed with --env-file when the sandbox is created):
#   ZAP_URL          the daemon's API base URL, e.g. http://host.docker.internal:8090
#                    (host.docker.internal, localhost, 127.0.0.1 or [::1]; no path).
#                    Unset or empty: one line on stderr, exit 78, nothing else runs
#   ZAP_API_KEY      the daemon's api.key; sent only in the X-ZAP-API-Key header
#   ZAP_TARGET_HOST  the host name ZAP uses to reach published ports:
#                    host.docker.internal (default), localhost or 127.0.0.1
#
# WARNING: every scan writes. Importing the definition sends one generated
# request per operation (POST, PUT and DELETE included), so point every scan at
# a disposable database. --active adds attack payloads on top.
#
# The daemon is shared. Results are kept apart by site (ZAP_TARGET_HOST:P), so
# two scans of the same host port at once are unsupported: the second deletes
# the first one's results. IGNORE in -c only filters the result; the rule still
# runs (changing the shared scan policy would affect every sandbox).
#
# Gone with the Docker mode: SOAP, -O, -g and -- ZAP_ARGS.
#
# Exit codes:
#   0   no FAIL and no WARN (or only WARNs with --no-fail-on-warn)
#   1   at least one FAIL
#   2   at least one WARN and no FAIL (every alert is a WARN unless -c says otherwise)
#   3   no usable result: the API did not answer, the import reached nothing,
#       a timeout, a ZAP API error mid-scan, or requests went to another site
#   64  bad arguments or invalid input
#   66  definition file or rules file missing
#   69  curl or jq missing, or the ZAP daemon unreachable or rejecting the request
#   78  ZAP not configured or misconfigured; scan skipped (not a pass)

set -euo pipefail

URL_PATTERN='^(https?)://(\[[^]]+\]|[^/:?#@]+)(:[0-9]+)?([/?#].*)?$'
ZAP_URL_PATTERN='^(https?)://(\[::1\]|[A-Za-z0-9.-]+)(:[0-9]+)?/?$'
POLL_SECONDS=2

src="${BASH_SOURCE[0]}"

usage_text() {
	sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "$src" | sed '$d'
}

# bad_input <message> -- exit 64 with the message and the usage text.
bad_input() {
	printf 'zap-api-scan: %s\n\n' "$1" >&2
	usage_text >&2
	exit 64
}

# not_configured <message> -- exit 78: the scan is skipped, not failed.
not_configured() {
	printf 'zap-api-scan: %s; scan skipped.\n' "$1" >&2
	exit 78
}

# missing_file <label> <path> -- exit 66.
missing_file() {
	printf 'zap-api-scan: %s not found or unreadable: %s\n' "$1" "$2" >&2
	exit 66
}

# is_port <value> -- a decimal port number 1-65535.
is_port() {
	[[ "$1" =~ ^[0-9]+$ ]] && [[ ${#1} -le 5 ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

target=''
format=''
out_dir=./zap-reports
active=0
no_fail_on_warn=0
config=''
host_port=''
timeout_min=10
header_env=''

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			usage_text
			exit 0
			;;
		-t | --target | -f | --format | -o | --out-dir | -c | --config | --host-port | --timeout | --header-env)
			[[ $# -ge 2 ]] || bad_input "$1 needs a value"
			case "$1" in
			-t | --target) target="$2" ;;
			-f | --format) format="$2" ;;
			-o | --out-dir) out_dir="$2" ;;
			-c | --config) config="$2" ;;
			--host-port) host_port="$2" ;;
			--timeout) timeout_min="$2" ;;
			--header-env) header_env="$2" ;;
			esac
			shift 2
			;;
		--active)
			active=1
			shift
			;;
		--no-fail-on-warn)
			no_fail_on_warn=1
			shift
			;;
		--) bad_input "-- ZAP_ARGS have no meaning in API mode: the script drives ZAP's REST API" ;;
		*) bad_input "unknown option: $1" ;;
		esac
	done
}

# Sets ZAP_BASE and target_host from the environment; exits 78 when ZAP is not
# configured. Builtins only, so it runs before the tool check. Never prints the
# key, nor ZAP_URL (it could carry credentials).
ZAP_BASE=''
target_host=''

check_env() {
	if [[ -z "${ZAP_URL:-}" ]]; then
		# Agents in other projects cannot read this repo's AGENTS.md, so the skill comes first.
		printf '%s\n' 'zap-api-scan: ZAP is not configured (ZAP_URL is not set); scan skipped. See the zap-api-scan skill ("Host setup") or AGENTS.md "ZAP host daemon".' >&2
		exit 78
	fi
	if [[ ! "$ZAP_URL" =~ $ZAP_URL_PATTERN ]]; then
		not_configured 'ZAP_URL is not valid: want http(s)://HOST[:PORT] with HOST host.docker.internal, localhost, 127.0.0.1 or [::1], no path and no user info'
	fi
	case "${BASH_REMATCH[2]}" in
	host.docker.internal | localhost | 127.0.0.1 | '[::1]') ;;
	*) not_configured 'ZAP_URL must point to this machine (host.docker.internal, localhost, 127.0.0.1 or [::1]): a remote ZAP would receive the API key' ;;
	esac
	ZAP_BASE="${ZAP_URL%/}"

	[[ -n "${ZAP_API_KEY:-}" ]] || not_configured 'ZAP_API_KEY is not set (required with ZAP_URL)'
	[[ "$ZAP_API_KEY" != *[[:cntrl:]]* ]] || not_configured 'ZAP_API_KEY contains control characters and cannot be sent as a header'

	target_host="${ZAP_TARGET_HOST:-host.docker.internal}"
	case "$target_host" in
	host.docker.internal | localhost | 127.0.0.1) ;;
	*) not_configured "ZAP_TARGET_HOST must be host.docker.internal, localhost or 127.0.0.1, not $target_host" ;;
	esac
}

require_tools() {
	local tool
	for tool in curl jq; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			printf 'zap-api-scan: %s is required but not on PATH\n' "$tool" >&2
			exit 69
		fi
	done
}

# parse_rules <file> -- prints "id<TAB>LEVEL" per rule; exits 64 naming the
# first bad line.
parse_rules() {
	local rules status=0
	rules="$(awk -F '\t' '
		/^[ \t]*(#|$)/ { next }
		{
			if ($1 !~ /^[0-9]+$/ || ($2 != "IGNORE" && $2 != "INFO" && $2 != "WARN" && $2 != "FAIL")) {
				print NR
				exit 1
			}
			print $1 "\t" $2
		}' "$1")" || status=$?
	# On a bad line awk's last output line is that line's number.
	[[ $status -eq 0 ]] || bad_input "rules file $1, line ${rules##*$'\n'}: want id<TAB>IGNORE|INFO|WARN|FAIL[<TAB>name]"
	printf '%s\n' "$rules"
}

# Resolved scan inputs; resolve_inputs exits 64/66 before any network call or
# directory creation.
target_url=''   # URL target as given (this machine's view)
target_path=''  # its path and query, appended to SITE
target_port=''  # its port, the sandbox side of the published port
spec_file=''    # file target
rules_tsv=''
header_name=''
header_value=''
SITE=''

resolve_inputs() {
	[[ -n "$target" ]] || bad_input "-t is required"
	[[ -n "$format" ]] || bad_input "-f is required"
	case "$format" in
	openapi | graphql) ;;
	soap) bad_input "SOAP is not supported: ZAP has no host override for a WSDL, so requests would go to the soap:address host from the host's network (zap-host-service ADR F3)" ;;
	*) bad_input "-f must be openapi or graphql, not $format" ;;
	esac

	local scheme=http
	if [[ "$target" == http://* || "$target" == https://* ]]; then
		[[ "$target" =~ $URL_PATTERN ]] || bad_input "not a valid http(s) URL: $target"
		local host="${BASH_REMATCH[2]}"
		scheme="${BASH_REMATCH[1]}"
		target_port="${BASH_REMATCH[3]#:}"
		target_path="${BASH_REMATCH[4]%%#*}"
		case "$host" in
		localhost | 127.0.0.1 | '[::1]') ;;
		*) bad_input "-t must be this machine's loopback (localhost, 127.0.0.1, [::1]), not $host" ;;
		esac
		target_url="$target"
	else
		[[ "$format" != graphql ]] || bad_input "graphql takes an endpoint URL, not a file: $target"
		[[ -f "$target" && -r "$target" ]] || missing_file "definition file" "$target"
		[[ -n "$host_port" ]] || bad_input "a definition file needs --host-port: the host port the API is published on"
		spec_file="$target"
	fi

	local port="${host_port:-$target_port}"
	[[ -n "$port" ]] || bad_input "-t has no port; pass --host-port with the host port the API is published on"
	is_port "$port" || bad_input "not a valid port: $port"
	port=$((10#$port))
	[[ $port -ne 80 && $port -ne 443 ]] || bad_input "host port $port is refused: ZAP's site match for default ports is unverified"
	SITE="$scheme://$target_host:$port"

	[[ "$timeout_min" =~ ^[0-9]+$ && ${#timeout_min} -le 3 ]] && ((10#$timeout_min >= 1 && 10#$timeout_min <= 240)) ||
		bad_input "--timeout must be a whole number of minutes, 1-240, not $timeout_min"
	timeout_min=$((10#$timeout_min))

	if [[ -n "$config" ]]; then
		[[ -f "$config" && -r "$config" ]] || missing_file "rules file" "$config"
		rules_tsv="$(parse_rules "$config")"
	fi

	if [[ -n "$header_env" ]]; then
		[[ "$header_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || bad_input "--header-env takes a variable name, not $header_env"
		local header="${!header_env:-}"
		[[ -n "$header" ]] || bad_input "--header-env: \$$header_env is unset or empty"
		[[ "$header" != *[[:cntrl:]]* ]] || bad_input "--header-env: \$$header_env contains control characters"
		[[ "$header" =~ ^([A-Za-z0-9-]+):[[:space:]]*(.+)$ ]] || bad_input "--header-env: \$$header_env must hold 'Name: value'"
		header_name="${BASH_REMATCH[1]}"
		header_value="${BASH_REMATCH[2]}"
	fi

	[[ ! -e "$out_dir" || -d "$out_dir" ]] || bad_input "out dir exists and is not a directory: $out_dir"
}

# scan_failed <message> -- exit 3: the scan produced no usable result.
scan_failed() {
	printf 'zap-api-scan: %s\n' "$1" >&2
	exit 3
}

# unreachable <message> -- exit 69: the daemon cannot be used at all.
unreachable() {
	printf 'zap-api-scan: %s\n' "$1" >&2
	exit 69
}

check_local_api() {
	[[ -n "$target_url" ]] || return 0
	# No -f: a GraphQL endpoint answers a GET with 4xx, which still means it is up.
	curl -sS -g --max-time 10 -o /dev/null "$target_url" 2>/dev/null ||
		scan_failed "the API did not answer at $target_url; start it bound to 0.0.0.0 on that port"
}

# Per-run state, read by the EXIT trap.
tmp=''
resp=''
hdr_file=''
run_id=''

# prepare_run -- the out dir, a private temp dir and the header file that
# carries the key (curl reads it with -H @file, so the key never reaches argv).
prepare_run() {
	mkdir -p "$out_dir" || bad_input "cannot create out dir: $out_dir"
	tmp="$(mktemp -d "${TMPDIR:-/tmp}/zap-api-scan.XXXXXX")"
	chmod 0700 "$tmp"
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	resp="$tmp/response"
	hdr_file="$tmp/headers"
	(umask 077 && printf 'X-ZAP-API-Key: %s\nHost: zap\n' "$ZAP_API_KEY" >"$hdr_file")
	local host="${HOSTNAME:-sandbox}"
	run_id="jarvis-${host//[^A-Za-z0-9.-]/-}-$(date +%s)-$$"
}

# cleanup -- the EXIT trap. Best effort and never changes the exit status:
# remove this run's replacer rule, stop an active scan still running, delete
# this site's results from the shared session, and remove the temp dir. Calls
# ZAP only when the preflight got through.
cleanup() {
	local status=$?
	set +e
	trap '' INT TERM
	if [[ $zap_reached -eq 1 ]]; then
		[[ -z "$rule_description" ]] ||
			zap_request JSON replacer/action/removeRule "$resp" --data-urlencode "description=$rule_description"
		[[ -z "$active_scan_id" ]] ||
			zap_request JSON ascan/action/stop "$resp" --data-urlencode "scanId=$active_scan_id"
		delete_site_results || true
	fi
	[[ -z "$tmp" ]] || rm -rf "$tmp"
	exit "$status"
}

# zap_request <JSON|OTHER> <component/type/op> <output-file> [curl data args...]
# -- the one place ZAP is called. POST to ZAP_URL with Host: zap and the key
# from the header file; sets zap_rc (curl's exit) and zap_http (the status).
# Never called in a subshell, so a signal reaches the script while curl runs.
zap_rc=0
zap_http=''

zap_request() {
	local kind="$1" op="$2" output="$3"
	shift 3
	[[ $# -gt 0 ]] || set -- -d ''
	zap_rc=0
	curl -sS -g --max-time 60 -o "$output" -w '%{http_code}' -H "@$hdr_file" -X POST "$@" \
		"$ZAP_BASE/$kind/$op/" >"$tmp/http" 2>"$tmp/curl.err" || zap_rc=$?
	zap_http="$(cat "$tmp/http" 2>/dev/null || true)"
}

# zap_error_text -- ZAP's error (code and message) from the last response, or
# curl's own; truncated, since it is printed.
zap_error_text() {
	local text
	text="$(jq -r '[.code, .message] | map(select(. != null)) | join(": ")' "$resp" 2>/dev/null || true)"
	[[ -n "$text" ]] || text="HTTP $zap_http"
	printf '%.200s' "$text"
}

# zap_check <op> -- exit 3 unless the last call succeeded.
zap_check() {
	[[ $zap_rc -eq 0 ]] || scan_failed "lost the ZAP daemon during $1 (curl exit $zap_rc)"
	[[ "$zap_http" == 200 ]] || scan_failed "ZAP API error during $1: $(zap_error_text)"
}

# zap_call <component/type/op> [curl data args...] -- a JSON call into $resp
# that must succeed (exit 3 otherwise).
zap_call() {
	zap_request JSON "$1" "$resp" "${@:2}"
	zap_check "$1"
}

# json <filter> -- read the last response; empty when it is not JSON.
json() {
	jq -r "$1" "$resp" 2>/dev/null || true
}

zap_reached=0
rule_description=''
active_scan_id=''

preflight() {
	zap_request JSON core/view/version "$resp"
	case $zap_rc in
	0) ;;
	52) unreachable "ZAP at $ZAP_BASE rejected (key, Host header or permitted address): empty reply" ;;
	*) unreachable "ZAP is not reachable at $ZAP_BASE (curl exit $zap_rc); is the daemon running on the host?" ;;
	esac
	[[ "$zap_http" == 200 ]] || unreachable "ZAP at $ZAP_BASE rejected the request (HTTP $zap_http)"
	zap_reached=1
	printf 'zap-api-scan: ZAP %s at %s, site %s\n' "$(json '.version // "?"')" "$ZAP_BASE" "$SITE" >&2
}

# delete_site_results -- this site's alerts, then its node. The order matters:
# deleting the node first leaves orphan alerts that deleteAlerts then refuses.
# Never exits, because the EXIT trap calls it too; ZAP's own errors are ignored
# (a site not in the tree yet is an error). Returns 1 when a connection was lost.
delete_site_results() {
	local lost=0
	zap_request JSON alert/action/deleteAlerts "$resp" --data-urlencode "baseurl=$SITE"
	[[ $zap_rc -eq 0 ]] || lost=1
	zap_request JSON core/action/deleteSiteNode "$resp" --data-urlencode "url=$SITE"
	[[ $zap_rc -eq 0 ]] || lost=1
	return "$lost"
}

# clean_slate -- remove what an earlier run against this site left behind. Only
# this site: never newSession, loadSession, setMode or any option or policy.
clean_slate() {
	delete_site_results || scan_failed "lost the ZAP daemon while deleting earlier results of $SITE (curl exit $zap_rc)"
	zap_call replacer/view/rules
	jq -r --arg prefix "jarvis-zap:$SITE:" \
		'[.. | objects | .description? | strings | select(startswith($prefix))] | .[]' \
		"$resp" >"$tmp/stale-rules" 2>/dev/null || true
	local description
	while IFS= read -r description; do
		zap_call replacer/action/removeRule --data-urlencode "description=$description"
	done <"$tmp/stale-rules"
}

# count_strings -- the number of strings inside arrays in the last response
# (import failures, site URLs).
count_strings() {
	local n
	n="$(json '[.. | arrays | .[] | strings] | length')"
	printf '%s' "${n:-0}"
}

import_definition() {
	zap_call core/view/sites
	cp "$resp" "$tmp/sites-before"

	if [[ -n "$spec_file" ]]; then
		zap_request OTHER core/other/fileUpload "$resp" \
			--data-urlencode "fileName=$run_id/${spec_file##*/}" --data-urlencode "fileContents@$spec_file"
		zap_check core/other/fileUpload
		local uploaded
		uploaded="$(json '.Uploaded // empty')"
		[[ -n "$uploaded" ]] || scan_failed "ZAP did not accept the upload of $spec_file; the daemon needs -config api.filexfer=true"
		zap_call openapi/action/importFile --data-urlencode "file=$uploaded" --data-urlencode "target=$SITE"
	elif [[ "$format" == openapi ]]; then
		zap_call openapi/action/importUrl --data-urlencode "url=$SITE$target_path" --data-urlencode "hostOverride=$SITE"
	else
		zap_call graphql/action/importUrl --data-urlencode "endurl=$SITE$target_path"
	fi
	local failures
	failures="$(count_strings)"

	zap_call core/view/sites
	# A new site on ZAP_TARGET_HOST is another sandbox's published port, scanned
	# at the same time on the shared daemon; any other new host is drift.
	local elsewhere
	elsewhere="$(jq -r -n --slurpfile before "$tmp/sites-before" --slurpfile after "$resp" --arg site "$SITE" \
		--arg host "$target_host" \
		'(($after[0].sites // []) - ($before[0].sites // []) - [$site])
		| map(select((sub("^[A-Za-z][A-Za-z0-9+.-]*://"; "") | sub("[/?#].*$"; "") | sub(":[0-9]+$"; "")) != $host))
		| join(" ")' 2>/dev/null || true)"
	[[ -z "$elsewhere" ]] || scan_failed "requests went elsewhere: new site(s) $elsewhere appeared during the import (expected only $SITE)"

	zap_call core/view/urls --data-urlencode "baseurl=$SITE"
	if [[ $failures -gt 0 && $(count_strings) -eq 0 ]]; then
		scan_failed "the import reached nothing at $SITE ($failures failure(s)). Is host port ${SITE##*:} published to this sandbox? Run on the host: sbx port publish ${SANDBOX_NAME:-${HOSTNAME:-<sandbox>}} ${SITE##*:}:${target_port:-${SITE##*:}}"
	fi
	[[ $failures -eq 0 ]] || printf 'zap-api-scan: warning: the import reported %s failure(s); scanning what it reached\n' "$failures" >&2
}

# wait_until <label> <op> <jq filter> <done value> [curl data args...] -- poll
# until the filter reads the done value. Bounded by a poll count derived from
# --timeout, so the bound does not depend on the clock.
wait_until() {
	local label="$1" op="$2" filter="$3" want="$4"
	shift 4
	local polls=$((timeout_min * 60 / POLL_SECONDS)) i=0 value
	while :; do
		zap_call "$op" "$@"
		value="$(json "$filter")"
		[[ "$value" != "$want" ]] || return 0
		i=$((i + 1))
		[[ $i -lt $polls ]] || scan_failed "timed out after $timeout_min min waiting for the $label (last value: ${value:-none})"
		sleep "$POLL_SECONDS"
	done
}

passive_wait() {
	wait_until "passive scan" pscan/view/recordsToScan '.recordsToScan // empty' 0
}

# add_header_rule -- the --header-env header, as a replacer rule scoped to
# SITE. The value goes in a private file that curl reads (replacement@FILE),
# so it never reaches argv, a URL or any output.
add_header_rule() {
	[[ -n "$header_name" ]] || return 0
	local value_file="$tmp/header-value" site_regex
	(umask 077 && printf '%s' "$header_value" >"$value_file")
	site_regex="$(printf '%s' "$SITE" | sed 's/[][\.^$|?*+(){}]/\\&/g')"
	rule_description="jarvis-zap:$SITE:$run_id"
	zap_call replacer/action/addRule \
		--data-urlencode "description=$rule_description" \
		--data-urlencode enabled=true \
		--data-urlencode matchType=REQ_HEADER \
		--data-urlencode matchRegex=false \
		--data-urlencode "matchString=$header_name" \
		--data-urlencode "replacement@$value_file" \
		--data-urlencode "url=^$site_regex/"
}

active_scan() {
	zap_call ascan/action/scan --data-urlencode "url=$SITE" --data-urlencode recurse=true
	active_scan_id="$(json '.scan // empty')"
	[[ -n "$active_scan_id" ]] || scan_failed "ZAP did not start an active scan of $SITE"
	wait_until "active scan" ascan/view/status '.status // empty' 100 --data-urlencode "scanId=$active_scan_id"
	active_scan_id=''
	passive_wait
}

# fetch_reports -- report.json and report.html for SITE only, generated in
# ZAP's transfer dir and downloaded into the out dir. Never jsonreport or
# htmlreport: those cover the whole shared session.
fetch_reports() {
	zap_call core/view/zapHomePath
	local home kind
	home="$(json '.zapHomePath // empty')"
	[[ -n "$home" ]] || scan_failed "ZAP did not report its home directory"
	for kind in json html; do
		zap_call reports/action/generate \
			--data-urlencode "title=ZAP API scan of $SITE" \
			--data-urlencode "template=traditional-$kind" \
			--data-urlencode "sites=$SITE" \
			--data-urlencode "reportDir=${home%/}/transfer" \
			--data-urlencode "reportFileName=$run_id-report.$kind"
		zap_request OTHER core/other/fileDownload "$tmp/report.$kind" --data-urlencode "fileName=$run_id-report.$kind"
		zap_check core/other/fileDownload
	done
	jq -e '.site | type == "array"' "$tmp/report.json" >/dev/null 2>&1 ||
		scan_failed "ZAP's JSON report for $SITE is not usable"
	mv "$tmp/report.json" "$out_dir/report.json"
	mv "$tmp/report.html" "$out_dir/report.html"
}

# classify -- print each alert with its level and set exit_code: each alert's
# level is the -c rule for its pluginid, or WARN. Any FAIL gives 1; else any
# WARN gives 2 unless --no-fail-on-warn; else 0. Values reach jq only as --arg.
exit_code=0

classify() {
	local levels
	# shellcheck disable=SC2016 # $rules and $alerts are jq variables
	levels='($rules | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries) as $map
		| [.site[]?.alerts[]? | {id: (.pluginid | tostring), name: (.name // .alert // ""),
			level: ($map[.pluginid | tostring] // "WARN")}]'
	jq -r --arg rules "$rules_tsv" "$levels"' | .[] | select(.level != "IGNORE") | "\(.level)\t\(.id)\t\(.name)"' \
		"$out_dir/report.json"
	exit_code="$(jq -r --arg rules "$rules_tsv" --argjson nowarn "$no_fail_on_warn" "$levels"' as $alerts
		| if ($alerts | map(select(.level == "FAIL")) | length) > 0 then 1
		elif $nowarn == 0 and ($alerts | map(select(.level == "WARN")) | length) > 0 then 2
		else 0 end' "$out_dir/report.json")"
	printf 'reports: %s/report.json, %s/report.html\n' "$out_dir" "$out_dir"
}

main() {
	parse_args "$@"
	check_env
	require_tools
	resolve_inputs
	check_local_api
	prepare_run
	preflight
	clean_slate
	add_header_rule
	import_definition
	passive_wait
	[[ $active -eq 0 ]] || active_scan
	fetch_reports
	classify
	exit "$exit_code"
}

main "$@"
