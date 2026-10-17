#!/usr/bin/env bash
# Exercise the public audit sweep and protected reporter with synthetic locks only.
# No private helper, real scanner, Cargo, source tests or network access is used.
set -euo pipefail
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
export RUNNER_TEMP="${dir}/runner"
mkdir -p "${RUNNER_TEMP}" "${dir}/work" "${dir}/bin"

# These control-owned steps only write the two libraries. Use their real functions
# so a direct-output regression cannot pass behind a stub run_deferred.
ruby .github/policy/extract-step.rb .github/actions/sanitize/action.yml \
  'Write the sanitizer library' run > "${dir}/sanitize-install.sh"
ruby .github/policy/extract-step.rb .github/actions/concern-report/action.yml \
  'Write the concern reporting library' run > "${dir}/report-install.sh"
bash "${dir}/sanitize-install.sh"
bash "${dir}/report-install.sh"
ruby .github/policy/extract-step.rb .github/actions/linux-concern-js/action.yml \
  'Run the JavaScript concern' run > "${dir}/step.sh"

# Keep the actual install-result guard and whole sweep, excluding unrelated app
# checks and the network installer. Missing or ambiguous boundaries fail closed.
ruby -e '
  text = File.read(ARGV[0])
  first = "# Accepted advisories are recorded in exactly one place:"
  last = "# Unused dependencies (cargo-machete):"
  abort "audit fixture: sweep boundaries changed" unless text.scan(first).length == 1 && text.scan(last).length == 1
  start = text.index(first)
  stop = text.index(last)
  abort "audit fixture: sweep boundaries reversed" unless start < stop
  print text[start...stop]
' "${dir}/step.sh" > "${dir}/sweep.sh"
cat > "${dir}/run.sh" <<'RUN'
set -euo pipefail
source "${RUNNER_TEMP}/taurine-ci/sanitize.sh"
source "${RUNNER_TEMP}/taurine-ci/report.sh"
run_deferred cargo-audit-install bash -c 'exit "${STUB_INSTALL_STATUS}"'
source "${STUB_SWEEP}"
finish_deferred
RUN

audit_bin="${RUNNER_TEMP}/cargo-audit-bin/cargo-audit-x86_64-unknown-linux-gnu-v0.22.2/cargo-audit"
mkdir -p "$(dirname "${audit_bin}")"
cat > "${audit_bin}" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
deny=0
if [[ "$#" -eq 5 && "$1" == audit && "$2" == --deny && "$3" == unsound && "$4" == --file ]]; then
  deny=1; lock="$5"
elif [[ "$#" -eq 3 && "$1" == audit && "$2" == --file ]]; then
  # Model the old scanner's warning-only behavior for the missing-flag falsifier.
  lock="$3"
else
  echo 'audit fixture: unexpected argv' >&2
  exit 64
fi
printf '%s|%s\n' "${lock}" "${deny}" >> "${STUB_CALLS}"
# Deliberately private-shaped output: none of these markers may be public.
echo 'Traceback (most recent call last):'
echo '  File "/private/source/internal.py", line 62, in run'
echo '    PRIVATE_SOURCE_SENTINEL()'
echo 'crate: PRIVATE_CRATE_SENTINEL; token: ghp_PRIVATE_TOKEN_SENTINEL'
case "${STUB_AUDIT_MODE}" in
  clean) exit 0 ;;
  unmaintained) echo 'Warning: unmaintained'; exit 0 ;;
  scanner-error) echo 'audit fixture: scanner failed' >&2; exit 70 ;;
  unsound|nonfatal)
    if [[ "$(cat "${lock}")" == affected ]]; then
      echo 'ID: RUSTSEC-2026-0097'
      echo 'Warning: unsound'
      if [[ "${deny}" -eq 1 && "${STUB_AUDIT_MODE}" != nonfatal ]]; then exit 1; fi
    fi
    exit 0 ;;
  *) exit 64 ;;
esac
STUB
chmod +x "${audit_bin}"

# A PATH or option-string decoy must not select a different executable or append
# arguments. These env names are fixture probes, not supported wrapper inputs.
cat > "${dir}/bin/cargo-audit" <<'DECOY'
#!/usr/bin/env bash
touch "${STUB_DECOY}"
exit 0
DECOY
chmod +x "${dir}/bin/cargo-audit"
export PATH="${dir}/bin:${PATH}"
export CARGO_AUDIT_BIN="${dir}/bin/cargo-audit"
export CARGO_AUDIT_ARGS='--ignore RUSTSEC-2026-0097'
export AUDIT_ARGS='--ignore RUSTSEC-2026-0097'
export AUDIT_DENY=notice
export STUB_DECOY="${dir}/decoy-used"
export STUB_CALLS="${dir}/calls"
export GITHUB_STEP_SUMMARY="${dir}/summary.md"
export CONCERN=contracts OS_LABEL=Linux

odd='untracked ; $(touch ARG_INJECTION)'
mkdir -p "${dir}/work/ignored" "${dir}/work/patched" "${dir}/work/${odd}" \
  "${dir}/work/target" "${dir}/work/node_modules"
