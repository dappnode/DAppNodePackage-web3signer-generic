#!/bin/sh

SUPPORTED_NETWORKS="mainnet hoodi gnosis lukso"
KEYFILES_DIR="/data/keyfiles"
# EIP-3076 interchange export of the slashing protection database, declared in the manifest `backup`
SLASHING_PROTECTION_FILE="/data/slashing-protection.json"
# "<postgres system identifier> <sha256 of the interchange file>" the database is known to contain.
# Kept out of the backup so a restored interchange file never matches it and is imported.
SLASHING_PROTECTION_STATE_FILE="/data/.slashing-protection-state"
SLASHING_PROTECTION_EXPORT_INTERVAL_SECONDS=600

# shellcheck disable=SC1091
. /etc/profile

WEB3SIGNER_DOMAIN=$(get_web3signer_domain "${NETWORK}" "${SUPPORTED_NETWORKS}")
POSTGRES_HOST="postgres.${WEB3SIGNER_DOMAIN}"
SLASHING_PROTECTION_DB_FLAGS="--slashing-protection-db-url=jdbc:postgresql://${POSTGRES_HOST}:5432/${POSTGRES_DB} \
  --slashing-protection-db-username=${POSTGRES_USER} \
  --slashing-protection-db-password=${PGPASSWORD}"

generate_cors_settings() {
  CORS_ORIGINS="http://web3signer.${WEB3SIGNER_DOMAIN},http://brain.${WEB3SIGNER_DOMAIN},http://signer.${NETWORK}.dncore.dappnode,http://signer.${NETWORK}.staker.dappnode"

  consensus_dnp=$(get_value_from_global_env "CONSENSUS_CLIENT" "${NETWORK}")

  consensus_domain=$(get_client_network_alias "${consensus_dnp}")

  if [ -n "${consensus_domain}" ]; then
    CORS_ORIGINS="${CORS_ORIGINS},http://validator.${consensus_domain}"
  fi

  echo "[INFO - entrypoint] Generated CORS_ORIGINS: ${CORS_ORIGINS}"
}

# Hostnames (Host header) web3signer accepts on port 9000. Every name another package
# or the DAppManager uses to reach this service must be listed here, otherwise its
# requests get a 403. Users can append more (or "*") with EXTRA_HOST_ALLOWLIST.
generate_host_allowlist() {
  # localhost/127.0.0.1: web3signer defaults, used by local tooling
  # web3signer.<domain>: staker-scripts validator URL, rocketpool, keys registered by brain <= 0.1.19
  HOST_ALLOWLIST="localhost,127.0.0.1,${WEB3SIGNER_DOMAIN},web3signer.${WEB3SIGNER_DOMAIN},brain.${WEB3SIGNER_DOMAIN}"

  # Aliases added by the DAppManager stakers module on dncore, staker and private networks.
  # signer.<network>.dncore.dappnode: brain >= 0.1.20 (and the remote keys it registers), lido-csm
  # web3signer.<network>.dncore.dappnode: validator-tracker
  for alias in signer web3signer; do
    HOST_ALLOWLIST="${HOST_ALLOWLIST},${alias}.${NETWORK}.dncore.dappnode,${alias}.${NETWORK}.staker.dappnode,${alias}.${NETWORK}.dappnode.private"
  done

  # Remaining names Docker and the DAppManager give this container: the compose service
  # name, the private network domain and the container name
  if [ "${NETWORK}" = "mainnet" ]; then dnp_name="web3signer.dnp.dappnode.eth"; else dnp_name="web3signer-${NETWORK}.dnp.dappnode.eth"; fi
  HOST_ALLOWLIST="${HOST_ALLOWLIST},web3signer,${WEB3SIGNER_DOMAIN}.private,web3signer.${WEB3SIGNER_DOMAIN}.private,DAppNodePackage-web3signer.${dnp_name}"

  if [ -n "${consensus_domain}" ]; then
    HOST_ALLOWLIST="${HOST_ALLOWLIST},validator.${consensus_domain}"
  fi

  # Strip whitespace: FLAGS is word-split, so "a, b" would pass "b" as a stray argument and web3signer would not start
  extra_hosts=$(printf '%s' "${EXTRA_HOST_ALLOWLIST}" | tr -d '[:space:]')
  if [ -n "${extra_hosts}" ]; then
    HOST_ALLOWLIST="${HOST_ALLOWLIST},${extra_hosts}"
  fi

  echo "[INFO - entrypoint] Generated HOST_ALLOWLIST: ${HOST_ALLOWLIST}"
}

