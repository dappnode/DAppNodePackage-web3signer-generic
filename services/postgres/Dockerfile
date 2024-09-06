FROM alpine:3.15.10 as migrations-download
ARG WEB3SIGNER_VERSION
WORKDIR /usr/src/app

# Copy files in branch ${WEB3SIGNER_VERSION} from web3signer repository
RUN apk --no-cache add git && \
    git clone --depth 1 --branch ${WEB3SIGNER_VERSION} https://github.com/ConsenSys/web3signer.git

#FROM postgres:14.1-alpine3.15

FROM postgres:14.1-bullseye

ARG POSTGRES_PASSWORD
ARG PGPASSWORD
ARG POSTGRES_DB
ARG POSTGRES_USER

ENV POSTGRES_PASSWORD=${POSTGRES_PASSWORD} \
    PGPASSWORD=${PGPASSWORD} \
    POSTGRES_USER=${POSTGRES_USER} \
    POSTGRES_DB=${POSTGRES_DB} \
    INITDB_DIR=/docker-entrypoint-initdb.d/

COPY rename_files.sh /usr/local/bin/rename_files.sh
#COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --from=migrations-download /usr/src/app/web3signer/slashing-protection/src/main/resources/migrations/postgresql/* ${INITDB_DIR}

# RUN apk --no-cache add sudo && \
#     adduser postgres root && \
#     echo "postgres ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

#RUN chmod +x /usr/local/bin/rename_files.sh /usr/local/bin/entrypoint.sh && /usr/local/bin/rename_files.sh

RUN chmod +x /usr/local/bin/rename_files.sh && /usr/local/bin/rename_files.sh

USER postgres

#ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
CMD [ "postgres" ]