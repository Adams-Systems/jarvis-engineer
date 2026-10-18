#!/usr/bin/env bash
#
# Image-level acceptance checks for the jarvis-engineer-codex sandbox template.
#
# Same rules as verify-image-claude.sh: every case asserts an observable output of a
# command run as the sandbox's agent user (uid 1000), not merely that a build
# step exited zero. The Claude-only cases (plugins, status line) have no Codex
# counterpart and are not here.
#
# Usage: scripts/verify-image-codex.sh [image]

set -uo pipefail

cd "$(dirname "$0")/.."

IMAGE="${1:-jarvis-engineer:codex}"
HOOKS_DIR=/usr/local/share/ai-memory/hooks

# The codex-docker base installs npm globals here (spike S10, same prefix as
# the Claude image); startup steps call codex by this absolute path.
NPM_PREFIX=/usr/local/share/npm-global

pass=0
fail=0

# arg_of <Dockerfile> <ARG name> -- the default value of that build ARG.
arg_of() {
	sed -n "s/^ARG $2=//p" "$1" | head -n 1
}

AI_MEMORY_VERSION="$(arg_of Dockerfile AI_MEMORY_VERSION)"
GOLANGCI_LINT_VERSION="$(arg_of Dockerfile GOLANGCI_LINT_VERSION)"

# report <name> <expected-substring> <actual>
report() {
	if [[ -n "$2" && "$3" == *"$2"* ]]; then
		printf 'ok   %s\n' "$1"
		pass=$((pass + 1))
	else
		printf 'FAIL %s\n     want substring: %s\n     got: %s\n' \
			"$1" "${2:-<empty>}" "${3:-<empty>}"
		fail=$((fail + 1))
	fi
}

# check <name> <expected-substring> <shell-command>
#
# Runs the command in the image as uid 1000 and asserts the expected substring
# appears in its combined output.
check() {
	report "$1" "$2" "$(docker run --rm --user 1000:1000 --entrypoint sh "$IMAGE" -c "$3" 2>&1)"
}

# check_label <name> <expected-substring> <label-key>
#
# Labels drive sbx's own behaviour (it reads them before the container exists),
# so they have to be asserted on the image metadata rather than from inside it.
check_label() {
	report "$1" "$2" "$(docker image inspect "$IMAGE" --format "{{index .Config.Labels \"$3\"}}" 2>&1)"
}

printf '== image acceptance: %s ==\n' "$IMAGE"

# --- ai-memory ----------------------------------------------------------
check 'ai-memory resolves on the agent PATH' \
	'/usr/local/bin/ai-memory' \
	'command -v ai-memory'

check 'ai-memory is the pinned version' \
	"ai-memory $AI_MEMORY_VERSION" \
	'ai-memory --version'

check 'codex hook bundle sits at the install-hooks default path' \
	'session-start.sh' \
	"ls $HOOKS_DIR/codex"

check 'codex hook scripts are executable by the agent' \
	'EXEC_OK' \
	"test -x $HOOKS_DIR/codex/session-start.sh && echo EXEC_OK"

# install-hooks writes the absolute path of its own executable into
# ~/.codex/hooks.json; it must be the stable copy, not the mise install that a
# version bump would remove.
check 'install-hooks writes the stable binary path into hooks.json' \
	'/usr/local/bin/ai-memory' \
	'AI_MEMORY_DATA_DIR=/tmp/v ai-memory init >/dev/null 2>&1;
	 AI_MEMORY_DATA_DIR=/tmp/v ai-memory install-hooks --agent codex --apply >/dev/null 2>&1;
	 cat ~/.codex/hooks.json'

check 'install-hooks does not leak a version-pinned path' \
	'CLEAN' \
	'AI_MEMORY_DATA_DIR=/tmp/v ai-memory init >/dev/null 2>&1;
	 AI_MEMORY_DATA_DIR=/tmp/v ai-memory install-hooks --agent codex --apply >/dev/null 2>&1;
	 grep -q "/opt/mise" ~/.codex/hooks.json && echo LEAKED || echo CLEAN'

# sbx writes its own ~/.codex/config.toml at create time (spike S2), so the
# registration has to merge into that file, and a re-run must not duplicate.
check 'install-mcp merges into config.toml, idempotently, keeping other servers' \
	'ai-memory=1 x=1' \
	'mkdir -p ~/.codex; printf "[mcp_servers.x]\ncommand = \"true\"\n" >~/.codex/config.toml;
	 AI_MEMORY_DATA_DIR=/tmp/v ai-memory init >/dev/null 2>&1;
	 AI_MEMORY_DATA_DIR=/tmp/v ai-memory install-mcp --client codex --apply >/dev/null 2>&1;
	 AI_MEMORY_DATA_DIR=/tmp/v ai-memory install-mcp --client codex --apply >/dev/null 2>&1;
	 echo "ai-memory=$(grep -c "^\[mcp_servers.ai-memory\]" ~/.codex/config.toml) x=$(grep -c "^\[mcp_servers.x\]" ~/.codex/config.toml)"'

check 'install-mcp targets the loopback server' \
	'127.0.0.1:49374' \
	'AI_MEMORY_DATA_DIR=/tmp/v ai-memory init >/dev/null 2>&1;
	 AI_MEMORY_DATA_DIR=/tmp/v ai-memory install-mcp --client codex'

check 'agent can initialise a data directory' \
	'config.toml' \
	'AI_MEMORY_DATA_DIR=/tmp/v ai-memory init >/dev/null 2>&1; ls /tmp/v'

# --- hook trust ---------------------------------------------------------
# Codex runs no hook until its exact definition is trusted, and sbx recreates
# ~/.codex per sandbox, so the trust has to be re-established by a startup
# step (spike S7: hook-mode pretrust). trust-codex-hooks asks Codex's own
# app-server for each hook's current hash and trusts only ai-memory's.
#
# hook_trust_counts: prints trusted=<n> untrusted=<n> as Codex itself reports
# them, read from the app-server independently of the helper under test.
hook_trust_counts='(printf "%s\n" "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"verify\",\"version\":\"0\"}}}" "{\"method\":\"initialized\"}" "{\"id\":2,\"method\":\"hooks/list\",\"params\":{\"cwds\":[\"$HOME\"]}}"; sleep 4) | timeout 20 '"$NPM_PREFIX"'/bin/codex app-server 2>/dev/null | grep "\"id\":2" >/tmp/list.json;
	 echo "trusted=$(grep -o "\"trustStatus\":\"trusted\"" /tmp/list.json | wc -l | tr -d " ") untrusted=$(grep -o "\"trustStatus\":\"untrusted\"" /tmp/list.json | wc -l | tr -d " ")"'

