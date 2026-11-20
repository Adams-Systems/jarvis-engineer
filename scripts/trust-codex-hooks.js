#!/usr/bin/env node
//
// Pre-trusts ai-memory's lifecycle hooks for Codex, and nothing else.
//
// Codex runs a hook only once its exact definition is trusted: the trust is a
// per-handler hash stored under [hooks.state] in ~/.codex/config.toml. sbx
// recreates ~/.codex for every sandbox, so without this every Codex session
// would start with memory capture silently off (spike S7). The hash is
// computed by Codex itself (codex-rs/hooks hook_hash), so rather than baking
// hashes that break on the next Codex or ai-memory release, this asks the
// installed Codex's app-server for them (hooks/list) and writes the trust
// through the same config/batchWrite call its own hook-review UI uses.
//
// Only hooks defined in ~/.codex/hooks.json whose command is ai-memory's
// `hook --event` handler are trusted (ADR D6: pre-trust ai-memory's hooks, no
// blanket bypass). Any other hook keeps going through Codex's review.
//
// Exit: 0 when every ai-memory hook is trusted afterwards, 1 otherwise.
// Usage: trust-codex-hooks

'use strict';

const { spawn } = require('child_process');
const path = require('path');

const CODEX = process.env.CODEX_BIN || '/usr/local/bin/codex';
const HOME = process.env.HOME;
const HOOKS_FILE = path.join(HOME, '.codex', 'hooks.json');
// The whole command, not a prefix: it runs through a shell, so anything after
// ai-memory's own arguments (`; ...`, `| ...`) would be trusted along with it.
// Arguments are restricted to the characters ai-memory's own handler uses
// (flags, paths, the loopback server URL).
const ARG = '[A-Za-z0-9_./:=-]+';
const AI_MEMORY_HOOK = new RegExp(`^/usr/local/bin/ai-memory( ${ARG})* hook --event [a-z-]+( ${ARG})*$`);
const TIMEOUT_MS = 30000;

const server = spawn(CODEX, ['app-server'], { stdio: ['pipe', 'pipe', 'ignore'] });
const pending = new Map();
let nextId = 1;
let buffered = '';

// The app-server speaks JSON-RPC, one message per line, without the
// "jsonrpc" member.
server.stdout.on('data', (chunk) => {
  buffered += chunk;
  let eol;
  while ((eol = buffered.indexOf('\n')) >= 0) {
    const line = buffered.slice(0, eol);
    buffered = buffered.slice(eol + 1);
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    const waiter = msg.id !== undefined && pending.get(msg.id);
    if (!waiter) continue;
    pending.delete(msg.id);
    if (msg.error) waiter.reject(new Error(`${waiter.method}: ${JSON.stringify(msg.error)}`));
    else waiter.resolve(msg.result);
  }
});

server.on('error', (err) => rejectAll(err));
server.on('exit', (code) => rejectAll(new Error(`codex app-server exited with ${code}`)));

function rejectAll(err) {
  for (const waiter of pending.values()) waiter.reject(err);
  pending.clear();
}

function request(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { method, resolve, reject });
    server.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });
}

async function aiMemoryHooks() {
  const listed = await request('hooks/list', { cwds: [HOME] });
  const entry = listed.data.find((e) => e.cwd === HOME) || { hooks: [] };
  return entry.hooks.filter(
    (h) => h.sourcePath === HOOKS_FILE && h.handlerType === 'command' && AI_MEMORY_HOOK.test(h.command),
  );
}

async function main() {
  await request('initialize', { clientInfo: { name: 'trust-codex-hooks', version: '1' } });
  server.stdin.write(JSON.stringify({ method: 'initialized' }) + '\n');

  const hooks = await aiMemoryHooks();
  if (hooks.length === 0) throw new Error(`no ai-memory hooks found in ${HOOKS_FILE}`);

  // `modified` (the definition changed since it was trusted) is re-trusted
  // too: the only definitions that reach this filter are ai-memory's own.
  const untrusted = hooks.filter((h) => h.trustStatus !== 'trusted');
  if (untrusted.length > 0) {
    const value = {};
    for (const h of untrusted) value[h.key] = { trusted_hash: h.currentHash };
    await request('config/batchWrite', {
      edits: [{ keyPath: 'hooks.state', value, mergeStrategy: 'upsert' }],
      filePath: null,
      expectedVersion: null,
      reloadUserConfig: true,
    });
  }

  const still = (await aiMemoryHooks()).filter((h) => h.trustStatus !== 'trusted');
  if (still.length > 0) throw new Error(`still untrusted: ${still.map((h) => h.key).join(', ')}`);
  console.log(`trust-codex-hooks: ${hooks.length} ai-memory hooks trusted (${untrusted.length} newly)`);
}

const timer = setTimeout(() => {
  console.error('trust-codex-hooks: timed out waiting for codex app-server');
  server.kill();
  process.exit(1);
}, TIMEOUT_MS);

main()
  .catch((err) => {
    console.error(`trust-codex-hooks: ${err.message}`);
    process.exitCode = 1;
  })
  .finally(() => {
    clearTimeout(timer);
    server.removeAllListeners('exit');
    server.stdin.end();
    server.kill();
    // A startup step has no timeout of its own: if the app-server ignores
    // SIGTERM, its open stdout pipe would keep this process alive forever.
    // Let go of it so we exit with our own result regardless.
    server.stdout.destroy();
    server.unref();
  });
