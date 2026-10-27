#!/bin/sh

SUPPORTED_NETWORKS="mainnet hoodi gnosis lukso"
KEYFILES_DIR="/data/keyfiles"

# shellcheck disable=SC1091
. /etc/profile

WEB3SIGNER_DOMAIN=$(get_web3signer_domain "${NETWORK}" "${SUPPORTED_NETWORKS}")

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
    --slashing-protection-db-url=jdbc:postgresql://postgres.${WEB3SIGNER_DOMAIN}:5432/${POSTGRES_DB} \
    --slashing-protection-db-username=$POSTGRES_USER \
    --slashing-protection-db-password=$PGPASSWORD \
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
run_web3signer
