# Eclipse EDC IdentityHub — DCP Wallet Integration Guide

> **Version**: 0.17.0-SNAPSHOT  
> **Date**: February 2026  
> **Audience**: EDC connector developers integrating IdentityHub as a DCP wallet for provider/consumer setups

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Build from Source](#build-from-source)
5. [Docker Deployment](#docker-deployment)
6. [Configuration Reference](#configuration-reference)
7. [Bootstrap & Admin Seed](#bootstrap--admin-seed)
8. [Creating Participants (Provider & Consumer)](#creating-participants-provider--consumer)
9. [DID Web Resolution](#did-web-resolution)
10. [STS Token Issuance](#sts-token-issuance)
11. [Issuer Service Setup](#issuer-service-setup)
12. [Connecting EDC Connectors](#connecting-edc-connectors)
13. [API Endpoint Reference](#api-endpoint-reference)
14. [Test Script](#test-script)
15. [Troubleshooting](#troubleshooting)

---

## Overview

The Eclipse EDC IdentityHub provides a Decentralized Claims Protocol (DCP) wallet and issuer infrastructure for the EDC ecosystem. This guide covers how to deploy and integrate IdentityHub as the identity backend for **provider** and **consumer** EDC connectors.

The repository ships two runtimes:

| Runtime            | Launcher                  | Role                                                                                                  |
| ------------------ | ------------------------- | ----------------------------------------------------------------------------------------------------- |
| **IdentityHub**    | `launcher:identityhub`    | DCP wallet — DID management, credential storage, Verifiable Presentation API, STS, Identity Admin API |
| **Issuer Service** | `launcher:issuer-service` | DCP issuer — credential issuance, attestation definitions, credential definitions, StatusList         |

Both runtimes use PostgreSQL for persistence and share a Docker network (`edc-shared`) with EDC connectors.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        edc-shared network                       │
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │  EDC Provider │    │  EDC Consumer│    │   pg-identityhub │  │
│  │  Connector    │    │  Connector   │    │   (Postgres 17)  │  │
│  └──────┬───────┘    └──────┬───────┘    └────────┬─────────┘  │
│         │                   │                     │             │
│         │  DCP / STS        │  DCP / STS          │ JDBC        │
│         ▼                   ▼                     ▼             │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    identityhub                            │  │
│  │  :8080  Health        :15151  Identity Admin API          │  │
│  │  :13131 Credentials   :10100  DID Web                     │  │
│  │  :9292  STS                                               │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                   issuer-service                          │  │
│  │  :8080  Health        :15152  Issuer Admin API            │  │
│  │  :13132 Issuance      :10101  DID Web                     │  │
│  │  :9999  StatusList    :9293   STS                         │  │
│  │  :15153 Identity API                                      │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │       vault  (shared, from EDC Connector stack)          │  │
│  │  :8200  KV v2 secrets   token via edc-vault-token volume │  │
│  │  Used by: connectors, identityhub, issuer-service        │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- **Java 17+** (JDK 17 or higher; builds with Temurin 24 in Docker)
- **Gradle** (wrapper included — `./gradlew`)
- **Docker** and **Docker Compose** v2+
- An external Docker network:
  ```bash
  docker network create edc-shared
  ```

---

## Build from Source

### 1. Modified files (required patches on top of `main`)

The following files were added or modified to enable a production-like deployment with Postgres and HashiCorp Vault:

<details>
<summary><strong>gradle/libs.versions.toml</strong> — add vault-hashicorp catalog entry</summary>

Add to the `[libraries]` section:

```toml
edc-vault-hashicorp = { module = "org.eclipse.edc:vault-hashicorp", version.ref = "edc" }
```

</details>

<details>
<summary><strong>settings.gradle.kts</strong> — register admin-seed module</summary>

Add this line to the `include()` block:

```kotlin
include(":extensions:api:identity-api:admin-seed")
```

</details>

<details>
<summary><strong>launcher/identityhub/build.gradle.kts</strong> — add SQL, admin-seed, and vault</summary>

```kotlin
dependencies {
    runtimeOnly(project(":dist:bom:identityhub-bom"))
    runtimeOnly(project(":dist:bom:identityhub-feature-sql-bom"))
    runtimeOnly(project(":extensions:api:identity-api:admin-seed"))
    runtimeOnly(libs.edc.vault.hashicorp)
}
```

</details>

<details>
<summary><strong>launcher/issuer-service/build.gradle.kts</strong> — add SQL, admin-seed, DID/identity APIs, and vault</summary>

```kotlin
dependencies {
    runtimeOnly(project(":dist:bom:issuerservice-bom"))
    runtimeOnly(project(":dist:bom:issuerservice-feature-sql-bom"))
    runtimeOnly(project(":extensions:api:identity-api:admin-seed"))
    runtimeOnly(project(":extensions:api:identity-api:did-api"))
    runtimeOnly(project(":extensions:api:identity-api:identity-api-configuration"))
    runtimeOnly(libs.edc.vault.hashicorp)
}
```

</details>

<details>
<summary><strong>extensions/api/identity-api/admin-seed/</strong> — new bootstrap extension</summary>

This extension seeds an initial "super-admin" participant on startup, solving the chicken-and-egg problem of needing an API key to create participants.

See [Admin Seed Extension](#bootstrap--admin-seed) for details.

</details>

### 2. Build shadow JARs

```bash
./gradlew :launcher:identityhub:shadowJar :launcher:issuer-service:shadowJar --parallel
```

Output:

- `launcher/identityhub/build/libs/identity-hub.jar`
- `launcher/issuer-service/build/libs/issuer-service.jar`

### 3. Build Docker images

```bash
docker build -t identityhub:local     launcher/identityhub
docker build -t issuer-service:local  launcher/issuer-service
```

---

## Docker Deployment

### File structure

```
config/
├── identityhub.properties          # IdentityHub runtime config
├── issuer-service.properties       # Issuer Service runtime config
├── credentials.env                 # Saved API keys (written by bootstrap)
├── pg-init/
│   └── create-databases.sh         # Creates both Postgres databases
└── vault/
    └── secrets.properties          # Legacy FsVault reference (not used at runtime)
scripts/
├── bootstrap-dcp.sh                # Creates participants, publishes DIDs, sets up issuer
├── finish-bootstrap.sh             # Recovery: creates holders + attestations if bootstrap step 8 failed
├── store-membership-vc.py          # Issues and stores MembershipCredential JWTs
└── add-credential-service.py       # Adds CredentialService to DID documents
docker-compose.identityhub.yml      # Full stack definition
test-api.sh                         # 38-endpoint API validation script
```

### Start the stack

> **Prerequisite:** The EDC Connector stack must be running first — it creates the `edc-vault-token` Docker volume that the IdentityHub stack requires for Vault authentication. See the [Shared vault architecture](#shared-vault-architecture) section for details.

```bash
# Ensure network exists
docker network create edc-shared 2>/dev/null || true

# Start (builds images if needed — requires EDC stack running)
docker compose -f docker-compose.identityhub.yml up -d

# Verify health
curl -s http://localhost:8080/api/check/health | jq .
curl -s http://localhost:8081/api/check/health | jq .
```

### Port mapping

| Service            | Port         | Purpose                            |
| ------------------ | ------------ | ---------------------------------- |
| **identityhub**    | 8080         | Default API / health               |
|                    | 15151        | Identity Admin API                 |
|                    | 13131        | DCP Credentials / Presentation API |
|                    | 10100        | DID web endpoint                   |
|                    | 9292         | Secure Token Service (STS)         |
| **issuer-service** | 8081 (→8080) | Default API / health               |
|                    | 15152        | Issuer Admin API                   |
|                    | 15153        | Identity API (participant-context) |
|                    | 13132        | DCP Issuance API                   |
|                    | 10101        | DID web endpoint                   |
|                    | 9999         | StatusList credential endpoint     |
|                    | 9293         | STS (issuer)                       |
| **pg-identityhub** | 5435 (→5432) | PostgreSQL                         |

### Databases

The Postgres container initializes two separate databases:

- `identityhub` — used by the IdentityHub runtime
- `issuerservice` — used by the Issuer Service runtime

This separation avoids SQL schema conflicts between the two runtimes. The init script (`config/pg-init/create-databases.sh`) handles this automatically.

---

## Configuration Reference

### Key configuration properties

#### IdentityHub (`config/identityhub.properties`)

| Property                             | Value                         | Description                                                     |
| ------------------------------------ | ----------------------------- | --------------------------------------------------------------- |
| `edc.iam.issuer.id`                  | `did:web:identityhub%3A10100` | DID used when issuing self-signed tokens (uses Docker hostname) |
| `edc.ih.admin.seed.did.web.host`     | `localhost%3A10100`           | DID web host for auto-generated admin DID                       |
| `edc.iam.did.web.use.https`          | `false`                       | Disable HTTPS for local dev                                     |
| `edc.sql.schema.autocreate`          | `true`                        | Auto-create SQL tables on startup                               |
| `edc.vault.hashicorp.url`            | `http://vault:8200`           | HashiCorp Vault URL (shared with EDC Connectors)                |
| `edc.vault.hashicorp.token`          | `OVERRIDE_VIA_ENV`            | Injected at runtime from shared `edc-vault-token` Docker volume |
| `edc.vault.hashicorp.allow-fallback` | `true`                        | Fall back to default vault for partitioned secrets              |
| `edc.encryption.strict`              | `false`                       | Relaxed encryption for local dev                                |

#### Issuer Service (`config/issuer-service.properties`)

| Property                          | Value                                   | Description                               |
| --------------------------------- | --------------------------------------- | ----------------------------------------- |
| `edc.iam.issuer.id`               | `did:web:issuer-service%3A10101`        | Issuer DID (Docker hostname)              |
| `edc.ih.admin.seed.did.web.host`  | `localhost%3A10101`                     | DID web host for auto-generated admin DID |
| `edc.statuslist.callback.address` | `http://issuer-service:9999/statuslist` | StatusList callback URL                   |

### DID web host configuration

The `edc.ih.admin.seed.did.web.host` property controls how DIDs are constructed for auto-seeded admin participants. The value must be URL-encoded (`:` → `%3A`):

| Context                            | Value                 | Resulting DID                             |
| ---------------------------------- | --------------------- | ----------------------------------------- |
| Host testing (curl from localhost) | `localhost%3A10100`   | `did:web:localhost%3A10100:super-admin`   |
| Docker-to-Docker (EDC connector)   | `identityhub%3A10100` | `did:web:identityhub%3A10100:super-admin` |
| Production (public domain)         | `wallet.example.com`  | `did:web:wallet.example.com:super-admin`  |

---

## Bootstrap & Admin Seed

### The chicken-and-egg problem

The Identity Admin API requires an `x-api-key` header for authentication. API keys are returned when creating a participant. But you can't create a participant without an API key.

### Solution: Admin Seed Extension

The `AdminSeedExtension` (in `extensions/api/identity-api/admin-seed/`) solves this by automatically creating a `super-admin` participant on first startup and printing the API key to the container logs.

#### Configuration properties

| Property                          | Default            | Description                      |
| --------------------------------- | ------------------ | -------------------------------- |
| `edc.ih.admin.seed.enabled`       | `true`             | Enable/disable auto-seeding      |
| `edc.ih.admin.seed.participantId` | `super-admin`      | Participant context ID           |
| `edc.ih.admin.seed.did`           | _(auto-generated)_ | Explicit DID override            |
| `edc.ih.admin.seed.did.web.host`  | _(none)_           | DID web host for auto-generation |

#### Retrieving the API key

```bash
# Extract from identityhub container logs
docker logs identityhub 2>&1 | grep "API Key" | head -1

# Example output:
# ║  API Key        : c3VwZXItYWRtaW4=.o7HiTpQHnLpdc/U9MhK/...
```

The API key format is: `base64(participantContextId).base64(random-64-bytes)`

#### Automated extraction

```bash
IH_KEY=$(docker logs identityhub 2>&1 \
  | sed 's/\x1b\[[0-9;]*m//g' \
  | grep "API Key" | head -1 \
  | sed 's/.*API Key        : //' \
  | sed 's/[[:space:]]*║.*//')
```

---

## Creating Participants (Provider & Consumer)

### Important: Path parameter encoding

All `{participantId}` path parameters in the Identity Admin API must be **Base64-URL-encoded**:

```bash
# Encode participant IDs
b64url() { echo -n "$1" | base64 | tr '+/' '-_' | tr -d '='; }

ADMIN_B64=$(b64url "super-admin")    # c3VwZXItYWRtaW4
PROVIDER_B64=$(b64url "provider")    # cHJvdmlkZXI
CONSUMER_B64=$(b64url "consumer")    # Y29uc3VtZXI
```

### Important: DID format

DIDs **must** match the DID web URL resolution pattern. The `DidWebParser` converts HTTP URLs to DID strings using this algorithm:

```
http://localhost:10100/provider/did.json
  → Strip did.json and trailing /
  → Replace / with :
  → URL-encode host:port (: → %3A)
  → Prepend did:web:
  → did:web:localhost%3A10100:provider
```

**The DID stored in the participant context must exactly match this computed string.**

### Create a provider participant

```bash
DID_WEB_HOST="localhost%3A10100"
PROVIDER_DID="did:web:${DID_WEB_HOST}:provider"

curl -X POST http://localhost:15151/api/identity/v1alpha/participants \
  -H "x-api-key: $IH_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "participantContextId": "provider",
    "did": "'"$PROVIDER_DID"'",
    "active": true,
    "roles": ["participant"],
    "serviceEndpoints": [
      {
        "id": "#credential-service",
        "type": "CredentialService",
        "serviceEndpoint": "http://identityhub:13131/api/credentials"
      }
    ],
    "key": {
      "keyId": "'"$PROVIDER_DID"'#provider-key",
      "privateKeyAlias": "provider-alias",
      "resourceId": "provider-resource",
      "keyGeneratorParams": {
        "algorithm": "EdDSA",
        "curve": "Ed25519"
      },
      "active": true,
      "usage": ["sign_token", "sign_presentation", "sign_credentials"]
    }
  }'
```

**Response** (HTTP 200/201):

```json
{
  "apiKey": "cHJvdmlkZXI=.GNZjkBjEowI5Wqab...",
  "clientId": "did:web:localhost%3A10100:provider",
  "clientSecret": "IyWUHVFpGh3Aoyjq"
}
```

Save the `apiKey` (for Identity Admin API), `clientId` and `clientSecret` (for STS `client_credentials` flow).

### Create a consumer participant

```bash
CONSUMER_DID="did:web:${DID_WEB_HOST}:consumer"

curl -X POST http://localhost:15151/api/identity/v1alpha/participants \
  -H "x-api-key: $IH_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "participantContextId": "consumer",
    "did": "'"$CONSUMER_DID"'",
    "active": true,
    "roles": ["participant"],
    "serviceEndpoints": [
      {
        "id": "#credential-service",
        "type": "CredentialService",
        "serviceEndpoint": "http://identityhub:13131/api/credentials"
      }
    ],
    "key": {
      "keyId": "'"$CONSUMER_DID"'#consumer-key",
      "privateKeyAlias": "consumer-alias",
      "resourceId": "consumer-resource",
      "keyGeneratorParams": {
        "algorithm": "EdDSA",
        "curve": "Ed25519"
      },
      "active": true,
      "usage": ["sign_token", "sign_presentation", "sign_credentials"]
    }
  }'
```

> **Important**: The `serviceEndpoints` array with a `CredentialService` entry is **required for DCP**. Without it, the verifier cannot discover where to request Verifiable Presentations. The `serviceEndpoint` URL must be reachable from other Docker containers (use the container hostname `identityhub`, not `localhost`). The `bootstrap-dcp.sh` script handles this automatically.

### Publish DIDs

After creating participants, their DIDs are in `GENERATED` state. You must publish them to make them resolvable via the DID web endpoint:

```bash
PROVIDER_B64=$(echo -n "provider" | base64 | tr '+/' '-_' | tr -d '=')

curl -X POST "http://localhost:15151/api/identity/v1alpha/participants/$PROVIDER_B64/dids/publish" \
  -H "x-api-key: $IH_KEY" \
  -H "Content-Type: application/json" \
  -d '{"did": "did:web:localhost%3A10100:provider"}'
# Returns 204 No Content on success

curl -X POST "http://localhost:15151/api/identity/v1alpha/participants/$CONSUMER_B64/dids/publish" \
  -H "x-api-key: $IH_KEY" \
  -H "Content-Type: application/json" \
  -d '{"did": "did:web:localhost%3A10100:consumer"}'
```

---

## DID Web Resolution

Once a DID is published, the DID web endpoint serves DID documents:

```bash
# Resolve provider DID document
curl -s http://localhost:10100/provider/did.json | jq .
```

**Response:**

```json
{
  "@context": ["https://www.w3.org/ns/did/v1"],
  "id": "did:web:localhost%3A10100:provider",
  "verificationMethod": [
    {
      "id": "provider-key",
      "type": "JsonWebKey2020",
      "controller": "did:web:localhost%3A10100:provider",
      "publicKeyJwk": {
        "kty": "OKP",
        "crv": "Ed25519",
        "x": "cwrxvi_efq8Vo_orcwHj65uJ-SpWy_2rffoeSscFCGc"
      }
    }
  ],
  "service": [],
  "authentication": []
}
```

### URL-to-DID mapping

| HTTP URL                                      | Resolved DID                                             |
| --------------------------------------------- | -------------------------------------------------------- |
| `http://localhost:10100/provider/did.json`    | `did:web:localhost%3A10100:provider`                     |
| `http://localhost:10100/consumer/did.json`    | `did:web:localhost%3A10100:consumer`                     |
| `http://localhost:10100/super-admin/did.json` | `did:web:localhost%3A10100:super-admin`                  |
| `http://identityhub:10100/provider/did.json`  | `did:web:identityhub%3A10100:provider` (Docker-internal) |

### DID state lifecycle

```
INITIAL(100) → GENERATED(200) → PUBLISHED(300) → UNPUBLISHED(400)
```

Only DIDs in the `PUBLISHED` state are served by the DID web endpoint.

---

## STS Token Issuance

The embedded Secure Token Service (STS) supports the `client_credentials` OAuth2 flow. EDC connectors use this to obtain self-issued tokens for DCP interactions.

### Endpoint

```
POST http://localhost:9292/api/sts/token
Content-Type: application/x-www-form-urlencoded
```

### Parameters

| Parameter             | Value                                | Description                                                                 |
| --------------------- | ------------------------------------ | --------------------------------------------------------------------------- |
| `grant_type`          | `client_credentials`                 | OAuth2 grant type                                                           |
| `client_id`           | `did:web:localhost%3A10100:provider` | The participant DID (URL-encoded in form data)                              |
| `client_secret`       | _(from create response)_             | Secret returned when creating the participant                               |
| `audience`            | Target audience DID/URI              | The audience for the token                                                  |
| `bearer_access_scope` | Scope string                         | Requested scope (e.g., `org.eclipse.edc.vc.type:MembershipCredential:read`) |

### Example

```bash
# Note: In application/x-www-form-urlencoded, special chars must be doubly encoded
# DID did:web:localhost%3A10100:provider becomes:
#   : → %3A, % → %25
# So: did%3Aweb%3Alocalhost%253A10100%3Aprovider

curl -X POST http://localhost:9292/api/sts/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials\
&client_id=did%3Aweb%3Alocalhost%253A10100%3Aprovider\
&client_secret=IyWUHVFpGh3Aoyjq\
&audience=did:web:consumer-connector\
&bearer_access_scope=org.eclipse.edc.vc.type:MembershipCredential:read"
```

---

## Issuer Service Setup

### Create a holder (link provider to issuer)

```bash
IS_BASE=http://localhost:15152/api/issuer/v1alpha
ADMIN_B64=$(echo -n "issuer-admin" | base64 | tr '+/' '-_' | tr -d '=')

curl -X POST "$IS_BASE/participants/$ADMIN_B64/holders" \
  -H "x-api-key: $IS_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "holderId": "provider",
    "did": "did:web:localhost%3A10100:provider",
    "name": "Provider Organization"
  }'
```

### Create an attestation definition

```bash
curl -X POST "$IS_BASE/participants/$ADMIN_B64/attestations" \
  -H "x-api-key: $IS_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "id": "membership-attestation",
    "attestationType": "database",
    "configuration": {
      "dataSourceName": "default",
      "tableName": "membership_attestations"
    }
  }'
```

### Create a credential definition

```bash
curl -X POST "$IS_BASE/participants/$ADMIN_B64/credentialdefinitions" \
  -H "x-api-key: $IS_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "id": "membership-cdef",
    "credentialType": "MembershipCredential",
    "format": "VC1_0_JWT",
    "jsonSchema": "{\"type\":\"object\"}",
    "attestations": ["membership-attestation"]
  }'
```

---

## Connecting EDC Connectors

### DCP authentication flow

When an EDC connector (e.g. consumer) makes a protocol request to another connector (e.g. provider), the DCP authentication flow works as follows:

```
Consumer-CP                    IdentityHub (STS)              Provider-CP
    │                                │                             │
    │ 1. POST /api/sts/token         │                             │
    │    client_id=consumer-DID      │                             │
    │    client_secret=<secret>      │                             │
    │    scope=MembershipCredential  │                             │
    │ ──────────────────────────────>│                             │
    │                                │                             │
    │ 2. SI Token (JWT)              │                             │
    │ <──────────────────────────────│                             │
    │                                │                             │
    │ 3. CatalogRequest + SI Token                                │
    │ ───────────────────────────────────────────────────────────> │
    │                                │                             │
    │                                │ 4. Verify SI token          │
    │                                │    Resolve consumer DID     │
    │                                │ <───────────────────────────│
    │                                │                             │
    │                                │ 5. Request VP (credential)  │
    │                                │    using access_token       │
    │                                │ <───────────────────────────│
    │                                │                             │
    │                                │ 6. VP with MembershipCred   │
    │                                │ ───────────────────────────>│
    │                                │                             │
    │ 7. Catalog response (if VP valid)                            │
    │ <────────────────────────────────────────────────────────────│
```

**Key insight**: The DCP scope is injected into the SI token request via the **policy engine** (pre/post validators from `DcpScopeExtractorExtension` and `DynamicDcpScopeExtension`), **not** the `TokenDecorator`. The warning "No TokenDecorator was registered" in connector logs is harmless — it simply means no _additional_ token decoration is applied beyond the policy-engine-derived scopes.

### Prerequisites for DCP to work

For the end-to-end flow to succeed, the following must be in place:

1. **Participant contexts** exist in IdentityHub for each connector (provider, consumer)
2. **STS client secrets** — both IdentityHub and Connectors use the same HashiCorp Vault; secrets are written once by IdentityHub under `{participantId}-sts-client-secret` and read by the Connector from the same key
3. **DIDs are published** and resolvable via Docker networking
4. **MembershipCredential VCs** are stored in IdentityHub for each participant
5. **Trusted issuer** is configured in the Connector and the issuer DID resolves

### Bootstrap script

A bootstrap script automates all the above:

```bash
./scripts/bootstrap-dcp.sh
```

This script:

- Creates "provider" and "consumer" participants in IdentityHub (with Docker-internal DIDs)
- Creates an "issuer" participant in the Issuer Service
- Publishes all DIDs
- Sets up holders and attestation definitions in the Issuer Service
- Verifies STS token creation

> **Note**: STS client secrets are automatically stored in the shared HashiCorp Vault when participants are created — no separate vault sync step is needed.
> See [Connector Discussion #4200](https://github.com/eclipse-edc/Connector/discussions/4200) for background on the shared vault architecture.

### EDC connector configuration

The Connector's properties must be configured for DCP. Here is a complete example for _provider_:

```properties
# --- DCP Identity ---
edc.iam.issuer.id=did:web:identityhub%3A10100:provider
edc.iam.did.web.use.https=false

# --- STS (remote, delegated to IdentityHub) ---
edc.iam.sts.oauth.token.url=http://identityhub:9292/api/sts/token
edc.iam.sts.oauth.client.id=did:web:identityhub%3A10100:provider
edc.iam.sts.oauth.client.secret.alias=provider-sts-client-secret
edc.iam.sts.publickey.id=did:web:identityhub%3A10100:provider#provider-key
edc.iam.sts.privatekey.alias=provider-private-key
edc.iam.sts.token.expiration=5

# --- DCP Scope ---
edc.iam.dcp.scopes.membership.id=membership-scope
edc.iam.dcp.scopes.membership.type=DEFAULT
edc.iam.dcp.scopes.membership.value=org.eclipse.edc.vc.type:MembershipCredential:read

# --- Trusted issuer ---
edc.iam.trusted-issuer.issuer.id=did:web:issuer-service%3A10101:issuer

# --- HashiCorp Vault ---
edc.vault.hashicorp.url=http://vault:8200
edc.vault.hashicorp.token=OVERRIDE_VIA_ENV
# Token is injected at container startup via entrypoint wrapper
# (reads from the shared edc-vault-token Docker volume)
edc.vault.hashicorp.api.secret.path=/v1/secret
```

The `provider-sts-client-secret` in the Connector's Vault is the same key that IdentityHub writes when the "provider" participant is created. Both runtimes share the same HashiCorp Vault instance — no external sync is required.

### Shared vault architecture

Both IdentityHub and EDC Connectors use a single HashiCorp Vault instance (running in the Connector stack). The Vault token is **randomly generated on every startup** — there is no hardcoded token.

**Token lifecycle:**

1. The EDC stack's `vault-token-gen` init service generates a 32-character random token and writes it to the `edc-vault-token` Docker volume
2. Vault, `vault-init`, and all EDC connectors read the token from the shared volume
3. The IdentityHub stack declares `edc-vault-token` as an **external volume** and mounts it read-only
4. Both `identityhub` and `issuer-service` use entrypoint wrappers that read the token and export it as `EDC_VAULT_HASHICORP_TOKEN` before starting the Java process

> **Important**: The EDC Connector stack must be started **before** the IdentityHub stack, because the EDC stack creates the `edc-vault-token` named volume.

**STS client secret flow** — when a participant is created in IdentityHub:

1. IdentityHub auto-generates a random STS client secret
2. The secret is stored in HashiCorp Vault under `{participantId}-sts-client-secret` (e.g., `provider-sts-client-secret`)
3. The Connector reads the same key from the same Vault instance

The IdentityHub uses partition-aware vault calls with `allow-fallback=true` (default), so all secrets land in the default KV v2 mount path (`secret/`) alongside the Connector's own secrets.

**Vault initialization**: The Connector's `vault-init` service (in `docker-compose.edc.yml`) seeds all secrets — Connector keys, IdentityHub STS signing key (`identityhub-alias`), and Issuer Service STS signing key (`issuer-alias`) — into the shared Vault at startup.

### Network considerations

| Context          | DID Host              | STS URL                                    | Notes                              |
| ---------------- | --------------------- | ------------------------------------------ | ---------------------------------- |
| Docker-to-Docker | `identityhub%3A10100` | `http://identityhub:9292/api/sts/token`    | Use container hostnames            |
| Host testing     | `localhost%3A10100`   | `http://localhost:9292/api/sts/token`      | Use `localhost` with exposed ports |
| Production       | `wallet.example.com`  | `https://wallet.example.com/api/sts/token` | Use public domain, HTTPS           |

> **Important**: When EDC connectors run inside Docker on the `edc-shared` network, they should use the container hostname (`identityhub`) rather than `localhost`. The DID stored in the participant context must match the hostname that will be used for resolution.

---

## API Endpoint Reference

### Identity Admin API (`:15151`)

| Method     | Path                                                                      | Description                   | Auth      |
| ---------- | ------------------------------------------------------------------------- | ----------------------------- | --------- |
| `POST`     | `/api/identity/v1alpha/participants`                                      | Create participant            | x-api-key |
| `GET`      | `/api/identity/v1alpha/participants`                                      | List all participants         | x-api-key |
| `GET`      | `/api/identity/v1alpha/participants/{id}`                                 | Get participant by ID         | x-api-key |
| `POST`     | `/api/identity/v1alpha/participants/{id}/state?isActive=true`             | Activate participant          | x-api-key |
| `PUT`      | `/api/identity/v1alpha/participants/{id}/roles`                           | Update roles                  | x-api-key |
| `POST`     | `/api/identity/v1alpha/participants/{id}/token`                           | Regenerate API token          | x-api-key |
| `GET`      | `/api/identity/v1alpha/keypairs`                                          | List all keypairs             | x-api-key |
| `GET`      | `/api/identity/v1alpha/participants/{id}/keypairs`                        | List participant keypairs     | x-api-key |
| `PUT`      | `/api/identity/v1alpha/participants/{id}/keypairs`                        | Add keypair                   | x-api-key |
| `POST`     | `/api/identity/v1alpha/participants/{id}/keypairs/{rid}/rotate`           | Rotate keypair                | x-api-key |
| `GET`      | `/api/identity/v1alpha/dids`                                              | List all DIDs                 | x-api-key |
| `POST`     | `/api/identity/v1alpha/participants/{id}/dids/query`                      | Query participant DIDs        | x-api-key |
| `POST`     | `/api/identity/v1alpha/participants/{id}/dids/state`                      | Get DID state                 | x-api-key |
| `POST`     | `/api/identity/v1alpha/participants/{id}/dids/publish`                    | Publish DID                   | x-api-key |
| `GET`      | `/api/identity/v1alpha/credentials`                                       | List all credentials          | x-api-key |
| `GET`      | `/api/identity/v1alpha/participants/{id}/credentials`                     | List participant credentials  | x-api-key |
| `GET`      | `/api/identity/v1alpha/participants/{id}/credentials?type=X`              | Filter credentials by type    | x-api-key |
| **`POST`** | **`/api/identity/v1alpha/participants/{id}/credentials`**                 | **Store a VC**                | x-api-key |
| `PUT`      | `/api/identity/v1alpha/participants/{id}/credentials`                     | Update a VC                   | x-api-key |
| `GET`      | `/api/identity/v1alpha/participants/{id}/credentials/{credId}`            | Get VC by ID                  | x-api-key |
| `DELETE`   | `/api/identity/v1alpha/participants/{id}/credentials/{credId}`            | Delete a VC                   | x-api-key |
| `POST`     | `/api/identity/v1alpha/participants/{id}/credentials/request`             | Request VC from issuer (DCP)  | x-api-key |
| `GET`      | `/api/identity/v1alpha/participants/{id}/credentials/request/{holderPid}` | Get credential request status | x-api-key |

> All `{id}` parameters are Base64-URL-encoded participant context IDs.

### Storing a Verifiable Credential

To store a VC for a participant, `POST` to the credentials endpoint with a `VerifiableCredentialManifest`:

```bash
PARTICIPANT_B64=$(echo -n "provider" | base64 | tr '+/' '-_' | tr -d '=')

curl -X POST "http://localhost:15151/api/identity/v1alpha/participants/${PARTICIPANT_B64}/credentials" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $IH_KEY" \
  -d '{
    "id": "membership-cred-001",
    "participantContextId": "provider",
    "verifiableCredentialContainer": {
      "rawVc": "eyJhbGciOi...<signed-JWT>",
      "format": "VC1_0_JWT",
      "credential": {
        "id": "urn:uuid:12345678-abcd-1234-abcd-123456789abc",
        "type": ["VerifiableCredential", "MembershipCredential"],
        "issuer": { "id": "did:web:issuer-service%3A10101:issuer" },
        "issuanceDate": "2025-06-01T00:00:00Z",
        "credentialSubject": {
          "id": "did:web:localhost%3A10100:provider",
          "memberOf": "ExampleOrganization"
        }
      }
    }
  }'
# Returns: 204 No Content
```

### Requesting a Credential via DCP (Holder → Issuer)

To trigger the DCP issuance protocol where the holder requests a credential from a remote issuer:

```bash
curl -X POST "http://localhost:15151/api/identity/v1alpha/participants/${PARTICIPANT_B64}/credentials/request" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $IH_KEY" \
  -d '{
    "issuerDid": "did:web:issuer-service%3A10101:issuer",
    "holderPid": "my-request-001",
    "credentials": [
      { "format": "VC1_0_JWT", "type": "MembershipCredential", "id": "mc-1" }
    ]
  }'
# Returns: 201 Created with Location header
```

Check the request status:

```bash
curl -s "http://localhost:15151/api/identity/v1alpha/participants/${PARTICIPANT_B64}/credentials/request/my-request-001" \
  -H "x-api-key: $IH_KEY" | jq .
```

### DID Web Endpoint (`:10100`)

| Method | Path                           | Description                       | Auth |
| ------ | ------------------------------ | --------------------------------- | ---- |
| `GET`  | `/{path}/did.json`             | Resolve DID document              | None |
| `GET`  | `/{path}/.well-known/did.json` | Resolve DID document (well-known) | None |

### STS Endpoint (`:9292`)

| Method | Path             | Description                      | Auth                              |
| ------ | ---------------- | -------------------------------- | --------------------------------- |
| `POST` | `/api/sts/token` | Issue token (client_credentials) | client_id + client_secret in body |

### Issuer Admin API (`:15152`)

| Method | Path                                                                   | Description                 | Auth      |
| ------ | ---------------------------------------------------------------------- | --------------------------- | --------- |
| `POST` | `/api/issuer/v1alpha/participants/{id}/holders`                        | Create holder               | x-api-key |
| `POST` | `/api/issuer/v1alpha/participants/{id}/holders/query`                  | Query holders               | x-api-key |
| `GET`  | `/api/issuer/v1alpha/participants/{id}/holders/{holderId}`             | Get holder                  | x-api-key |
| `PUT`  | `/api/issuer/v1alpha/participants/{id}/holders`                        | Update holder               | x-api-key |
| `POST` | `/api/issuer/v1alpha/participants/{id}/attestations`                   | Create attestation def      | x-api-key |
| `POST` | `/api/issuer/v1alpha/participants/{id}/attestations/query`             | Query attestation defs      | x-api-key |
| `POST` | `/api/issuer/v1alpha/participants/{id}/credentialdefinitions`          | Create credential def       | x-api-key |
| `POST` | `/api/issuer/v1alpha/participants/{id}/credentialdefinitions/query`    | Query credential defs       | x-api-key |
| `GET`  | `/api/issuer/v1alpha/participants/{id}/credentialdefinitions/{cdefId}` | Get credential def          | x-api-key |
| `POST` | `/api/issuer/v1alpha/participants/{id}/credentials/query`              | Query credentials           | x-api-key |
| `POST` | `/api/issuer/v1alpha/participants/{id}/credentials/{credId}/revoke`    | Revoke a credential         | x-api-key |
| `GET`  | `/api/issuer/v1alpha/participants/{id}/credentials/{credId}/status`    | Check revocation status     | x-api-key |
| `POST` | `/api/issuer/v1alpha/participants/{id}/credentials/offer`              | Send credential offer (DCP) | x-api-key |
| `POST` | `/api/issuer/v1alpha/participants/{id}/issuanceprocesses/query`        | Query issuance processes    | x-api-key |

### Health Check

| Method | Path                | Port                  | Description            |
| ------ | ------------------- | --------------------- | ---------------------- |
| `GET`  | `/api/check/health` | 8080 (IH) / 8081 (IS) | Health/readiness probe |

---

## Test Script

A comprehensive test script (`test-api.sh`) is included that validates all 38 API endpoints:

> **Prerequisite:** The EDC Connector stack must be running — the test script requires the shared Vault (via `edc-vault-token` volume).

```bash
# Ensure EDC stack is running (creates vault-token volume)
cd ../public-Eclipse-Connector
docker compose -f docker-compose.edc.yml up -d
cd ../public-Eclipse-IdentityHub

# Run on a fresh IH stack for full coverage (including STS token test)
docker compose -f docker-compose.identityhub.yml down -v
docker compose -f docker-compose.identityhub.yml up -d
sleep 15   # wait for services to be healthy

bash test-api.sh
```

The script is self-contained — it creates provider/consumer participants, publishes their DIDs, and then runs all tests. Expected result: **38/38 PASS**.

---

## Troubleshooting

### Common issues

| Symptom                                                                      | Cause                                   | Fix                                                                                                                                          |
| ---------------------------------------------------------------------------- | --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `relation "participant_context" does not exist`                              | SQL schema not created                  | Set `edc.sql.schema.autocreate=true`                                                                                                         |
| `duplicate key value violates unique constraint "pg_type_typname_nsp_index"` | Both runtimes share same database       | Use separate databases (`identityhub` and `issuerservice`)                                                                                   |
| DID web returns 204                                                          | DID string mismatch                     | Ensure the DID stored in the participant exactly matches the `DidWebParser` output (include `host%3Aport`)                                   |
| `P-256 is not a valid or supported EC curve std name`                        | JCA does not recognize `P-256`          | Use `secp256r1` or switch to `EdDSA`/`Ed25519`                                                                                               |
| `The curve must not be null` (Nimbus JWK)                                    | EC curve mapping fails on Alpine JDK 24 | Use `EdDSA`/`Ed25519` instead of EC curves                                                                                                   |
| STS returns `invalid_client`                                                 | Wrong `client_id` or `client_secret`    | `client_id` must be the DID (form-URL-encoded: `did%3Aweb%3Alocalhost%253A10100%3Aprovider`)                                                 |
| 401 on Identity Admin API                                                    | Missing or invalid `x-api-key` header   | Extract key from container logs; key format is `base64(pid).base64(random)`                                                                  |
| "No TokenDecorator was registered" in Connector logs                         | **Red herring** — not an error          | DCP scopes flow via the policy engine, not TokenDecorator. This warning is harmless.                                                         |
| 401 Unauthorized on DCP catalog request                                      | STS client secret mismatch              | Both IH and Connector share the same Vault; check that `provider-sts-client-secret` exists: `vault kv get secret/provider-sts-client-secret` |
| STS returns 404 / `client not found`                                         | No participant context in IdentityHub   | Create "provider"/"consumer" participants via the Identity Admin API                                                                         |
| Connector can't resolve counterpart DID                                      | DID uses wrong hostname for Docker      | Use `did:web:identityhub%3A10100:<pid>` for Docker-to-Docker (not `localhost`)                                                               |
| VP presentation fails / empty credentials                                    | No VCs stored in IdentityHub            | Issue and store MembershipCredential VCs for each participant                                                                                |

### Verifying DID web resolution

```bash
# DID Web spec: a URL maps to a DID by encoding the authority and path.
# From the HOST, http://localhost:10100/provider/did.json would map to
# did:web:localhost%3A10100:provider.
#
# However, bootstrap-dcp.sh creates participants with DOCKER-INTERNAL DIDs
# so that EDC Connectors (also running in Docker) can resolve them:
#   → did:web:identityhub%3A10100:provider
#   → did:web:identityhub%3A10100:consumer

# Check what DID is stored for a participant:
curl -s http://localhost:15151/api/identity/v1alpha/participants/$(echo -n "provider" | base64 | tr '+/' '-_' | tr -d '=') \
  -H "x-api-key: $IH_KEY" | jq '.did'
# Should output: "did:web:identityhub%3A10100:provider"
```

### Logs

```bash
docker logs identityhub 2>&1 | tail -50
docker logs issuer-service 2>&1 | tail -50
docker logs pg-identityhub 2>&1 | tail -20
```

---

## Quick Start Summary

```bash
# 1. Build
./gradlew :launcher:identityhub:shadowJar :launcher:issuer-service:shadowJar --parallel

# 2. Deploy EDC Connector stack FIRST (owns Vault + vault-token volume)
cd ../public-Eclipse-Connector
docker network create edc-shared 2>/dev/null || true
docker compose -f docker-compose.edc.yml up -d --build
sleep 15
cd ../public-Eclipse-IdentityHub

# 3. Deploy IdentityHub stack (uses external edc-vault-token volume)
docker compose -f docker-compose.identityhub.yml up -d --build
sleep 15

# 4. Bootstrap DCP integration (creates participants, publishes DIDs)
./scripts/bootstrap-dcp.sh

# 5. Issue and store Membership VCs (required for DCP auth)
python3 scripts/store-membership-vc.py

# 6. Verify DID resolution (must use Docker hostname to match stored DIDs)
docker exec identityhub curl -sf http://identityhub:10100/provider/did.json | jq .
docker exec identityhub curl -sf http://identityhub:10100/consumer/did.json | jq .

# 7. Run IdentityHub API tests
bash test-api.sh

# 8. Test end-to-end DCP catalog request (from Connector repo)
curl -s -X POST http://localhost:28181/management/v3/catalog/request \
  -H "X-Api-Key: ApiKeyDefaultLocal" \
  -H "Content-Type: application/json" \
  -d '{
    "@context": {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"},
    "counterPartyAddress": "http://provider-cp:8282/protocol/2025-1",
    "counterPartyId": "did:web:identityhub%3A10100:provider",
    "protocol": "dataspace-protocol-http:2025-1"
  }'
```
