#!/bin/sh
#
# Install the third-party skills listed in a config file, for one agent.
#
# Usage: install-agent-skills <claude-code|codex> [config.json]
#
# The config is JSON so it can be edited without touching the Dockerfile:
#
#   {
#     "skills": ["security-audit@cloudflare/security-audit-skill"]
#   }
#
# Each entry is skill@source, the way a plugin is plugin@marketplace: the skill
# name, then where the `skills` CLI fetches it from (a GitHub owner/repo, a URL,
# a git URL). The split is at the first `@`, so a git@host source still works.
# Pin a skill with `#ref` on the source (a commit sha, tag or branch; the CLI
# checks it out), e.g. security-audit@cloudflare/security-audit-skill#<sha>.
# Without one the CLI takes the source's current tip. Skills this repo writes
# itself live in shared/skills/ and do not go through here.
#
# Run at image build time as the agent user, with HOME set: the CLI installs
# into the user's directory (~/.claude/skills for claude-code, ~/.agents/skills
# for codex), and installing as root would leave them unreadable to uid 1000.
# --copy writes real files instead of symlinks into a shared directory.

set -eu

AGENT="${1:-}"
CONFIG="${2:-/usr/local/share/jarvis-engineer/config.json}"

case "$AGENT" in
claude-code) DIR="$HOME/.claude/skills" ;;
codex) DIR="$HOME/.agents/skills" ;;
*)
	echo "usage: install-agent-skills <claude-code|codex> [config.json]" >&2
	exit 2
	;;
esac

[ -r "$CONFIG" ] || {
	echo "install-agent-skills: cannot read $CONFIG" >&2
	exit 1
}

# node ships in both base images, so the config is parsed rather than pattern
# matched -- a stray comma should fail the build loudly, not silently install a
# truncated list.
SKILLS="$(node -e '
	const path = require("path");
	const cfg = require(path.resolve(process.argv[1]));
	const list = cfg.skills === undefined ? [] : cfg.skills;
	if (!Array.isArray(list) || list.some(e => typeof e !== "string" || !/^[^@\s]+@\S+$/.test(e))) {
		console.error("skills must be an array of skill@source strings");
		process.exit(1);
	}
	console.log(list.join("\n"));
' "$CONFIG")"

[ -n "$SKILLS" ] || exit 0

# No telemetry from the build, which has no use for it.
DISABLE_TELEMETRY=1 DO_NOT_TRACK=1
export DISABLE_TELEMETRY DO_NOT_TRACK

for entry in $SKILLS; do
	npx -y skills add "${entry#*@}" --skill "${entry%%@*}" -g -a "$AGENT" --copy -y
done

# The CLI can exit 0 without writing a skill (unknown name, agent it does not
# map), so confirm each SKILL.md is on disk rather than trusting its report.
for entry in $SKILLS; do
	name="${entry%%@*}"
	[ -s "$DIR/$name/SKILL.md" ] || {
		echo "install-agent-skills: $name is not installed under $DIR" >&2
		exit 1
	}
done
