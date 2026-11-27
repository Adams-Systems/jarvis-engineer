#!/usr/bin/env bash
#
# Create (or re-attach to) a jarvis-engineer sandbox for the current project.
#
# `make sandbox <agent>` always builds the sandbox around this repo and replaces
# it. This script is the same flow for any other project: it stages the kit from
# this repo, creates a sandbox named after the project directory with that
# directory as its workspace, and attaches. An existing sandbox is re-attached,
# never replaced, unless --recreate is passed.
#
# Usage: jarvis-sandbox claude|codex [options] [workspace]
#
#   claude|codex      the agent to run; required, there is no default
#   workspace         directory to mount (default: the current directory)
#   --name NAME       sandbox name (default: jarvis-engineer-<dir>, or
#                     jarvis-engineer-<dir>-codex for codex)
#   --env-file FILE   credentials passed at create time (default: .env in this
#                     repo, or $JARVIS_ENV_FILE)
#   --recreate        remove an existing sandbox of that name first
#   --detach          create without attaching
#   --publish PORT|HOST:PORT   publish a sandbox port on the host's loopback at
#                     create time (repeatable). PORT means PORT:PORT; needed
#                     for zap-api-scan so ZAP can reach the API. Ignored when
#                     re-attaching to an existing sandbox
#   --dry-run         print the commands instead of running them
#
# Put it on PATH once, from anywhere:
#   ln -s /path/to/jarvis-engineer/scripts/jarvis-sandbox.sh ~/.local/bin/jarvis-sandbox
# macOS does not put ~/.local/bin on PATH; add to ~/.zprofile:
#   export PATH="$HOME/.local/bin:$PATH"
#
# A kit change (shared/, config.json, a descriptor) reaches an existing sandbox
# only through --recreate: sbx builds a kit at create time.

set -euo pipefail

# Follow symlinks to find this repo (no `readlink -f` on macOS).
src="${BASH_SOURCE[0]}"
while [[ -L "$src" ]]; do
	dir="$(cd "$(dirname "$src")" && pwd)"
	src="$(readlink "$src")"
	[[ "$src" == /* ]] || src="$dir/$src"
done
repo="$(cd "$(dirname "$src")/.." && pwd)"

KIT_BUILDER=kit-builder

usage() {
	sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "$src" | sed '$d' >&2
	exit 2
}

agent=''
name=''
env_file="${JARVIS_ENV_FILE:-$repo/.env}"
recreate=0
detach=0
dry=0
workspace=''
publish_specs=()

# publish_spec <value> -- prints the value as HOST_PORT:SANDBOX_PORT, or fails.
# Only PORT and HOST:PORT: no HOST_IP (the binding stays loopback), no protocol
# (tcp4), no bare ephemeral host port (the host port must be known to scan).
publish_spec() {
	local host_port sandbox_port n
	[[ "$1" =~ ^([0-9]+)(:([0-9]+))?$ ]] || return 1
	host_port="${BASH_REMATCH[1]}"
	sandbox_port="${BASH_REMATCH[3]:-$host_port}"
	for n in "$host_port" "$sandbox_port"; do
		[[ ${#n} -le 5 ]] && ((10#$n >= 1 && 10#$n <= 65535)) || return 1
	done
	printf '%d:%d\n' "$((10#$host_port))" "$((10#$sandbox_port))"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	claude | codex)
		[[ -z "$agent" ]] || usage
		agent="$1"
		;;
	--name)
		[[ $# -ge 2 ]] || usage
		name="$2"
		shift
		;;
	--env-file)
		[[ $# -ge 2 ]] || usage
		env_file="$2"
		shift
		;;
	--publish)
		[[ $# -ge 2 ]] || usage
		spec="$(publish_spec "$2")" || {
			echo "jarvis-sandbox: invalid --publish value: $2" >&2
			usage
		}
		publish_specs+=("$spec")
		shift
		;;
	--recreate) recreate=1 ;;
	--detach) detach=1 ;;
	--dry-run) dry=1 ;;
	-h | --help) usage ;;
	-*) usage ;;
	*)
		[[ -z "$workspace" ]] || usage
		workspace="$1"
		;;
	esac
	shift
done

if [[ -z "$agent" ]]; then
	echo "jarvis-sandbox: name the agent: claude or codex" >&2
	usage
fi

workspace="$(cd "${workspace:-.}" && pwd)" || {
	echo "jarvis-sandbox: no such directory: ${workspace:-.}" >&2
	exit 1
}

if [[ -z "$name" ]]; then
	slug="$(basename "$workspace" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/^-*//; s/-*$//')"
	[[ -n "$slug" ]] || slug=workspace
	if [[ "$agent" == codex ]]; then
		name="jarvis-engineer-$slug-codex"
	else
		name="jarvis-engineer-$slug"
	fi
fi

# Echo and run, or only echo with --dry-run.
run() {
	if [[ $dry -eq 1 ]]; then
		printf '+'
		printf ' %q' "$@"
		printf '\n'
	else
		"$@"
	fi
}

if [[ -f "$env_file" ]]; then
	env_args=(--env-file "$env_file")
else
	echo "jarvis-sandbox: $env_file not found; creating without credentials (no MySQL/Postgres/private Go modules)" >&2
	env_args=()
fi

# Re-attach to a sandbox that exists, unless asked to replace it.
if sbx ls -q 2>/dev/null | grep -Fxq "$name"; then
	if [[ $recreate -eq 0 ]]; then
		echo "jarvis-sandbox: $name exists; attaching (--recreate to replace it)" >&2
		if [[ ${#publish_specs[@]} -gt 0 ]]; then
			echo "jarvis-sandbox: --publish ignored: $name exists; run sbx port publish $name ${publish_specs[*]} or use --recreate" >&2
		fi
		[[ $detach -eq 1 ]] && exit 0
		run sbx run --name "$name"
		exit 0
	fi
	run sbx rm --force "$name"
fi

# The staged kit is the build context sbx builds from; staging is cheap and sbx
# caches the build by source hash.
kit_dir="$("$repo/scripts/stage-kit.sh" "$agent")"
# stage-kit.sh prints the path relative to the repo; sbx runs from the project.
[[ "$kit_dir" == /* ]] || kit_dir="$repo/$kit_dir"

docker buildx inspect "$KIT_BUILDER" >/dev/null 2>&1 ||
	run docker buildx create --name "$KIT_BUILDER" --driver docker-container --bootstrap

run env BUILDX_BUILDER="$KIT_BUILDER" sbx create --name "$name" ${env_args[@]+"${env_args[@]}"} "$kit_dir" "$workspace"
# sbx port publish is documented after create; whether sbx create takes a
# --publish of its own is unverified.
if [[ ${#publish_specs[@]} -gt 0 ]]; then
	run sbx port publish "$name" "${publish_specs[@]}" || {
		echo "jarvis-sandbox: $name was created but publishing failed; run: sbx port publish $name ${publish_specs[*]}" >&2
		exit 1
	}
fi
[[ $detach -eq 1 ]] || run sbx run --name "$name"
