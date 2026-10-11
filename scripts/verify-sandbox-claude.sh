#!/usr/bin/env bash
#
# Live acceptance checks against a running sandbox.
#
# Kit and image checks cannot prove the MySQL path works: reaching the host's
# MySQL is only observable at runtime. These cases assert the output of real
# queries and a real MCP health check.
#
# Usage: scripts/verify-sandbox-claude.sh <sandbox-name>

set -uo pipefail

cd "$(dirname "$0")/.."

# Same config the image was built from: the live cases assert that what the
# template baked actually reaches the agent.
CONFIG=config.json
PLUGIN_COUNT="$(jq -r '.plugins | length' "$CONFIG")"

# The kit's generated content, compared with what the sandbox received.
KIT_HOME=agent/claude/files/home

SANDBOX="${1:-}"
if [[ -z "$SANDBOX" ]]; then
	printf 'usage: %s <sandbox-name>\n\n' "$0" >&2
	sbx ls >&2
	exit 2
fi

pass=0
fail=0

# check <name> <expected-substring> <remote-shell-command>
check() {
	local name="$1" expected="$2" actual

	actual="$(sbx exec "$SANDBOX" -- sh -c "$3" 2>&1)"

	if [[ "$actual" == *"$expected"* ]]; then
		printf 'ok   %s\n' "$name"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n     want substring: %s\n     got: %s\n' \
			"$name" "$expected" "${actual:-<empty>}"
		fail=$((fail + 1))
	fi
}

printf '== live sandbox acceptance: %s ==\n' "$SANDBOX"

# Startup steps complete asynchronously after `sbx create` returns, so poll for
# the last one rather than racing it.
printf 'waiting for startup steps to finish'
sbx exec "$SANDBOX" -- sh -c '
	for i in $(seq 1 60); do
		/home/agent/.local/bin/claude mcp list 2>/dev/null | grep -qE "^mysql:" && exit 0
		sleep 2
	done
	exit 1' >/dev/null 2>&1 && printf ' done\n\n' || printf ' TIMED OUT\n\n'

# --- ai-memory ----------------------------------------------------------
check 'ai-memory MCP server answers a handshake' \
	'"serverInfo":{"name":"ai-memory"' \
	'curl -s --max-time 10 http://127.0.0.1:49374/mcp -X POST -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"v\",\"version\":\"0\"}}}"'

check 'memory store is on the persistent volume' \
	'/var/lib/ai-memory' \
	'echo "$AI_MEMORY_DATA_DIR"'

check 'memory volume is writable by the agent' \
	'agent:agent' \
	'stat -c %U:%G /var/lib/ai-memory'

# --- mysql --------------------------------------------------------------
check 'host mysql port is reachable from the sandbox' \
	'PORT_UP' \
	'socat -u /dev/null TCP:host.docker.internal:3306,connect-timeout=5 >/dev/null 2>&1 && echo PORT_UP'

# A MySQL server greets on connect; anything else means we reached a stub.
check 'the port answers as a real MySQL server' \
	'GREETING_OK' \
	'node -e "
	  const net=require(\"net\");
	  const s=net.connect(3306,\"host.docker.internal\");
	  s.setTimeout(8000);
	  s.on(\"data\",d=>{console.log(/[0-9]+\.[0-9]+\.[0-9]+/.test(d.toString(\"latin1\"))?\"GREETING_OK\":\"NO_VERSION\");s.end();});
	  s.on(\"timeout\",()=>{console.log(\"TIMEOUT\");s.destroy();});
	  s.on(\"error\",e=>console.log(\"ERROR\",e.code));
	"'

check 'mysql MCP server is registered and connects' \
	'mysql' \
	'claude mcp list 2>&1 | grep -E "^mysql:"'

check 'both MCP servers report connected' \
	'2' \
	'claude mcp list 2>&1 | grep -cE "^(mysql|ai-memory):.*Connected"'

check 'mysql credentials are absent from the agent config' \
	'CLEAN' \
	'grep -qE "MYSQL_(PASS|USER)" ~/.claude.json && echo LEAKED || echo CLEAN'

# --- docker engine ------------------------------------------------------
# The image only opts in via a label; whether sbx actually launched dockerd and
# whether the agent can reach its socket is observable at runtime only.
check 'docker daemon answers the agent' \
	'Server: Docker Engine' \
	'docker version 2>&1 | grep -A1 "^Server:"'

check 'agent can build and run a container' \
	'CONTAINER_OK' \
	'docker run --rm alpine echo CONTAINER_OK 2>&1 | tail -1'

# Proves the daemon is the sandbox's own and not the host's: the nested engine
# reports the sandbox hostname, the host engine would report the host VM.
check 'daemon is the sandbox-local engine, not the host' \
	"$SANDBOX" \
	'docker info --format "{{.Name}}"'

# `compose version` is client-only and passes even with no daemon at all;
# `compose ls` has to reach the engine, so it is the one worth asserting.
check 'compose plugin reaches the nested engine' \
	'NAME' \
	'docker compose ls 2>&1'

# --- claude code plugins ------------------------------------------------
# The image bakes the plugins, but a sandbox gets a fresh ~/.claude and its
# startup steps rewrite ~/.claude/settings.json, so whether the baked state
# actually reaches the agent is only observable here.
check 'baked plugins survive sandbox creation' \
	"enabled=$PLUGIN_COUNT disabled=0" \
	'e=$(claude plugin list --json | grep -c "\"enabled\": true");
	 d=$(claude plugin list --json | grep -c "\"enabled\": false");
	 echo "enabled=$e disabled=$d"'

# `ai-memory install-hooks --apply` rewrites settings.json on every start. It is
# documented as preserving unrelated entries; this is what proves it, because
# losing extraKnownMarketplaces silently unloads every plugin.
check 'plugin settings survive ai-memory hook registration' \
	"$(jq -r '.plugins[] | split("@")[1]' "$CONFIG" | sort -u | paste -sd, -)" \
	'node -e "const s=require(\"/home/agent/.claude/settings.json\"); console.log(Object.keys(s.extraKnownMarketplaces).sort().join(\",\"))"'

# --- status line --------------------------------------------------------
# Three startup steps write settings.json in sequence; only here is it
# observable that the last of them left `statusLine` in place.
check 'status line survives the startup steps' \
	'/usr/local/bin/jarvis-statusline' \
	'node -e "const s=require(\"/home/agent/.claude/settings.json\"); console.log(s.statusLine && s.statusLine.command)"'

check 'status line renders the kit role label' \
	"$(sbx exec "$SANDBOX" -- sh -c 'cat /home/agent/.jarvis-role' 2>/dev/null | tr -d '\r\n')" \
	'jarvis-statusline </dev/null'

check 'superpowers skills are readable in the sandbox' \
	'brainstorming' \
	'ls /home/agent/.claude/plugins/cache/claude-plugins-official/superpowers/*/skills'

# --- sub-agents ---------------------------------------------------------
# sbx copies files/home into the sandbox; a stale or partial copy would leave
# the review fan-out in ROLE.md pointing at reviewers that are not there.
check 'every sub-agent file is in place' \
	"$(cd "$KIT_HOME/.claude/agents" && ls | sort | paste -sd ' ' -)" \
	'cd /home/agent/.claude/agents && ls | sort | paste -sd " " -'

check 'specialized reviewers carry their disallowedTools line' \
	'restricted=3' \
	'cd /home/agent/.claude/agents && echo "restricted=$(grep -l "^disallowedTools: " security-reviewer.md code-reviewer.md database-reviewer.md 2>/dev/null | wc -l | tr -d " ")"'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
