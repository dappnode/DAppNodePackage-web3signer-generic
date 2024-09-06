FROM alpine:3.15.10 as migrations-download
ARG WEB3SIGNER_VERSION
WORKDIR /usr/src/app

# Copy files in branch ${WEB3SIGNER_VERSION} from web3signer repository
RUN apk --no-cache add git && \
    git clone --depth 1 --branch ${WEB3SIGNER_VERSION} https://github.com/ConsenSys/web3signer.git

FROM flyway/flyway:9.16.1-alpine

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
