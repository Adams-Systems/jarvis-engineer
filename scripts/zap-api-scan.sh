#!/usr/bin/env bash
#
# Run the OWASP ZAP API scan (zap-api-scan.py) in Docker against an API that is
# running on this machine, and write the reports to a local directory.
#
# Usage: zap-api-scan.sh -t TARGET -f openapi|soap|graphql [options] [-- ZAP_ARGS...]
#
#   -t, --target URL|FILE  API definition URL or local file (openapi, soap);
#                          the endpoint URL (graphql)
#   -f, --format FMT       openapi | soap | graphql (required, no default)
#   -o, --out-dir DIR      report directory (default ./zap-reports), created if
#                          missing; receives report.html and report.json
#       --active           also run ZAP's active scan, which sends attack payloads.
#                          The default is -S, which skips only that phase
#       --no-fail-on-warn  pass -I so warnings do not set a non-zero exit code
#   -c, --config FILE      ZAP rules config (-c), mounted read-only
#   -O, --override HOST    openapi only: the local host[:port] or URL that replaces
#                          the servers[].url hosts named in the spec. Passed to
#                          ZAP as -O with a scheme (http:// unless -t says https).
#                          Defaults to the -t origin for a URL target; required
#                          for a file target
#   -h, --help             print this text
#   -- ZAP_ARGS...         everything after -- is passed to zap-api-scan.py
#
# WARNING: any run can create, modify or delete data. -S only withholds attack
# payloads: ZAP's import of the definition still sends one generated request per
# operation (POST, PUT and DELETE included) to the API, so even the default run
# is not read-only. Point every scan at a disposable database.
#
# Only the definition file and the config file are mounted (each read-only, as a
# single file), never their directories. On Linux the out dir must be writable by
# the image's fixed user, uid 1000: a different host uid gets "Permission denied"
# on report.html after the scan. Run `chmod a+w DIR`, or `chown 1000 DIR`, first.
# --user is not an option: ZAP does not start under another uid.
#
# Environment: ZAP_IMAGE overrides the pinned image.
#
# Targets are limited to this machine: localhost, 127.0.0.1, [::1] or
# host.docker.internal. The container cannot reach the host through the loopback
# names, so they are rewritten to host.docker.internal (announced on stderr). On Linux the API must listen on
# 0.0.0.0 or the docker bridge address, not only 127.0.0.1, to be reachable.
#
# ZAP sends its requests to the hosts named INSIDE the definition (OpenAPI
# servers[].url, WSDL soap:address), not to the host it loaded the definition
# from, unless -O replaces them. So for -f openapi this script always passes -O
# (the -t origin by default), which keeps every request on this machine and
# gives the scan real endpoint coverage. A file target has no origin of its own,
# so it needs a loopback -O. -f soap has no override: it takes a URL target
# only, and the WSDL decides where requests go (a stderr note says so).
#
# The image is pinned by digest. ZAP still runs its add-on update at startup
# (it fetches add-ons from the network and installs pscanrulesBeta); passing
# -z -silent would stop both, and with them the beta passive rules.
#
# Exit codes:
#   0-3   zap-api-scan.py's own: 0 pass, 1 a FAIL, 2 a WARN and no FAIL, 3 other
#         failure. Every alert is a WARN by default, so a first run on a real
#         API normally exits 2; use --no-fail-on-warn or -c to change that.
#   64    bad arguments or invalid input
#   66    definition file or config file missing
#   69    docker is not installed or its daemon is not reachable
#   125+  docker's own, passed through

set -euo pipefail

# Exact pin by digest: a tag can be re-pushed. Docker Hub zaproxy/zap-stable 2.17.0.
ZAP_IMAGE="${ZAP_IMAGE:-zaproxy/zap-stable:2.17.0@sha256:9624669db72f54d86c4b46a7064518bd9bf79d8c61a4c31befa9923489f328af}"

CONTAINER_HOST=host.docker.internal
URL_PATTERN='^(https?)://(\[[^]]+\]|[^/:?#@]+)(:[0-9]+)?([/?#].*)?$'
HOSTPORT_PATTERN='^(\[[^]]+\]|[^/:?#@]+)(:[0-9]+)?$'

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

