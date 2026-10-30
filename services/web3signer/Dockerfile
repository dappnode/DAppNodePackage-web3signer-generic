ARG WEB3SIGNER_VERSION

FROM alpine:3.24 AS ca-trust
RUN apk add --no-cache 'ca-certificates>=20261020' 'ca-certificates-bundle>=20261020'

FROM ca-trust AS java-ca-helper
RUN apk add --no-cache openjdk21-jdk
COPY RemoveDistrustedRoots.java /tmp/
RUN mkdir -p /opt/ca-trust && javac --release 11 -d /opt/ca-trust /tmp/RemoveDistrustedRoots.java

FROM consensys/web3signer:$WEB3SIGNER_VERSION

ARG NETWORK
ARG STAKER_SCRIPTS_VERSION
ARG PGPASSWORD
ARG POSTGRES_DB
ARG POSTGRES_USER

USER root

RUN apt-get update && apt-get install --yes --no-install-recommends ca-certificates && apt-get clean

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

ENV STAKER_SCRIPTS_URL=https://github.com/dappnode/staker-package-scripts/releases/download/${STAKER_SCRIPTS_VERSION}

ADD ${STAKER_SCRIPTS_URL}/common_tools.sh /etc/profile.d/

RUN chmod +rx /usr/local/bin/entrypoint.sh /etc/profile.d/common_tools.sh

# This env changes the variant
# Placed at the end to regenerate the least amount of layers
ENV NETWORK=${NETWORK} \
    PGPASSWORD=${PGPASSWORD} \
    POSTGRES_DB=${POSTGRES_DB} \
    POSTGRES_USER=${POSTGRES_USER}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Refresh all OS trust files, then clean Java's independent default keystore.
RUN rm -rf /etc/ssl/certs /usr/share/ca-certificates
COPY --from=ca-trust /etc/ssl/certs/ /etc/ssl/certs/
COPY --from=ca-trust /usr/share/ca-certificates/ /usr/share/ca-certificates/
COPY --from=ca-trust /etc/ca-certificates.conf /etc/ca-certificates.conf
RUN ln -sf certs/ca-certificates.crt /etc/ssl/cert.pem
COPY --from=java-ca-helper /opt/ca-trust/ /tmp/ca-trust/
RUN java -cp /tmp/ca-trust RemoveDistrustedRoots && rm -rf /tmp/ca-trust
