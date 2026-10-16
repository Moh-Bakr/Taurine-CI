#!/usr/bin/env bash
# The weekly run's openssl-src patch cadence: the develop tip only warns, while a uat or main tip
# fails closed when its lock is behind the newest 300.5.x, off the 300.5 line, past the 3.5 LTS end
# (2030-04-08), unresolved, unfetchable, or when crates.io answers nothing. The reviewed
# openssl_cadence function is extracted from the workflow and run on fixed inputs. Run from the
# repository root.
set -euo pipefail
fail() { echo "weekly cadence fixtures: $*" >&2; exit 1; }
cadence="$(ruby -ryaml -e '
  doc = YAML.safe_load(File.read(".github/workflows/weekly-validation.yml"), aliases: false)
  run = doc["jobs"]["dispatch"]["steps"].map { |s| s["run"].to_s }.join("\n")
  puts run[/^openssl_cadence\(\) \{\n.*?^\}\n/m] || abort("openssl_cadence not found")')"
check_cadence() {
  local want="$1" latest="$2" list="$3" fail_flag="$4" note
  note="$(OPENSSL_LTS_END=2030-04-08 latest="${latest}" bash -c "${cadence}"$'\n''openssl_cadence uat "$1" "$2"' _ "${list}" "${fail_flag}" 2>/dev/null)"
  case "${want}" in
    fails) [[ "${note}" == *'fails this run'* ]] || fail "cadence passed: latest='${latest}' list='${list}' fail=${fail_flag}: ${note}" ;;
    passes) [[ "${note}" != *'fails this run'* ]] || fail "cadence failed: latest='${latest}' list='${list}' fail=${fail_flag}: ${note}" ;;
  esac
}
check_cadence passes 300.5.5+3.5.5 300.5.5+3.5.5 true
check_cadence fails 300.5.6+3.5.6 300.5.5+3.5.5 true
check_cadence fails '' 300.5.5+3.5.5 true
check_cadence fails 300.5.5+3.5.5 '' true
check_cadence fails 300.5.5+3.5.5 tip-unresolved true
check_cadence fails 300.5.5+3.5.5 fetch-failed,300.5.5+3.5.5 true
check_cadence fails 300.5.5+3.5.5 300.3.1+3.3.1 true
check_cadence passes '' '' false
check_cadence passes 300.5.6+3.5.6 300.5.5+3.5.5 false
echo 'weekly cadence fixtures: the release line fails closed and develop only warns'