# The container's own alias for this machine is as local as loopback is.
is_local_host() {
	case "$1" in
	localhost | 127.0.0.1 | '[::1]' | "$CONTAINER_HOST") return 0 ;;
	esac
	return 1
}

# rewrite_url <url> -- sets $rewritten to the url with its loopback host
# replaced by $CONTAINER_HOST, and $rewritten_origin to its scheme://host[:port].
# Exits 64 for anything that is not an http(s) URL on a loopback host.
rewrite_url() {
	local url="$1"
	[[ "$url" =~ $URL_PATTERN ]] || bad_input "not a valid http(s) URL: $url"
	local scheme="${BASH_REMATCH[1]}" host="${BASH_REMATCH[2]}"
	local port="${BASH_REMATCH[3]}" rest="${BASH_REMATCH[4]}"
	is_local_host "$host" || bad_input "Phase 1 scans local hosts only (localhost, 127.0.0.1, [::1], host.docker.internal), not $host"
	rewritten="$scheme://$CONTAINER_HOST$port$rest"
	rewritten_origin="$scheme://$CONTAINER_HOST$port"
	[[ "$rewritten" == "$url" ]] || printf 'zap-api-scan: %s -> %s\n' "$url" "$rewritten" >&2
}

# rewrite_override <value> <default-scheme> -- sets $rewritten for -O, which takes
# a URL or host[:port]. The result always has a scheme: zap-api-scan.py parses a
# bare host:port as scheme:path and then scans nothing.
rewrite_override() {
	local value="$1"
	if [[ "$value" == http://* || "$value" == https://* ]]; then
		rewrite_url "$value"
		rewritten="$rewritten_origin"
		return
	fi
	[[ "$value" =~ $HOSTPORT_PATTERN ]] || bad_input "not a valid -O host[:port]: $value"
	local host="${BASH_REMATCH[1]}" port="${BASH_REMATCH[2]}" scheme="$2"
	is_local_host "$host" || bad_input "Phase 1 scans local hosts only (localhost, 127.0.0.1, [::1], host.docker.internal), not $host"
	rewritten="$scheme://$CONTAINER_HOST$port"
	[[ "$rewritten" == "$value" ]] || printf 'zap-api-scan: -O %s -> %s\n' "$value" "$rewritten" >&2
}

# absolute_path_of <file> -- the file's absolute path, with its directory
# resolved but the file name itself left as given (a symlink stays a symlink;
# docker resolves it when it binds the mount).
absolute_path_of() {
	local dir=.
	[[ "$1" == */* ]] && dir="${1%/*}"
	[[ -n "$dir" ]] || dir=/
	dir="$(cd "$dir" && pwd)"
	[[ "$dir" == / ]] && dir=''
	printf '%s/%s\n' "$dir" "${1##*/}"
}

# reject_colon <label> <path> -- exits 64: a colon in a path would be read as a
# field separator in docker's -v SOURCE:TARGET:MODE.
reject_colon() {
	[[ "$2" != *:* ]] || bad_input "$1 path must not contain a colon (docker -v cannot mount it): $2"
}

target=''
format=''
out_dir=./zap-reports
active=0
no_fail_on_warn=0
config=''
override=''
extra=()

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			usage_text
			exit 0
			;;
		-t | --target | -f | --format | -o | --out-dir | -c | --config | -O | --override)
			[[ $# -ge 2 ]] || bad_input "$1 needs a value"
			case "$1" in
			-t | --target) target="$2" ;;
			-f | --format) format="$2" ;;
			-o | --out-dir) out_dir="$2" ;;
			-c | --config) config="$2" ;;
			-O | --override) override="$2" ;;
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
		--)
			shift
			extra=("$@")
			break
			;;
		*) bad_input "unknown option: $1" ;;
		esac
	done
}

# Sets the scan inputs resolved from the arguments; exits 64/66/69 on a
# problem, before anything is created or run.
target_arg=''
spec_file=''
config_file=''
config_arg=''
override_arg=''
out_abs=''

