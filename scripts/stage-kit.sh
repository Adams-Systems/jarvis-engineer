#!/usr/bin/env bash
#
# Assemble the build context of an agent's v3 kit and print its directory.
#
# sbx builds a local kit from its own directory, with that directory as the
# whole build context, and a recipe there cannot be FROM a locally built image.
# So the kit is staged: the agent's descriptor, the repo Dockerfile as the
# recipe, and every file that Dockerfile COPYs, at the same relative paths --
# the plain `docker build --target <agent> .` of `make build` keeps working on
# the repo as is.
#
# The staged directory is named after the descriptor's file stem, and sbx takes
# the agent name from it.
#
# Usage: scripts/stage-kit.sh claude|codex [out-root]   (default: build/kits)

set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
	echo "usage: scripts/stage-kit.sh claude|codex [out-root]" >&2
	exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
agent="$1"
case "$agent" in
claude | codex) ;;
*) usage ;;
esac
out_root="${2:-build/kits}"

# The descriptor is the one v3 file in the agent's directory.
descriptor=''
for f in agent/"$agent"/*.yaml; do
	[[ "$(head -n 1 "$f")" == '# syntax=docker/sandbox-kit:3' ]] || continue
	[[ -z "$descriptor" ]] || {
		echo "stage-kit: more than one v3 descriptor in agent/$agent/" >&2
		exit 1
	}
	descriptor="$f"
done
[[ -n "$descriptor" ]] || {
	echo "stage-kit: no v3 descriptor in agent/$agent/" >&2
	exit 1
}
name="$(basename "$descriptor" .yaml)"
dir="$out_root/$name"

rm -rf "$dir"
mkdir -p "$dir/scripts" "$dir/agent/$agent/files"

cp "$descriptor" "$dir/$name.yaml"

# Files beside the descriptor are ones it names (an agent-context@1
# contentFile), resolved against the kit directory. A v2 spec.yaml still there
# is not part of the kit.
for f in agent/"$agent"/*; do
	[[ -f "$f" && "$f" != "$descriptor" && "$(basename "$f")" != spec.yaml ]] || continue
	cp "$f" "$dir/"
done

# The frontend builds the recipe's last stage; the Dockerfile ends on codex.
{
	cat Dockerfile
	echo "# Staged by scripts/stage-kit.sh: the kit is the $agent stage."
	echo "FROM $agent"
} >"$dir/$name.dockerfile"

cp config.json "$dir/"

# .dockerignore is the list of scripts the image installs.
sed -n 's|^!scripts/||p' .dockerignore | while IFS= read -r script; do
	cp "scripts/$script" "$dir/scripts/"
done

cp -R "agent/$agent/files/home" "$dir/agent/$agent/files/"
find "$dir" -name .DS_Store -exec rm -f {} +

echo "$dir"
