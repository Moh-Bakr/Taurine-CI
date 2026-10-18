#!/usr/bin/env bash
# Exercise the all-locks advisory helper wiring and its protected reporting with a stub helper.
# The real helper, scanner, Cargo and network are never used. Run from the repository root.
set -euo pipefail
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
export RUNNER_TEMP="${dir}/runner"
mkdir -p "${RUNNER_TEMP}" "${dir}/work/scripts"
export GITHUB_STEP_SUMMARY="${dir}/summary.md"
export CONCERN=contracts OS_LABEL=Linux

# Wiring: the Linux concern requires the helper exactly on a protected SHA (the source-checkout
# answer), and the action's own default stays the strict one. Dropping either weakens the gate.
grep -qF "require-all-locks-audit: \${{ steps.verified-source.outputs.protected-ancestor == 'true' }}" \
  .github/workflows/linux-validation-concern.yml || { echo 'all-locks fixture: the workflow no longer ties the helper to protected ancestry' >&2; exit 1; }
[[ "$(ruby -ryaml -e 'puts YAML.safe_load(File.read(ARGV[0])).dig("inputs", "require-all-locks-audit", "default")' .github/actions/linux-concern-js/action.yml)" == true ]] || { echo 'all-locks fixture: require-all-locks-audit no longer defaults to true' >&2; exit 1; }

ruby .github/policy/extract-step.rb .github/actions/sanitize/action.yml 'Write the sanitizer library' run > "${dir}/sanitize-install.sh"
ruby .github/policy/extract-step.rb .github/actions/concern-report/action.yml 'Write the concern reporting library' run > "${dir}/report-install.sh"
bash "${dir}/sanitize-install.sh"
bash "${dir}/report-install.sh"
ruby .github/policy/extract-step.rb .github/actions/linux-concern-js/action.yml 'Run the JavaScript concern' run > "${dir}/step.sh"

# The real block, between its two reviewed boundary comments. Missing or ambiguous boundaries
# fail closed.
ruby -e '
  text = File.read(ARGV[0])
  first = "# All-locks advisory audit through the reviewed private helper."
  last = "# End of the all-locks advisory audit."
  abort "all-locks fixture: boundaries changed" unless text.scan(first).length == 1 && text.scan(last).length == 1
  start = text.index(first); stop = text.index(last)
  abort "all-locks fixture: boundaries reversed" unless start < stop
  print text[start...stop]
' "${dir}/step.sh" > "${dir}/block.sh"
cat > "${dir}/run.sh" <<'RUN'
set -euo pipefail
source "${RUNNER_TEMP}/taurine-ci/sanitize.sh"
source "${RUNNER_TEMP}/taurine-ci/report.sh"
if [[ "${STUB_INSTALL}" == failed ]]; then deferred_results+=("cargo-audit-install|failed: stub"); deferred_failed=1; fi
source "${STUB_BLOCK}"
finish_deferred
RUN

helper="${dir}/work/scripts/audit-all-locks.sh"
install_helper() {
  cat > "${helper}" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
# Records what the helper was given, then behaves as the case selects. The case comes from a
# file beside it: the helper runs with a cleared environment, so no variable can carry it.
root="$(cd "$(dirname "$0")/.." && pwd)"
mode="$(cat "${root}/.mode")"
{ echo "argc=$#"; echo "scanner=${CARGO_AUDIT_BIN:-unset}"; echo "sentinel=${PRIVATE_ENV_SENTINEL:-unset}"
  echo "token=${GITHUB_TOKEN:-unset}"; } > "${root}/.seen"
echo 'Traceback (most recent call last):'
echo '  File "/private/source/internal.py", line 62, in run'
echo 'crate: PRIVATE_CRATE_SENTINEL; token: ghp_PRIVATE_TOKEN_SENTINEL'
case "${mode}" in
  clean) echo '4 lockfile(s) audited, 0 failed.'; exit 0 ;;
  findings)
    printf 'ID: RUSTSEC-2026-0097\nWarning: unsound\n'
    echo '4 lockfile(s) audited, 1 failed.'
    printf -- '-- failed lock: %q\n' './untracked path/PRIVATE_PATH_SENTINEL/Cargo.lock'
    exit 1 ;;
  silent) exit 0 ;;
  zero) echo '0 lockfile(s) audited, 0 failed.'; exit 0 ;;
  lying) echo '3 lockfile(s) audited, 1 failed.'; exit 0 ;;
  forged) echo 'ID: RUSTSEC-2026-0097'; echo '4 lockfile(s) audited, 0 failed.'; echo '5 lockfile(s) audited, 0 failed.'; exit 0 ;;
