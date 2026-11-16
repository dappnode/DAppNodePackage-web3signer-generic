ARG TRACKER_VERSION

FROM golang:1.27.3-alpine3.24 AS patched-go
ARG TRACKER_VERSION
# Update this pin together with TRACKER_VERSION.
ARG TRACKER_COMMIT=1c2c8076710bfc59e4958d226130ecc191a4222c
ENV GOTOOLCHAIN=local GOMAXPROCS=2 GOFLAGS=-p=2 GOMEMLIMIT=1500MiB
RUN apk add --no-cache git 'ca-certificates>=20261020'
WORKDIR /src
RUN git clone --depth 1 --branch "${TRACKER_VERSION}" https://github.com/dappnode/validator-tracker.git . && \
    test "$(git rev-parse HEAD)" = "${TRACKER_COMMIT}"
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 go build -trimpath -o /out/validator-tracker ./cmd/main.go

FROM alpine:3.24 AS ca-trust
RUN apk add --no-cache 'ca-certificates>=20261020' 'ca-certificates-bundle>=20261020'

FROM ghcr.io/dappnode/validator-tracker:${TRACKER_VERSION}
COPY --from=patched-go /out/validator-tracker /app/validator-tracker
RUN rm -rf /etc/ssl/certs /usr/share/ca-certificates
COPY --from=ca-trust /etc/ssl/certs/ /etc/ssl/certs/
COPY --from=ca-trust /usr/share/ca-certificates/ /usr/share/ca-certificates/
COPY --from=ca-trust /etc/ca-certificates.conf /etc/ca-certificates.conf
RUN ln -sf certs/ca-certificates.crt /etc/ssl/cert.pem

ARG NETWORK
# Ordinary TCP remains available; the host still needs its kernel security update.
ENV NETWORK=${NETWORK} GODEBUG=multipathtcp=0
