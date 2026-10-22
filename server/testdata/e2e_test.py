"""End-to-end check for Frogster stages 0-3.

Exercises the real server over HTTP and WebSocket:
  1. register two users with X3DH key material
  2. fetch a peer key bundle and confirm a one-time prekey is consumed
  3. create a direct chat
  4. deliver a live message over WebSocket
  5. deliver to an OFFLINE recipient, then confirm it flushes on reconnect
  6. confirm rate limiting returns 429

Requires: pip install websocket-client
"""

import base64
import json
import sys
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:18080"
WS = "ws://127.0.0.1:18080/v1/ws"

PASSED, FAILED = [], []


def check(name, cond, detail=""):
    (PASSED if cond else FAILED).append(name)
    print(f"  [{'PASS' if cond else 'FAIL'}] {name}" + (f" -- {detail}" if detail and not cond else ""))
    return cond


def b64(raw):
    return base64.b64encode(raw).decode()


def post(path, body, token=None, raw=False):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        # Always drain the body. Leaving it unread makes the connection
        # unreusable and the next request fails with a reset.
        body = e.read() or b"{}"
        if raw:
            return e.code, {}
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, {}
    except (urllib.error.URLError, ConnectionError) as e:
        return 0, {"error": str(e)}


def get(path, token=None):
    req = urllib.request.Request(BASE + path, method="GET")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def login_attempt():
    """One login on a fresh connection, returning the status code.

    Uses http.client directly with Connection: close. urllib keeps the socket
    alive, and a rejected request whose body was never sent leaves the
    connection desynchronised, which surfaces as a reset rather than the 429
    the server actually sent.
    """
    import http.client

    conn = http.client.HTTPConnection("127.0.0.1", 18080, timeout=10)
    try:
        body = json.dumps({"username": "nonexistent-user", "password": "x"})
        conn.request("POST", "/v1/login", body=body,
                     headers={"Content-Type": "application/json", "Connection": "close"})
        resp = conn.getresponse()
        resp.read()
        return resp.status
    except Exception:
        return 0
    finally:
        conn.close()


def make_device(reg_id, n_prekeys=100):
    """Build plausible key material. Values are random-looking but not real
    curve points -- the server stores keys verbatim without validating them,
    which is exactly the trust model under test."""
    return {
        "name": f"device-{reg_id}",
        "registration_id": reg_id,
        "identity_key": b64(bytes([5] + [reg_id % 251] * 32)),
        "signed_pre_key": {
            "key_id": 1,
            "public_key": b64(bytes([5] + [(reg_id + 1) % 251] * 32)),
            "signature": b64(bytes([(reg_id + 2) % 251] * 64)),
        },
        "one_time_pre_keys": [
            {"key_id": i, "public_key": b64(bytes([5] + [(i * 7 + reg_id) % 251] * 32))}
            for i in range(1, n_prekeys + 1)
        ],
    }


