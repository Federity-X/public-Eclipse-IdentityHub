# Docker-Compose IdentityHub — Goals & Design Notes

## Objective

Run the Eclipse EDC **IdentityHub** locally in a production-like way so it can
act as a **DCP wallet + issuer** for an external EDC Connector running in a
separate docker-compose stack.

## Architecture (from the repo)

| Runtime        | Launcher module           | BOM                 | Role                                                                  |
| -------------- | ------------------------- | ------------------- | --------------------------------------------------------------------- |
| IdentityHub    | `launcher:identityhub`    | `identityhub-bom`   | DCP **wallet** (presentation, credential storage, STS, identity API)  |
| Issuer Service | `launcher:issuer-service` | `issuerservice-bom` | DCP **issuer** (issuance, admin, status-list, credential definitions) |

> **Note:** The repo has no single combined "wallet + issuer" launcher.
> The E2E tests (`DcpIssuanceFlowAllInOneTest`) load both BOMs in one JVM, but
> for a Docker deployment the recommended pattern is **two separate containers**
> sharing a Postgres database — exactly how the BOM and launcher structure is
> designed.

### SQL persistence

| SQL BOM                         | Adds persistence for                                                                             |
| ------------------------------- | ------------------------------------------------------------------------------------------------ |
| `identityhub-feature-sql-bom`   | credentials, DIDs, keypairs, credential offers/requests, STS clients                             |
| `issuerservice-feature-sql-bom` | holders, attestation definitions, credential definitions, issuance processes, plus shared stores |

Both BOMs pull in `edc-sql-pool`, `edc-sql-bootstrapper`, and the Postgres
driver automatically.

## docker-compose services

| Service          | Image source                         | Purpose                                                |
| ---------------- | ------------------------------------ | ------------------------------------------------------ |
| `identityhub`    | Built from `launcher:identityhub`    | Wallet runtime (DCP presentation + credential storage) |
| `issuer-service` | Built from `launcher:issuer-service` | Issuer runtime (DCP issuance + status list)            |
| `pg-identityhub` | `postgres:17`                        | Shared SQL store                                       |

## Key configuration properties (from source)

### Web / HTTP endpoints

| Property                    | Value              |
| --------------------------- | ------------------ |
| `web.http.port`             | 8080 (default API) |
| `web.http.path`             | `/api`             |
| `web.http.identity.port`    | 15151              |
| `web.http.identity.path`    | `/api/identity`    |
| `web.http.credentials.port` | 13131              |
| `web.http.credentials.path` | `/api/credentials` |
| `web.http.did.port`         | 10100              |
| `web.http.did.path`         | `/`                |
| `web.http.sts.port`         | 9292               |
| `web.http.sts.path`         | `/api/sts`         |
| `web.http.issueradmin.port` | 15152              |
| `web.http.issueradmin.path` | `/api/issuer`      |
| `web.http.issuance.port`    | 13132              |
| `web.http.issuance.path`    | `/api/issuance`    |
| `web.http.statuslist.port`  | 9999               |
| `web.http.statuslist.path`  | `/statuslist`      |

### Datasource

| Property                          | Value                                               |
| --------------------------------- | --------------------------------------------------- |
| `edc.datasource.default.url`      | `jdbc:postgresql://pg-identityhub:5432/identityhub` |
| `edc.datasource.default.user`     | `ih`                                                |
| `edc.datasource.default.password` | `ihpass`                                            |

### STS / IAM

| Property                             | Value                          |
| ------------------------------------ | ------------------------------ |
| `edc.iam.sts.publickey.id`           | Public key ID for embedded STS |
| `edc.iam.sts.privatekey.alias`       | Private key alias in vault     |
| `edc.iam.did.web.use.https`          | `false` (local dev)            |
| `edc.iam.accesstoken.jti.validation` | `true`                         |

### Issuer

| Property                          | Value                           |
| --------------------------------- | ------------------------------- |
| `edc.statuslist.callback.address` | Base URL of the status-list API |

### Filesystem config

| Mount                               | Purpose                   |
| ----------------------------------- | ------------------------- |
| `./config/identityhub.properties`   | Main runtime config       |
| `./config/vault/secrets.properties` | File-system vault secrets |

## Build commands

```bash
# Build IdentityHub (wallet) Docker image
./gradlew :launcher:identityhub:shadowJar
docker build -t identityhub:local launcher/identityhub

# Build Issuer Service Docker image
./gradlew :launcher:issuer-service:shadowJar
docker build -t issuer-service:local launcher/issuer-service
```

## Exposed ports (host mapping)

| Host port | Container      | Container port | API                            |
| --------- | -------------- | -------------- | ------------------------------ |
| 8080      | identityhub    | 8080           | Default / health               |
| 15151     | identityhub    | 15151          | Identity API                   |
| 13131     | identityhub    | 13131          | DCP Credentials / Presentation |
| 10100     | identityhub    | 10100          | DID web endpoint               |
| 9292      | identityhub    | 9292           | STS                            |
| 15152     | issuer-service | 15152          | Issuer Admin API               |
| 13132     | issuer-service | 13132          | DCP Issuance API               |
| 9999      | issuer-service | 9999           | Status List                    |
| 5432      | pg-identityhub | 5432           | Postgres                       |
