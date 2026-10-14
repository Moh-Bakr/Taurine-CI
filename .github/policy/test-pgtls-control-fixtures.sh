#!/usr/bin/env bash
# Source-free checks for the control-owned PostgreSQL TLS fixture contract.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

generator="${root}/.github/policy/prepare-pgtls-fixtures.sh"
entrypoint="${root}/.github/policy/pgtls-postgres-entrypoint.sh"
action="${root}/.github/actions/live-start-pg/action.yml"
[[ -s "${generator}" && -s "${entrypoint}" ]] || { echo 'pgtls control fixture files are missing' >&2; exit 1; }
bash -n "${generator}"
sh -n "${entrypoint}"
if sh "${entrypoint}" unsupported >/dev/null 2>&1 || sh "${entrypoint}" pgtls extra >/dev/null 2>&1; then
  echo 'container entrypoint accepted an unreviewed profile or extra argument' >&2; exit 1
fi
grep -Fq 'pgtls|mtls|tls10|tls11|rsakex)' "${entrypoint}"
mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

mkdir -p "${work}/workspace/src" "${work}/runner-temp" "${work}/fakebin"
cat > "${work}/fakebin/openssl" <<'FAKE_OPENSSL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "${FAKE_OPENSSL_LOG}"
subcommand="$1"
shift
case "${subcommand}" in
  req)
    key=''
    out=''
    while (($#)); do
      case "$1" in
        -keyout) key="$2"; shift 2 ;;
        -out) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -n "${key}" && -n "${out}" ]]
    printf 'synthetic-test-key\n' > "${key}"
    printf 'synthetic-test-request-or-certificate\n' > "${out}"
    ;;
  x509)
    if [[ " $* " == *' -pubkey '* ]]; then
      printf 'synthetic-public-key\n'
    elif [[ " $* " == *' -subject '* ]]; then
      printf 'subject=CN=taurine\n'
    elif [[ " $* " != *' -checkhost '* ]]; then
      out=''
      while (($#)); do
        case "$1" in
          -out) out="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      [[ -n "${out}" ]]
      printf 'synthetic-test-certificate\n' > "${out}"
    fi
    ;;
  verify)
    if [[ "$*" == *untrusted-client.crt* ]]; then
      [[ "$*" == *rogue-ca.crt* ]]
    fi
    ;;
  pkey)
    out=''
    while (($#)); do
      case "$1" in
        -out) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ -n "${out}" ]]; then
      printf 'synthetic-public-key\n' > "${out}"
    else
      printf 'synthetic-public-key\n'
    fi
    ;;
  dgst)
    printf 'SHA256(stdin)= fixture-public-key\n'
    ;;
  *) exit 2 ;;
esac
FAKE_OPENSSL
chmod +x "${work}/fakebin/openssl"

fixture_log="${work}/openssl.log"
runner_real="$(cd "${work}/runner-temp" && pwd -P)"
lab="$(env GITHUB_WORKSPACE="${work}/workspace" RUNNER_TEMP="${work}/runner-temp" \
  FAKE_OPENSSL_LOG="${fixture_log}" PATH="${work}/fakebin:${PATH}" bash "${generator}")"
