#!/bin/bash
# =============================================================================
# bootstrap-dcp.sh  –  Bootstrap DCP integration between IdentityHub and
#                       EDC Connectors (Provider + Consumer)
#
# This script:
#   1. Waits for IdentityHub + Issuer Service to be healthy
#   2. Extracts admin API keys from container logs
#   3. Creates "provider" and "consumer" participant contexts in IdentityHub
#   4. Creates an "issuer" participant in the Issuer Service
#   5. Publishes DIDs for all participants
#   6. Verifies DID resolution
#   7. Verifies STS token creation
#   8. Creates holders + attestation definitions in the Issuer Service
#
# After this script, run store-membership-vc.py to issue and store
# MembershipCredential VCs for provider and consumer.
#
# Vault architecture:
#   Both IdentityHub and EDC Connectors share a single HashiCorp Vault
#   instance.  When a participant is created, the STS client secret is written
#   directly into the shared Vault under "{participantId}-sts-client-secret".
#   The Connector reads the same key — no external sync is required.
#   See: https://github.com/eclipse-edc/Connector/discussions/4200
#
# Prerequisites:
#   - Connector stack running:    docker compose -f docker-compose.edc.yml up -d
#     (provides HashiCorp Vault + Connector runtimes on edc-shared network)
#   - IdentityHub stack running:  docker compose -f docker-compose.identityhub.yml up -d
#   - jq installed:  brew install jq
#
# Usage:
#   ./scripts/bootstrap-dcp.sh
#
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# IdentityHub (accessed from host via port mapping)
IH_IDENTITY_URL="http://localhost:15151/api/identity/v1alpha"
IH_HEALTH_URL="http://localhost:8080/api/check/health"
IH_DID_PORT=10100

# Issuer Service (accessed from host via port mapping)
IS_IDENTITY_URL="http://localhost:15153/api/identity/v1alpha"
IS_ADMIN_URL="http://localhost:15152/api/issuer/v1alpha"
IS_HEALTH_URL="http://localhost:8081/api/check/health"
IS_DID_PORT=10101

# STS (for verification)
STS_URL="http://localhost:9292/api/sts/token"

# Docker-internal hostnames (used in DIDs for Docker-to-Docker communication)
IH_DOCKER_HOST="identityhub"
IS_DOCKER_HOST="issuer-service"

# DID prefixes (Docker-internal, URL-encoded port)
IH_DID_PREFIX="did:web:${IH_DOCKER_HOST}%3A${IH_DID_PORT}"
IS_DID_PREFIX="did:web:${IS_DOCKER_HOST}%3A${IS_DID_PORT}"

# Trusted issuer DID (must match Connector config edc.iam.trusted-issuer.issuer.id)
ISSUER_DID="${IS_DID_PREFIX}:issuer"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
b64url() { echo -n "$1" | base64 | tr '+/' '-_' | tr -d '='; }

wait_for_health() {
    local url="$1" name="$2" max_attempts="${3:-60}"
    info "Waiting for $name to be healthy ($url) ..."
    for i in $(seq 1 "$max_attempts"); do
        if curl -sf "$url" > /dev/null 2>&1; then
            ok "$name is healthy"
            return 0
        fi
        sleep 2
    done
    fail "$name did not become healthy after $((max_attempts * 2))s"
}

get_api_key() {
    local container="$1"
    docker logs "$container" 2>&1 \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | grep "API Key" \
        | head -1 \
        | sed 's/.*API Key        : //' \
        | sed 's/[[:space:]]*║.*//'
}

