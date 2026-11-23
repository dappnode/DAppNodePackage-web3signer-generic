#!/bin/sh

# Backup of the slashing protection database (Postgres). The DAppNode backup copies the manifest
# `backup` paths, so the database is kept as an EIP-3076 interchange file at SLASHING_PROTECTION_FILE:
#
#   slashing-protection export  Export the database to SLASHING_PROTECTION_FILE. The entrypoint runs it
#                               once Web3Signer has stopped, so the file holds everything it signed.
#   slashing-protection import  Import SLASHING_PROTECTION_FILE unless the database already contains it
#                               (restored from a backup, or a new database). Run before Web3Signer starts.

SUPPORTED_NETWORKS="mainnet hoodi gnosis lukso"
SLASHING_PROTECTION_FILE="/data/slashing-protection.json"
# "<postgres system identifier> <sha256 of the interchange file>" of the last export or import, i.e. a
# file the database contains. Not backed up, so a restored file never matches it.
SLASHING_PROTECTION_STATE_FILE="/data/.slashing-protection-state"

# shellcheck disable=SC1091
. /etc/profile

WEB3SIGNER_DOMAIN=$(get_web3signer_domain "${NETWORK}" "${SUPPORTED_NETWORKS}")
DB_URL="jdbc:postgresql://postgres.${WEB3SIGNER_DOMAIN}:5432/${POSTGRES_DB}"
DB_FLAGS="--slashing-protection-db-url=${DB_URL} --slashing-protection-db-username=${POSTGRES_USER} --slashing-protection-db-password=${PGPASSWORD}"

log() {
  echo "[$1 - slashing-protection] $2"
}

# Prints "<postgres system identifier> <sha256 of file $1>". The identifier changes when the
# postgres_data volume is recreated. Read with the JDBC driver bundled with Web3Signer.
get_state() {
  db_id=$(java -Xmx64m -cp "$(echo /opt/web3signer/lib/postgresql-*.jar):/opt/dappnode" PgSystemIdentifier \
    "${DB_URL}" "${POSTGRES_USER}") && [ -n "${db_id}" ] || return 1
  echo "${db_id} $(sha256sum "$1" | cut -d' ' -f1)"
}

# 0: the database contains SLASHING_PROTECTION_FILE, 1: it does not, 2: the database can't be read
is_file_in_db() {
  current_state=$(get_state "${SLASHING_PROTECTION_FILE}") || return 2
  [ "$(cat "${SLASHING_PROTECTION_STATE_FILE}" 2>/dev/null)" = "${current_state}" ]
}

# Importing merges: entries already in the database are skipped, nothing is deleted and low
# watermarks only move up, so importing the same file again, or an older one, is always safe.
import_slashing_protection() {
  [ -f "${SLASHING_PROTECTION_FILE}" ] || return 0

  is_file_in_db
  case $? in
  0)
    log INFO "The database already contains ${SLASHING_PROTECTION_FILE}"
    return 0
    ;;
  2)
    log ERROR "Could not read the slashing protection database at ${DB_URL}"
    return 1
    ;;
  esac

  log INFO "Importing ${SLASHING_PROTECTION_FILE} (restored from a backup, or new database)"
  import_log=$(mktemp)
  # shellcheck disable=SC2086
  /opt/web3signer/bin/web3signer eth2 ${DB_FLAGS} import --from="${SLASHING_PROTECTION_FILE}" >"${import_log}" 2>&1
  import_status=$?
  cat "${import_log}"
  # Web3Signer only logs, and still exits 0, when the data of a single validator fails to import
  if [ "${import_status}" -ne 0 ] || grep -q "Failed importing slashing protection data" "${import_log}"; then
    rm -f "${import_log}"
    log ERROR "Import of ${SLASHING_PROTECTION_FILE} failed"
    return 1
  fi
  rm -f "${import_log}"
  echo "${current_state}" >"${SLASHING_PROTECTION_STATE_FILE}"
  log INFO "Imported ${SLASHING_PROTECTION_FILE}"
}

export_slashing_protection() {
  # Never overwrite a file the database does not contain (a backup restored into the container, or a
  # recreated postgres_data volume): it is imported on the next start
  if [ -f "${SLASHING_PROTECTION_FILE}" ]; then
    is_file_in_db
    case $? in
    1)
      log ERROR "Not exporting: the database does not contain ${SLASHING_PROTECTION_FILE} yet, it is imported on the next start"
      return 1
      ;;
    2)
      log ERROR "Export FAILED, ${SLASHING_PROTECTION_FILE} keeps the previous export: could not read the slashing protection database at ${DB_URL}"
      return 1
      ;;
    esac
  fi

  # Same directory, so the rename below is atomic: the file is either the previous export or the new one
  export_tmp=$(mktemp "${SLASHING_PROTECTION_FILE}.XXXXXX") || return 1
  export_log=$(mktemp)
  # shellcheck disable=SC2086
  if ! JAVA_OPTS="-Xmx512m" /opt/web3signer/bin/web3signer --logging=WARN eth2 ${DB_FLAGS} \
    export --to="${export_tmp}" >"${export_log}" 2>&1; then
    rm -f "${export_tmp}"
    # Web3Signer stores the genesis validators root when it signs for the first time
    if grep -q "No genesis validators root" "${export_log}"; then
      rm -f "${export_log}"
      log INFO "Nothing to export, Web3Signer has not signed anything yet"
      return 0
    fi
    cat "${export_log}"
    rm -f "${export_log}"
    log ERROR "Export FAILED, ${SLASHING_PROTECTION_FILE} keeps the previous export"
    return 1
  fi
  rm -f "${export_log}"

  if ! new_state=$(get_state "${export_tmp}"); then
    rm -f "${export_tmp}"
    log ERROR "Export FAILED, ${SLASHING_PROTECTION_FILE} keeps the previous export: could not read the slashing protection database at ${DB_URL}"
    return 1
  fi
  # A restore may have replaced the file during the export
  if [ -f "${SLASHING_PROTECTION_FILE}" ] && ! is_file_in_db; then
    rm -f "${export_tmp}"
    log ERROR "Not exporting: ${SLASHING_PROTECTION_FILE} was replaced during the export"
    return 1
  fi
  chmod 644 "${export_tmp}"
  mv -f "${export_tmp}" "${SLASHING_PROTECTION_FILE}"
  echo "${new_state}" >"${SLASHING_PROTECTION_STATE_FILE}"
  sync
  log INFO "Exported the slashing protection database to ${SLASHING_PROTECTION_FILE}"
}

case "$1" in
import) import_slashing_protection ;;
export) export_slashing_protection ;;
*)
  echo "Usage: slashing-protection import|export"
  exit 2
  ;;
esac