install_ai_memory_hooks='AI_MEMORY_DATA_DIR=/tmp/v ai-memory init >/dev/null 2>&1;
	 AI_MEMORY_DATA_DIR=/tmp/v ai-memory install-hooks --agent codex --apply >/dev/null 2>&1;'

check 'trust-codex-hooks resolves on the agent PATH' \
	'/usr/local/bin/trust-codex-hooks' \
	'command -v trust-codex-hooks'

check 'ai-memory hooks start untrusted (the baseline the helper changes)' \
	'trusted=0 untrusted=6' \
	"$install_ai_memory_hooks $hook_trust_counts"

check 'trust-codex-hooks makes Codex report every ai-memory hook trusted' \
	'trusted=6 untrusted=0' \
	"$install_ai_memory_hooks trust-codex-hooks >/dev/null 2>&1; $hook_trust_counts"

# Only ai-memory's hooks are pre-trusted (ADR D6); anything else in the file
# still goes through Codex's own review.
check 'trust-codex-hooks leaves a hook that is not ai-memory untrusted' \
	'trusted=6 untrusted=1' \
	"$install_ai_memory_hooks
	 node -e 'const f=process.env.HOME+\"/.codex/hooks.json\",fs=require(\"fs\"),h=JSON.parse(fs.readFileSync(f));h.hooks.Stop.push({matcher:\"\",hooks:[{type:\"command\",command:\"sh -c true\"}]});fs.writeFileSync(f,JSON.stringify(h))';
	 trust-codex-hooks >/dev/null 2>&1; $hook_trust_counts"

# A command that merely starts like ai-memory's (here with a shell command
# appended) is not ai-memory's hook, and must not be trusted.
check 'trust-codex-hooks leaves a hook that only starts like ai-memory untrusted' \
	'trusted=6 untrusted=1' \
	"$install_ai_memory_hooks
	 node -e 'const f=process.env.HOME+\"/.codex/hooks.json\",fs=require(\"fs\"),h=JSON.parse(fs.readFileSync(f));h.hooks.Stop.push({matcher:\"\",hooks:[{type:\"command\",command:\"/usr/local/bin/ai-memory --x hook --event stop; touch /tmp/spoofed\"}]});fs.writeFileSync(f,JSON.stringify(h))';
	 trust-codex-hooks >/dev/null 2>&1; $hook_trust_counts"

# Startup steps have no timeout of their own, so the helper must return even
# when the app-server ignores SIGTERM. The fake answers every request (one
# ai-memory hook, already trusted) and then refuses to die.
check 'trust-codex-hooks returns when the app-server ignores SIGTERM' \
	'EXIT=0' \
	'cat >/tmp/fake-codex <<EOF