# Create a participant context and return the full JSON response
create_participant() {
    local base_url="$1" api_key="$2" pid="$3" pdid="$4" roles="$5" service_endpoints="${6:-}"
    # keyId must be a full DID URL (did:web:...#fragment) so the STS sets the
    # JWT kid header to a value that DidPublicKeyResolver can parse.
    local key_id="${pdid}#${pid}-key"
    local svc_json="[]"
    if [ -n "$service_endpoints" ]; then
        svc_json="$service_endpoints"
    fi
    curl -sf -X POST "${base_url}/participants" \
        -H "x-api-key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "{
            \"participantContextId\": \"${pid}\",
            \"did\": \"${pdid}\",
            \"active\": true,
            \"roles\": ${roles},
            \"serviceEndpoints\": ${svc_json},
            \"key\": {
                \"keyId\": \"${key_id}\",
                \"privateKeyAlias\": \"${pid}-alias\",
                \"resourceId\": \"${pid}-resource\",
                \"keyGeneratorParams\": {\"algorithm\": \"EdDSA\", \"curve\": \"Ed25519\"},
                \"active\": true,
                \"usage\": [\"sign_token\", \"sign_presentation\", \"sign_credentials\"]
            }
        }" 2>&1
}

publish_did() {
    local base_url="$1" api_key="$2" pid="$3" pdid="$4"
    local pid_b64
    pid_b64=$(b64url "$pid")
    local code
    code=$(curl -sf -o /dev/null -w "%{http_code}" -X POST \
        "${base_url}/participants/${pid_b64}/dids/publish" \
        -H "x-api-key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "{\"did\": \"${pdid}\"}" 2>&1 || echo "000")
    if [ "$code" = "204" ] || [ "$code" = "200" ]; then
        ok "Published DID for ${pid}"
    else
        warn "DID publish for ${pid} returned ${code} (may already be published)"
    fi
}

# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      DCP Integration Bootstrap Script                      ║"
echo "║      IdentityHub ↔ EDC Connector                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# Step 1: Wait for services
# =============================================================================
info "Step 1: Checking service health..."
wait_for_health "$IH_HEALTH_URL" "IdentityHub"
wait_for_health "$IS_HEALTH_URL" "Issuer Service"
echo ""

# =============================================================================
# Step 2: Get admin API keys from container logs
# =============================================================================
info "Step 2: Extracting API keys from container logs..."

IH_API_KEY=$(get_api_key "identityhub")
IS_API_KEY=$(get_api_key "issuer-service")

if [ -z "$IH_API_KEY" ]; then
    fail "Could not extract IdentityHub API key from logs"
fi
if [ -z "$IS_API_KEY" ]; then
    fail "Could not extract Issuer Service API key from logs"
fi

ok "IdentityHub API key: ${IH_API_KEY:0:8}..."
ok "Issuer Service API key: ${IS_API_KEY:0:8}..."
echo ""

# =============================================================================
# Step 3: Create participants in IdentityHub (provider + consumer)
# =============================================================================
info "Step 3: Creating participants in IdentityHub..."

PROVIDER_DID="${IH_DID_PREFIX}:provider"
CONSUMER_DID="${IH_DID_PREFIX}:consumer"

# Build CredentialService endpoint URLs
# The Connector resolves the DID document, finds the CredentialService URL, and
# appends /presentations/query. The URL uses the base64url-encoded
# participantContextId (the short name, not the DID).
PROVIDER_CS_B64=$(b64url "provider")
CONSUMER_CS_B64=$(b64url "consumer")
PROVIDER_CS_URL="http://${IH_DOCKER_HOST}:13131/api/credentials/v1/participants/${PROVIDER_CS_B64}"
CONSUMER_CS_URL="http://${IH_DOCKER_HOST}:13131/api/credentials/v1/participants/${CONSUMER_CS_B64}"

# Provider
PROVIDER_SVC="[{\"id\":\"#credential-service\",\"type\":\"CredentialService\",\"serviceEndpoint\":\"${PROVIDER_CS_URL}\"}]"
PROVIDER_RESP=$(create_participant "$IH_IDENTITY_URL" "$IH_API_KEY" "provider" "$PROVIDER_DID" '["participant"]' "$PROVIDER_SVC" || true)
if echo "$PROVIDER_RESP" | jq -e '.clientSecret' > /dev/null 2>&1; then
    PROVIDER_CLIENT_SECRET=$(echo "$PROVIDER_RESP" | jq -r '.clientSecret')
    PROVIDER_CLIENT_ID=$(echo "$PROVIDER_RESP" | jq -r '.clientId')
    ok "Created provider participant"
    info "  DID:           ${PROVIDER_DID}"
    info "  Client ID:     ${PROVIDER_CLIENT_ID}"
    info "  Client Secret: ${PROVIDER_CLIENT_SECRET:0:8}..."
else
    warn "Provider participant may already exist: $(echo "$PROVIDER_RESP" | head -1 | cut -c1-120)"
    PROVIDER_CLIENT_SECRET=""
fi

# Consumer
CONSUMER_SVC="[{\"id\":\"#credential-service\",\"type\":\"CredentialService\",\"serviceEndpoint\":\"${CONSUMER_CS_URL}\"}]"
CONSUMER_RESP=$(create_participant "$IH_IDENTITY_URL" "$IH_API_KEY" "consumer" "$CONSUMER_DID" '["participant"]' "$CONSUMER_SVC" || true)
if echo "$CONSUMER_RESP" | jq -e '.clientSecret' > /dev/null 2>&1; then
    CONSUMER_CLIENT_SECRET=$(echo "$CONSUMER_RESP" | jq -r '.clientSecret')
    CONSUMER_CLIENT_ID=$(echo "$CONSUMER_RESP" | jq -r '.clientId')
    ok "Created consumer participant"
    info "  DID:           ${CONSUMER_DID}"
    info "  Client ID:     ${CONSUMER_CLIENT_ID}"
    info "  Client Secret: ${CONSUMER_CLIENT_SECRET:0:8}..."
else
    warn "Consumer participant may already exist: $(echo "$CONSUMER_RESP" | head -1 | cut -c1-120)"
    CONSUMER_CLIENT_SECRET=""
fi
echo ""

# =============================================================================
# Step 4: Create issuer participant in Issuer Service
# =============================================================================
info "Step 4: Creating issuer participant in Issuer Service..."

ISSUER_RESP=$(create_participant "$IS_IDENTITY_URL" "$IS_API_KEY" "issuer" "$ISSUER_DID" '["admin"]' || true)
if echo "$ISSUER_RESP" | jq -e '.clientSecret' > /dev/null 2>&1; then
    ok "Created issuer participant"
    info "  DID: ${ISSUER_DID}"
else
    warn "Issuer participant may already exist"
fi
echo ""

# =============================================================================
# Step 5: Publish DIDs
# =============================================================================
info "Step 5: Publishing DIDs..."

publish_did "$IH_IDENTITY_URL" "$IH_API_KEY" "provider" "$PROVIDER_DID"
publish_did "$IH_IDENTITY_URL" "$IH_API_KEY" "consumer" "$CONSUMER_DID"
publish_did "$IS_IDENTITY_URL" "$IS_API_KEY" "issuer" "$ISSUER_DID"
echo ""

# =============================================================================
# Step 6: Verify DID resolution
# =============================================================================
info "Step 6: Verifying DID resolution..."
# DIDs use Docker-internal hostnames (identityhub:10100, issuer-service:10101),
# so we must resolve from inside the container where the Host header matches.

for pid in provider consumer; do
    code=$(docker exec identityhub curl -sf -o /dev/null -w "%{http_code}" \
        "http://${IH_DOCKER_HOST}:${IH_DID_PORT}/${pid}/did.json" 2>&1 || echo "000")
    if [ "$code" = "200" ]; then
        ok "DID resolves: ${IH_DID_PREFIX}:${pid} → HTTP 200"
    else
        warn "DID resolution for ${pid} returned ${code}"
    fi
done

code=$(docker exec issuer-service curl -sf -o /dev/null -w "%{http_code}" \
    "http://${IS_DOCKER_HOST}:${IS_DID_PORT}/issuer/did.json" 2>&1 || echo "000")
if [ "$code" = "200" ]; then
    ok "DID resolves: ${ISSUER_DID} → HTTP 200"
else
    warn "DID resolution for issuer returned ${code}"
fi
echo ""

# =============================================================================
# Step 7: Verify STS token creation
# =============================================================================
info "Step 7: Verifying STS token creation..."
info "  (STS client secrets are in the shared HashiCorp Vault — no sync needed)"

if [ -n "$PROVIDER_CLIENT_SECRET" ]; then
    # URL-encode the DID for form data: : → %3A, % → %25
    STS_CLIENT_ID=$(echo -n "$PROVIDER_DID" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=''))")

    STS_RESP=$(curl -sf -w "\n%{http_code}" -X POST "$STS_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials&client_id=${STS_CLIENT_ID}&client_secret=${PROVIDER_CLIENT_SECRET}&audience=test-audience&bearer_access_scope=org.eclipse.dspace.dcp.vc.type:MembershipCredential:read" 2>&1 || echo -e "\n000")
    STS_CODE=$(echo "$STS_RESP" | tail -1)
    if [ "$STS_CODE" = "200" ]; then
        ok "STS token creation successful (provider)"
    else
        warn "STS token creation returned ${STS_CODE} — check IdentityHub logs"
    fi
