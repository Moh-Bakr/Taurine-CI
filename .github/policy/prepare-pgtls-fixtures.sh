#!/usr/bin/env bash
# Create fixed, synthetic PostgreSQL TLS fixtures for the protected live arms.
# This script accepts no caller-controlled arguments or source-tree paths.
set -euo pipefail
umask 077

fail() {
  echo "pgtls fixtures: $1" >&2
  exit 1
}

[[ $# -eq 0 ]] || fail 'arguments are not accepted'
[[ -n "${RUNNER_TEMP:-}" && -d "${RUNNER_TEMP}" ]] || fail 'runner temp is unavailable'
[[ -n "${GITHUB_WORKSPACE:-}" && -d "${GITHUB_WORKSPACE}" ]] || fail 'control workspace is unavailable'

runner_temp="$(cd -- "${RUNNER_TEMP}" && pwd -P)"
source_root="$(cd -- "${GITHUB_WORKSPACE}/src" 2>/dev/null && pwd -P)" || fail 'source root is unavailable'
case "${runner_temp}/" in
  "${source_root}/"*) fail 'runner temp resolves inside the source checkout' ;;
esac

lab="$(mktemp -d "${runner_temp}/taurine-pgtls-fixtures.XXXXXXXX")" || fail 'cannot create fixture directory'
lab="$(cd -- "${lab}" && pwd -P)"
case "${lab}/" in
  "${source_root}/"*) fail 'fixture directory resolves inside the source checkout' ;;
esac
chmod 700 "${lab}"

cat > "${lab}/server.ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:pg.taurine.test
EXT
cat > "${lab}/client.ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EXT
cat > "${lab}/pg_hba.conf" <<'PG_HBA'
local all all trust
hostssl payments taurine 172.16.0.0/12 scram-sha-256 clientcert=verify-full
host all all 0.0.0.0/0 reject
host all all ::/0 reject
PG_HBA
chmod 644 "${lab}/server.ext" "${lab}/client.ext" "${lab}/pg_hba.conf"

# Keys and certificates are generated locally on the ephemeral hosted runner.
# Silence OpenSSL diagnostics: no key material or source-provided values are
# allowed into workflow logs.
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -subj '/CN=Taurine protected live fixture CA' \
  -keyout "${lab}/ca.key" -out "${lab}/ca.crt" >/dev/null 2>&1 || fail 'trusted CA generation failed'
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -subj '/CN=Taurine protected rogue fixture CA' \
  -keyout "${lab}/rogue-ca.key" -out "${lab}/rogue-ca.crt" >/dev/null 2>&1 || fail 'rogue CA generation failed'

openssl req -new -newkey rsa:2048 -nodes -sha256 \
  -subj '/CN=pg.taurine.test' -keyout "${lab}/server.key" \
  -out "${lab}/server.csr" >/dev/null 2>&1 || fail 'server key generation failed'
openssl x509 -req -sha256 -days 2 -in "${lab}/server.csr" \
  -CA "${lab}/ca.crt" -CAkey "${lab}/ca.key" -CAcreateserial \
  -extfile "${lab}/server.ext" -out "${lab}/server.crt" >/dev/null 2>&1 || fail 'server certificate generation failed'

openssl req -new -newkey rsa:2048 -nodes -sha256 \
  -subj '/CN=taurine' -keyout "${lab}/client.key" \
  -out "${lab}/client.csr" >/dev/null 2>&1 || fail 'trusted client key generation failed'
openssl x509 -req -sha256 -days 2 -in "${lab}/client.csr" \
  -CA "${lab}/ca.crt" -CAkey "${lab}/ca.key" -CAcreateserial \
  -extfile "${lab}/client.ext" -out "${lab}/client.crt" >/dev/null 2>&1 || fail 'trusted client certificate generation failed'

openssl req -new -newkey rsa:2048 -nodes -sha256 \
  -subj '/CN=taurine' -keyout "${lab}/untrusted-client.key" \
  -out "${lab}/untrusted-client.csr" >/dev/null 2>&1 || fail 'untrusted client key generation failed'
