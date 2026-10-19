#!/usr/bin/env bash
#
# Live acceptance checks against a running Codex sandbox (agent/codex kit).
#
# The agent-neutral cases (ai-memory, MySQL, nested Docker) are copied from
# verify-sandbox-claude.sh rather than shared: that script has no CI coverage, so
# refactoring it to share code is a risk with nothing to catch it. The Codex
# cases assert what only a live sandbox shows: that the generated content is
# where Codex reads it, and that the startup steps left config.toml with both
# MCP servers, no credential values, and ai-memory's hooks trusted.
#
# No case makes a model call (that costs tokens and needs the account); see
# AGENTS.md for the one manual `codex exec` check.
#
# Usage: scripts/verify-sandbox-codex.sh <sandbox-name>

set -uo pipefail

cd "$(dirname "$0")/.."

KIT_HOME=agent/codex/files/home
CODEX=/usr/local/share/npm-global/bin/codex

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

	if [[ -n "$expected" && "$actual" == *"$expected"* ]]; then
		printf 'ok   %s\n' "$name"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n     want substring: %s\n     got: %s\n' \
			"$name" "${expected:-<empty>}" "${actual:-<empty>}"
		fail=$((fail + 1))
	fi
}

printf '== live Codex sandbox acceptance: %s ==\n' "$SANDBOX"

# Startup steps complete asynchronously after `sbx create` returns, so poll for
# the last one (the MySQL registration) rather than racing it.
printf 'waiting for startup steps to finish'
sbx exec "$SANDBOX" -- sh -c '
	for i in $(seq 1 60); do
		grep -q "^\[mcp_servers\.mysql\]" /home/agent/.codex/config.toml 2>/dev/null && exit 0
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
	'node -e "
	  const s=require(\"net\").connect(3306,\"host.docker.internal\");
	  s.setTimeout(5000);
	  s.on(\"connect\",()=>{console.log(\"PORT_UP\");s.destroy();});
	  s.on(\"timeout\",()=>{console.log(\"TIMEOUT\");s.destroy();});
	  s.on(\"error\",e=>console.log(\"ERROR\",e.code));
	"'

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

# --- codex configuration ------------------------------------------------
check 'Codex lists both MCP servers' \
	'ai-memory mysql' \
	"$CODEX mcp list 2>&1 | awk '\$1 == \"ai-memory\" || \$1 == \"mysql\" { print \$1 }' | sort | paste -sd ' ' -"

# Codex does not forward the environment to stdio MCP servers on its own
# (spike S8); without env_vars the server would start with no credentials.
check 'mysql credentials are forwarded by name' \
	'env_vars = ["MYSQL_USER", "MYSQL_PASS"]' \
	'cat /home/agent/.codex/config.toml'

check 'mysql credential values are absent from the agent config' \
	'CLEAN' \
	'grep -qE "MYSQL_(PASS|USER) *=" /home/agent/.codex/config.toml && echo LEAKED || echo CLEAN'

# The kit registers postgres only when the sandbox was created with
# POSTGRES_MCP_CONNECTION_STRING, so these cases apply only then.
if sbx exec "$SANDBOX" -- sh -c '[ -n "$POSTGRES_MCP_CONNECTION_STRING" ]' >/dev/null 2>&1; then
	check 'Codex lists the postgres MCP server' \
		'postgres' \
		"$CODEX mcp list 2>&1 | awk '\$1 == \"postgres\" { print \$1 }'"

	check 'postgres connection string is forwarded by name' \
		'env_vars = ["POSTGRES_MCP_CONNECTION_STRING"]' \
		'cat /home/agent/.codex/config.toml'

	check 'postgres connection string value is absent from the agent config' \
		'CLEAN' \
		'grep -qE "POSTGRES_MCP_CONNECTION_STRING *=" /home/agent/.codex/config.toml && echo LEAKED || echo CLEAN'

	check 'postgres write tools are disabled' \
		'DISABLED' \
		'for t in postgres_mcp_modify postgres_mcp_bulk_load_csv postgres_mcp_add_connection; do
			grep -q "disabled_tools = .*\"$t\"" /home/agent/.codex/config.toml || { echo "MISSING $t"; exit 0; }
		done; echo DISABLED'
else
	printf 'skip postgres cases: POSTGRES_MCP_CONNECTION_STRING not set in the sandbox\n'
fi

# sbx's model provider lives in the same file the startup steps merge into;
# losing it cuts the agent off from the model.
check 'startup steps keep the sbx model provider' \
	'model_provider = "sandboxd"' \
	'cat /home/agent/.codex/config.toml'

# Codex runs a hook only once it is trusted; this is Codex's own view of the
# hooks after every startup step ran, read through its app-server.
check 'Codex reports every ai-memory hook trusted' \
	'trusted=7 untrusted=0' \
	"(printf '%s\n' '{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"verify\",\"version\":\"0\"}}}' '{\"method\":\"initialized\"}' '{\"id\":2,\"method\":\"hooks/list\",\"params\":{\"cwds\":[\"/home/agent\"]}}'; sleep 4) | timeout 20 $CODEX app-server 2>/dev/null | grep '\"id\":2' >/tmp/hooks-list.json;
	 echo \"trusted=\$(grep -o '\"trustStatus\":\"trusted\"' /tmp/hooks-list.json | wc -l | tr -d ' ') untrusted=\$(grep -o '\"trustStatus\":\"untrusted\"' /tmp/hooks-list.json | wc -l | tr -d ' ')\""

# --- generated content --------------------------------------------------
# Compared byte for byte with the kit: sbx copies files/home into the sandbox,
# and a stale or partial copy would give the agent instructions no source
# describes.
check 'AGENTS.md in the sandbox is the kit file' \
	"$(cksum <"$KIT_HOME/.codex/AGENTS.md")" \
	'cksum </home/agent/.codex/AGENTS.md'

check 'AGENTS.md starts with the generated marker' \
	'<!-- GENERATED by scripts/sync-agents.sh' \
	'head -n 1 /home/agent/.codex/AGENTS.md'

check 'every sub-agent TOML is in place' \
	"$(cd "$KIT_HOME/.codex/agents" && ls | sort | paste -sd ' ' -)" \
	'cd /home/agent/.codex/agents && ls | sort | paste -sd " " -'

check 'every rule the AGENTS.md index points at exists' \
	"$(cd "$KIT_HOME/.jarvis/rules" && ls | sort | paste -sd ' ' -)" \
	'cd /home/agent/.jarvis/rules && ls | sort | paste -sd " " -'

check 'every skill is in place' \
	"$(cd "$KIT_HOME/.agents/skills" && ls | sort | paste -sd ' ' -)" \
	'cd /home/agent/.agents/skills && ls | sort | paste -sd " " -'

# --- docker engine ------------------------------------------------------
check 'docker daemon answers the agent' \
	'Server: Docker Engine' \
	'docker version 2>&1 | grep -A1 "^Server:"'

check 'agent can build and run a container' \
	'CONTAINER_OK' \
	'docker run --rm alpine echo CONTAINER_OK 2>&1 | tail -1'

# The nested engine reports the sandbox hostname; the host's would not.
check 'daemon is the sandbox-local engine, not the host' \
	"$SANDBOX" \
	'docker info --format "{{.Name}}"'

# `compose ls` has to reach the engine; `compose version` would not.
check 'compose plugin reaches the nested engine' \
	'NAME' \
	'docker compose ls 2>&1'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