else
    warn "Skipping STS verification (no provider secret)"
fi
echo ""

# =============================================================================
# Step 8: Create holders in Issuer Service for VC issuance
# =============================================================================
info "Step 8: Setting up VC issuance in Issuer Service..."

IS_ADMIN_B64=$(b64url "issuer-admin")

# Create holders for provider and consumer
# The holder API returns 201 Created with empty body on success, 409 on duplicate
for pid in provider consumer; do
    HOLDER_DID="${IH_DID_PREFIX}:${pid}"
    HOLDER_NAME="$(echo "${pid}" | awk '{print toupper(substr($0,1,1)) substr($0,2)}') Organization"
    HOLDER_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "${IS_ADMIN_URL}/participants/${IS_ADMIN_B64}/holders" \
        -H "x-api-key: ${IS_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{
            \"holderId\": \"${pid}\",
            \"did\": \"${HOLDER_DID}\",
            \"name\": \"${HOLDER_NAME}\"
        }" 2>&1 || echo "000")
    if [ "$HOLDER_CODE" = "201" ]; then
        ok "Created holder '${pid}' in Issuer Service"
    elif [ "$HOLDER_CODE" = "409" ]; then
        ok "Holder '${pid}' already exists in Issuer Service"
    else
        warn "Holder '${pid}' creation returned HTTP ${HOLDER_CODE}"
    fi
