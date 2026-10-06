#!/usr/bin/env bash
# The reviewed egress allow-list (.github/egress-allowlist.txt): every entry names a known
# scope, a host pattern and a reason after "#". A pattern is a host name in which a leading
# "*." stands for one or more labels and any other "*" for characters within a label; the
# last two labels (the registrable part) must be literal, so "*.com" or "*.net" is refused. The egress-audit
# composite publishes only names that match an entry, so an entry is a decision that the name
# is safe to appear in a public log (and, for Linux block mode, safe to reach).
# Run from the repository root (the policy workflow does).
set -euo pipefail
file=.github/egress-allowlist.txt
[[ -f "${file}" ]] || { echo "${file} is missing" >&2; exit 1; }
scopes='all|linux|macos|windows|android|ios|orchestrate|live'
label='[a-z0-9*]([a-z0-9*-]*[a-z0-9*])?'
literal='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
host="(\\*\\.)?(${label}\\.)*${literal}\\.${literal}"
entries=0
line_no=0
while IFS= read -r line || [[ -n "${line}" ]]; do
  line_no=$((line_no + 1))
  [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]] && continue
  if [[ ! "${line}" =~ ^(${scopes})[[:space:]]+${host}[[:space:]]+#[[:space:]]*[^[:space:]] ]]; then
    echo "${file}:${line_no}: expected '<scope> <host pattern>  # reason': ${line}" >&2
    exit 1
  fi
  entries=$((entries + 1))
done < "${file}"
dupes="$(sed -E 's/#.*//' "${file}" | awk 'NF >= 2 { print $1, $2 }' | sort | uniq -d)"
if [[ -n "${dupes}" ]]; then
  echo "${file}: duplicate entries: ${dupes}" >&2
  exit 1
fi
echo "egress allow-list: ${entries} entries, each with a scope and a reason"
