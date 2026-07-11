#!/usr/bin/env node
'use strict';

// scrollback-mcp — the thin MCP stdio proxy.
//
// It speaks MCP JSON-RPC (newline-delimited) to the client (Claude Desktop / Code)
// on stdio, and forwards tool calls to scrollbackd's local AF_UNIX recall socket
// using the daemon's length-prefixed wire protocol. It holds NO memory, NO DB key,
// and NO retrieval/spotlighting logic — key custody and the prompt-injection fence
// live entirely in the daemon (tech-spec §3a: "thin proxy; key custody never leaves
// the daemon"). Zero npm dependencies: Node ships inside Claude Desktop, users
// install nothing, and there is no supply-chain surface here.

const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');

const BASE = path.join(os.homedir(), 'Library', 'Application Support', 'Scrollback');
const SOCKET_PATH = process.env.SCROLLBACK_SOCKET || path.join(BASE, 'mcp.sock');
const TOKEN_PATH = process.env.SCROLLBACK_TOKEN || path.join(BASE, 'mcp.token');

const PROTOCOL_VERSION = '2025-06-18'; // MCP protocol version this proxy implements
const SERVER_INFO = { name: 'scrollback', version: '0.1.0' };
const MAX_FRAME = 1 << 20;         // mirror the daemon's frame cap
const DAEMON_TIMEOUT_MS = 8000;

// ---- daemon socket wire (length-prefixed JSON: 4-byte BE length + body) ----

function encodeFrame(obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  const header = Buffer.allocUnsafe(4);
  header.writeUInt32BE(body.length, 0);
  return Buffer.concat([header, body]);
}

// One short-lived daemon connection per call: connect → hello (token) → request →
// reply. Stateless and restart-safe (the token is re-read each time); the local
// handshake is cheap. Resolves the daemon's reply object or rejects on any failure.
function daemonCall(request) {
  return new Promise((resolve, reject) => {
    let token;
    try {
      token = fs.readFileSync(TOKEN_PATH, 'utf8').trim();
    } catch (e) {
      return reject(new Error('cannot read daemon token file (' + TOKEN_PATH + '): ' + e.message));
    }

    const socket = net.createConnection(SOCKET_PATH);
    socket.setTimeout(DAEMON_TIMEOUT_MS);
    let buf = Buffer.alloc(0);
    let stage = 'hello';
    let done = false;

    const finish = (err, val) => {
      if (done) return;
      done = true;
      socket.destroy();
      err ? reject(err) : resolve(val);
    };

    socket.on('connect', () => socket.write(encodeFrame({ id: 0, method: 'hello', token })));

    socket.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      while (buf.length >= 4) {
        const len = buf.readUInt32BE(0);
        if (len > MAX_FRAME) return finish(new Error('daemon frame exceeds cap'));
        if (buf.length < 4 + len) break;
        const body = buf.subarray(4, 4 + len);
        buf = buf.subarray(4 + len);
        let msg;
        try {
          msg = JSON.parse(body.toString('utf8'));
        } catch (e) {
          return finish(new Error('malformed daemon frame'));
        }
        if (stage === 'hello') {
          if (!msg.ok) return finish(new Error('daemon handshake rejected: ' + (msg.error && msg.error.code)));
          stage = 'request';
          socket.write(encodeFrame(Object.assign({ id: 1 }, request)));
        } else {
          return finish(null, msg);
        }
      }
    });

    socket.on('timeout', () => finish(new Error('daemon socket timed out')));
    socket.on('error', (e) => finish(new Error('cannot reach the Scrollback daemon: ' + e.message)));
    socket.on('close', () => finish(new Error('daemon closed the connection unexpectedly')));
  });
}

// ---- MCP JSON-RPC dispatch ----

async function dispatch(method, params) {
  switch (method) {
    case 'initialize':
      return {
        protocolVersion: (params && params.protocolVersion) || PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: SERVER_INFO,
      };

    case 'notifications/initialized':
    case 'notifications/cancelled':
      return undefined; // notifications — no response

    case 'ping':
      return {};

    case 'tools/list': {
      const reply = await daemonCall({ method: 'tools/list' });
      const tools = (reply.tools || []).map((t) => ({
        name: t.name,
        description: t.description,
        inputSchema: t.inputSchema,
        annotations: { readOnlyHint: !!t.readOnlyHint },
      }));
      return { tools };
    }

    case 'tools/call': {
      const name = params && params.name;
      const args = (params && params.arguments) || {};
      if (!name) {
        const e = new Error('tools/call requires a tool name');
        e.code = -32602;
        throw e;
      }
      let reply;
      try {
        reply = await daemonCall({ method: 'tools/call', call: { tool: name, arguments: args } });
      } catch (e) {
        // Surface a daemon-reachability problem to Claude as a tool error (readable),
        // not a hard JSON-RPC failure that looks like the proxy is broken.
        return { content: [{ type: 'text', text: 'Scrollback is unavailable: ' + e.message }], isError: true };
      }
      if (reply.error) {
        // Transport-level error (should not happen in normal operation — the proxy
        // always sends a valid hello). Report as a tool error.
        return { content: [{ type: 'text', text: 'Scrollback transport error: ' + reply.error.code }], isError: true };
      }
      const call = reply.result || {};
      if (call.response) {
        // The daemon already assembled + spotlighted the text — forward it verbatim.
        return { content: [{ type: 'text', text: call.response.rendered }] };
      }
      // Application-level decline (LOCKED / RATE_LIMITED / EMPTY_RANGE / INVALID_ARGUMENTS).
      const appErr = call.error || { message: 'unknown error' };
      return { content: [{ type: 'text', text: 'Scrollback: ' + appErr.message }], isError: true };
    }

    default: {
      const e = new Error('method not found: ' + method);
      e.code = -32601;
      throw e;
    }
  }
}

// ---- stdio loop (newline-delimited JSON-RPC) ----

function write(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

async function handleLine(line) {
  line = line.trim();
  if (!line) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (e) {
    return; // ignore non-JSON noise
  }
  const isNotification = msg.id === undefined || msg.id === null;
  try {
    const result = await dispatch(msg.method, msg.params);
    if (!isNotification) write({ jsonrpc: '2.0', id: msg.id, result });
  } catch (err) {
    if (!isNotification) {
      write({ jsonrpc: '2.0', id: msg.id, error: { code: err.code || -32000, message: err.message } });
    }
  }
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => { handleLine(line); });
rl.on('close', () => process.exit(0));