printf 'affected\n' > "${dir}/work/Cargo.lock"
printf 'affected\n' > "${dir}/work/ignored/Cargo.lock"
printf 'patched\n' > "${dir}/work/patched/Cargo.lock"
printf 'patched\n' > "${dir}/work/${odd}/Cargo.lock"
printf 'affected\n' > "${dir}/work/target/Cargo.lock"
printf 'affected\n' > "${dir}/work/node_modules/Cargo.lock"
printf 'ignored/\ntarget/\nnode_modules/\n' > "${dir}/work/.gitignore"
git -C "${dir}/work" init -q
git -C "${dir}/work" add .gitignore Cargo.lock patched/Cargo.lock
git -C "${dir}/work" check-ignore -q ignored/Cargo.lock
[[ -z "$(git -C "${dir}/work" ls-files -- "${odd}/Cargo.lock")" ]]
printf './Cargo.lock|1\n./ignored/Cargo.lock|1\n./patched/Cargo.lock|1\n./%s/Cargo.lock|1\n' \
  "${odd}" | LC_ALL=C sort > "${dir}/expected-calls"

run_case() {
  local mode="$1" sweep="$2" install="$3"
  : > "${STUB_CALLS}"
  : > "${GITHUB_STEP_SUMMARY}"
  rc=0
  ( cd "${dir}/work"
    STUB_AUDIT_MODE="${mode}" STUB_SWEEP="${sweep}" STUB_INSTALL_STATUS="${install}" \
      bash "${dir}/run.sh" ) > "${dir}/out" 2>&1 || rc=$?
}
must() { grep -qF -- "$1" "${dir}/out" || { echo "audit fixture: missing expected output: $1" >&2; exit 1; }; }
rc_is() { [[ "${rc}" -eq "$1" ]] || { echo "audit fixture: expected exit $1, got ${rc}" >&2; return 1; }; }
private_output_is_withheld() {
  if grep -Eq 'PRIVATE_|/private/source|internal\.py|Traceback|ARG_INJECTION|untracked ;' \
      "${dir}/out" "${GITHUB_STEP_SUMMARY}"; then
    echo 'audit fixture: private-shaped output escaped protected reporting' >&2
    exit 1
  fi
  [[ ! -e "${STUB_DECOY}" && ! -e "${dir}/work/ARG_INJECTION" ]] || {
    echo 'audit fixture: environment or lock path selected a command' >&2; exit 1;
  }
}
all_locks_scanned() {
  LC_ALL=C sort "${STUB_CALLS}" > "${dir}/actual-calls"
  cmp -s "${dir}/expected-calls" "${dir}/actual-calls" || {
    echo 'audit fixture: exact argv or all-lock scan changed' >&2; exit 1;
  }
}

run_case clean "${dir}/sweep.sh" 0
rc_is 0; all_locks_scanned; private_output_is_withheld
must 'cargo-audit: passed'
run_case unmaintained "${dir}/sweep.sh" 0
rc_is 0; all_locks_scanned; private_output_is_withheld

# Both affected locks fail; the patched locks still run afterwards. The actual
# reporter/aggregator must propagate failure, without publishing raw scanner text.
run_case unsound "${dir}/sweep.sh" 0
rc_is 1; all_locks_scanned; private_output_is_withheld
must 'cargo-audit: failed'
must 'ID: RUSTSEC-2026-0097'
must 'Warning: unsound'
[[ "$(grep -c '^ID: RUSTSEC-2026-0097$' "${dir}/out")" -eq 2 ]]
grep -qF '| `cargo-audit` | failed:' "${GITHUB_STEP_SUMMARY}"
grep -qF 'error: unaccepted advisory findings in lock #1' "${RUNNER_TEMP}/cargo-audit.log"
grep -qF 'error: unaccepted advisory findings in lock #2' "${RUNNER_TEMP}/cargo-audit.log"
grep -qF 'cargo-audit: lock #4: passed' "${RUNNER_TEMP}/cargo-audit.log"

run_case scanner-error "${dir}/sweep.sh" 0
rc_is 1; all_locks_scanned; private_output_is_withheld
run_case clean "${dir}/sweep.sh" 1
rc_is 1; private_output_is_withheld
[[ ! -s "${STUB_CALLS}" ]]
must 'cargo-audit-install: failed'
must 'cargo-audit: failed'

# Falsify the same required unsound-failure assertion. A missing flag makes the
# old warning-only scanner pass; a nonfatal unsound result must also fail this
# fixture. This does not purport to validate a real scanner's implementation.
ruby -e '
  text = File.read(ARGV[0])
  abort "audit fixture: missing literal deny flag" unless text.scan("audit --deny unsound --file").length == 1
  print text.sub("audit --deny unsound --file", "audit --file")
' "${dir}/sweep.sh" > "${dir}/no-deny.sh"
run_case unsound "${dir}/no-deny.sh" 0
rc_is 0
if rc_is 1 > "${dir}/falsifier" 2>&1; then
  echo 'audit fixture: missing-flag falsifier unexpectedly passed' >&2; exit 1
fi
private_output_is_withheld
run_case nonfatal "${dir}/sweep.sh" 0
rc_is 0
all_locks_scanned
if rc_is 1 > "${dir}/falsifier" 2>&1; then
  echo 'audit fixture: nonfatal-unsound falsifier unexpectedly passed' >&2; exit 1
fi
private_output_is_withheld
echo 'cargo-audit fixtures: explicit deny, all locks, protected reporting and both falsifiers PASS'
