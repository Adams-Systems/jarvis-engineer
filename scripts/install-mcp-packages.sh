#!/bin/sh
#
# Install the MCP server packages listed in a config file, globally with npm.
#
# Usage: install-mcp-packages [config.json]
#
# The config is JSON so it can be edited without touching the Dockerfile:
#
#   {
#     "mcpServers": ["@benborla29/mcp-server-mysql@2.0.9", "@microsoft/postgres-mcp"]
#   }
#
# Each entry is an npm package spec. Pin a release with `@version` for a
# reproducible rebuild; an entry without one takes the registry's `latest`.
# Installing is only half of an MCP server: a kit's startup step still registers
# it with the agent, because ~/.claude.json and ~/.codex/config.toml are reset
# on every sandbox creation.
#
# Run as root at image build time: the global prefix is not writable by the
# agent user. `--engine-strict` turns a package's `engines.node` mismatch into a
# build failure instead of a warning, so an image whose Node is too old for a
# server does not ship.

set -eu

CONFIG="${1:-/usr/local/share/jarvis-engineer/config.json}"

[ -r "$CONFIG" ] || {
	echo "install-mcp-packages: cannot read $CONFIG" >&2
	exit 1
}

# node ships in both base images, so the config is parsed rather than pattern
# matched -- a stray comma should fail the build loudly, not silently install a
# truncated list.
PACKAGES="$(node -e '
	const path = require("path");
	const cfg = require(path.resolve(process.argv[1]));
	const list = cfg.mcpServers === undefined ? [] : cfg.mcpServers;
	if (!Array.isArray(list) || list.some(e => typeof e !== "string" || e === "")) {
		console.error("mcpServers must be an array of non-empty strings");
		process.exit(1);
	}
	console.log(list.join("\n"));
' "$CONFIG")"

[ -n "$PACKAGES" ] || exit 0

ROOT="$(npm root -g)"

for spec in $PACKAGES; do
	npm install -g --engine-strict "$spec"
done

# `npm install` can exit 0 without leaving the package where `npx` looks, so
# confirm each one is present rather than trusting the installer's report. The
# name is the spec without its version: the last `@` that is not the scope.
for spec in $PACKAGES; do
	name="$spec"
	case "${spec#@}" in
	*@*) name="${spec%@*}" ;;
	esac
	[ -d "$ROOT/$name" ] || {
		echo "install-mcp-packages: $name is not installed under $ROOT" >&2
		exit 1
	}
done
