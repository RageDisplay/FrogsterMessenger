"""End-to-end check for per-device message fan-out.

The bug this guards against: sending one shared ciphertext to every recipient
device. Each device runs its own Double Ratchet session, so a shared payload is
decryptable by exactly one of them -- and the server cannot detect the problem,
because it cannot tell ciphertext from noise.

Verifies that a message addressed to several devices delivers each device the
payload meant for it, and that a device the sender did not encrypt for gets
nothing rather than an undecryptable frame.

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


def post(path, body, token=None):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read() or b"{}"
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {}


def device(reg_id, n=20):
    return {
        "name": f"device-{reg_id}",
        "registration_id": reg_id,
        "identity_key": b64(bytes([5] + [reg_id % 251] * 32)),
        "identity_key_ed25519": b64(bytes([(reg_id + 3) % 251] * 32)),
        "signed_pre_key": {
            "key_id": 1,
            "public_key": b64(bytes([5] + [(reg_id + 1) % 251] * 32)),
            "signature": b64(bytes([(reg_id + 2) % 251] * 64)),
        },
        "one_time_pre_keys": [
            {"key_id": i, "public_key": b64(bytes([5] + [(i * 7 + reg_id) % 251] * 32))}
            for i in range(1, n + 1)
        ],
    }


def collect(ws, want_type, timeout=6):
    """Returns the first frame of the given type, or None."""
    end = time.time() + timeout
    while time.time() < end:
        try:
            ws.settimeout(max(0.2, end - time.time()))
            frame = json.loads(ws.recv())
        except Exception:
            return None
        if frame.get("type") == want_type:
            return frame
    return None


def drain(ws, seconds=1.0):
    end = time.time() + seconds
    out = []
    while time.time() < end:
        try:
            ws.settimeout(max(0.1, end - time.time()))
            out.append(json.loads(ws.recv()))
        except Exception:
            break
    return out


def main():
    stamp = str(int(time.time()))
    alice, bob = f"fan_alice{stamp}", f"fan_bob{stamp}"

    print("\n=== setup: alice (1 device), bob (2 devices) ===")
    st, a1 = post("/v1/register", {
        "username": alice, "password": "correct-horse-battery",
        "device": device(7001)})
    check("alice registers", st == 200, f"status={st} body={a1}")

    st, b1 = post("/v1/register", {
        "username": bob, "password": "correct-horse-battery",
        "device": device(8001)})
    check("bob registers device 1", st == 200, f"status={st}")

    st, b2 = post("/v1/login", {
        "username": bob, "password": "correct-horse-battery",
        "device": device(8002)})
    check("bob registers device 2", st == 200, f"status={st}")

    if not all(t.get("access_token") for t in (a1, b1, b2)):
        return finish()

    st, chat = post("/v1/chats", {"type": "direct", "peer": bob},
                    a1["access_token"])
    check("direct chat created", st in (200, 201), f"status={st}")
    chat_id = chat.get("id")

    try:
        import websocket
    except ImportError:
        print("\n[skip] websocket-client not installed")
        return finish()

    print("\n=== per-device payloads reach the right devices ===")
    wa = websocket.create_connection(
        WS, subprotocols=["frogster.bearer." + a1["access_token"]], timeout=10)
    wb1 = websocket.create_connection(
        WS, subprotocols=["frogster.bearer." + b1["access_token"]], timeout=10)
    wb2 = websocket.create_connection(
        WS, subprotocols=["frogster.bearer." + b2["access_token"]], timeout=10)

    drain(wa)
    drain(wb1)
    drain(wb2)

    # Distinct payloads stand in for the distinct ratchet outputs a real client
    # would produce for each device.
    payload_for_b1 = b"CIPHERTEXT-INTENDED-FOR-DEVICE-1"
    payload_for_b2 = b"CIPHERTEXT-INTENDED-FOR-DEVICE-2"

    wa.send(json.dumps({
        "v": 1, "type": "msg", "id": "fanout-1", "chat_id": chat_id,
        "payloads": [
            {"user_id": b1["user_id"], "device_id": b1["device_id"],
             "ct_type": 2, "ciphertext": b64(payload_for_b1)},
            {"user_id": b2["user_id"], "device_id": b2["device_id"],
             "ct_type": 2, "ciphertext": b64(payload_for_b2)},
        ],
    }))

    ack = collect(wa, "ack")
    check("sender receives an ack", ack is not None and ack.get("seq", 0) > 0,
          f"ack={ack}")

    got1 = collect(wb1, "msg")
    got2 = collect(wb2, "msg")

    check("bob's device 1 received a message", got1 is not None)
    check("bob's device 2 received a message", got2 is not None)

    if got1 and got2:
        ct1 = base64.b64decode(got1.get("ciphertext", ""))
        ct2 = base64.b64decode(got2.get("ciphertext", ""))

        check("device 1 got the payload addressed to it",
              ct1 == payload_for_b1, f"got {ct1!r}")
        check("device 2 got the payload addressed to it",
              ct2 == payload_for_b2, f"got {ct2!r}")
        check("the two devices received DIFFERENT ciphertexts",
              ct1 != ct2,
              "identical payloads mean only one device could ever decrypt")
        check("both share one server sequence number",
              got1.get("seq") == got2.get("seq"),
              "one logical message must have one seq")

    wa.close()
    wb1.close()
    wb2.close()

    print("\n=== a device the sender skipped is not queued garbage ===")
    wa = websocket.create_connection(
        WS, subprotocols=["frogster.bearer." + a1["access_token"]], timeout=10)
    wb2 = websocket.create_connection(
        WS, subprotocols=["frogster.bearer." + b2["access_token"]], timeout=10)
    drain(wa)
    drain(wb2)

    # Address only device 1, as a sender with a stale device list would.
    wa.send(json.dumps({
        "v": 1, "type": "msg", "id": "fanout-2", "chat_id": chat_id,
        "payloads": [
            {"user_id": b1["user_id"], "device_id": b1["device_id"],
             "ct_type": 2, "ciphertext": b64(b"only-for-device-1")},
        ],
    }))
    collect(wa, "ack")

    skipped = drain(wb2, 2.0)
    messages = [f for f in skipped if f.get("type") == "msg"]
    check("the unaddressed device receives nothing",
          len(messages) == 0,
          f"got {len(messages)} frames it could not decrypt")

    wa.close()
    wb2.close()

    return finish()


def finish():
    print(f"\n{'=' * 52}")
    print(f"PASSED: {len(PASSED)}   FAILED: {len(FAILED)}")
    for f in FAILED:
        print("  -", f)
    print("=" * 52)
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