esac
exit 64
HELPER
}
audit_bin="${RUNNER_TEMP}/cargo-audit-bin/cargo-audit-x86_64-unknown-linux-gnu-v0.22.2/cargo-audit"

export PRIVATE_ENV_SENTINEL=leak GITHUB_TOKEN=ghs_PRIVATE_ENV_TOKEN
STUB_SEEN="${dir}/work/.seen"
run_case() {
  # run_case BLOCK HELPER_MODE REQUIRE INSTALL
  : > "${GITHUB_STEP_SUMMARY}"; rm -f "${STUB_SEEN}"
  rc=0
  ( cd "${dir}/work"
    printf "%s" "$2" > "${dir}/work/.mode"
    STUB_BLOCK="$1" REQUIRE_ALL_LOCKS_AUDIT="$3" STUB_INSTALL="$4" bash "${dir}/run.sh" ) > "${dir}/out" 2>&1 || rc=$?
}
must() { grep -qF -- "$1" "${dir}/out" || { echo "all-locks fixture: missing expected output: $1" >&2; exit 1; }; }
rc_is() { [[ "${rc}" -eq "$1" ]] || { echo "all-locks fixture: expected exit $1, got ${rc}" >&2; cat "${dir}/out" >&2; return 1; }; }
nothing_private_published() {
  if grep -Eq 'PRIVATE_|/private/source|internal\.py|Traceback|untracked path|ghs_|ghp_' "${dir}/out" "${GITHUB_STEP_SUMMARY}"; then
    echo 'all-locks fixture: private-shaped output escaped protected reporting' >&2; exit 1
  fi
}

install_helper
chmod +x "${helper}"

# 1. Clean helper: passes, count published, helper saw no arguments, the pinned scanner path,
#    and none of the caller's environment.
run_case "${dir}/block.sh" clean true ok
rc_is 0; nothing_private_published
must 'cargo-audit-all-locks: passed'
grep -qF '4 lockfile(s) audited, 0 failed.' "${GITHUB_STEP_SUMMARY}"
grep -qxF 'argc=0' "${STUB_SEEN}"
grep -qxF "scanner=${audit_bin}" "${STUB_SEEN}"
grep -qxF 'sentinel=unset' "${STUB_SEEN}"
grep -qxF 'token=unset' "${STUB_SEEN}"

# 2. A failing helper fails the concern; advisory ids and the count are published, nothing else.
run_case "${dir}/block.sh" findings true ok
rc_is 1; nothing_private_published
must 'cargo-audit-all-locks: failed'
must 'ID: RUSTSEC-2026-0097'
must '4 lockfile(s) audited, 1 failed.'
grep -qF '| `cargo-audit-all-locks` | failed:' "${GITHUB_STEP_SUMMARY}"

# 3. An exit 0 that is not a clean counted pass is a failure (silent, zero locks, a counted failure).
for mode in silent zero lying; do
  run_case "${dir}/block.sh" "${mode}" true ok
  rc_is 1; nothing_private_published
  must 'cargo-audit-all-locks: failed'
done
# A forged extra count line cannot publish anything but the last fixed-shape count.
run_case "${dir}/block.sh" forged true ok
rc_is 0; nothing_private_published
grep -qF '5 lockfile(s) audited, 0 failed.' "${GITHUB_STEP_SUMMARY}"

