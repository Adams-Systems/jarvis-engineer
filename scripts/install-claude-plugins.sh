#!/bin/sh
#
# Install the Claude Code plugins listed in a config file.
#
# Usage: install-claude-plugins [config.json]
#
# The config is JSON so it can be edited without touching the Dockerfile:
#
#   {
#     "marketplaces": ["anthropics/claude-plugins-official"],
#     "plugins":      ["superpowers@claude-plugins-official"]
#   }
#
# Skills are not a separate entry: Claude Code installs skills as part of a
# plugin, so listing the plugin is what brings its skills in.
#
# Run at image build time as the agent user, and available inside a running
# sandbox -- with no arguments it reads the config the image was built from, so
# re-running it repairs a sandbox whose plugin state was lost.
#
# Both lists matter. The cache alone is not enough: a plugin whose marketplace
# is not declared in the user settings cannot be refreshed or re-resolved, and a
# plugin absent from `enabledPlugins` is on disk but never loaded. `plugin
# install` writes both, which is why this shells out to the CLI rather than
# assembling the JSON by hand.

set -eu

CONFIG="${1:-/usr/local/share/jarvis-engineer/config.json}"

[ -r "$CONFIG" ] || {
	echo "install-claude-plugins: cannot read $CONFIG" >&2
	exit 1
}

# node ships in the base image, so the config is parsed rather than pattern
# matched -- a stray comma should fail the build loudly, not silently install a
# truncated list.
read_list() {
	# shellcheck disable=SC2016
	node -e '
		const path = require("path");
		const cfg = require(path.resolve(process.argv[1]));
		const key = process.argv[2];
		const list = cfg[key] === undefined ? [] : cfg[key];
		if (!Array.isArray(list) || list.some(e => typeof e !== "string")) {
			console.error(`${key} must be an array of strings`);
			process.exit(1);
		}
		console.log(list.join("\n"));
	' "$CONFIG" "$1"
}

MARKETPLACES="$(read_list marketplaces)"
PLUGINS="$(read_list plugins)"

# Startup steps and `su` run with a narrower PATH than an interactive shell --
# it omits ~/.local/bin, where the claude CLI lives, so a bare `claude` exits
# 127. Prefer the stable symlink over the versioned binary it points at.
CLAUDE="$HOME/.local/bin/claude"
[ -x "$CLAUDE" ] || CLAUDE="$(command -v claude)"

# `claude-plugins-official` is bootstrapped by a running Claude Code session,
# not by the plugin CLI, so in a fresh ~/.claude it is unknown and installs from
# it fail with "not found in marketplace". Declaring it in `marketplaces` is
# what makes a build-time install work; it resolves to the same public repo.
for marketplace in $MARKETPLACES; do
	"$CLAUDE" plugin marketplace add "$marketplace"
done

# -y is required when stdin is not a TTY and the marketplace declares an install
# command; it is a no-op for the plain git-backed plugins.
for plugin in $PLUGINS; do
	case "$plugin" in
	*@*) ;;
	*)
		echo "install-claude-plugins: $plugin must be written plugin@marketplace" >&2
		exit 1
		;;
	esac
	"$CLAUDE" plugin install "$plugin" -y
done

# A failed install still exits 0 in some paths, so confirm each id is actually
# registered rather than trusting the installer's own report.
for plugin in $PLUGINS; do
	"$CLAUDE" plugin list --json | grep -q "\"id\": \"$plugin\"" || {
		echo "install-claude-plugins: $plugin is not registered" >&2
		exit 1
	}
done
