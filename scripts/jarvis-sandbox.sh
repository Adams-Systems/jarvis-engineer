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
[[ $detach -eq 1 ]] || run sbx run --name "$name"