[[ "${lab}" == "${runner_real}"/taurine-pgtls-fixtures.* && -d "${lab}" ]] || {
  echo 'fixture generator did not return an owned runner-temp directory' >&2; exit 1;
}
[[ "${lab}" != "${work}/workspace/src"/* ]] || { echo 'fixture generator wrote under source checkout' >&2; exit 1; }
[[ "$(mode_of "${lab}")" == 700 ]] || {
  echo 'fixture directory permissions are not 0700' >&2; exit 1;
}
for key in server.key client.key untrusted-client.key; do
  [[ -s "${lab}/${key}" ]] || { echo "missing generated key ${key}" >&2; exit 1; }
  [[ "$(mode_of "${lab}/${key}")" == 600 ]] || {
    echo 'generated private key permissions are not 0600' >&2; exit 1;
  }
done
for cert in ca.crt rogue-ca.crt server.crt client.crt untrusted-client.crt; do
  [[ -s "${lab}/${cert}" ]] || { echo "missing generated certificate ${cert}" >&2; exit 1; }
  [[ "$(mode_of "${lab}/${cert}")" == 644 ]] || {
    echo 'generated certificate permissions are not 0644' >&2; exit 1;
  }
done
grep -Fq 'subjectAltName=DNS:pg.taurine.test' "${generator}"
grep -Fq 'extendedKeyUsage=serverAuth' "${generator}"
grep -Fq 'extendedKeyUsage=clientAuth' "${generator}"
grep -Fq 'CN=taurine' "${generator}"
grep -Fq 'CN=pg.taurine.test' "${generator}"
grep -Fq 'hostssl payments taurine 172.16.0.0/12 scram-sha-256 clientcert=verify-full' "${lab}/pg_hba.conf"
root_files="$(for path in "${lab}"/*; do [[ -f "${path}" ]] && basename "${path}"; done | sort | paste -sd ' ' -)"
[[ "${root_files}" == 'ca.crt client.crt client.key pg_hba.conf rogue-ca.crt server.crt server.key untrusted-client.crt untrusted-client.key' ]] || {
  echo 'fixture lab contains an unexpected or missing top-level file' >&2; exit 1;
}
container_files="$(for path in "${lab}/container"/*; do [[ -f "${path}" ]] && basename "${path}"; done | sort | paste -sd ' ' -)"
[[ "${container_files}" == 'ca.crt pg_hba.conf server.crt server.key' ]] || {
  echo 'container mount includes unexpected fixture files' >&2; exit 1;
}
[[ "$(mode_of "${lab}/container")" == 755 && "$(mode_of "${lab}/container/server.key")" == 600 ]] || {
  echo 'container fixture permissions are not least-privilege' >&2; exit 1;
}
! grep -Eiq 'BEGIN (RSA|OPENSSH|EC|PRIVATE) KEY|synthetic-test-key' "${lab}"/*.crt

if env GITHUB_WORKSPACE="${work}/workspace" RUNNER_TEMP="${work}/runner-temp" \
  FAKE_OPENSSL_LOG="${fixture_log}" PATH="${work}/fakebin:${PATH}" bash "${generator}" unreviewed >/dev/null 2>&1; then
  echo 'fixture generator accepted caller-controlled arguments' >&2; exit 1
fi
before="$(wc -l < "${fixture_log}")"
mkdir -p "${work}/workspace/src/tmp"
source_reject="$(env GITHUB_WORKSPACE="${work}/workspace" RUNNER_TEMP="${work}/workspace/src/tmp" \
  FAKE_OPENSSL_LOG="${fixture_log}" PATH="${work}/fakebin:${PATH}" bash "${generator}" 2>&1 || true)"
[[ "${source_reject}" == 'pgtls fixtures: runner temp resolves inside the source checkout' ]] || {
  echo 'fixture generator did not issue its fixed source-checkout containment refusal' >&2; exit 1;
}
ln -s "${work}/workspace/src/tmp" "${work}/source-temp-link"
symlink_reject="$(env GITHUB_WORKSPACE="${work}/workspace" RUNNER_TEMP="${work}/source-temp-link" \
  FAKE_OPENSSL_LOG="${fixture_log}" PATH="${work}/fakebin:${PATH}" bash "${generator}" 2>&1 || true)"
[[ "${symlink_reject}" == 'pgtls fixtures: runner temp resolves inside the source checkout' ]] || {
  echo 'fixture generator did not reject a source-checkout temp symlink' >&2; exit 1;
}
after="$(wc -l < "${fixture_log}")"
[[ "${before}" == "${after}" ]] || { echo 'fixture generator ran OpenSSL after rejecting source path or symlink' >&2; exit 1; }

ruby -ryaml -e '
  doc = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
  run = doc.fetch("runs").fetch("steps").find { |step| step["name"] == "Start the postgres, pgtls, tls-legacy, bastion server and wait for readiness" }.fetch("run")
  File.write(ARGV.fetch(1), run)
' "${action}" "${work}/start.sh"
awk '/^[[:space:]]*pgtls\)/,/^[[:space:]]*;;/' "${work}/start.sh" > "${work}/pgtls.sh"
awk '/^[[:space:]]*tls-legacy\)/,/^[[:space:]]*;;/' "${work}/start.sh" > "${work}/legacy.sh"
for arm in pgtls legacy; do
  if grep -E 'src/tools/db-lab/pgtls|generate\.sh|/pgtls-src|/entrypoint\.sh' "${work}/${arm}.sh"; then
    echo "${arm} arm refers to a private source fixture or entrypoint" >&2; exit 1
  fi
  grep -Fq '${GITHUB_WORKSPACE}/.github/policy/prepare-pgtls-fixtures.sh' "${work}/${arm}.sh"
  grep -Fq '${GITHUB_WORKSPACE}/.github/policy/pgtls-postgres-entrypoint.sh' "${work}/${arm}.sh"
  grep -Fq '"${lab}/container:/pgtls-fixtures:ro"' "${work}/${arm}.sh"
done
grep -Fq '/control-entrypoint.sh mtls' "${work}/pgtls.sh"
grep -Fq '/control-entrypoint.sh tls10' "${work}/legacy.sh"
grep -Fq '/control-entrypoint.sh tls11' "${work}/legacy.sh"
grep -Fq '/control-entrypoint.sh rsakex' "${work}/legacy.sh"
grep -Fq '15433:5432' "${work}/pgtls.sh"
grep -Fq '15438:5432' "${work}/pgtls.sh"
grep -Fq '15435:5432' "${work}/legacy.sh"
grep -Fq '15436:5432' "${work}/legacy.sh"
grep -Fq '15437:5432' "${work}/legacy.sh"
grep -Fq 'ssl_min_protocol_version=TLSv1' "${entrypoint}"
grep -Fq 'ssl_max_protocol_version=TLSv1' "${entrypoint}"
grep -Fq 'install -o postgres -g postgres -m 0600' "${entrypoint}"
grep -Fq 'exec /usr/local/bin/docker-entrypoint.sh postgres' "${entrypoint}"

# Execute the exact fixed-profile argv-selection case with a fake official
# entrypoint boundary. The real container command receives these same values.
{
  printf '%s\n' '#!/bin/sh' 'set -eu' 'profile=$1' 'dest=/var/lib/postgresql/certs' 'shift'
  awk '
    /^case "\$profile" in$/ { seen++; if (seen == 2) capture=1 }
    capture { print }
    capture && /^esac$/ { exit }
  ' "${entrypoint}"
  printf '%s\n' 'printf "%s\\n" "$@"'
} > "${work}/profile-argv.sh"
expect_profile() {
  local profile="$1" expected="$2" actual
  actual="$(sh "${work}/profile-argv.sh" "${profile}")"
  [[ "${actual}" == "${expected}" ]] || { echo "fixed ${profile} container argv changed" >&2; exit 1; }
}
expect_profile pgtls "$(printf '%s\n' -c ssl=on -c ssl_cert_file=/var/lib/postgresql/certs/server.crt -c ssl_key_file=/var/lib/postgresql/certs/server.key)"
expect_profile mtls "$(printf '%s\n' -c ssl=on -c ssl_cert_file=/var/lib/postgresql/certs/server.crt -c ssl_key_file=/var/lib/postgresql/certs/server.key -c ssl_ca_file=/var/lib/postgresql/certs/ca.crt -c hba_file=/var/lib/postgresql/certs/pg_hba.conf)"
expect_profile tls10 "$(printf '%s\n' -c ssl=on -c ssl_cert_file=/var/lib/postgresql/certs/server.crt -c ssl_key_file=/var/lib/postgresql/certs/server.key -c ssl_min_protocol_version=TLSv1 -c ssl_max_protocol_version=TLSv1 -c ssl_ciphers=DEFAULT@SECLEVEL=0)"
expect_profile tls11 "$(printf '%s\n' -c ssl=on -c ssl_cert_file=/var/lib/postgresql/certs/server.crt -c ssl_key_file=/var/lib/postgresql/certs/server.key -c ssl_min_protocol_version=TLSv1.1 -c ssl_max_protocol_version=TLSv1.1 -c ssl_ciphers=DEFAULT@SECLEVEL=0)"
expect_profile rsakex "$(printf '%s\n' -c ssl=on -c ssl_cert_file=/var/lib/postgresql/certs/server.crt -c ssl_key_file=/var/lib/postgresql/certs/server.key -c ssl_min_protocol_version=TLSv1.2 -c ssl_max_protocol_version=TLSv1.2 -c ssl_ciphers=AES128-GCM-SHA256:AES256-GCM-SHA384)"
mutation_changes_profile() {
  local profile="$1" expected="$2" before="$3" after="$4" actual
  ruby -e 'source=File.read(ARGV.fetch(0)); before=ARGV.fetch(1); after=ARGV.fetch(2); abort "mutation input absent" unless source.sub!(before, after); File.write(ARGV.fetch(3), source)' \
    "${work}/profile-argv.sh" "${before}" "${after}" "${work}/mutated-profile-argv.sh"
  actual="$(sh "${work}/mutated-profile-argv.sh" "${profile}")"
  [[ "${actual}" != "${expected}" ]] || { echo 'protocol profile mutation escaped the fixed-argv fixture' >&2; exit 1; }
}
tls10_expected="$(printf '%s\n' -c ssl=on -c ssl_cert_file=/var/lib/postgresql/certs/server.crt -c ssl_key_file=/var/lib/postgresql/certs/server.key -c ssl_min_protocol_version=TLSv1 -c ssl_max_protocol_version=TLSv1 -c ssl_ciphers=DEFAULT@SECLEVEL=0)"
tls11_expected="$(printf '%s\n' -c ssl=on -c ssl_cert_file=/var/lib/postgresql/certs/server.crt -c ssl_key_file=/var/lib/postgresql/certs/server.key -c ssl_min_protocol_version=TLSv1.1 -c ssl_max_protocol_version=TLSv1.1 -c ssl_ciphers=DEFAULT@SECLEVEL=0)"
rsakex_expected="$(printf '%s\n' -c ssl=on -c ssl_cert_file=/var/lib/postgresql/certs/server.crt -c ssl_key_file=/var/lib/postgresql/certs/server.key -c ssl_min_protocol_version=TLSv1.2 -c ssl_max_protocol_version=TLSv1.2 -c ssl_ciphers=AES128-GCM-SHA256:AES256-GCM-SHA384)"
mutation_changes_profile tls10 "${tls10_expected}" 'ssl_min_protocol_version=TLSv1 ' 'ssl_min_protocol_version=TLSv1.1 '
mutation_changes_profile tls10 "${tls10_expected}" 'ssl_max_protocol_version=TLSv1 ' 'ssl_max_protocol_version=TLSv1.1 '
mutation_changes_profile tls10 "${tls10_expected}" 'ssl_ciphers=DEFAULT@SECLEVEL=0' 'ssl_ciphers=DEFAULT@SECLEVEL=1'
mutation_changes_profile tls11 "${tls11_expected}" 'ssl_min_protocol_version=TLSv1.1 ' 'ssl_min_protocol_version=TLSv1.2 '
mutation_changes_profile tls11 "${tls11_expected}" 'ssl_max_protocol_version=TLSv1.1 ' 'ssl_max_protocol_version=TLSv1.2 '
mutation_changes_profile rsakex "${rsakex_expected}" 'ssl_min_protocol_version=TLSv1.2 ' 'ssl_min_protocol_version=TLSv1.1 '
mutation_changes_profile rsakex "${rsakex_expected}" 'ssl_max_protocol_version=TLSv1.2 ' 'ssl_max_protocol_version=TLSv1.1 '
mutation_changes_profile rsakex "${rsakex_expected}" 'AES128-GCM-SHA256:AES256-GCM-SHA384' 'ECDHE-RSA-AES128-GCM-SHA256'

printf 'Control-owned TLS fixtures and pgtls/tls-legacy source isolation checks passed.\n'
