#!/bin/bash
# Creates both 'identityhub' and 'issuerservice' databases on first startup.
# Postgres only auto-creates the database named in POSTGRES_DB, so we handle
# the rest here.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    SELECT 'CREATE DATABASE identityhub OWNER $POSTGRES_USER'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'identityhub')\gexec

    SELECT 'CREATE DATABASE issuerservice OWNER $POSTGRES_USER'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'issuerservice')\gexec
EOSQL
