#!/usr/bin/env bash
# The base-policy step must not be steerable by environment that an earlier step of the job wrote to
# GITHUB_ENV or GITHUB_PATH. This extracts the reviewed step itself, runs it over fixture base
# scripts that all reject, and shows the step still rejects when RUBYOPT/RUBYLIB/BASH_ENV and a PATH
# shim have been planted to make every process exit 0. A second run over scripts that inspect their
# own environment shows the scrub removes the planted variables and keeps what the base policy needs.
# Run from the repository root. Usage: test-base-policy-env.sh [workflow-file]
#
# Emulating the runner: the step's `shell:` is read from the workflow and run the way the runner runs
# it, the string split on spaces into one command with `{0}` replaced by the script file, started
# with the planted PATH so a bare `bash` resolves through it. The runner's own process setup is not
# reproduced (it is not available here); only the command it executes is.
set -euo pipefail

workflow="${1:-.github/workflows/validate-public-changes.yml}"
step="Run the base commit's policy against this pull request"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/base-policy-env-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
root="${PWD}"

ruby "${root}/.github/policy/extract-step.rb" "${workflow}" "${step}" run > "${work}/step.sh"
step_shell="$(ruby -ryaml -e '
  doc = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  found = doc.fetch("jobs").values.flat_map { |job| job.fetch("steps").select { |s| s["name"] == ARGV[1] } }
  abort "expected one step" unless found.length == 1
  print found.first.fetch("shell")
' "${workflow}" "${step}")"
[[ -n "${step_shell}" ]] || { echo "base-policy environment: the step declares no shell" >&2; exit 1; }
# The runner turns the named shell `bash` into this command; any other value is used as written.
[[ "${step_shell}" != bash ]] || step_shell='bash --noprofile --norc -eo pipefail {0}'

# What a hostile earlier step could have planted: every process it affects exits 0, the step's own
# shell included.
poison="${work}/poison"
mkdir -p "${poison}/shim"
printf 'at_exit { exit!(0) }\n' > "${poison}/poison.rb"
printf 'exit 0\n' > "${poison}/poison.sh"
printf '#!/bin/sh\nexit 0\n' > "${poison}/shim/ruby"
for name in bash cp rm mv mkdir diff; do cp "${poison}/shim/ruby" "${poison}/shim/${name}"; done
chmod +x "${poison}/shim/"*
# Run if the shell evaluates PS4 under an imported SHELLOPTS=xtrace: proof that planted code ran.
xtrace_marker="${work}/xtrace-code-ran"

# A fresh tree per run: the base policy checked out beside a pull request tree.
fixture() {
  local dir="$1"
  rm -rf "${dir}"
  mkdir -p "${dir}/tree/base-policy/.github/policy" "${dir}/tree/.github/policy" "${dir}/runner"
  printf '%s\n' "${dir}/tree"
}

reject_scripts() {
  local policy="$1/base-policy/.github/policy"
  for name in check-reject.rb test-reject.rb; do printf 'exit 1\n' > "${policy}/${name}"; done
  for name in check-reject.sh test-reject.sh lint.sh; do printf 'exit 1\n' > "${policy}/${name}"; done
}

witness_scripts() {
  local policy="$1/base-policy/.github/policy"
  cat > "${policy}/check-env.sh" <<'SH'
set -u
[[ "${PATH}" == /usr/bin:/bin:/usr/sbin:/sbin ]] || { echo "PATH is ${PATH}" >&2; exit 1; }
for name in RUBYOPT RUBYLIB BASH_ENV ENV GITHUB_ENV GITHUB_PATH LD_PRELOAD DYLD_INSERT_LIBRARIES PLANTED GH_TOKEN; do
  [[ -z "${!name+x}" ]] || { echo "${name} leaked into the base policy" >&2; exit 1; }
done
[[ "${HOME}" == "${RUNNER_TEMP}/base-policy-home" ]] || { echo "HOME is not the clean home" >&2; exit 1; }
for name in RUNNER_TEMP GITHUB_WORKSPACE GITHUB_REPOSITORY; do
  [[ -n "${!name:-}" ]] || { echo "${name} was not passed through" >&2; exit 1; }
done
# bash always sets SHELLOPTS itself, so what matters is what was exported into this process.
if env | grep -qE '^(SHELLOPTS|PS4|BASH_FUNC_[^=]*)='; then echo "an exported shell setting leaked into the base policy" >&2; exit 1; fi
[[ "$(command -v ruby)" == /usr/bin/ruby ]] || { echo "ruby resolves to $(command -v ruby)" >&2; exit 1; }
SH
  cat > "${policy}/check-env.rb" <<'RB'
%w[RUBYOPT RUBYLIB BASH_ENV GITHUB_ENV GITHUB_PATH PLANTED SHELLOPTS PS4 GH_TOKEN].each do |name|
  abort "#{name} leaked into the base policy" if ENV.key?(name)
end
abort 'PATH is not fixed' unless ENV['PATH'] == '/usr/bin:/bin:/usr/sbin:/sbin'
RB
  cp "${policy}/check-env.rb" "${policy}/test-env.rb"
  # lint.sh is the one script that is given the token; it must see exactly that and nothing planted.
  sed -e 's/ PLANTED GH_TOKEN; do/ PLANTED; do/' "${policy}/check-env.sh" > "${policy}/lint.sh"
  printf '%s\n' '[[ "${GH_TOKEN:-}" == fixture-token ]] || { echo "lint.sh did not receive the token" >&2; exit 1; }' >> "${policy}/lint.sh"
}

