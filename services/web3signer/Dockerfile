ARG WEB3SIGNER_VERSION

# Reads the Postgres system identifier with the JDBC driver bundled with Web3Signer (see slashing-protection.sh)
FROM --platform=$BUILDPLATFORM eclipse-temurin:21.0.13.1_2-jdk-alpine AS pg-system-identifier
COPY PgSystemIdentifier.java /src/
RUN javac --release 17 -d /out /src/PgSystemIdentifier.java

FROM consensys/web3signer:$WEB3SIGNER_VERSION

ARG NETWORK
ARG STAKER_SCRIPTS_VERSION
ARG PGPASSWORD
ARG POSTGRES_DB
ARG POSTGRES_USER

USER root

RUN apt-get update && apt-get install --yes --no-install-recommends ca-certificates && apt-get clean

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY slashing-protection.sh /usr/local/bin/slashing-protection
COPY --from=pg-system-identifier /out/PgSystemIdentifier.class /opt/dappnode/

ENV STAKER_SCRIPTS_URL=https://github.com/dappnode/staker-package-scripts/releases/download/${STAKER_SCRIPTS_VERSION}

ADD ${STAKER_SCRIPTS_URL}/common_tools.sh /etc/profile.d/

RUN chmod +rx /usr/local/bin/entrypoint.sh /usr/local/bin/slashing-protection /etc/profile.d/common_tools.sh

# This env changes the variant
# Placed at the end to regenerate the least amount of layers
ENV NETWORK=${NETWORK} \
    PGPASSWORD=${PGPASSWORD} \
    POSTGRES_DB=${POSTGRES_DB} \
    POSTGRES_USER=${POSTGRES_USER}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
