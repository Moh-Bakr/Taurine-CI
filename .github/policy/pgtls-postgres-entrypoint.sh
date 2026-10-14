#!/bin/sh
# Fixed control-owned entrypoint: install the mounted synthetic server
# material with PostgreSQL ownership, then hand off to the pinned official
# image entrypoint. This script accepts only the fixed postgres -c arguments
# supplied by live-start-pg/action.yml.
set -eu

if [ "$#" -ne 1 ]; then
  echo 'pgtls entrypoint: unsupported command' >&2
  exit 2
fi
profile=$1
case "$profile" in
  pgtls|mtls|tls10|tls11|rsakex) ;;
  *) echo 'pgtls entrypoint: unsupported profile' >&2; exit 2 ;;
esac

fixture=/pgtls-fixtures
dest=/var/lib/postgresql/certs
for file in server.crt server.key; do
  [ -s "$fixture/$file" ] || { echo 'pgtls entrypoint: required server material is absent' >&2; exit 1; }
done
if [ "$profile" = mtls ]; then
  for file in ca.crt pg_hba.conf; do
    [ -s "$fixture/$file" ] || { echo 'pgtls entrypoint: required mTLS material is absent' >&2; exit 1; }
  done
fi
install -d -o postgres -g postgres -m 0700 "$dest"
install -o postgres -g postgres -m 0644 "$fixture/server.crt" "$dest/server.crt"
install -o postgres -g postgres -m 0600 "$fixture/server.key" "$dest/server.key"
if [ -f "$fixture/ca.crt" ]; then
  install -o postgres -g postgres -m 0644 "$fixture/ca.crt" "$dest/ca.crt"
fi
if [ -f "$fixture/pg_hba.conf" ]; then
  install -o postgres -g postgres -m 0644 "$fixture/pg_hba.conf" "$dest/pg_hba.conf"
fi
case "$profile" in
  pgtls) set -- -c ssl=on -c "ssl_cert_file=$dest/server.crt" -c "ssl_key_file=$dest/server.key" ;;
  mtls) set -- -c ssl=on -c "ssl_cert_file=$dest/server.crt" -c "ssl_key_file=$dest/server.key" -c "ssl_ca_file=$dest/ca.crt" -c "hba_file=$dest/pg_hba.conf" ;;
  tls10) set -- -c ssl=on -c "ssl_cert_file=$dest/server.crt" -c "ssl_key_file=$dest/server.key" -c ssl_min_protocol_version=TLSv1 -c ssl_max_protocol_version=TLSv1 -c 'ssl_ciphers=DEFAULT@SECLEVEL=0' ;;
  tls11) set -- -c ssl=on -c "ssl_cert_file=$dest/server.crt" -c "ssl_key_file=$dest/server.key" -c ssl_min_protocol_version=TLSv1.1 -c ssl_max_protocol_version=TLSv1.1 -c 'ssl_ciphers=DEFAULT@SECLEVEL=0' ;;
  rsakex) set -- -c ssl=on -c "ssl_cert_file=$dest/server.crt" -c "ssl_key_file=$dest/server.key" -c ssl_min_protocol_version=TLSv1.2 -c ssl_max_protocol_version=TLSv1.2 -c 'ssl_ciphers=AES128-GCM-SHA256:AES256-GCM-SHA384' ;;
esac
exec /usr/local/bin/docker-entrypoint.sh postgres "$@"
