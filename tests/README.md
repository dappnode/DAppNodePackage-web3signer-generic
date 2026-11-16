# Runtime security validation

The security update retains Web3Signer 26.10.2 and Brain 0.1.33. It rebuilds
Validator Tracker 0.1.5 from commit `1c2c8076710bfc59e4958d226130ecc191a4222c`
with Go 1.27.3, upgrades Flyway's Java runtime to Temurin 21.0.13+9, refreshes
the three affected services' OS trust files, and removes the four roots listed
in [Oracle's current mitigation](https://ops.java/emudhra) from both Java stores.
The main signer's existing Java 25.0.5+8 runtime is retained.

Run from the repository root with Docker Compose v2, Python 3 and OpenSSL:

```sh
python3 tests/security.py
```

This builds the three changed services for the mainnet variant and checks:

- All four variants' Compose configuration.
- The compiled Tracker Go version and its default `GODEBUG=multipathtcp=0`.
- OS certificate bundles against the incident's three blocked public-key hashes.
- Java runtime versions and all four distrusted root names in the actual default stores.
- JKS and PKCS12 cleanup with unrelated aliases, preservation of an unrelated root,
  idempotency, and rejection of an implausibly small trust store.
- Tracker initialization against a mock beacon and successful initialization after restart.
- The real signer health/public-key APIs with an empty key directory, before and after restart.
- Fresh slashing-protection migrations on PostgreSQL 14 and a repeated no-op migration.

Application fixtures run on a disposable internal Docker network without published
ports, production volumes, validator keys or external notification endpoints. Test
containers and their anonymous volumes are removed on exit. Builds download public
dependencies. The signer smoke test disables slashing protection only for its empty-key
API fixture; it is separate from the Flyway/database migration test and does not prove
full production signer/database integration or an existing database upgrade.

CI runs these checks on native amd64 and ARM64 runners. To reuse images already built
with a specific Compose project name:

```sh
python3 tests/security.py --project web3signer-security --skip-build
```

Update `TRACKER_COMMIT` alongside `TRACKER_VERSION` for future upstream bumps. The Go
setting changes the default for new sockets and can be overridden by application code
or operator-supplied environment. It reduces MPTCP exposure; **CVE-2026-98432 still needs
a patched host kernel**. Docker's daemon-owned DNS sockets require separate host/daemon
mitigation. No host sysctl, Docker daemon, PostgreSQL data format or package version is
changed by this PR.