# 4. Missing helper: required on a protected SHA, a fixed-shape notice otherwise.
rm -f "${helper}"
run_case "${dir}/block.sh" clean true ok
rc_is 1; must 'cargo-audit-all-locks: failed'
run_case "${dir}/block.sh" clean false ok
rc_is 0; must 'helper absent at this unprotected SHA'
grep -qF 'not run: helper absent at an unprotected SHA' "${GITHUB_STEP_SUMMARY}"

# 5. A symlink or a directory at the helper path fails on every ref, and is never followed.
# The marker path is written into the target itself: the helper runs with a cleared environment.
STUB_SYMLINK_RAN="${dir}/symlink-ran"
printf '#!/usr/bin/env bash\ntouch %q\necho "1 lockfile(s) audited, 0 failed."\n' "${STUB_SYMLINK_RAN}" > "${dir}/elsewhere.sh"
ln -s "${dir}/elsewhere.sh" "${helper}"
for req in true false; do
  run_case "${dir}/block.sh" clean "${req}" ok
  rc_is 1; must 'cargo-audit-all-locks: failed'
  [[ ! -e "${STUB_SYMLINK_RAN}" ]]
done
rm -f "${helper}"; mkdir "${helper}"
run_case "${dir}/block.sh" clean false ok
rc_is 1
rmdir "${helper}"

# 6. A scanner that did not install means the helper is not run and the concern fails.
install_helper; chmod +x "${helper}"
run_case "${dir}/block.sh" clean true failed
rc_is 1; [[ ! -e "${STUB_SEEN}" ]]
must 'cargo-audit-all-locks: failed'

# Falsifiers: each re-weakening must be caught by the same assertions.
mutate() {  # mutate OLD NEW OUTFILE
  OLD="$1" NEW="$2" ruby -e 's = File.read(ARGV[0]); abort("falsifier text not found: #{ENV["OLD"]}") unless s.scan(ENV["OLD"]).length == 1; File.write(ARGV[1], s.sub(ENV["OLD"]) { ENV["NEW"] })' "${dir}/block.sh" "$3"
}
expect_caught() {  # expect_caught LABEL BLOCK HELPER REQUIRE EXPECTED_RC
  install_helper; chmod +x "${helper}"
  [[ "$3" == absent ]] && rm -f "${helper}"
  run_case "$2" "${3/absent/clean}" "$4" ok
  if [[ "${rc}" -ne "$5" ]]; then return 0; fi
  echo "all-locks fixture: falsifier not caught: $1" >&2; exit 1
}
mutate 'elif [[ "${REQUIRE_ALL_LOCKS_AUDIT}" == true ]]; then' 'elif [[ "${REQUIRE_ALL_LOCKS_AUDIT}" == never ]]; then' "${dir}/m1.sh"
expect_caught 'a protected SHA may drop the helper' "${dir}/m1.sh" absent true 1
mutate '[[ "${BASH_REMATCH[1]}" -lt 1 || "${BASH_REMATCH[2]}" -ne 0 ]]' 'false' "${dir}/m2.sh"
expect_caught 'a counted failure or zero locks passes' "${dir}/m2.sh" lying true 1
mutate 'env -i PATH="${PATH}" HOME="${HOME}" LANG=C.UTF-8 TMPDIR="${RUNNER_TEMP}" \' 'env PATH="${PATH}" \' "${dir}/m3.sh"
install_helper; chmod +x "${helper}"; run_case "${dir}/m3.sh" clean true ok
if grep -qxF 'sentinel=unset' "${STUB_SEEN}"; then echo 'all-locks fixture: env falsifier not caught' >&2; exit 1; fi
mutate '-L "${all_locks_helper}" || ' '' "${dir}/m4.sh"
ln -sf "${dir}/elsewhere.sh" "${helper}.link" && rm -f "${helper}" && mv "${helper}.link" "${helper}"
run_case "${dir}/m4.sh" clean true ok
[[ -e "${STUB_SYMLINK_RAN}" ]] || { echo 'all-locks fixture: symlink falsifier not caught' >&2; exit 1; }
echo 'all-locks fixtures: protected-required, unprivileged env, counts-only reporting, fail-closed results and four falsifiers PASS'
