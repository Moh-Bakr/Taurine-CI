#!/usr/bin/env bash
# The rustfmt step of rust-lint-enforce must fail the job on a difference as shipped (no caller
# input), independently of the clippy `fail` input. Runs the reviewed step itself against a stub
# cargo, then re-runs the same assertions against three re-weakened copies, each of which must be
# rejected. No private source, Rust toolchain or network is used. Run from the repository root.
set -euo pipefail
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
mkdir -p "${dir}/bin" "${dir}/work/src"
export RUNNER_TEMP="${dir}/runner"
mkdir -p "${RUNNER_TEMP}"
export GITHUB_STEP_SUMMARY="${dir}/summary.md"
export GITHUB_WORKSPACE="${dir}/work"

step='Check formatting with cargo fmt'
# The stub reports one rustfmt hunk (with a private-shaped path) or none, as selected.
cat > "${dir}/bin/cargo" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == fmt ]] || exit 64
if [[ "${STUB_FMT}" == diff ]]; then
  echo 'Diff in /private/source/PRIVATE_SENTINEL.rs:3:'
  echo '-    let   x = 1;'
  exit 1
fi
exit 0
STUB
chmod +x "${dir}/bin/cargo"

# check ACTION_FILE: 0 when the shipped step fails on a difference and passes when clean.
check() {
  local action="$1" fail_default fmt_default env_file
  fmt_default="$(ruby -ryaml -e 'puts YAML.safe_load(File.read(ARGV[0])).dig("inputs", "fmt-fail", "default")' "${action}")"
  fail_default="$(ruby -ryaml -e 'puts YAML.safe_load(File.read(ARGV[0])).dig("inputs", "fail", "default")' "${action}")"
  printf '{"${{ github.workspace }}/${{ inputs.path }}": "x", "${{ inputs.fmt-fail }}": "%s", "${{ inputs.fail }}": "%s"}\n' \
    "${fmt_default}" "${fail_default}" > "${dir}/map.json"
  ruby .github/policy/extract-step.rb "${action}" "${step}" run > "${dir}/step.sh" || return 1
  env_file="${dir}/step.env"
  ruby .github/policy/extract-step.rb "${action}" "${step}" env "${dir}/map.json" > "${env_file}" || return 1
  local rc=0
  # The step's own environment, exactly as the action wires it: FAIL comes from the input
  # the action names, so a swapped input is seen here.
  ( cd "${dir}/work/src"
    set -a; . "${env_file}"; set +a
    PATH="${dir}/bin:${PATH}" STUB_FMT=diff bash "${dir}/step.sh" ) > "${dir}/out" 2>&1 || rc=$?
  [[ "${rc}" -eq 1 ]] || { echo "fmt difference exited ${rc}, not 1" >&2; return 1; }
  grep -qF 'fmt: 1 file(s) differ' "${dir}/out" || { echo 'fmt difference not reported' >&2; return 1; }
  if grep -q 'PRIVATE_SENTINEL\|/private/source' "${dir}/out" "${GITHUB_STEP_SUMMARY}"; then
    echo 'a path or diff body from the source was published' >&2; return 1
  fi
  rc=0
  ( cd "${dir}/work/src"
    set -a; . "${env_file}"; set +a
    PATH="${dir}/bin:${PATH}" STUB_FMT=clean bash "${dir}/step.sh" ) > "${dir}/out" 2>&1 || rc=$?
  [[ "${rc}" -eq 0 ]] && grep -qF 'fmt: passed' "${dir}/out" || { echo 'clean tree did not pass' >&2; return 1; }
  # An empty value must enforce too (only the exact string false relaxes).
  rc=0
  ( cd "${dir}/work/src"
    set -a; . "${env_file}"; set +a
    FAIL='' PATH="${dir}/bin:${PATH}" STUB_FMT=diff bash "${dir}/step.sh" ) > "${dir}/out" 2>&1 || rc=$?
  [[ "${rc}" -eq 1 ]] || { echo 'an empty FAIL did not enforce' >&2; return 1; }
  # Clippy stays report-only by default: the clippy input must not have been flipped here.
  [[ "${fail_default}" == false ]] || { echo 'the clippy fail default changed without clippy evidence' >&2; return 1; }
}

action=.github/actions/rust-lint-enforce/action.yml
check "${action}"
# The fmt step may be switched to report-only explicitly, never by default.
ruby .github/policy/extract-step.rb "${action}" "${step}" run > "${dir}/step.sh"
( cd "${dir}/work/src"; PATH="${dir}/bin:${PATH}" STUB_FMT=diff FAIL=false bash "${dir}/step.sh" ) >/dev/null 2>&1
# No caller (workflow or composite) overrides fmt-fail, other than the action's own file.
if grep -rn 'fmt-fail' .github/workflows .github/actions | grep -v '^.github/actions/rust-lint-enforce/action.yml:' | grep -qv 'fmt-fail: true'; then
  echo 'a caller overrides fmt-fail' >&2; exit 1
fi
# Only the exact string false relaxes: an empty or odd value enforces, in both steps.
for v in '' 'False' 'no'; do
  rc=0
  ( cd "${dir}/work/src"; PATH="${dir}/bin:${PATH}" STUB_FMT=diff FAIL="${v}" bash "${dir}/step.sh" ) >/dev/null 2>&1 || rc=$?
  [[ "${rc}" -eq 1 ]] || { echo "fmt value '${v}' did not enforce" >&2; exit 1; }
done

falsify() {
  local label="$1" old="$2" new="$3"
  OLD="${old}" NEW="${new}" ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("falsifier text not found: #{ENV["OLD"]}"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[1], s)' "${action}" "${dir}/mutant.yml"
  if check "${dir}/mutant.yml" >/dev/null 2>&1; then
    echo "lint-enforce fixture: the falsifier was not rejected: ${label}" >&2; exit 1
  fi
}
falsify 'fmt-fail default flipped back to report-only' "    default: 'true'" "    default: 'false'"
falsify 'fmt step reads the clippy input' 'FAIL: ${{ inputs.fmt-fail }}' 'FAIL: ${{ inputs.fail }}'
falsify 'fmt difference never exits non-zero' '          [[ "${FAIL}" != false ]] || exit 0
          exit 1' '          exit 0'
falsify 'an empty value relaxes fmt' '          [[ "${FAIL}" != false ]] || exit 0
          exit 1' '          [[ "${FAIL}" == true ]] || exit 0
          exit 1'
echo 'lint-enforce fixtures: rustfmt fails by default, independent of clippy, and three re-weakenings are rejected PASS'
