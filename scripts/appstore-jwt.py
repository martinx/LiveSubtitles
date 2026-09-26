#!/usr/bin/env python3
"""Mints an App Store Connect API JWT (ES256) with nothing but openssl + the stdlib."""
import base64, json, subprocess, sys, time

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def der_to_raw(der: bytes) -> bytes:
    """openssl emits a DER ECDSA signature; JWT wants raw 32-byte R || 32-byte S."""
    idx = 0
    assert der[idx] == 0x30, "not a SEQUENCE"
    idx += 1
    if der[idx] & 0x80:
        idx += 1 + (der[idx] & 0x7F)
    else:
        idx += 1
    out = b""
    for _ in range(2):
        assert der[idx] == 0x02, "not an INTEGER"
        idx += 1
        length = der[idx]; idx += 1
        value = der[idx:idx + length].lstrip(b"\x00"); idx += length
        out += value.rjust(32, b"\x00")
    return out

key_path, key_id, issuer_id = sys.argv[1], sys.argv[2], sys.argv[3]
now = int(time.time())
header  = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
payload = {"iss": issuer_id, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
signing_input = ".".join(
    b64url(json.dumps(part, separators=(",", ":")).encode()) for part in (header, payload)
)
der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                     input=signing_input.encode(), capture_output=True, check=True).stdout
print(f"{signing_input}.{b64url(der_to_raw(der))}")
