#!/bin/sh
set -eu
JAVA_HOME=${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}

# Exercise both supported keystore formats with synthetic roots and unrelated aliases.
for format in JKS PKCS12; do
  store="/tmp/roots-${format}"
  keytool -importkeystore -srckeystore "$JAVA_HOME/lib/security/cacerts" \
    -srcstorepass changeit -destkeystore "$store" -deststorepass changeit \
    -deststoretype "$format" -noprompt >/dev/null 2>&1
  i=0
  for cn in 'emSign ECC Root CA - G3' 'AAA Certificate Services' \
    'emSign Root CA - G1' 'emSign Root CA - G2' 'Security test retained root'; do
    keytool -genkeypair -alias "fixture-$i" -dname "CN=$cn" -keyalg RSA -keysize 2048 \
      -validity 1 -keystore "$store" -storepass changeit -keypass changeit \
      -noprompt >/dev/null 2>&1
    i=$((i + 1))
  done
  java -cp /opt/ca-trust RemoveDistrustedRoots "$store"
  for i in 0 1 2 3; do
    if keytool -list -alias "fixture-$i" -keystore "$store" -storepass changeit >/dev/null 2>&1; then
      echo "Distrusted fixture-$i survived in $format" >&2
      exit 1
    fi
  done
  keytool -list -alias fixture-4 -keystore "$store" -storepass changeit >/dev/null
  java -cp /opt/ca-trust RemoveDistrustedRoots "$store" | grep -Fx 'Removed distrusted Java roots: 0'
done

# An implausibly small keystore must fail instead of silently accepting a broken bundle.
keytool -genkeypair -alias retained -dname 'CN=Security test retained root' -keyalg RSA \
  -keysize 2048 -validity 1 -keystore /tmp/small-store -storepass changeit \
  -keypass changeit -noprompt >/dev/null 2>&1
if java -cp /opt/ca-trust RemoveDistrustedRoots /tmp/small-store; then
  echo 'Unexpectedly small trust store was accepted' >&2
  exit 1
fi
