// Smoke test for the scrollback-mcp proxy: spawns it, speaks MCP JSON-RPC over stdio,
// and asserts the bridge to a running `scrollbackd mcp-serve` works end-to-end
// (initialize → tools/list → tools/call). This is the observed-working proof for the
// proxy — it needs a live daemon: run `scrollbackd mcp-serve &` first.
//
// Usage:  node smoke.mjs        (exit 0 = all pass, 1 = failure, 2 = daemon not up)
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';

const here = path.dirname(fileURLToPath(import.meta.url));
const SOCK = path.join(os.homedir(), 'Library', 'Application Support', 'Scrollback', 'mcp.sock');

if (!fs.existsSync(SOCK)) {
  console.error('daemon socket not found — run `scrollbackd mcp-serve &` first');
  process.exit(2);
}

const proxy = spawn('node', [path.join(here, 'index.js')], { stdio: ['pipe', 'pipe', 'inherit'] });

const pending = new Map(); // id -> resolver
let outBuf = '';
proxy.stdout.on('data', (chunk) => {
  outBuf += chunk.toString('utf8');
  let nl;
  while ((nl = outBuf.indexOf('\n')) >= 0) {
    const line = outBuf.slice(0, nl).trim();
    outBuf = outBuf.slice(nl + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    if (pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  }
});

let nextId = 1;
function rpc(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout on ' + method)), 10000);
    pending.set(id, (m) => { clearTimeout(timer); resolve(m); });
    proxy.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}

let ok = true;
const check = (name, cond) => { console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}`); ok = ok && cond; };

try {
  const init = await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'smoke', version: '0' } });
  check('initialize → serverInfo.name=scrollback', init.result?.serverInfo?.name === 'scrollback');
  check('initialize → advertises tools capability', !!init.result?.capabilities?.tools);

  const list = await rpc('tools/list', {});
  const names = (list.result?.tools || []).map((t) => t.name).sort();
  check('tools/list → [recent_activity, search_memory]', JSON.stringify(names) === JSON.stringify(['recent_activity', 'search_memory']));
  check('tools/list → all readOnly', (list.result?.tools || []).every((t) => t.annotations?.readOnlyHint === true));
  check('tools/list → each has an inputSchema', (list.result?.tools || []).every((t) => t.inputSchema && t.inputSchema.type === 'object'));

  const call = await rpc('tools/call', { name: 'search_memory', arguments: { query: 'the', limit: 3 } });
  const content = call.result?.content;
  check('tools/call → text content', Array.isArray(content) && content[0]?.type === 'text' && typeof content[0]?.text === 'string');
  check('tools/call → not isError', call.result?.isError !== true);

  const badArgs = await rpc('tools/call', { name: 'search_memory', arguments: {} });
  check('tools/call missing query → isError + INVALID msg', badArgs.result?.isError === true && /missing required arguments|not recognized|Scrollback/.test(badArgs.result?.content?.[0]?.text || ''));

  const badWindow = await rpc('tools/call', { name: 'recent_activity', arguments: { window: 'today' } });
  check('tools/call recent_activity today → text content', badWindow.result?.content?.[0]?.type === 'text');

  const unknown = await rpc('foo/bar', {});
  check('unknown method → JSON-RPC -32601', unknown.error?.code === -32601);
} catch (e) {
  console.error('ERROR:', e.message);
  ok = false;
}

proxy.stdin.end();
proxy.kill();
console.log('\nRESULT:', ok ? 'ALL PASS' : 'FAILURES');
process.exit(ok ? 0 : 1);