openssl x509 -req -sha256 -days 2 -in "${lab}/untrusted-client.csr" \
  -CA "${lab}/rogue-ca.crt" -CAkey "${lab}/rogue-ca.key" -CAcreateserial \
  -extfile "${lab}/client.ext" -out "${lab}/untrusted-client.crt" >/dev/null 2>&1 || fail 'untrusted client certificate generation failed'

# Validate certificate purpose, identity, chain and key pairing without ever
# printing certificate or private-key contents.
openssl verify -purpose sslserver -CAfile "${lab}/ca.crt" "${lab}/server.crt" >/dev/null 2>&1 || fail 'server certificate validation failed'
openssl x509 -in "${lab}/server.crt" -noout -checkhost pg.taurine.test >/dev/null 2>&1 || fail 'server SAN validation failed'
openssl verify -purpose sslclient -CAfile "${lab}/ca.crt" "${lab}/client.crt" >/dev/null 2>&1 || fail 'trusted client certificate validation failed'
client_subject="$(openssl x509 -in "${lab}/client.crt" -noout -subject -nameopt RFC2253 2>/dev/null | tr -d '\r')" || fail 'trusted client subject validation failed'
[[ "${client_subject}" == 'subject=CN=taurine' ]] || fail 'trusted client certificate subject is invalid'
if openssl verify -purpose sslclient -CAfile "${lab}/ca.crt" "${lab}/untrusted-client.crt" >/dev/null 2>&1; then
  fail 'untrusted client unexpectedly chains to the trusted CA'
fi
openssl verify -purpose sslclient -CAfile "${lab}/rogue-ca.crt" "${lab}/untrusted-client.crt" >/dev/null 2>&1 || fail 'rogue client fixture validation failed'
untrusted_subject="$(openssl x509 -in "${lab}/untrusted-client.crt" -noout -subject -nameopt RFC2253 2>/dev/null | tr -d '\r')" || fail 'untrusted client subject validation failed'
[[ "${untrusted_subject}" == 'subject=CN=taurine' ]] || fail 'untrusted client certificate subject is invalid'
for pair in server client untrusted-client; do
  openssl pkey -in "${lab}/${pair}.key" -pubout -outform DER -out "${lab}/${pair}.key-public.der" >/dev/null 2>&1 || fail 'private-key validation failed'
  openssl x509 -in "${lab}/${pair}.crt" -pubkey -noout > "${lab}/${pair}.cert-public.pem" 2>/dev/null || fail 'certificate public-key extraction failed'
  openssl pkey -pubin -in "${lab}/${pair}.cert-public.pem" -outform DER -out "${lab}/${pair}.cert-public.der" >/dev/null 2>&1 || fail 'certificate public-key validation failed'
  cmp -s "${lab}/${pair}.key-public.der" "${lab}/${pair}.cert-public.der" || fail 'certificate and private key do not match'
  rm -f "${lab}/${pair}.key-public.der" "${lab}/${pair}.cert-public.pem" "${lab}/${pair}.cert-public.der"
done

chmod 600 "${lab}/"*.key
chmod 644 "${lab}/"*.crt
chmod 700 "${lab}"
for file in ca.crt rogue-ca.crt server.crt server.key client.crt client.key untrusted-client.crt untrusted-client.key pg_hba.conf; do
  [[ -s "${lab}/${file}" ]] || fail 'required fixture is missing'
done

# Drop signing keys, CSRs, serials and extension work files once the fixed
# certificate set is validated. The hosted runner owns this temporary lab.
rm -f "${lab}/ca.key" "${lab}/ca.srl" "${lab}/rogue-ca.key" "${lab}/rogue-ca.srl" \
  "${lab}/server.csr" "${lab}/client.csr" "${lab}/untrusted-client.csr" \
  "${lab}/server.ext" "${lab}/client.ext"

# Containers receive only the files the server needs. Client keys and CA
# signing keys remain on the runner for the test process or are never mounted.
mkdir -m 755 "${lab}/container"
cp "${lab}/server.crt" "${lab}/server.key" "${lab}/ca.crt" "${lab}/pg_hba.conf" "${lab}/container/"
chmod 644 "${lab}/container/server.crt" "${lab}/container/ca.crt" "${lab}/container/pg_hba.conf"
chmod 600 "${lab}/container/server.key"
printf '%s\n' "${lab}"
