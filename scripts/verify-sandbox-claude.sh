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

# session_args -- the argv of the agent process, read while a TTY session is
# attached. The agent only runs inside a session, so one is attached for a few
# seconds under `script` (util-linux and BSD spell its arguments differently).
session_args() {
	local pid args='' i

	if script --version >/dev/null 2>&1; then
		script -qec "sbx run --name $SANDBOX" /dev/null >/dev/null 2>&1 &
	else
		script -q /dev/null sbx run --name "$SANDBOX" >/dev/null 2>&1 &
	fi
	pid=$!
	for i in $(seq 1 30); do
		args="$(sbx exec "$SANDBOX" -- sh -c 'ps -eo args | grep "^claude " | head -n 1' 2>/dev/null)"
		[[ -n "$args" ]] && break
		sleep 1
	done
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	printf '%s' "${args:-<no agent process>}"
}

# expect <name> <expected-substring> <actual> -- for values read on the host.
expect() {
	if [[ "$3" == *"$2"* ]]; then
		printf 'ok   %s\n' "$1"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n     want substring: %s\n     got: %s\n' "$1" "$2" "${3:-<empty>}"
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
	'AUTH_TOKEN="$AI_MEMORY_AUTH_TOKEN"
	if [ -z "$AUTH_TOKEN" ] && [ -s "$AI_MEMORY_DATA_DIR/auth-tokens/default" ]; then
		AUTH_TOKEN=$(cat "$AI_MEMORY_DATA_DIR/auth-tokens/default")
	fi
	if [ -n "$AUTH_TOKEN" ]; then
		curl -s --max-time 10 http://127.0.0.1:49374/mcp -X POST -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "Authorization: Bearer $AUTH_TOKEN" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"v\",\"version\":\"0\"}}}"
	else
		curl -s --max-time 10 http://127.0.0.1:49374/mcp -X POST -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"v\",\"version\":\"0\"}}}"
	fi'

check 'memory store is on the persistent volume' \
	'/var/lib/ai-memory' \
	'echo "$AI_MEMORY_DATA_DIR"'

check 'memory volume is writable by the agent' \
	'agent:agent' \
	'stat -c %U:%G /var/lib/ai-memory'

check 'go caches are on the persistent volume and writable' \
	'/var/lib/go/mod agent:agent' \
	'echo "$GOMODCACHE $(stat -c %U:%G /var/lib/go)"'

check 'go race detector prerequisites are present' \
	'CGO=1' \
	'command -v gcc >/dev/null && echo CGO=$(go env CGO_ENABLED)'

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

# --- postgres -----------------------------------------------------------
# The kit registers postgres only when the sandbox was created with
# POSTGRES_MCP_CONNECTION_STRING, so these cases apply only then.
if sbx exec "$SANDBOX" -- sh -c '[ -n "$POSTGRES_MCP_CONNECTION_STRING" ]' >/dev/null 2>&1; then
	check 'postgres MCP server is registered and connects' \
		'Connected' \
		'claude mcp list 2>&1 | grep -E "^postgres:"'

	check 'postgres write tools are denied' \
		'DENIED' \
		'for t in postgres_mcp_modify postgres_mcp_bulk_load_csv postgres_mcp_add_connection; do
			grep -q "mcp__postgres__$t" ~/.claude/settings.json || { echo "MISSING $t"; exit 0; }
		done; echo DENIED'

	check 'postgres connection string is absent from the agent config' \
		'CLEAN' \
		'grep -q "POSTGRES_MCP_CONNECTION_STRING" ~/.claude.json && echo LEAKED || echo CLEAN'
else
	printf 'skip postgres cases: POSTGRES_MCP_CONNECTION_STRING not set in the sandbox\n'
fi

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

# --- baked third-party skills -------------------------------------------
# config.json's skills are installed into ~/.claude/skills at image build time.
# Whether that directory survives `sbx create` is only observable here.
check 'baked skills survive sandbox creation' \
	"$(jq -r '.skills[] | split("@")[0]' "$CONFIG" | sort | paste -sd ' ' -)" \
	'cd /home/agent/.claude/skills && for n in $(node -e "for (const e of require(\"/usr/local/share/jarvis-engineer/config.json\").skills || []) console.log(e.split(\"@\")[0])"); do test -s "$n/SKILL.md" && echo "$n"; done | sort | paste -sd " " -'

# --- persona ------------------------------------------------------------
# The image bakes the kit content into /home/agent and appends the persona in
# its Cmd. Both fail silently: a sandbox without them is stock Claude, and
# every other case here still passes.
check 'ROLE.md reached the sandbox byte for byte' \
	"$(cksum <"$KIT_HOME/ROLE.md")" \
	'cksum </home/agent/ROLE.md'

expect 'agent launches with the role prompt appended' \
	'--append-system-prompt-file /home/agent/ROLE.md' \
	"$(session_args)"

# --- sub-agents ---------------------------------------------------------
# The image bakes files/home into /home/agent; a stale or partial copy would
# leave the review fan-out in ROLE.md pointing at reviewers that are not there.
check 'every sub-agent file is in place' \
	"$(cd "$KIT_HOME/.claude/agents" && ls | sort | paste -sd ' ' -)" \
	'cd /home/agent/.claude/agents && ls | sort | paste -sd " " -'

check 'specialized reviewers carry their disallowedTools line' \
	'restricted=3' \
	'cd /home/agent/.claude/agents && echo "restricted=$(grep -l "^disallowedTools: " security-reviewer.md code-reviewer.md database-reviewer.md 2>/dev/null | wc -l | tr -d " ")"'

# --- restart ------------------------------------------------------------
# Startup steps re-run on every start against volumes that kept their state:
# a stale serve lock or a second server would surface only after a restart.
# `sbx exec` starts a stopped sandbox and returns once its startup steps ran.
sbx stop "$SANDBOX" >/dev/null 2>&1
check 'after a restart, exactly one ai-memory server runs' \
	'servers=1' \
	'for i in $(seq 1 30); do
		curl -s -o /dev/null --max-time 2 http://127.0.0.1:49374/mcp && break
		sleep 1
	done
	echo "servers=$(ps -eo args | grep -c "^ai-memory serve")"'

check 'after a restart, the memory store and plugins are intact' \
	"store=/var/lib/ai-memory enabled=$PLUGIN_COUNT" \
	'echo "store=$AI_MEMORY_DATA_DIR enabled=$(claude plugin list --json | grep -c "\"enabled\": true")"'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
