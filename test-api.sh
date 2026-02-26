#!/bin/bash
# ===========================================================================
# Comprehensive API endpoint test script for IdentityHub + Issuer Service
#
# Self-contained: creates provider/consumer participants, publishes DIDs,
# and tests all API endpoints including DID web resolution (expects 200).
#
# DID format: did:web:localhost%3A10100:<participantId>  (matches DID web URL)
# All {participantId} path params must be Base64-URL-encoded.
# ===========================================================================

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DID_WEB_HOST="localhost%3A10100"   # URL-encoded host:port for DID web
IH_BASE=http://localhost:15151/api/identity/v1alpha
IS_BASE=http://localhost:15152/api/issuer/v1alpha
IH_HEALTH=http://localhost:8080/api/check/health
IS_HEALTH=http://localhost:8081/api/check/health
DID_WEB_URL=http://localhost:10100
STS_URL=http://localhost:9292/api/sts/token

# ---------------------------------------------------------------------------
# Extract admin API keys from container logs
# ---------------------------------------------------------------------------
IH_KEY=$(docker logs identityhub 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep "API Key" | head -1 | sed 's/.*API Key        : //' | sed 's/[[:space:]]*║.*//')
IS_KEY=$(docker logs issuer-service 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep "API Key" | head -1 | sed 's/.*API Key        : //' | sed 's/[[:space:]]*║.*//')

# Base64-URL encode participant IDs
b64url() { echo -n "$1" | base64 | tr '+/' '-_' | tr -d '='; }
ADMIN_B64=$(b64url "super-admin")
PROVIDER_B64=$(b64url "provider")
CONSUMER_B64=$(b64url "consumer")

PASS=0; FAIL=0

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------
test_ep() {
    local method="$1" url="$2" key="$3" label="$4" expected="${5:-200}" data="${6:-}"
    local args=(-s -w "\n%{http_code}" -X "$method" "$url" -H "x-api-key: $key")
    [ -n "$data" ] && args+=(-H "Content-Type: application/json" -d "$data")
    local resp; resp=$(curl "${args[@]}" 2>&1)
    local code; code=$(echo "$resp" | tail -1)
    local body; body=$(echo "$resp" | sed '$d')
    if [ "$code" = "$expected" ]; then
        echo -e "  ${GREEN}PASS${NC} [$code] $method $label"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} [$code != $expected] $method $label"
        echo "       $(echo "$body" | head -1 | cut -c1-120)"
        FAIL=$((FAIL + 1))
    fi
}

test_noauth() {
    local method="$1" url="$2" label="$3" expected="${4:-200}" ct="${5:-}" data="${6:-}"
    local args=(-s -w "\n%{http_code}" -X "$method" "$url")
    [ -n "$ct" ] && [ -n "$data" ] && args+=(-H "Content-Type: $ct" -d "$data")
    local resp; resp=$(curl "${args[@]}" 2>&1)
    local code; code=$(echo "$resp" | tail -1)
    local body; body=$(echo "$resp" | sed '$d')
    if [ "$code" = "$expected" ]; then
        echo -e "  ${GREEN}PASS${NC} [$code] $method $label"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} [$code != $expected] $method $label"
        echo "       $(echo "$body" | head -1 | cut -c1-120)"
        FAIL=$((FAIL + 1))
    fi
}

echo "================================================================"
echo "  IdentityHub + Issuer Service — API Endpoint Tests"
echo "  DID web host: $DID_WEB_HOST"
echo "================================================================"
echo ""

# ---------------------------------------------------------------------------
# 0. Setup — create provider & consumer participants (idempotent)
# ---------------------------------------------------------------------------
echo "--- 0. Setup: Create participants & publish DIDs ---"

PROVIDER_DID="did:web:${DID_WEB_HOST}:provider"
CONSUMER_DID="did:web:${DID_WEB_HOST}:consumer"

create_participant() {
    local pid="$1" pdid="$2" label="$3"
    local resp code body
    resp=$(curl -s -w "\n%{http_code}" -X POST "$IH_BASE/participants" \
        -H "x-api-key: $IH_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"participantContextId\": \"$pid\",
            \"did\": \"$pdid\",
            \"active\": true,
            \"roles\": [\"participant\"],
            \"key\": {
                \"keyId\": \"${pid}-key\",
                \"privateKeyAlias\": \"${pid}-alias\",
                \"resourceId\": \"${pid}-resource\",
                \"keyGeneratorParams\": {\"algorithm\": \"EdDSA\", \"curve\": \"Ed25519\"},
                \"active\": true,
                \"usage\": [\"sign_token\", \"sign_presentation\", \"sign_credentials\"]
            }
        }" 2>&1)
    code=$(echo "$resp" | tail -1)
    body=$(echo "$resp" | sed '$d')
    if [ "$code" = "201" ] || [ "$code" = "200" ]; then
        echo -e "  ${GREEN}CREATED${NC} $label (DID: $pdid)" >&2
        # Return client_secret on stdout
        echo "$body" | grep -o '"clientSecret":"[^"]*"' | head -1 | sed 's/"clientSecret":"//;s/"//' || true
    elif [ "$code" = "409" ]; then
        echo -e "  ${YELLOW}EXISTS${NC}  $label (already created)" >&2
        echo ""
    else
        echo -e "  ${RED}ERROR${NC}   $label [$code]" >&2
        echo "       $(echo "$body" | head -1 | cut -c1-120)" >&2
        echo ""
    fi
}

