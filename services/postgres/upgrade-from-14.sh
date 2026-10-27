#!/bin/bash
# Entrypoint wrapper: upgrades a PostgreSQL 14 cluster created by older package versions
# to PostgreSQL 18, then hands over to the official docker-entrypoint.sh.
#
# Layout (the volume is mounted at /var/lib/postgresql, as the 18+ images expect):
#   /var/lib/postgresql/PG_VERSION = 14   -> cluster created by package versions running PostgreSQL 14
#   /var/lib/postgresql/18/docker         -> PGDATA of the PostgreSQL 18 cluster
#
# Upgrade = dump/restore (the slashing protection DB is small: it is pruned to 500 epochs):
#   1. start PostgreSQL 14 on the old cluster (unix socket only) and pg_dump every database
#   2. initdb a PostgreSQL 18 cluster in a temporary directory and restore the dumps
#   3. compare exact row counts of every table between both clusters
#   4. atomically move the new cluster into PGDATA
#   5. disable the old cluster (rename its PG_VERSION) so an older package version cannot start
#      on it and sign with a stale slashing protection history
# Any failure exits non-zero before step 4, leaving the old cluster untouched: postgres does not
# start, so flyway and web3signer do not start either (fail closed). The next restart retries.

set -euo pipefail

OLD_DATA=/var/lib/postgresql
OLD_BIN=/usr/lib/postgresql/14/bin
NEW_DATA="${PGDATA}"
WORK_DATA="${PGDATA}.upgrading"
UPGRADE_DIR=/var/lib/postgresql/upgrade-14-to-18
OLD_SOCKET=/tmp/pg14
NEW_SOCKET=/tmp/pg18

log() { echo "[INFO - upgrade-from-14] $*"; }

# Exact row count of every user table, one "db.schema.table count" line each.
table_counts() {
  local bin=$1 socket=$2 db
  for db in $("${bin}/psql" -h "${socket}" -U "${POSTGRES_USER}" -d postgres -Atc \
    "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1"); do
    "${bin}/psql" -h "${socket}" -U "${POSTGRES_USER}" -d "${db}" -At -v ON_ERROR_STOP=1 <<-SQL
	SELECT format('SELECT %L || '' '' || count(*) FROM %I.%I', '${db}.' || schemaname || '.' || relname, schemaname, relname)
	FROM pg_stat_user_tables ORDER BY schemaname, relname \gexec
	SQL
  done | sort
}

upgrade() {
  log "Found a PostgreSQL 14 cluster in ${OLD_DATA}, upgrading it to PostgreSQL ${PG_MAJOR}"
  rm -rf "${WORK_DATA}" "${UPGRADE_DIR}"
  mkdir -p "$(dirname "${NEW_DATA}")" "${UPGRADE_DIR}" "${OLD_SOCKET}" "${NEW_SOCKET}"

  log "Dumping databases from PostgreSQL 14"
  "${OLD_BIN}/pg_ctl" -D "${OLD_DATA}" -w -o "-c listen_addresses='' -c unix_socket_directories=${OLD_SOCKET}" start
  "${OLD_BIN}/psql" -h "${OLD_SOCKET}" -U "${POSTGRES_USER}" -d postgres -Atc \
    "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1" > "${UPGRADE_DIR}/databases"
  while read -r db; do
    pg_dump -h "${OLD_SOCKET}" -U "${POSTGRES_USER}" -Fc -f "${UPGRADE_DIR}/${db}.dump" "${db}"
  done < "${UPGRADE_DIR}/databases"
  table_counts "${OLD_BIN}" "${OLD_SOCKET}" > "${UPGRADE_DIR}/counts-14"
  "${OLD_BIN}/pg_ctl" -D "${OLD_DATA}" -m fast -w stop

  log "Restoring into a new PostgreSQL ${PG_MAJOR} cluster"
  initdb -D "${WORK_DATA}" --username="${POSTGRES_USER}" --pwfile=<(printf "%s\n" "${POSTGRES_PASSWORD}") > /dev/null
  printf '\nhost all all all scram-sha-256\n' >> "${WORK_DATA}/pg_hba.conf"
  pg_ctl -D "${WORK_DATA}" -w -o "-c listen_addresses='' -c unix_socket_directories=${NEW_SOCKET}" start
  while read -r db; do
    if [ "${db}" = postgres ]; then
      pg_restore -h "${NEW_SOCKET}" -U "${POSTGRES_USER}" --exit-on-error -d postgres "${UPGRADE_DIR}/${db}.dump"
    else
      pg_restore -h "${NEW_SOCKET}" -U "${POSTGRES_USER}" --exit-on-error --create -d postgres "${UPGRADE_DIR}/${db}.dump"
    fi
  done < "${UPGRADE_DIR}/databases"
  table_counts /usr/lib/postgresql/${PG_MAJOR}/bin "${NEW_SOCKET}" > "${UPGRADE_DIR}/counts-${PG_MAJOR}"
  pg_ctl -D "${WORK_DATA}" -m fast -w stop

  if ! diff -u "${UPGRADE_DIR}/counts-14" "${UPGRADE_DIR}/counts-${PG_MAJOR}"; then
    echo "[ERROR - upgrade-from-14] Row counts differ between PostgreSQL 14 and ${PG_MAJOR}, aborting. The PostgreSQL 14 cluster was not modified." >&2
    exit 1
  fi
  log "Row counts match: $(tr '\n' ' ' < "${UPGRADE_DIR}/counts-${PG_MAJOR}")"

  mv "${WORK_DATA}" "${NEW_DATA}"
  disable_old_cluster
  log "Upgrade completed. Dumps kept in ${UPGRADE_DIR}"
}

disable_old_cluster() {
  if [ -s "${OLD_DATA}/PG_VERSION" ]; then
    mv "${OLD_DATA}/PG_VERSION" "${OLD_DATA}/PG_VERSION.upgraded-to-${PG_MAJOR}"
    log "Disabled the old PostgreSQL 14 cluster so older package versions cannot use its stale data"
  fi
}

if [ "${1:-}" = postgres ]; then
  if [ -s "${NEW_DATA}/PG_VERSION" ]; then
    # Already upgraded (or fresh install). Finish step 5 if a previous run stopped right before it.
    disable_old_cluster
  elif [ "$(cat "${OLD_DATA}/PG_VERSION" 2>/dev/null)" = 14 ]; then
    upgrade
  fi
fi

exec docker-entrypoint.sh "$@"