done

# Create attestation definition for MembershipCredential
# Required fields: id, attestationType, configuration (with dataSourceName + tableName)
ATTEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "${IS_ADMIN_URL}/participants/${IS_ADMIN_B64}/attestations" \
    -H "x-api-key: ${IS_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{
        "id": "membership-attestation",
        "attestationType": "database",
        "configuration": {
            "dataSourceName": "default",
            "tableName": "membership_attestations"
        }
    }' 2>&1 || echo "000")
if [ "$ATTEST_CODE" = "201" ] || [ "$ATTEST_CODE" = "200" ]; then
    ok "Created attestation definition 'membership-attestation'"
elif [ "$ATTEST_CODE" = "409" ]; then
    ok "Attestation definition 'membership-attestation' already exists"
else
    warn "Attestation definition creation returned HTTP ${ATTEST_CODE}"
fi
echo ""

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                  Bootstrap Summary                         ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                            ║"
echo "║  IdentityHub Participants:                                 ║"
echo "║    provider → ${PROVIDER_DID}"
echo "║    consumer → ${CONSUMER_DID}"
echo "║                                                            ║"
echo "║  Issuer Service:                                           ║"
echo "║    issuer   → ${ISSUER_DID}"
echo "║                                                            ║"
echo "║  Vault:   Shared HashiCorp Vault (http://vault:8200)       ║"
echo "║    STS client secrets written directly by IdentityHub.     ║"
echo "║    No external sync required.                              ║"
echo "║                                                            ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                            ║"
echo "║  Next Steps:                                               ║"
echo "║  1. Issue MembershipCredential VCs to provider & consumer  ║"
echo "║  2. Store VCs in IdentityHub for each participant          ║"
echo "║  3. Test catalog request: consumer → provider              ║"
echo "║                                                            ║"
echo "║  See docs/developer/dcp-wallet-integration-guide.md        ║"
echo "║  for detailed VC issuance and storage instructions.        ║"
echo "║                                                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
