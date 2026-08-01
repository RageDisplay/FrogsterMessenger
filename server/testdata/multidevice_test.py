"""End-to-end check for stage 7: multi-device key-change notifications.

Verifies that when a user registers a second device, the server tells:
  * that user's other devices (device_added), so they can build sessions;
  * their contacts (key_change), so a client can surface a safety-number
    change instead of silently trusting a new key.

The second signal is the security-relevant one. A server that stays quiet
about a new device is indistinguishable from a server that quietly registered
a device of its own to receive copies.

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
        body = e.read() or b"{}"
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, {}


def device(reg_id, n_prekeys=20):
    """Plausible key material. The server stores keys verbatim without
    validating them -- that is the documented trust model."""
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
            for i in range(1, n_prekeys + 1)
        ],
    }


def drain(ws, seconds=1.5):
    """Collects frames arriving within a window."""
    frames = []
    end = time.time() + seconds
    while time.time() < end:
        try:
            ws.settimeout(max(0.1, end - time.time()))
            frames.append(json.loads(ws.recv()))
        except Exception:
            break
    return frames


def main():
    stamp = str(int(time.time()))
    alice, bob = f"md_alice{stamp}", f"md_bob{stamp}"

    print("\n=== setup: two users, one shared chat ===")
    st, a1 = post("/v1/register", {
        "username": alice, "password": "correct-horse-battery",
        "device": device(3001)})
    check("alice registers device 1", st == 200, f"status={st} body={a1}")

    st, b1 = post("/v1/register", {
        "username": bob, "password": "correct-horse-battery",
        "device": device(4001)})
    check("bob registers", st == 200, f"status={st} body={b1}")

    if not (a1.get("access_token") and b1.get("access_token")):
        return finish()

    st, chat = post("/v1/chats", {"type": "direct", "peer": bob},
                    a1["access_token"])
    check("shared chat created", st in (200, 201), f"status={st}")

    st, ed_extra = post("/v1/register", {
        "username": f"md_stranger{stamp}", "password": "correct-horse-battery",
        "device": device(5001)})
    check("unrelated stranger registers", st == 200, f"status={st}")

    try:
        import websocket
    except ImportError:
        print("\n[skip] websocket-client not installed")
        return finish()

    print("\n=== alice adds a second device ===")
    # Alice's first device and Bob both listen; so does an unrelated stranger.
    wa1 = websocket.create_connection(
        WS, subprotocols=["frogster.bearer." + a1["access_token"]], timeout=10)
    wb = websocket.create_connection(
        WS, subprotocols=["frogster.bearer." + b1["access_token"]], timeout=10)
    ws_stranger = websocket.create_connection(
        WS, subprotocols=["frogster.bearer." + ed_extra["access_token"]],
        timeout=10)

    drain(wa1)
    drain(wb)
    drain(ws_stranger)

    # Alice logs in from a new installation, registering device 2.
    st, a2 = post("/v1/login", {
        "username": alice, "password": "correct-horse-battery",
        "device": device(3002)})
    check("alice registers device 2", st == 200, f"status={st} body={a2}")

    alice_frames = drain(wa1, 3)
    bob_frames = drain(wb, 3)
    stranger_frames = drain(ws_stranger, 1.5)

    wa1.close()
    wb.close()
    ws_stranger.close()

    alice_types = [f.get("type") for f in alice_frames]
    bob_types = [f.get("type") for f in bob_frames]
    stranger_types = [f.get("type") for f in stranger_frames]

    check("alice's device 1 is told a device was added",
          "device_added" in alice_types, f"got {alice_types}")

    check("bob is told alice's keys changed",
          "key_change" in bob_types, f"got {bob_types}")

    check("the new device id is named in the notification",
          any(f.get("sender", {}).get("device_id") == a2.get("device_id")
              for f in bob_frames if f.get("type") == "key_change"),
          f"expected {a2.get('device_id')}")

    check("an unrelated user is NOT notified",
          "key_change" not in stranger_types,
          f"got {stranger_types}; notifying strangers would leak the social graph")

    print("\n=== both alice devices are published ===")
    st, bundles = post("/v1/chats", {"type": "direct", "peer": alice},
                       b1["access_token"])
    from urllib.request import Request, urlopen
    req = Request(f"{BASE}/v1/keys/{alice}", method="GET")
    req.add_header("Authorization", "Bearer " + b1["access_token"])
    with urlopen(req, timeout=15) as r:
        keys = json.loads(r.read())

    device_ids = {d["device_id"] for d in keys.get("devices", [])}
    check("bob can fetch bundles for both of alice's devices",
          len(device_ids) == 2, f"got {len(device_ids)} devices")
    check("each bundle carries an ed25519 signing key",
          all(d.get("identity_key_ed25519") for d in keys.get("devices", [])),
          "signatures cannot be verified without it")

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
