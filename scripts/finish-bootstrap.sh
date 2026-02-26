#!/bin/bash
# Finish the bootstrap steps that failed (step 9: holders + attestation)
set -euo pipefail

# Extract API keys
IS_KEY=$(docker logs issuer-service 2>&1 | sed $'s/\033\[[0-9;]*m//g' | grep "API Key" | head -1 | awk -F'API Key        : ' '{print $2}' | awk '{print $1}')
IH_KEY=$(docker logs identityhub 2>&1 | sed $'s/\033\[[0-9;]*m//g' | grep "API Key" | head -1 | awk -F'API Key        : ' '{print $2}' | awk '{print $1}')

echo "IS_KEY: ${IS_KEY:0:12}..."
echo "IH_KEY: ${IH_KEY:0:12}..."

IS_ADMIN_B64="c3VwZXItYWRtaW4"

# Create holders for provider and consumer in Issuer Service
for pid in provider consumer; do
    HOLDER_DID="did:web:identityhub%3A10100:${pid}"
    NAME="$(echo "$pid" | awk '{print toupper(substr($0,1,1)) substr($0,2)}') Organization"
    CODE=$(curl -s -o /tmp/holder_resp.json -w "%{http_code}" -X POST \
        "http://localhost:15152/api/issuer/v1alpha/participants/${IS_ADMIN_B64}/holders" \
        -H "x-api-key: ${IS_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"holderId\":\"${pid}\",\"did\":\"${HOLDER_DID}\",\"holderName\":\"${NAME}\"}")
    echo "Holder '${pid}': HTTP ${CODE} - $(cat /tmp/holder_resp.json | head -c 120)"
done

# Create attestation definition
CODE=$(curl -s -o /tmp/attest_resp.json -w "%{http_code}" -X POST \
    "http://localhost:15152/api/issuer/v1alpha/participants/${IS_ADMIN_B64}/attestations" \
    -H "x-api-key: ${IS_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"attestationId":"membership-attestation","credentialType":"MembershipCredential","rules":[]}')
echo "Attestation: HTTP ${CODE} - $(cat /tmp/attest_resp.json | head -c 120)"

echo ""
echo "Done! Now run store-membership-vc.py to issue VCs."