def main():
    stamp = str(int(time.time()))
    alice, bob = f"alice{stamp}", f"bob{stamp}"

    print("\n=== 1. Registration (client uploads public keys) ===")
    st, a = post("/v1/register", {"username": alice, "password": "correct-horse-battery",
                                  "device": make_device(1001)})
    check("alice registers", st == 200, f"status={st} body={a}")
    st, b = post("/v1/register", {"username": bob, "password": "correct-horse-battery",
                                  "device": make_device(2002)})
    check("bob registers", st == 200, f"status={st} body={b}")

    if not (a.get("access_token") and b.get("access_token")):
        print("\nRegistration failed; aborting.")
        return finish()

    a_tok, b_tok = a["access_token"], b["access_token"]

    print("\n=== 2. Key distribution (X3DH bundle) ===")
    st, before = get("/v1/keys/count", b_tok)
    n_before = before.get("available", -1)

    st, bundle = get(f"/v1/keys/{bob}", a_tok)
    check("alice fetches bob's bundle", st == 200, f"status={st}")
    dev = (bundle.get("devices") or [{}])[0]
    check("bundle carries identity key", bool(dev.get("identity_key")))
    check("bundle carries signed prekey + signature",
          bool(dev.get("signed_pre_key", {}).get("signature")))
    check("bundle carries a one-time prekey", dev.get("one_time_pre_key") is not None)

    st, after = get("/v1/keys/count", b_tok)
    n_after = after.get("available", -1)
    check("one-time prekey was consumed", n_after == n_before - 1,
          f"{n_before} -> {n_after}")

    print("\n=== 3. Chat creation ===")
    st, chat = post("/v1/chats", {"type": "direct", "peer": bob}, a_tok)
    check("direct chat created", st in (200, 201), f"status={st} body={chat}")
    chat_id = chat.get("id")

    st, again = post("/v1/chats", {"type": "direct", "peer": bob}, a_tok)
    check("direct chat is deduplicated", again.get("id") == chat_id)

    try:
        import websocket
    except ImportError:
        print("\n[skip] websocket-client not installed; skipping realtime checks")
        return finish()

    print("\n=== 4. Live delivery over WebSocket ===")
    # NOTE: these bytes are NOT encrypted. The client crypto core is stage 5,
    # so this harness puts a recognisable marker in the ciphertext field to
    # prove two things about the server: it routes the field byte-for-byte
    # without parsing it, and it never writes it to a log. Once stage 5 lands
    # this becomes real Double Ratchet output and the marker disappears.
    secret = b"ATTACKER_MUST_NEVER_SEE_THIS_PLAINTEXT"

    wa = websocket.create_connection(WS, subprotocols=["frogster.bearer." + a_tok], timeout=10)
    wb = websocket.create_connection(WS, subprotocols=["frogster.bearer." + b_tok], timeout=10)
    drain(wb)

    wa.send(json.dumps({
        "v": 1, "type": "msg", "id": "e2e-live-1", "chat_id": chat_id,
        "ct_type": 2, "ciphertext": b64(secret),
    }))

    ack = wait_for(wa, "ack")
    check("sender receives ack with server seq", ack is not None and ack.get("seq", 0) > 0,
          f"ack={ack}")

    got = wait_for(wb, "msg")
    check("recipient receives the message", got is not None)
    if got:
        check("ciphertext survives the round trip",
              base64.b64decode(got.get("ciphertext", "")) == secret)

    wa.close()
    wb.close()

    print("\n=== 5. Offline queue (recipient disconnected) ===")
    # Bob is now offline. Alice sends three messages.
    wa = websocket.create_connection(WS, subprotocols=["frogster.bearer." + a_tok], timeout=10)
    for i in range(3):
        wa.send(json.dumps({
            "v": 1, "type": "msg", "id": f"e2e-offline-{i}", "chat_id": chat_id,
            "ct_type": 2, "ciphertext": b64(f"offline-message-{i}".encode()),
        }))
        wait_for(wa, "ack")
    wa.close()

    # Bob reconnects and should receive the backlog in order.
    wb = websocket.create_connection(WS, subprotocols=["frogster.bearer." + b_tok], timeout=10)
    flushed, sync_done = [], False
    deadline = time.time() + 10
    while time.time() < deadline:
        try:
            wb.settimeout(2)
            frame = json.loads(wb.recv())
        except Exception:
            break
        if frame.get("type") == "msg":
            flushed.append(base64.b64decode(frame.get("ciphertext", "")).decode(errors="replace"))
        elif frame.get("type") == "sync_done":
            sync_done = True
            break
    wb.close()

    expected = [f"offline-message-{i}" for i in range(3)]
    check("all offline messages were flushed on reconnect",
          all(e in flushed for e in expected), f"got={flushed}")
    check("offline messages arrive in order",
          [m for m in flushed if m.startswith("offline-message")] == expected, f"got={flushed}")
    check("server signals end of backlog (sync_done)", sync_done)

    # Run last: it deliberately exhausts a bucket, and buckets live in Redis
    # across restarts. Clear them with:
    #   docker compose exec redis redis-cli --scan --pattern 'frogster:rl:*' | xargs redis-cli del
    print("\n=== 6. Rate limiting ===")
    codes = [login_attempt() for _ in range(14)]
    check("login endpoint returns 429 under flood", 429 in codes,
          f"codes={codes}")
    check("rate limiter allows some requests before blocking", 401 in codes,
          f"codes={codes}")

    return finish()


def drain(ws):
    ws.settimeout(0.5)
    while True:
        try:
            ws.recv()
        except Exception:
            return


def wait_for(ws, want, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        try:
            ws.settimeout(2)
            frame = json.loads(ws.recv())
        except Exception:
            return None
        if frame.get("type") == want:
            return frame
    return None


def finish():
    print(f"\n{'=' * 52}")
    print(f"PASSED: {len(PASSED)}   FAILED: {len(FAILED)}")
    if FAILED:
        print("Failures:")
        for f in FAILED:
            print("  -", f)
    print("=" * 52)
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