prepare_keyfiles_dir() {
  # IMPORTANT! The dir defined for --key-store-path must exist and have specific permissions. Should not be created with a docker volume
  mkdir -p "${KEYFILES_DIR}"

  if grep -Fq "/opt/web3signer/keyfiles" ${KEYFILES_DIR}/*.yaml; then
    sed -i "s|/opt/web3signer/keyfiles|${KEYFILES_DIR}|g" ${KEYFILES_DIR}/*.yaml
  fi
}

# Prints "<postgres system identifier> <sha256 of the file>": the identifier changes when the
# postgres_data volume is recreated, the hash when a backup restore replaces the file
get_slashing_protection_state() {
  db_id=$(psql -h "${POSTGRES_HOST}" -p 5432 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -t -A \
    -c "SELECT system_identifier FROM pg_control_system();") && [ -n "${db_id}" ] || return 1
  echo "${db_id} $(sha256sum "$1" | cut -d' ' -f1)"
}

# Whether the database already contains SLASHING_PROTECTION_FILE: it was exported from it, or imported into it
is_slashing_protection_file_in_db() {
  current_state=$(get_slashing_protection_state "${SLASHING_PROTECTION_FILE}") || return 2
  [ "$(cat "${SLASHING_PROTECTION_STATE_FILE}" 2>/dev/null)" = "${current_state}" ]
}

# A backup restore (full DAppNode backup or the package Backup tab) puts back the interchange file
# exported on the old node. Import it before web3signer starts signing, unless the database already
# contains it. Importing merges: entries already in the database are skipped and nothing is deleted,
# so importing the same file again, or an older one, never weakens the protection.
import_slashing_protection() {
  [ -f "${SLASHING_PROTECTION_FILE}" ] || return 0

  is_slashing_protection_file_in_db
  case $? in
  0)
    echo "[INFO - entrypoint] Slashing protection database already contains ${SLASHING_PROTECTION_FILE}"
    return 0
    ;;
  2)
    echo "[ERROR - entrypoint] Could not read the slashing protection database at ${POSTGRES_HOST}. Exiting..."
    exit 1
    ;;
  esac

  echo "[INFO - entrypoint] Importing slashing protection data from ${SLASHING_PROTECTION_FILE} (restored from a backup, or new database)"
  import_log=/tmp/slashing-protection-import.log
  # shellcheck disable=SC2086
  /opt/web3signer/bin/web3signer eth2 $SLASHING_PROTECTION_DB_FLAGS import --from="${SLASHING_PROTECTION_FILE}" >"${import_log}" 2>&1
  import_status=$?
  cat "${import_log}"
  # web3signer only logs, and still exits 0, when the data of a single validator fails to import
  if [ "${import_status}" -ne 0 ] || grep -q "Failed importing slashing protection data" "${import_log}"; then
    echo "[ERROR - entrypoint] Slashing protection import failed. Web3Signer does not start without it, to never sign without the protection of the restored validators."
    echo "[ERROR - entrypoint] Fix the error above, or delete ${SLASHING_PROTECTION_FILE} to start without the backed up slashing protection data. Exiting..."
    exit 1
  fi
  echo "${current_state}" >"${SLASHING_PROTECTION_STATE_FILE}"
  echo "[INFO - entrypoint] Slashing protection data imported"
}

# Write an EIP-3076 interchange of the slashing protection database to SLASHING_PROTECTION_FILE, so the
# DAppNode backup, which copies files from the running container, contains a consistent copy of it
export_slashing_protection() {
  # Never overwrite a file the database does not contain yet (a backup restored into the running
  # container, or a recreated postgres_data volume): it is imported on the next start
  if [ -f "${SLASHING_PROTECTION_FILE}" ]; then
    is_slashing_protection_file_in_db
    case $? in
    1)
      echo "[WARN - entrypoint] The slashing protection database does not contain ${SLASHING_PROTECTION_FILE} yet, restart the package to import it. Not exporting until then"
      return 1
      ;;
    2)
      echo "[WARN - entrypoint] Could not read the slashing protection database at ${POSTGRES_HOST}, not exporting"
      return 1
      ;;
    esac
  fi

  export_tmp="${SLASHING_PROTECTION_FILE}.tmp"
  export_log=/tmp/slashing-protection-export.log
  # shellcheck disable=SC2086
  if ! JAVA_OPTS="-Xmx512m" /opt/web3signer/bin/web3signer --logging=WARN eth2 $SLASHING_PROTECTION_DB_FLAGS \
    export --to="${export_tmp}" >"${export_log}" 2>&1; then
    rm -f "${export_tmp}"
    # Nothing to export until web3signer signs for the first time and stores the genesis validators root
    grep -q "No genesis validators root" "${export_log}" && return 0
    echo "[WARN - entrypoint] Slashing protection export failed:"
    tail -n 20 "${export_log}"
    return 1
  fi

  new_state=$(get_slashing_protection_state "${export_tmp}") || return 1
  # A restore may have replaced the file while exporting
  if [ -f "${SLASHING_PROTECTION_FILE}" ] && ! is_slashing_protection_file_in_db; then
    rm -f "${export_tmp}"
    return 1
  fi
  # Replace the file atomically, a backup can copy it at any time
  mv -f "${export_tmp}" "${SLASHING_PROTECTION_FILE}"
  echo "${new_state}" >"${SLASHING_PROTECTION_STATE_FILE}"
}

export_slashing_protection_periodically() {
  # Let web3signer start first
  sleep 60
  while true; do
    export_slashing_protection
    sleep "${SLASHING_PROTECTION_EXPORT_INTERVAL_SECONDS}"
  done
}

run_web3signer() {
  FLAGS="--key-store-path=$KEYFILES_DIR \
    --http-listen-port=9000 \
    --http-listen-host=0.0.0.0 \
    --http-host-allowlist=$HOST_ALLOWLIST \
    --http-cors-origins=$CORS_ORIGINS \
    --metrics-enabled=true \
    --metrics-host 0.0.0.0 \
    --metrics-port 9091 \
    --metrics-host-allowlist=* \
    --idle-connection-timeout-seconds=900 \
    eth2 \
    --network=$NETWORK \
    $SLASHING_PROTECTION_DB_FLAGS \
    --slashing-protection-pruning-enabled=true \
    --slashing-protection-pruning-epochs-to-keep=500 \
    --key-manager-api-enabled=true ${EXTRA_OPTS}"

  echo "[INFO - entrypoint] Starting Web3Signer with flags: $FLAGS"

  # shellcheck disable=SC2086
  exec /opt/web3signer/bin/web3signer $FLAGS
}

generate_cors_settings
generate_host_allowlist
prepare_keyfiles_dir
import_slashing_protection
# Keeps running in the background after exec, as a child of web3signer
export_slashing_protection_periodically &
run_web3signer