PROVIDER_SECRET=$(create_participant "provider" "$PROVIDER_DID" "Provider participant")
CONSUMER_SECRET=$(create_participant "consumer" "$CONSUMER_DID" "Consumer participant")

# Publish DIDs for DID web resolution
publish_did() {
    local pid_b64="$1" pdid="$2" label="$3"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "$IH_BASE/participants/$pid_b64/dids/publish" \
        -H "x-api-key: $IH_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"did\":\"$pdid\"}")
    if [ "$code" = "204" ]; then
        echo -e "  ${GREEN}PUBLISHED${NC} $label DID"
    else
        echo -e "  ${YELLOW}PUBLISH${NC}   $label returned $code (may already be published)"
    fi
}

publish_did "$PROVIDER_B64" "$PROVIDER_DID" "Provider"
publish_did "$CONSUMER_B64" "$CONSUMER_DID" "Consumer"
echo ""

# ===========================================================================
# Tests
# ===========================================================================

echo "--- 1. Health Checks ---"
test_noauth GET "$IH_HEALTH" "IdentityHub health"
test_noauth GET "$IS_HEALTH" "Issuer-service health"
echo ""

echo "--- 2. Participant Management (Identity API) ---"
test_ep GET "$IH_BASE/participants" "$IH_KEY" "List all participants"
test_ep GET "$IH_BASE/participants/$ADMIN_B64" "$IH_KEY" "Get super-admin"
test_ep GET "$IH_BASE/participants/$PROVIDER_B64" "$IH_KEY" "Get provider"
test_ep GET "$IH_BASE/participants/$CONSUMER_B64" "$IH_KEY" "Get consumer"
test_ep POST "$IH_BASE/participants/$CONSUMER_B64/state?isActive=true" "$IH_KEY" "Activate consumer" 204
test_ep PUT "$IH_BASE/participants/$PROVIDER_B64/roles" "$IH_KEY" "Update provider roles" 204 '["participant","publisher"]'
test_ep POST "$IH_BASE/participants/$PROVIDER_B64/token" "$IH_KEY" "Regenerate provider token" 200
echo ""

echo "--- 3. Key Pair Management ---"
test_ep GET "$IH_BASE/keypairs" "$IH_KEY" "List all keypairs"
test_ep GET "$IH_BASE/participants/$PROVIDER_B64/keypairs" "$IH_KEY" "List provider keypairs"
KP_SUFFIX=$(date +%s)
test_ep PUT "$IH_BASE/participants/$PROVIDER_B64/keypairs" "$IH_KEY" "Add keypair to provider" 204 "{
    \"keyId\":\"prov-key-$KP_SUFFIX\",\"privateKeyAlias\":\"prov-alias-$KP_SUFFIX\",\"resourceId\":\"prov-res-$KP_SUFFIX\",
    \"keyGeneratorParams\":{\"algorithm\":\"EdDSA\",\"curve\":\"Ed25519\"},\"active\":true,\"usage\":[\"sign_token\"]
}"
test_ep GET "$IH_BASE/participants/$PROVIDER_B64/keypairs" "$IH_KEY" "List provider keypairs (after add)"
test_ep POST "$IH_BASE/participants/$PROVIDER_B64/keypairs/prov-res-$KP_SUFFIX/rotate" "$IH_KEY" "Rotate keypair" 204 "{
    \"keyId\":\"prov-key-rot-$KP_SUFFIX\",\"privateKeyAlias\":\"prov-alias-rot-$KP_SUFFIX\",\"resourceId\":\"prov-res-rot-$KP_SUFFIX\",
    \"keyGeneratorParams\":{\"algorithm\":\"EdDSA\",\"curve\":\"Ed25519\"},\"active\":true,
    \"usage\":[\"sign_presentation\",\"sign_credentials\",\"sign_token\"],\"duration\":15552000000
}"
echo ""

echo "--- 4. DID Management ---"
test_ep GET "$IH_BASE/dids" "$IH_KEY" "List all DIDs"
test_ep POST "$IH_BASE/participants/$PROVIDER_B64/dids/query" "$IH_KEY" "Query provider DIDs" 200 '{}'
test_ep POST "$IH_BASE/participants/$PROVIDER_B64/dids/state" "$IH_KEY" "Get provider DID state" 200 "{\"did\":\"$PROVIDER_DID\"}"
test_ep POST "$IH_BASE/participants/$PROVIDER_B64/dids/publish" "$IH_KEY" "Publish provider DID (idempotent)" 204 "{\"did\":\"$PROVIDER_DID\"}"
echo ""

