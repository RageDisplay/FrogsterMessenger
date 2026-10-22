"""Checks that a returning device can sign in.

The bug this covers: the client kept its keys in the keychain but not the
device id the server issued. On sign-in it re-sent the same key material as a
"new device", which collides with UNIQUE(user_id, registration_id) -- so a user
could register once and then never get back into their own account.

Requires: pip install websocket-client
"""

import base64
import json
import sys
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:18080"

PASSED, FAILED = [], []


def check(name, cond, detail=""):
    (PASSED if cond else FAILED).append(name)
    print(f"  [{'PASS' if cond else 'FAIL'}] {name}" + (f" -- {detail}" if detail and not cond else ""))
    return cond


def b64(raw):
    return base64.b64encode(raw).decode()


def post(path, body):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read() or b"{}"
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {}


def device(reg_id, n=10):
    """One device's key material, stable for a given reg_id.

    Re-sending it is exactly what the buggy client did on every sign-in.
    """
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


def main():
    stamp = str(int(time.time()))
    user = f"login_{stamp}"
    password = "correct-horse-battery"

    print("\n=== 1. First run: register ===")
    st, reg = post("/v1/register", {
        "username": user, "password": password, "device": device(9001)})
    check("registration succeeds", st == 200, f"status={st} body={reg}")

    device_id = reg.get("device_id")
    if not device_id:
        return finish()

    print("\n=== 2. Returning device signs in by device_id ===")
    # What the fixed client does: it kept the device id, so it resumes that
    # device instead of registering another one.
    st, login = post("/v1/login", {
        "username": user, "password": password, "device_id": device_id})

    check("sign-in with a known device_id succeeds", st == 200,
          f"status={st} body={login}")
    check("the same device is resumed, not duplicated",
          login.get("device_id") == device_id,
          f"got {login.get('device_id')}, want {device_id}")
    check("a fresh access token is issued", bool(login.get("access_token")))

    print("\n=== 3. Re-sending the same keys is still rejected ===")
    # The old client's behaviour. It must fail: two devices cannot share a
    # registration id. This is why the fix stores the device id.
    st, dup = post("/v1/login", {
        "username": user, "password": password, "device": device(9001)})
    check("re-registering identical key material is refused",
          st != 200,
          f"status={st} -- accepting this would break UNIQUE(user_id, registration_id)")

    print("\n=== 4. A genuinely new device may still register ===")
    st, second = post("/v1/login", {
        "username": user, "password": password, "device": device(9002)})
    check("a second device with fresh keys is accepted", st == 200,
          f"status={st} body={second}")
    check("it gets its own device id",
          second.get("device_id") not in (None, device_id))

    print("\n=== 5. Wrong password is refused ===")
    st, bad = post("/v1/login", {
        "username": user, "password": "wrong-password-here",
        "device_id": device_id})
    check("wrong password does not sign in", st == 401, f"status={st}")

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
