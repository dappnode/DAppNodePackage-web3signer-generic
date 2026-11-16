FROM alpine:3.24 AS ca-trust
RUN apk add --no-cache 'ca-certificates>=20261020' 'ca-certificates-bundle>=20261020'

FROM ca-trust AS java-ca-helper
RUN apk add --no-cache openjdk21-jdk
COPY RemoveDistrustedRoots.java /tmp/
RUN mkdir -p /opt/ca-trust && javac --release 11 -d /opt/ca-trust /tmp/RemoveDistrustedRoots.java

FROM ca-trust AS migrations-download
ARG WEB3SIGNER_VERSION
WORKDIR /usr/src/app

# Copy files in branch ${WEB3SIGNER_VERSION} from web3signer repository
RUN apk --no-cache add git && \
    git clone --depth 1 --branch ${WEB3SIGNER_VERSION} https://github.com/ConsenSys/web3signer.git

FROM ca-trust AS patched-java
ARG TARGETARCH
RUN apk add --no-cache curl
RUN case "${TARGETARCH}" in \
        amd64) url="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_x64_alpine-linux_hotspot_21.0.13_9.tar.gz"; sha="9138eab0f7d230e17163953f015ec9ae2431dbc49069c658b7f991e45b54fb9b" ;; \
        arm64) url="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_aarch64_alpine-linux_hotspot_21.0.13_9.tar.gz"; sha="382633eb2ba28cc5b97be1446eb1dd8d2a60a3795be0166a030e4cda338c490e" ;; \
        *) echo "Unsupported Java architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    curl --fail --location --retry 3 "$url" -o /tmp/jre.tar.gz && \
    echo "$sha  /tmp/jre.tar.gz" | sha256sum -c - && \
    mkdir /jre && tar -xzf /tmp/jre.tar.gz --strip-components=1 -C /jre && \
    rm /tmp/jre.tar.gz

FROM flyway/flyway:11.10-alpine
USER root
RUN rm -rf /opt/java/openjdk
COPY --from=patched-java /jre/ /opt/java/openjdk/
ENV JAVA_HOME=/opt/java/openjdk JAVA_VERSION=jre-21.0.13+9
ENV PATH="${JAVA_HOME}/bin:${PATH}"


ARG NETWORK
ARG PGPASSWORD
ARG POSTGRES_DB
ARG POSTGRES_USER


ENV MIGRATIONS_DIR=/flyway/sql \
    NETWORK=${NETWORK} \
    PGPASSWORD=${PGPASSWORD} \
    POSTGRES_DB=${POSTGRES_DB} \
    POSTGRES_USER=${POSTGRES_USER}

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh && rm -rf /flyway/sql/*

COPY --from=migrations-download /usr/src/app/web3signer/slashing-protection/src/main/resources/migrations/postgresql/* ${MIGRATIONS_DIR}/

RUN apk update && apk --no-cache add postgresql-client

ENTRYPOINT ["entrypoint.sh"]

# Refresh all OS trust files, then clean Java's independent default keystore.
RUN rm -rf /etc/ssl/certs /usr/share/ca-certificates
COPY --from=ca-trust /etc/ssl/certs/ /etc/ssl/certs/
COPY --from=ca-trust /usr/share/ca-certificates/ /usr/share/ca-certificates/
COPY --from=ca-trust /etc/ca-certificates.conf /etc/ca-certificates.conf
RUN ln -sf certs/ca-certificates.crt /etc/ssl/cert.pem
COPY --from=java-ca-helper /opt/ca-trust/ /tmp/ca-trust/
RUN java -cp /tmp/ca-trust RemoveDistrustedRoots && rm -rf /tmp/ca-trust
