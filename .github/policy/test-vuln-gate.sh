#!/usr/bin/env bash
# Fixture tests for the Keel Dock vulnerable-package gate (keeldock-supply-chain).
#
# The gate library is extracted from the composite and run over `dotnet list package --vulnerable`
# fixtures and exceptions files: clean, unlisted High (fail), listed and in date (honoured), expired
# (fail), malformed (fail), an incomplete scan (fail closed under high/critical, warn under none),
# and no package name in any published detail. Run from the repository root.
set -euo pipefail
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
awk "/cat > .*vuln-gate.sh.* <<'KD_VULN_GATE_LIBRARY'/{on=1; next} /^        KD_VULN_GATE_LIBRARY/{on=0} on" .github/actions/keeldock-supply-chain/action.yml | sed -E 's/^        //' > "${dir}/lib.sh"
[[ -s "${dir}/lib.sh" ]] || { echo 'the vulnerability-gate library was not found' >&2; exit 1; }
# shellcheck disable=SC1091
source "${dir}/lib.sh"

fail() { echo "vuln-gate fixture failed: $*" >&2; exit 1; }
clean_log() { printf 'The given project `A` has no vulnerable packages given the current sources.\n' > "$1"; }
vuln_log() { # file, then "Package Resolved Severity Advisory" rows
  local f="$1"; shift
  { printf 'Project `A` has the following vulnerable packages\n   [net10.0]:\n   Top-level Package      Requested   Resolved   Severity   Advisory URL\n'
    local r; for r in "$@"; do read -r p v s a <<<"${r}"; printf '   > %s     %s   %s   \033[1m%s\033[0m   https://github.com/advisories/%s\n' "${p}" "${v}" "${v}" "${s}" "${a}"; done
  } > "${f}"
}
run() { # gate, log, rc, exceptions-file, today
  vg_parse "$2" > "${dir}/rows.tsv"
  vuln_gate_evaluate "$1" "${dir}/rows.tsv" "$2" "$3" "$4" "$5"
}
expect() { # status, substring of the detail, label
  [[ "${vg_status}" == "$1" ]] || fail "$3: status ${vg_status} (${vg_detail}), wanted $1"
  [[ -z "$2" || "${vg_detail}" == *"$2"* ]] || fail "$3: detail '${vg_detail}' lacks '$2'"
  if [[ "${vg_detail}" == *secretpkg* ]]; then fail "$3: a package name was published"; fi
}
today=2026-10-05

clean_log "${dir}/clean.log"
run high "${dir}/clean.log" 0 "${dir}/absent.txt" "${today}"; expect pass 'none reported' 'clean'

vuln_log "${dir}/high.log" 'Secretpkg.One 1.0.0 High GHSA-aaaa-bbbb-cccc'
run high "${dir}/high.log" 0 "${dir}/absent.txt" "${today}"; expect FAIL 'GHSA-AAAA-BBBB-CCCC' 'unlisted high'
run none "${dir}/high.log" 0 "${dir}/absent.txt" "${today}"; expect warn 'warn-only' 'gate none reports only'
run critical "${dir}/high.log" 0 "${dir}/absent.txt" "${today}"; expect warn '' 'high is below a critical gate'

printf '# reviewed\n\nghsa-aaaa-bbbb-cccc  2026-12-01  # transitive, no fix released, not reachable\n' > "${dir}/ok.txt"
run high "${dir}/high.log" 0 "${dir}/ok.txt" "${today}"; expect warn '1 excepted' 'listed and in date'
run high "${dir}/high.log" 0 "${dir}/ok.txt" 2026-12-01; expect warn '1 excepted' 'honoured on the review-by day'
run high "${dir}/high.log" 0 "${dir}/ok.txt" 2026-12-02; expect FAIL 'exception expired' 'expired the day after'

vuln_log "${dir}/two.log" 'Secretpkg.One 1.0.0 High GHSA-aaaa-bbbb-cccc' 'Secretpkg.Two 2.0.0 Critical CVE-2099-12345' 'Secretpkg.Three 3.0.0 Moderate GHSA-dddd-eeee-ffff'
run high "${dir}/two.log" 0 "${dir}/ok.txt" "${today}"; expect FAIL 'CVE-2099-12345' 'an exception covers only its own id'
[[ "${vg_detail}" == *"1 excepted: GHSA-AAAA-BBBB-CCCC"* ]] || fail "excepted ids are not published: ${vg_detail}"

for bad in 'GHSA-aaaa-bbbb-cccc  2026-12-01' 'GHSA-aaaa-bbbb-cccc  2026-12-01  #' 'GHSA-aaaa-bbbb-cccc  2026-13-01  # month' 'GHSA-aaaa-bbbb-cccc  01/12/2026  # format' 'not-an-id  2026-12-01  # reason' 'GHSA-aaaa-bbbb-cccc # no date'; do
  printf '%s\n' "${bad}" > "${dir}/bad.txt"
  run high "${dir}/clean.log" 0 "${dir}/bad.txt" "${today}"; expect FAIL 'malformed' "malformed entry: ${bad}"
  run high "${dir}/high.log" 0 "${dir}/bad.txt" "${today}"; expect FAIL 'malformed' "malformed entry with a finding: ${bad}"
done
printf 'GHSA-aaaa-bbbb-cccc  2026-12-01  # fine\nnonsense\n' > "${dir}/bad.txt"
run high "${dir}/clean.log" 0 "${dir}/bad.txt" "${today}"; expect FAIL 'line 2' 'one bad line fails the file'

# Fail closed when the scan cannot be trusted; warn only under none.
printf 'error NU1900: Error occurred while getting package vulnerability data\n' > "${dir}/feed.log"
run high "${dir}/feed.log" 0 "${dir}/absent.txt" "${today}"; expect FAIL 'fails closed' 'feed unreachable'
run none "${dir}/feed.log" 0 "${dir}/absent.txt" "${today}"; expect warn 'did not complete' 'feed unreachable, gate none'
run critical "${dir}/clean.log" 1 "${dir}/absent.txt" "${today}"; expect FAIL 'exited 1' 'non-zero exit'
: > "${dir}/empty.log"
run high "${dir}/empty.log" 0 "${dir}/absent.txt" "${today}"; expect FAIL 'no recognisable result' 'empty output'
printf 'Project `A` has the following vulnerable packages\n   weird format\n' > "${dir}/parse.log"
run high "${dir}/parse.log" 0 "${dir}/absent.txt" "${today}"; expect FAIL 'could not be parsed' 'parse error'
echo 'vulnerability gate fixtures passed'
