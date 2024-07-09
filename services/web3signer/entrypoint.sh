#!/bin/sh

KEYFILES_DIR="/data/keyfiles"

set_web3signer_pkg_domain() {
  if [ -z "${NETWORK}" ]; then
    echo "[ERROR - entrypoint] NETWORK is not set. Exiting..."
    exit 1
  fi

  if [ "${NETWORK}" = "mainnet" ]; then
    WEB3SIGNER_DOMAIN="web3signer.dappnode"
  else
    WEB3SIGNER_DOMAIN="web3signer-${NETWORK}.dappnode"
  fi

  export WEB3SIGNER_DOMAIN
}

generate_cors_settings() {
  CORS_ALLOWLIST="web3signer.${WEB3SIGNER_DOMAIN},brain.${WEB3SIGNER_DOMAIN}"
  CORS_ORIGINS="http://web3signer.${WEB3SIGNER_DOMAIN},http://brain.${WEB3SIGNER_DOMAIN}"

  consensus_dnp=$(get_value_from_global_env "${CONSENSUS_CLIENT}" "${NETWORK}")

  consensus_domain=$(get_client_network_alias "${consensus_dnp}")

  if [ -n "${consensus_domain}" ]; then
    CORS_ALLOWLIST="${CORS_ALLOWLIST},${consensus_domain}"
    CORS_ORIGINS="${CORS_ORIGINS},http://${consensus_domain}"
  fi

  echo "[INFO - entrypoint] Generated CORS_ALLOWLIST: ${CORS_ALLOWLIST}"
  echo "[INFO - entrypoint] Generated CORS_ORIGINS: ${CORS_ORIGINS}"
}

prepare_keyfiles_dir() {
  # IMPORTANT! The dir defined for --key-store-path must exist and have specific permissions. Should not be created with a docker volume
  mkdir -p "${KEYFILES_DIR}"

  if grep -Fq "/opt/web3signer/keyfiles" ${KEYFILES_DIR}/*.yaml; then
    sed -i "s|/opt/web3signer/keyfiles|${KEYFILES_DIR}|g" ${KEYFILES_DIR}/*.yaml
  fi
}

run_web3signer() {
  echo "[INFO - entrypoint] Starting Web3Signer..."

  # shellcheck disable=SC2086
  exec /opt/web3signer/bin/web3signer \
    --key-store-path="${KEYFILES_DIR}" \
    --http-listen-port=9000 \
    --http-listen-host=0.0.0.0 \
    --http-host-allowlist="${CORS_ALLOWLIST}" \
    --http-cors-origins="${CORS_ORIGINS}" \
    --metrics-enabled=true \
    --metrics-host 0.0.0.0 \
    --metrics-port 9091 \
    --metrics-host-allowlist="*" \
    --idle-connection-timeout-seconds=900 \
    eth2 \
    --network="${NETWORK}" \
    --slashing-protection-db-url="jdbc:postgresql://postgres.${WEB3SIGNER_DOMAIN}:5432/web3signer" \
    --slashing-protection-db-username=postgres \
    --slashing-protection-db-password=password \
    --slashing-protection-pruning-enabled=true \
    --slashing-protection-pruning-epochs-to-keep=500 \
    --key-manager-api-enabled=true ${EXTRA_OPTS}
}

set_web3signer_pkg_domain
generate_cors_settings
prepare_keyfiles_dir
run_web3signer
