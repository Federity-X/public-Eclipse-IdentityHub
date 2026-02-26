#!/usr/bin/env python3
"""Add CredentialService endpoints to provider and consumer DID documents."""

import urllib.request
import json
import base64
import re
import subprocess
import sys


def get_ih_api_key():
    result = subprocess.run(["docker", "logs", "identityhub"], capture_output=True, text=True)
    for line in (result.stdout + result.stderr).split("\n"):
        if "API Key" in line and "c3VwZXIt" in line:
            raw = line.split("API Key")[1].strip().lstrip(":").strip()
            clean = re.sub(r'\x1b\[[0-9;]*m', '', raw)
            clean = ''.join(c for c in clean if c.isprintable())
            return clean.strip()
    raise RuntimeError("Could not find IH API key in docker logs")


def b64url(s):
    return base64.urlsafe_b64encode(s.encode()).decode().rstrip("=")


def api_call(method, url, api_key, body=None):
    data = json.dumps(body).encode() if body else None
    headers = {"x-api-key": api_key, "Content-Type": "application/json"}
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            text = resp.read().decode()
            return resp.status, text
    except urllib.error.HTTPError as e:
        text = e.read().decode()
        return e.code, text


def main():
    api_key = get_ih_api_key()
    print(f"IH API Key: {api_key[:20]}...")

    participants = [
        ("provider", "did:web:identityhub%3A10100:provider"),
        ("consumer", "did:web:identityhub%3A10100:consumer"),
    ]

    # First, query DIDs for provider to debug
    for name, pid in participants:
        pid_b64 = b64url(pid)
        print(f"\n--- {name} (pid_b64={pid_b64[:30]}...) ---")

        # Query DIDs via POST
        url = f"http://localhost:15151/api/identity/v1alpha/participants/{pid_b64}/dids/query"
        code, text = api_call("POST", url, api_key, {})
        print(f"  Query DIDs: HTTP {code}")
        if code == 200:
            dids = json.loads(text)
            print(f"  Found {len(dids)} DID(s)")
            for d in dids:
                print(f"    DID: {json.dumps(d, indent=2)[:300]}")
        else:
            print(f"  Response: {text[:300]}")

        # Try adding service endpoint directly
        did_b64 = b64url(pid)  # DID is same as participantId
        svc_url = (
            f"http://localhost:15151/api/identity/v1alpha/participants/{pid_b64}"
            f"/dids/{did_b64}/endpoints?autoPublish=true"
        )
        svc_body = {
            "id": "#credential-service",
            "type": "CredentialService",
            "serviceEndpoint": f"http://identityhub:13131/api/credentials/v1/participants/{pid_b64}",
        }
        svc_code, svc_text = api_call("POST", svc_url, api_key, svc_body)
        print(f"  Add service: HTTP {svc_code} - {svc_text[:300]}")

    # Verify DID documents
    print("\n=== Verifying DID documents ===")
    for name in ["provider", "consumer"]:
        result = subprocess.run(
            ["docker", "exec", "consumer-cp", "curl", "-s",
             f"http://identityhub:10100/{name}/did.json"],
            capture_output=True, text=True,
        )
        try:
            doc = json.loads(result.stdout)
            services = doc.get("service", [])
            print(f"  {name}: {len(services)} service(s)")
            for svc in services:
                print(f"    - {svc.get('type', '?')}: {svc.get('serviceEndpoint', '?')}")
        except json.JSONDecodeError:
            print(f"  {name}: Failed to parse DID doc: {result.stdout[:200]}")


if __name__ == "__main__":
    main()