#!/usr/bin/env node
process.on("SIGTERM", () => {});
setInterval(() => {}, 1000);
require("readline").createInterface({ input: process.stdin }).on("line", (line) => {
  const m = JSON.parse(line);
  if (m.id === undefined) return;
  const hook = { key: "k", sourcePath: process.env.HOME + "/.codex/hooks.json", handlerType: "command",
    command: "/usr/local/bin/ai-memory hook --event stop", trustStatus: "trusted", currentHash: "h" };
  const result = m.method === "hooks/list" ? { data: [{ cwd: process.env.HOME, hooks: [hook] }] } : {};
  process.stdout.write(JSON.stringify({ id: m.id, result }) + "\n");
});
EOF
	 chmod +x /tmp/fake-codex;
	 CODEX_BIN=/tmp/fake-codex timeout 15 trust-codex-hooks >/dev/null 2>&1; echo "EXIT=$?"'

# sbx writes its own config.toml (model provider, MCP gateway) before the
# startup steps run; losing it would cut the agent off from the model.
check 'trust-codex-hooks keeps the existing config.toml keys' \
	'model_provider = "sandboxd"' \
	"$install_ai_memory_hooks printf 'model_provider = \"sandboxd\"\n' >~/.codex/config.toml;
	 trust-codex-hooks >/dev/null 2>&1; cat ~/.codex/config.toml"

# A non-zero startup step silently aborts every later step, and startup steps
# re-run on every sandbox start.
check 'trust-codex-hooks is idempotent' \
	'RUN2_OK' \
	"$install_ai_memory_hooks trust-codex-hooks >/dev/null 2>&1; trust-codex-hooks >/dev/null 2>&1 && echo RUN2_OK"

# --- tools --------------------------------------------------------------
check 'golangci-lint is the pinned version' \
	"version $GOLANGCI_LINT_VERSION" \
	'golangci-lint version'

# Go's race detector needs cgo, which Go disables when no C compiler is on PATH.
check 'cgo is enabled and a C compiler is on the agent PATH' \
	'CGO=1' \
	'command -v gcc >/dev/null && echo CGO=$(go env CGO_ENABLED)'

check 'go tools are on the agent PATH' \
	'TOOLS_OK' \
	'for t in govulncheck gotestsum dlv mockgen swag goimports; do command -v "$t" >/dev/null || { echo "MISSING $t"; exit 0; }; done; echo TOOLS_OK'

# Driven by config.json's mcpServers, read from the copy inside the image (this
# script needs only docker, not jq). The name is the spec minus its version (the
# last `@` that is not the scope).
check 'every mcpServers entry is installed under the npm prefix' \
	'MCP_OK' \
	"node -e '
	  const fs = require(\"fs\");
	  const cfg = JSON.parse(fs.readFileSync(\"/usr/local/share/jarvis-engineer/config.json\", \"utf8\"));
	  const list = cfg.mcpServers || [];
	  if (list.length === 0) { console.log(\"EMPTY_LIST\"); process.exit(0); }
	  for (const spec of list) {
	    const name = spec.slice(1).includes(\"@\") ? spec.replace(/@[^@]*\$/, \"\") : spec;
	    if (!fs.existsSync(\"$NPM_PREFIX/lib/node_modules/\" + name)) { console.log(\"MISSING \" + name); process.exit(0); }
	  }
	  console.log(\"MCP_OK\");
	'")

# postgres-mcp needs Node 22+; an older base would install it and fail at start.
check 'node is new enough for postgres-mcp' \
	'NODE_OK' \
	'node -e "process.exit(+process.versions.node.split(\".\")[0] >= 22 ? 0 : 1)" && echo NODE_OK'

check 'codex resolves at the absolute path startup steps use' \
	"$NPM_PREFIX/bin/codex" \
	'command -v codex'

check 'codex executes as uid 1000' \
	'codex-cli ' \
	"$NPM_PREFIX/bin/codex --version"

# --- docker engine ------------------------------------------------------
check_label 'image opts in to docker-in-docker' \
	'true' \
	'com.docker.sandboxes.start-docker'

check 'dockerd is present for sbx to start' \
	'/usr/bin/dockerd' \
	'command -v dockerd'

check 'docker CLI resolves on the agent PATH' \
	'/usr/bin/docker' \
	'command -v docker'

check 'buildx plugin is installed' \
	'buildx' \
	'ls /usr/libexec/docker/cli-plugins'

check 'compose plugin is installed' \
	'compose' \
	'ls /usr/libexec/docker/cli-plugins'

# Asserted against /etc/group rather than the current process: `docker run
# --user 1000:1000` drops supplementary groups (see verify-image-claude.sh).
# A sentinel rather than the bare group name: `docker` also appears in the
# error text of a docker run that never started.
check 'agent user is in the docker group' \
	'IN_DOCKER_GROUP' \
	'id -nG agent | tr " " "\n" | grep -qx docker && echo IN_DOCKER_GROUP'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