# Run the step the way the job does: the environment the earlier steps left, then the script.
# $1 tree, $2 poisoned? (yes/no). The outer shell is invoked by absolute path on purpose.
run_step() {
  local tree="$1" poisoned="$2" runner="$1/../runner"
  local -a environment=(
    "RUNNER_TEMP=${runner}" GH_TOKEN=fixture-token "GITHUB_WORKSPACE=${tree}"
    GITHUB_REPOSITORY=Moh-Bakr/Taurine-CI GITHUB_EVENT_NAME=pull_request
  )
  if [[ "${poisoned}" == yes ]]; then
    environment+=(
      "RUBYOPT=-rpoison" "RUBYLIB=${poison}" "BASH_ENV=${poison}/poison.sh"
      "PATH=${poison}/shim:${PATH}" GITHUB_ENV=/dev/null GITHUB_PATH=/dev/null PLANTED=1
      # Exported functions that make the step's own commands no-ops, and a traced shell whose PS4 runs code.
      'BASH_FUNC_cp%%=() {  :; }' 'BASH_FUNC_rm%%=() {  :; }' 'BASH_FUNC_mv%%=() {  :; }'
      'BASH_FUNC_mkdir%%=() {  :; }' 'BASH_FUNC_diff%%=() {  :; }'
      SHELLOPTS=xtrace "PS4=\$(: > '${xtrace_marker}')"
    )
  fi
  local -a shell_argv=()
  read -r -a shell_argv <<< "${step_shell}"
  local i
  for i in "${!shell_argv[@]}"; do
    [[ "${shell_argv[i]}" != '{0}' ]] || shell_argv[i]="${work}/step.sh"
  done
  # The command is looked up through the planted PATH, as the runner does for a bare name.
  (cd "${tree}" && env "${environment[@]}" "${shell_argv[@]}")
}

expect_rejects() {
  local label="$1" poisoned="$2" dir="${work}/$1" tree rc=0
  tree="$(fixture "${dir}")"
  reject_scripts "${tree}"
  rm -f "${xtrace_marker}"
  run_step "${tree}" "${poisoned}" > "${dir}.out" 2>&1 || rc=$?
  if [[ -e "${xtrace_marker}" ]]; then
    echo "base-policy environment: ${label}: code planted in PS4 ran in the step's shell" >&2
    exit 1
  fi
  if [[ "${rc}" -eq 0 ]]; then
    echo "base-policy environment: ${label}: the step passed although every base script rejects" >&2
    sed 's/^/  /' "${dir}.out" >&2
    exit 1
  fi
  for name in check-reject.rb test-reject.rb check-reject.sh test-reject.sh lint.sh; do
    grep -qF "The base commit's ${name} rejects this pull request" "${dir}.out" || {
      echo "base-policy environment: ${label}: no rejection reported for ${name}" >&2
      exit 1
    }
  done
}

expect_clean_environment() {
  local label="$1" poisoned="$2" dir="${work}/$1" tree rc=0
  tree="$(fixture "${dir}")"
  witness_scripts "${tree}"
  rm -f "${xtrace_marker}"
  run_step "${tree}" "${poisoned}" > "${dir}.out" 2>&1 || rc=$?
  if [[ -e "${xtrace_marker}" ]]; then
    echo "base-policy environment: ${label}: code planted in PS4 ran in the step's shell" >&2
    exit 1
  fi
  if [[ "${rc}" -ne 0 ]]; then
    echo "base-policy environment: ${label}: a base script saw a polluted or incomplete environment" >&2
    sed 's/^/  /' "${dir}.out" >&2
    exit 1
  fi
}

# A step that runs nothing must fail, whatever the reason nothing ran.
expect_fails_when_nothing_runs() {
  local label="$1" poisoned="$2" dir="${work}/$1" tree rc=0
  tree="$(fixture "${dir}")"
  run_step "${tree}" "${poisoned}" > "${dir}.out" 2>&1 || rc=$?
  [[ "${rc}" -ne 0 ]] || { echo "base-policy environment: ${label}: the step passed with no base script to run" >&2; exit 1; }
  grep -qF 'the base commit has no policy scripts to run' "${dir}.out" || {
    echo "base-policy environment: ${label}: no reason reported" >&2
    exit 1
  }
}

expect_rejects 'rejecting scripts, clean environment' no
expect_rejects 'rejecting scripts, RUBYOPT/RUBYLIB/BASH_ENV and a PATH shim planted' yes
expect_clean_environment 'environment witness, clean environment' no
expect_clean_environment 'environment witness, planted variables' yes
expect_fails_when_nothing_runs 'no base scripts, clean environment' no
expect_fails_when_nothing_runs 'no base scripts, planted variables' yes

echo 'base-policy environment: planted RUBYOPT, RUBYLIB, BASH_ENV, SHELLOPTS/PS4, exported functions and PATH shims cannot make the base policy pass or skip; only the allow-listed environment reaches it, and the token only reaches lint.sh'
