#!/usr/bin/env bash
# Test the cargo-deny step of the scan composite against a stub cargo-deny
#
# cargo-deny's exit status is a bitmask of the failed checks (advisories 1, bans 2, licences 4,
# sources 8). The reviewed step is run as written, with a stub binary that prints fixture
# diagnostics and returns a chosen status, and its messages and counts are asserted: a failed check
# is reported as a failed check (never as "did not complete"), each policy error is counted once,
# and a status that is not a mask, or that no diagnostic explains, still fails closed.
# Run from the repository root.
set -euo pipefail

root="${PWD}"
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
step='Check Rust advisories and dependency policy with cargo-deny'
action=.github/actions/scan-concern/action.yml
export RUNNER_TEMP="${dir}/runner"
mkdir -p "${RUNNER_TEMP}/taurine-ci" "${RUNNER_TEMP}/scan-bin" "${dir}/work"
awk "/cat > .*sanitize.sh.* <<'TCI_SANITIZE_LIBRARY'/{on=1; next} /^        TCI_SANITIZE_LIBRARY/{on=0} on" .github/actions/sanitize/action.yml | sed -E 's/^        //' > "${RUNNER_TEMP}/taurine-ci/sanitize.sh"
[[ -s "${RUNNER_TEMP}/taurine-ci/sanitize.sh" ]] || { echo 'the sanitize library was not found' >&2; exit 1; }
ruby .github/policy/extract-step.rb "${action}" "${step}" run > "${dir}/step.sh"
[[ -s "${dir}/step.sh" ]] || { echo 'the cargo-deny step was not found' >&2; exit 1; }

cat > "${RUNNER_TEMP}/scan-bin/cargo-deny" <<'STUB'
#!/usr/bin/env bash
# Advisories run: STUB_ADV_STATUS. Policy run (bans licenses sources): STUB_POL_STATUS and the
# fixture lines in STUB_POL_FILE, written to stderr as cargo-deny does.
if [[ " $* " == *' advisories'* ]]; then exit "${STUB_ADV_STATUS:-0}"; fi
[[ -z "${STUB_POL_FILE:-}" ]] || cat "${STUB_POL_FILE}" >&2
exit "${STUB_POL_STATUS:-0}"
STUB
chmod +x "${RUNNER_TEMP}/scan-bin/cargo-deny"
: > "${dir}/work/deny.toml"; : > "${dir}/work/Cargo.toml"

err() { printf '{"type":"diagnostic","fields":{"code":"%s","severity":"error","graphs":[{"Krate":{"name":"%s","version":"1.0.0"}}]}}\n' "$1" "$2"; }

# run_case NAME STATUS FIXTURE-FILE POLICY-FAIL: the step's stdout+stderr in out.txt, its status in rc.
run_case() {
  : > "${dir}/summary.md"
  rc=0
  ( cd "${dir}/work"
    GITHUB_STEP_SUMMARY="${dir}/summary.md" DENY_POLICY_FAIL="$4" STUB_POL_STATUS="$2" STUB_POL_FILE="$3" \
      bash "${dir}/step.sh" ) > "${dir}/out.txt" 2>&1 || rc=$?
}
must() { grep -qF -- "$2" "${dir}/out.txt" || { echo "case '$1': expected '$2' in the step output:" >&2; cat "${dir}/out.txt" >&2; exit 1; }; }
must_not() { if grep -qF -- "$2" "${dir}/out.txt"; then echo "case '$1': unexpected '$2' in the step output:" >&2; cat "${dir}/out.txt" >&2; exit 1; fi; }
rc_is() { [[ "${rc}" -eq "$2" ]] || { echo "case '$1': exit ${rc}, expected $2" >&2; cat "${dir}/out.txt" >&2; exit 1; }; }

: > "${dir}/empty.jsonl"
err banned secretcrate > "${dir}/one.jsonl"
{ err banned a; err banned b; } > "${dir}/two.jsonl"
{ err banned a; err rejected b; } > "${dir}/mixed.jsonl"
printf '{"type":"log","fields":{"level":"ERROR","message":"failed to load deny.toml"}}\n' > "${dir}/toolerr.jsonl"

run_case clean 0 "${dir}/empty.jsonl" true
rc_is clean 0; must clean '0 dependency policy error(s)'; must_not clean 'did not complete'; must_not clean 'failed checks'

# Exit 2 is the bans bit: a failed check, one error, not "did not complete".
run_case bans 2 "${dir}/one.jsonl" true
rc_is bans 1
must bans 'failed checks (exit 2): bans'; must_not bans 'did not complete'; must bans '1 dependency policy error(s)'
must bans 'exit 2, 1 error(s)'

# Several diagnostics are counted once each, with nothing added for the status.
run_case bans-two 2 "${dir}/two.jsonl" true
rc_is bans-two 1; must bans-two '2 dependency policy error(s)'; must_not bans-two '3 dependency policy error(s)'

# A combined mask names every failed check.
run_case bans-licences 6 "${dir}/mixed.jsonl" true
rc_is bans-licences 1; must bans-licences 'failed checks (exit 6): bans, licences'; must bans-licences '2 dependency policy error(s)'
run_case sources 8 "${dir}/one.jsonl" true
must sources 'failed checks (exit 8): sources'

# A failed mask with no readable diagnostic still fails closed, as one error.
run_case bans-silent 2 "${dir}/empty.jsonl" true
rc_is bans-silent 1; must bans-silent 'failed checks (exit 2): bans'; must bans-silent '1 dependency policy error(s)'

# Exit 1 is not a policy mask (the advisories bit is not part of this run): the tool failed.
run_case tool-error 1 "${dir}/toolerr.jsonl" true
rc_is tool-error 1; must tool-error 'did not complete (exit 1)'; must tool-error 'failed to load deny.toml'; must tool-error '1 dependency policy error(s)'
run_case out-of-range 101 "${dir}/empty.jsonl" true
rc_is out-of-range 1; must out-of-range 'did not complete (exit 101)'; must out-of-range '1 dependency policy error(s)'

# Report-only mode records the same counts but does not fail the step.
run_case report-only 2 "${dir}/one.jsonl" false
rc_is report-only 0; must report-only '1 dependency policy error(s) (report only)'; must report-only 'failed checks (exit 2): bans'

# The published table row carries the error count once.
run_case table 2 "${dir}/two.jsonl" true
grep -qF '| lock #1 | 0 | 2 | 0 |' "${dir}/summary.md" || { echo 'the summary table row does not show 2 policy errors' >&2; cat "${dir}/summary.md" >&2; exit 1; }

# The crate name never reaches the published output.
must_not table secretcrate
run_case leak 2 "${dir}/one.jsonl" true
must_not leak secretcrate

echo 'scan-deny tests: exit codes map to the right messages and counts'
