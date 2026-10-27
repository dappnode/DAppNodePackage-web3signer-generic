#!/bin/bash

# Check if NETWORK is set
if [ -z "$NETWORK" ]; then
  echo "[INFO - entrypoint] NETWORK is not set. Exiting..."
  exit 1
fi

# If network is mainnet
if [ "$NETWORK" == "mainnet" ]; then
  POSTGRES_DOMAIN="postgres.web3signer.dappnode"
else
  POSTGRES_DOMAIN="postgres.web3signer-${NETWORK}.dappnode"
fi

# Wait for postgres to accept connections instead of exiting early: web3signer only starts once
# flyway completes successfully, and some docker compose versions abort `up` (making the
# DAppManager roll back the update) on the first non-zero exit of a dependency, even with a
# restart policy. Postgres can take a while to start, e.g. on first start or during an upgrade.
POSTGRES_WAIT_SECONDS=600
waited=0
until pg_isready -q -h "${POSTGRES_DOMAIN}" -p 5432 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"; do
  if [ "$waited" -ge "$POSTGRES_WAIT_SECONDS" ]; then
    echo "[ERROR - entrypoint] Postgres at ${POSTGRES_DOMAIN} not ready after ${POSTGRES_WAIT_SECONDS}s. Exiting..."
    exit 1
  fi
  [ $((waited % 30)) -eq 0 ] && echo "[INFO - entrypoint] Waiting for postgres at ${POSTGRES_DOMAIN}..."
  sleep 2
  waited=$((waited + 2))
done

set -e

# Get postgresql database version and trim whitespaces
# PGPASSWORD=${PGPASSWORD}
DATABASE_VERSION=$(psql -U "${POSTGRES_USER}" -h "${POSTGRES_DOMAIN}" -p 5432 -d "${POSTGRES_DB}" -t -A -c "SELECT version FROM database_version WHERE id=1;")

# Get the latest migration file version (ending in .sql) and trim whitespaces
LATEST_MIGRATION_VERSION=$(ls -1 /flyway/sql/ | grep -E "V[0-9]+__.*.sql$" | tail -n 1 | cut -d'_' -f1 | cut -d'V' -f2 | sed 's/^0*//' | tr -d '[:space:]')

# Ensure that either DATABASE_VERSION and LATEST_MIGRATION_VERSION are integers
if ! [[ "$DATABASE_VERSION" =~ ^[0-9]+$ ]] || ! [[ "$LATEST_MIGRATION_VERSION" =~ ^[0-9]+$ ]]; then
  echo "[ERROR - entrypoint]  Could not compare database and latest migration file versions. Exiting WITHOUT DATABASE MIGRATIONS. This may result in unexpected behaviour"
  exit 0
fi

echo "[INFO - entrypoint] Database version: $DATABASE_VERSION"
echo "[INFO - entrypoint] Latest migration file version: $LATEST_MIGRATION_VERSION"

if [ "$DATABASE_VERSION" -ge "$LATEST_MIGRATION_VERSION" ]; then
  echo "[INFO - entrypoint] Database version is greater or equal to the latest migration file version. Exiting..."
  exit 0
else
  echo "[INFO - entrypoint] Database version is less than the latest migration file version. Migrating..."
  flyway -baselineOnMigrate="true" -baselineVersion="${DATABASE_VERSION}" -url="jdbc:postgresql://${POSTGRES_DOMAIN}:5432/${POSTGRES_DB}" -user="${POSTGRES_USER}" -password="${PGPASSWORD}" -connectRetries=60 migrate
  echo "[INFO - entrypoint] Migration completed"
  exit 0
fi
