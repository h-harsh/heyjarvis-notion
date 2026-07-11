# scrollback-mcp

The thin MCP stdio proxy. It bridges an MCP client (Claude Desktop, Claude Code) to
the `scrollbackd` recall socket — nothing more. **Key custody, retrieval, and the
prompt-injection fence all live in the daemon**; this process holds no memory, no DB
key, and no spotlighting logic (tech-spec §3a). Zero npm dependencies (Node built-ins
only) — there is no supply-chain surface here.

```
Claude Desktop ──MCP stdio (JSON-RPC)──▶ scrollback-mcp ──AF_UNIX (framed + token)──▶ scrollbackd
```

## What it does

- Speaks newline-delimited MCP JSON-RPC on stdio: `initialize`, `tools/list`,
  `tools/call`, `ping`, and the `notifications/*` it can ignore.
- For each `tools/list` / `tools/call`, opens a short-lived connection to the daemon
  socket, completes the token handshake, forwards the request using the daemon's
  length-prefixed wire protocol, and translates the reply back to MCP.
- Forwards the daemon's already-assembled, already-spotlighted text **verbatim** — it
  never re-derives the untrusted-ambient fences.

## Requirements

The daemon must be serving its recall socket:

```sh
scrollbackd mcp-serve          # binds ~/Library/Application Support/Scrollback/mcp.sock (mode 0600)
```

It reads two files the daemon writes (both mode 0600), overridable via env:

- `SCROLLBACK_SOCKET` — default `~/Library/Application Support/Scrollback/mcp.sock`
- `SCROLLBACK_TOKEN`  — default `~/Library/Application Support/Scrollback/mcp.token`

## Wire it into Claude Desktop / Claude Code

`claude_desktop_config.json` (Claude Desktop) or your MCP client config:

```json
{
  "mcpServers": {
    "scrollback": {
      "command": "node",
      "args": ["/absolute/path/to/scrollback-mcp/index.js"]
    }
  }
}
```

The shipping build bundles this as a `.mcpb` (see `manifest.json`) so users install
nothing — Node ships inside Claude Desktop.

## Verify

With the daemon running, drive the proxy over stdio:

```sh
scrollbackd mcp-serve &
node smoke.mjs        # initialize → tools/list → tools/call, asserts the bridge
kill %1
```
