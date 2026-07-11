#!/usr/bin/env python3
"""Live smoke test for the scrollbackd MCP recall socket (`scrollbackd mcp-serve`).

This is the observed-working proof for the ONE part of the MCP layer that no headless
XCTest can cover: the POSIX AF_UNIX transport itself. The framing, token handshake, and
dispatch state machine are unit-tested in MCPTransportTests; this drives the real socket.

Usage:
    .build/debug/scrollbackd mcp-serve &      # bind the recall socket (no TCC, no net)
    python3 scripts/mcp-probe.py              # connect + exercise every path
    kill %1                                    # stop the daemon

Checks: file perms (0600 socket + token), both auth gates (no-hello → NOT_AUTHENTICATED
+ close; wrong token → UNAUTHORIZED + close), the happy path (hello → tools/list →
tools/call over one persistent connection), the two error planes (transport ok vs
application INVALID_ARGUMENTS), and the SIGPIPE hardening (dead-peer writes must not
kill the daemon). Exit 0 iff all pass.
"""
import json, os, socket, struct, sys, time

BASE = os.path.expanduser("~/Library/Application Support/Scrollback")
SOCK = os.path.join(BASE, "mcp.sock")
TOKEN_PATH = os.path.join(BASE, "mcp.token")


def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(SOCK)
    return s


def send(s, obj):
    body = json.dumps(obj).encode()
    s.sendall(struct.pack(">I", len(body)) + body)


def recv(s):
    hdr = b""
    while len(hdr) < 4:
        chunk = s.recv(4 - len(hdr))
        if not chunk:
            return None
        hdr += chunk
    n = struct.unpack(">I", hdr)[0]
    body = b""
    while len(body) < n:
        chunk = s.recv(n - len(body))
        if not chunk:
            return None
        body += chunk
    return json.loads(body)


def recv_eof(s):
    try:
        return s.recv(1) == b""
    except Exception:
        return True


def wait_for_socket():
    for _ in range(100):
        if os.path.exists(SOCK) and os.path.exists(TOKEN_PATH):
            try:
                connect().close()
                return True
            except OSError:
                pass
        time.sleep(0.1)
    return False


def main():
    if not wait_for_socket():
        print("socket never came up — is `scrollbackd mcp-serve` running?")
        sys.exit(2)
    token = open(TOKEN_PATH).read().strip()
    ok = True

    perms_ok = (os.stat(SOCK).st_mode & 0o777) == 0o600 and (os.stat(TOKEN_PATH).st_mode & 0o777) == 0o600
    print(f"[perms] socket + token both 0600  {'PASS' if perms_ok else 'FAIL'}")
    ok &= perms_ok

    # Gate 1: a gated method before hello → NOT_AUTHENTICATED, connection closed.
    s = connect(); send(s, {"id": 1, "method": "tools/list"}); r = recv(s)
    g1 = (not r["ok"]) and r["error"]["code"] == "NOT_AUTHENTICATED" and recv_eof(s)
    print(f"[gate] tools/list before hello → NOT_AUTHENTICATED + close  {'PASS' if g1 else 'FAIL'}")
    ok &= g1; s.close()

    # Gate 2: wrong token → UNAUTHORIZED, connection closed.
    s = connect(); send(s, {"id": 1, "method": "hello", "token": "deadbeef" * 4}); r = recv(s)
    g2 = (not r["ok"]) and r["error"]["code"] == "UNAUTHORIZED" and recv_eof(s)
    print(f"[gate] hello wrong token → UNAUTHORIZED + close  {'PASS' if g2 else 'FAIL'}")
    ok &= g2; s.close()

    # Happy path on one persistent authenticated connection.
    s = connect()
    send(s, {"id": 10, "method": "hello", "token": token}); r = recv(s)
    h = r["ok"] and r["id"] == 10
    print(f"[flow] hello correct token → ok  {'PASS' if h else 'FAIL'}"); ok &= h

    send(s, {"id": 11, "method": "tools/list"}); r = recv(s)
    names = sorted(t["name"] for t in (r.get("tools") or []))
    t_ok = names == ["recent_activity", "search_memory"] and all(t["readOnlyHint"] for t in r["tools"])
    print(f"[flow] tools/list → {names}, all readOnly  {'PASS' if t_ok else 'FAIL'}"); ok &= t_ok

    send(s, {"id": 12, "method": "tools/call",
             "call": {"tool": "search_memory", "arguments": {"query": "the", "limit": 3}}}); r = recv(s)
    resp = (r.get("result") or {}).get("response")
    c_ok = r["ok"] and resp is not None and "notice" in resp
    print(f"[flow] tools/call search_memory → ok, {len(resp.get('snippets', [])) if resp else 0} snippets  {'PASS' if c_ok else 'FAIL'}"); ok &= c_ok

    send(s, {"id": 13, "method": "tools/call", "call": {"tool": "search_memory", "arguments": {}}}); r = recv(s)
    err = (r.get("result") or {}).get("error") or {}
    e_ok = r["ok"] and err.get("code") == "INVALID_ARGUMENTS"
    print(f"[flow] missing query → transport ok, app-err INVALID_ARGUMENTS  {'PASS' if e_ok else 'FAIL'}"); ok &= e_ok
    s.close()

    # SIGPIPE hardening: force writes to peers that closed their read half, then
    # confirm the daemon is still alive and serving.
    for _ in range(5):
        s = connect()
        send(s, {"id": 1, "method": "hello", "token": token})
        send(s, {"id": 2, "method": "tools/call", "call": {"tool": "search_memory", "arguments": {"query": "x"}}})
        s.shutdown(socket.SHUT_RDWR); s.close()
    time.sleep(0.3)
    s = connect(); send(s, {"id": 9, "method": "hello", "token": token}); r = recv(s)
    alive = bool(r and r["ok"]); s.close()
    print(f"[sigpipe] daemon survived 5 dead-peer writes + still serving  {'PASS' if alive else 'FAIL'}"); ok &= alive

    print("\nRESULT:", "ALL PASS" if ok else "FAILURES")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