resolve_inputs() {
	[[ -n "$target" ]] || bad_input "-t is required"
	[[ -n "$format" ]] || bad_input "-f is required"
	case "$format" in
	openapi | soap | graphql) ;;
	*) bad_input "-f must be openapi, soap or graphql, not $format" ;;
	esac

	[[ -z "$override" || "$format" == openapi ]] || bad_input "-O applies to -f openapi only; ZAP ignores it for $format"

	local target_origin='' default_scheme=http
	if [[ "$target" == http://* || "$target" == https://* ]]; then
		rewrite_url "$target"
		target_arg="$rewritten"
		target_origin="$rewritten_origin"
		default_scheme="${target%%://*}"
	else
		[[ "$format" != graphql ]] || bad_input "graphql takes an endpoint URL, not a file: $target"
		if [[ ! -f "$target" || ! -r "$target" ]]; then
			printf 'zap-api-scan: definition file not found or unreadable: %s\n' "$target" >&2
			exit 66
		fi
		[[ "$format" != soap ]] || bad_input "soap takes a URL target in Phase 1: ZAP has no host override for a WSDL, so a file's soap:address would decide where requests go"
		[[ -n "$override" ]] || bad_input "a definition file needs -O with a loopback host[:port]: ZAP sends requests to the servers[].url hosts named in the file"
		spec_file="$(absolute_path_of "$target")"
		reject_colon definition "$spec_file"
		target_arg="/zap/spec/${target##*/}"
	fi

	if [[ -n "$override" ]]; then
		rewrite_override "$override" "$default_scheme"
		override_arg="$rewritten"
	elif [[ "$format" == openapi ]]; then
		override_arg="$target_origin"
	elif [[ "$format" == soap ]]; then
		printf 'zap-api-scan: note: ZAP cannot override hosts in a WSDL; requests go to the soap:address hosts named in %s\n' "$target" >&2
	fi

	if [[ -n "$config" ]]; then
		if [[ ! -f "$config" || ! -r "$config" ]]; then
			printf 'zap-api-scan: config file not found or unreadable: %s\n' "$config" >&2
			exit 66
		fi
		config_file="$(absolute_path_of "$config")"
		reject_colon config "$config_file"
		config_arg="/zap/config/${config##*/}"
	fi

	[[ ! -e "$out_dir" || -d "$out_dir" ]] || bad_input "out dir exists and is not a directory: $out_dir"
	# docker mounts the absolute path, and prepare_out_dir has not created it yet.
	case "$out_dir" in
	/*) reject_colon "out dir" "$out_dir" ;;
	*) reject_colon "out dir" "$PWD/$out_dir" ;;
	esac
}

require_docker() {
	if ! command -v docker >/dev/null 2>&1; then
		printf 'zap-api-scan: docker is not installed or not on PATH\n' >&2
		exit 69
	fi
	if ! docker info >/dev/null 2>&1; then
		printf 'zap-api-scan: the docker daemon is not reachable (docker info failed)\n' >&2
		exit 69
	fi
}

prepare_out_dir() {
	mkdir -p "$out_dir" || bad_input "cannot create out dir: $out_dir"
	out_abs="$(cd "$out_dir" && pwd)"
}

docker_args=()

build_docker_args() {
	docker_args=(run --rm)
	[[ -t 1 ]] && docker_args+=(-t)
	docker_args+=("--add-host=$CONTAINER_HOST:host-gateway")
	docker_args+=(-v "$out_abs:/zap/wrk:rw")
	[[ -z "$spec_file" ]] || docker_args+=(-v "$spec_file:/zap/spec/${spec_file##*/}:ro")
	[[ -z "$config_file" ]] || docker_args+=(-v "$config_file:/zap/config/${config_file##*/}:ro")
	docker_args+=("$ZAP_IMAGE" zap-api-scan.py -t "$target_arg" -f "$format" -r report.html -J report.json)
	[[ "$active" -eq 1 ]] || docker_args+=(-S)
	[[ "$no_fail_on_warn" -eq 0 ]] || docker_args+=(-I)
	[[ -z "$config_arg" ]] || docker_args+=(-c "$config_arg")
	[[ -z "$override_arg" ]] || docker_args+=(-O "$override_arg")
	# ${arr[@]+...} keeps an empty array legal under `set -u` on bash 3.2.
	docker_args+=(${extra[@]+"${extra[@]}"})
}

main() {
	parse_args "$@"
	resolve_inputs
	require_docker
	prepare_out_dir
	build_docker_args

	local status=0
	docker "${docker_args[@]}" || status=$?
	exit "$status"
}

main "$@"