echo "--- 5. Credential Management ---"
test_ep GET "$IH_BASE/credentials" "$IH_KEY" "List all credentials"
test_ep GET "$IH_BASE/participants/$PROVIDER_B64/credentials" "$IH_KEY" "List provider credentials"
echo ""

echo "--- 6. DID Web Endpoint (port 10100) ---"
test_noauth GET "$DID_WEB_URL/provider/did.json" "DID web resolve provider" 200
test_noauth GET "$DID_WEB_URL/consumer/did.json" "DID web resolve consumer" 200
test_noauth GET "$DID_WEB_URL/nonexistent/did.json" "DID web resolve nonexistent (204)" 204
echo ""

echo "--- 7. STS Token Endpoint (port 9292) ---"
# DID: did:web:localhost%3A10100:provider
# Form-URL-encoded: : → %3A, % → %25
STS_CLIENT_ID="did%3Aweb%3Alocalhost%253A10100%3Aprovider"
if [ -n "$PROVIDER_SECRET" ]; then
    test_noauth POST "$STS_URL" "STS token (client_credentials)" 200 \
        "application/x-www-form-urlencoded" \
        "grant_type=client_credentials&client_id=${STS_CLIENT_ID}&client_secret=${PROVIDER_SECRET}&audience=test-audience&bearer_access_scope=org.eclipse.edc.vc.type:MembershipCredential:read"
else
    echo -e "  ${YELLOW}SKIP${NC} STS token test (no provider client_secret — participant already existed)"
    echo -e "  ${YELLOW}NOTE${NC} To test STS, recreate stack: docker compose -f docker-compose.identityhub.yml down -v && up"
fi
echo ""

echo "--- 8. Issuer: Holder Management ---"
HOLDER_ID="holder-$(date +%s)"
test_ep POST "$IS_BASE/participants/$ADMIN_B64/holders" "$IS_KEY" "Create holder" 201 "{
    \"holderId\":\"$HOLDER_ID\",\"did\":\"$PROVIDER_DID\",\"holderName\":\"Provider Org\"
}"
test_ep POST "$IS_BASE/participants/$ADMIN_B64/holders/query" "$IS_KEY" "Query holders" 200 '{}'
test_ep GET "$IS_BASE/participants/$ADMIN_B64/holders/$HOLDER_ID" "$IS_KEY" "Get holder by ID" 200
test_ep PUT "$IS_BASE/participants/$ADMIN_B64/holders" "$IS_KEY" "Update holder" 200 "{
    \"holderId\":\"$HOLDER_ID\",\"did\":\"$PROVIDER_DID\",\"holderName\":\"Provider Updated\"
}"
echo ""

echo "--- 9. Issuer: Attestation Definitions ---"
ATT_ID="att-$(date +%s)"
test_ep POST "$IS_BASE/participants/$ADMIN_B64/attestations" "$IS_KEY" "Create attestation def" 201 "{
    \"id\":\"$ATT_ID\",\"attestationType\":\"database\",
    \"configuration\":{\"dataSourceName\":\"default\",\"tableName\":\"membership_data\",\"idColumn\":\"holder_id\"}
}"
test_ep POST "$IS_BASE/participants/$ADMIN_B64/attestations/query" "$IS_KEY" "Query attestations" 200 '{}'
echo ""

echo "--- 10. Issuer: Credential Definitions ---"
CDEF_ID="cdef-$(date +%s)"
CDEF_TYPE="MembershipCredential-${CDEF_ID}"
test_ep POST "$IS_BASE/participants/$ADMIN_B64/credentialdefinitions" "$IS_KEY" "Create credential def" 201 "{
    \"id\":\"$CDEF_ID\",\"credentialType\":\"$CDEF_TYPE\",\"format\":\"VC1_0_JWT\",
    \"jsonSchema\":\"{\\\"type\\\":\\\"object\\\"}\",\"attestations\":[\"$ATT_ID\"]
}"
test_ep POST "$IS_BASE/participants/$ADMIN_B64/credentialdefinitions/query" "$IS_KEY" "Query credential defs" 200 '{}'
test_ep GET "$IS_BASE/participants/$ADMIN_B64/credentialdefinitions/$CDEF_ID" "$IS_KEY" "Get credential def by ID" 200
echo ""

echo "--- 11. Issuer: Credentials + Issuance ---"
test_ep POST "$IS_BASE/participants/$ADMIN_B64/credentials/query" "$IS_KEY" "Query issuer credentials" 200 '{}'
test_ep POST "$IS_BASE/participants/$ADMIN_B64/issuanceprocesses/query" "$IS_KEY" "Query issuance processes" 200 '{}'
echo ""

echo "--- 12. Security: Authentication ---"
test_noauth GET "$IH_BASE/participants" "Identity API without auth" 401
test_ep GET "$IH_BASE/participants" "bad-api-key" "Identity API with bad key" 401
test_noauth GET "$IS_BASE/participants/$ADMIN_B64/holders/query" "Issuer API without auth" 401
echo ""

echo "================================================================"
echo -e "  RESULTS: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "================================================================"
