#!/usr/bin/env python3
"""
Store MembershipCredential VCs in IdentityHub participant wallets.

Signs JWT VCs using the issuer's Ed25519 private key from HashiCorp Vault,
then POSTs them to the Identity Admin API.
"""

import json
import base64
import uuid
import time
import urllib.request
import urllib.error

# --- PyJWT + cryptography ---
import jwt
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

# =============================================================================
# Configuration
# =============================================================================

IH_ADMIN_API = "http://localhost:15151/api/identity"

# API key — extracted from IdentityHub container logs or set via IH_API_KEY env var
import os
import subprocess

def _get_ih_api_key():
    """Extract the IH API key from env or docker logs."""
    env_key = os.environ.get("IH_API_KEY")
    if env_key:
        return env_key
    try:
        logs = subprocess.check_output(
            ["docker", "logs", "identityhub"],
            stderr=subprocess.STDOUT, text=True
        )
        # Strip ANSI escape codes
        import re
        logs = re.sub(r'\x1b\[[0-9;]*m', '', logs)
        for line in logs.splitlines():
            if "API Key" in line:
                key = line.split("API Key")[1].split(":")[1].strip()
                # Remove trailing box chars
                if "║" in key:
                    key = key.split("║")[0].strip()
                return key
    except Exception as e:
        print(f"Warning: Could not extract API key from docker logs: {e}")
    return ""

IH_ADMIN_KEY = _get_ih_api_key()

ISSUER_DID = "did:web:issuer-service%3A10101:issuer"
ISSUER_KEY_ID = "did:web:issuer-service%3A10101:issuer#issuer-key"

# Vault settings for fetching the issuer's Ed25519 private key
VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://localhost:8200")


def _get_vault_token():
    """Get the Vault root token from env var, or read it from the vault container."""
    env_token = os.environ.get("VAULT_TOKEN")
    if env_token:
        return env_token
    try:
        token = subprocess.check_output(
            ["docker", "exec", "vault", "cat", "/vault-token/token"],
            text=True
        ).strip()
        if token:
            return token
    except Exception as e:
        print(f"Warning: Could not read vault token from container: {e}")
    print("Error: Set VAULT_TOKEN or ensure the vault container is running.")
    return ""


VAULT_TOKEN = _get_vault_token()
ISSUER_KEY_VAULT_PATH = "issuer-alias"

PARTICIPANTS = [
    {
        "id": "provider",
        "did": "did:web:identityhub%3A10100:provider",
    },
    {
        "id": "consumer",
        "did": "did:web:identityhub%3A10100:consumer",
    },
]


# =============================================================================
# Helpers
# =============================================================================

def b64url_decode(s: str) -> bytes:
    """Base64url decode (add padding as needed)."""
    s = s.replace("-", "+").replace("_", "/")
    s += "=" * (4 - len(s) % 4)
    return base64.b64decode(s)


def fetch_issuer_jwk_from_vault() -> dict:
    """Fetch the issuer's private key JWK from HashiCorp Vault KV v2."""
    url = f"{VAULT_ADDR}/v1/secret/data/{ISSUER_KEY_VAULT_PATH}"
    req = urllib.request.Request(url, headers={"X-Vault-Token": VAULT_TOKEN})
    resp = urllib.request.urlopen(req)
    data = json.loads(resp.read().decode("utf-8"))
    jwk_str = data["data"]["data"]["content"]
    return json.loads(jwk_str)


def jwk_to_ed25519_private_key(jwk: dict):
    """Convert an OKP Ed25519 JWK dict to a cryptography Ed25519PrivateKey."""
    if jwk.get("kty") != "OKP" or jwk.get("crv") != "Ed25519":
        raise ValueError(
            f"Expected OKP/Ed25519 JWK from vault but got kty={jwk.get('kty')} crv={jwk.get('crv')}. "
            "The issuer's key in vault must be Ed25519 (set by IdentityHub bootstrap)."
        )
    d_bytes = b64url_decode(jwk["d"])
    return Ed25519PrivateKey.from_private_bytes(d_bytes)


def create_membership_vc_jwt(holder_did: str, private_key) -> str:
    """Create and sign a MembershipCredential JWT VC using Ed25519."""
    now = int(time.time())
    vc_id = f"urn:uuid:{uuid.uuid4()}"

    # W3C VCDM 1.1 credential payload (embedded in JWT "vc" claim)
    vc_payload = {
        "@context": [
            "https://www.w3.org/2018/credentials/v1"
        ],
        "type": ["VerifiableCredential", "MembershipCredential"],
        "credentialSubject": {
            "id": holder_did,
            "memberOf": "test-dataspace"
        }
    }

    # JWT claims
    claims = {
        "iss": ISSUER_DID,
        "sub": holder_did,
        "jti": vc_id,
        "iat": now,
        "nbf": now,
        "exp": now + (365 * 24 * 3600),  # 1 year
        "vc": vc_payload
    }

    token = jwt.encode(
        claims,
        private_key,
        algorithm="EdDSA",
        headers={
            "kid": ISSUER_KEY_ID,
            "typ": "JWT"
        }
    )
    return token, vc_id


def store_vc(participant_id: str, holder_did: str, raw_jwt: str, vc_id: str):
    """POST the VC to the IdentityHub wallet storage API."""
    pid_b64 = base64.b64encode(participant_id.encode()).decode()

    manifest = {
        "id": f"membership-{participant_id}",
        "participantContextId": participant_id,
        "verifiableCredentialContainer": {
            "rawVc": raw_jwt,
            "format": "VC1_0_JWT",
            "credential": {
                "id": vc_id,
                "type": ["VerifiableCredential", "MembershipCredential"],
                "issuer": {"id": ISSUER_DID},
                "issuanceDate": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "credentialSubject": {
                    "id": holder_did,
                    "memberOf": "test-dataspace"
                }
            }
        }
    }

    url = f"{IH_ADMIN_API}/v1alpha/participants/{pid_b64}/credentials"
    data = json.dumps(manifest).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "x-api-key": IH_ADMIN_KEY
        }
    )

    try:
        resp = urllib.request.urlopen(req)
        print(f"  ✅ Stored VC for {participant_id}: HTTP {resp.status}")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"  ❌ Failed for {participant_id}: HTTP {e.code}")
        print(f"     Response: {body[:500]}")
        raise


# =============================================================================
# Main
# =============================================================================

def main():
    print("=== Storing MembershipCredential VCs ===\n")

    # Fetch the issuer's Ed25519 private key from Vault once
    print("Fetching issuer signing key from Vault...")
    issuer_jwk = fetch_issuer_jwk_from_vault()
    private_key = jwk_to_ed25519_private_key(issuer_jwk)
    print("  Got Ed25519 signing key from Vault\n")

    for p in PARTICIPANTS:
        pid = p["id"]
        did = p["did"]

        print(f"Creating JWT VC for {pid} ({did})...")
        raw_jwt, vc_id = create_membership_vc_jwt(did, private_key)
        print(f"  JWT length: {len(raw_jwt)}, VC ID: {vc_id}")

        print(f"Storing in IdentityHub wallet...")
        store_vc(pid, did, raw_jwt, vc_id)
        print()

    print("=== Done ===")


if __name__ == "__main__":
    main()
