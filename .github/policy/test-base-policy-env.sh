#!/usr/bin/env bash
# The base-policy step must not be steerable by environment that an earlier step of the job wrote to
# GITHUB_ENV or GITHUB_PATH. This extracts the reviewed step itself, runs it over fixture base
# scripts that all reject, and shows the step still rejects when RUBYOPT/RUBYLIB/BASH_ENV and a PATH
# shim have been planted to make every child exit 0. A second run over scripts that inspect their own
# environment shows the scrub removes the planted variables and keeps what the base policy needs.
# Run from the repository root. Usage: test-base-policy-env.sh [workflow-file]
#
# The planted BASH_ENV is written to leave the step's own shell alone: a step cannot defend its own
# shell from inside its script (see docs/how-ci-works.md), so this models the child-targeted case.
set -euo pipefail

workflow="${1:-.github/workflows/validate-public-changes.yml}"
step="Run the base commit's policy against this pull request"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/base-policy-env-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
root="${PWD}"

ruby "${root}/.github/policy/extract-step.rb" "${workflow}" "${step}" run > "${work}/step.sh"

# What a hostile earlier step could have planted: every child process it affects exits 0.
poison="${work}/poison"
mkdir -p "${poison}/shim"
printf 'at_exit { exit!(0) }\n' > "${poison}/poison.rb"
# $0 is not yet the script name while BASH_ENV is read, so the shell is recognised by its command line.
printf 'case "$(ps -o command= -p "$$" 2>/dev/null)" in *step.sh*) ;; *) exit 0 ;; esac\n' > "${poison}/poison.sh"
printf '#!/bin/sh\nexit 0\n' > "${poison}/shim/ruby"
cp "${poison}/shim/ruby" "${poison}/shim/bash"
chmod +x "${poison}/shim/ruby" "${poison}/shim/bash"

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
for name in RUBYOPT RUBYLIB BASH_ENV ENV GITHUB_ENV GITHUB_PATH LD_PRELOAD DYLD_INSERT_LIBRARIES PLANTED; do
  [[ -z "${!name+x}" ]] || { echo "${name} leaked into the base policy" >&2; exit 1; }
done
[[ "${HOME}" == "${RUNNER_TEMP}/base-policy-home" ]] || { echo "HOME is not the clean home" >&2; exit 1; }
for name in GH_TOKEN RUNNER_TEMP GITHUB_WORKSPACE GITHUB_REPOSITORY; do
  [[ -n "${!name:-}" ]] || { echo "${name} was not passed through" >&2; exit 1; }
done
[[ "$(command -v ruby)" == /usr/bin/ruby ]] || { echo "ruby resolves to $(command -v ruby)" >&2; exit 1; }
SH
  cat > "${policy}/check-env.rb" <<'RB'
%w[RUBYOPT RUBYLIB BASH_ENV GITHUB_ENV GITHUB_PATH PLANTED].each do |name|
  abort "#{name} leaked into the base policy" if ENV.key?(name)
end
abort 'PATH is not fixed' unless ENV['PATH'] == '/usr/bin:/bin:/usr/sbin:/sbin'
abort 'GH_TOKEN was not passed through' if ENV.fetch('GH_TOKEN', '').empty?
RB
  cp "${policy}/check-env.rb" "${policy}/test-env.rb"
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
    )
  fi
  (cd "${tree}" && env "${environment[@]}" /bin/bash --noprofile --norc -eo pipefail "${work}/step.sh")
}

expect_rejects() {
  local label="$1" poisoned="$2" dir="${work}/$1" tree rc=0
  tree="$(fixture "${dir}")"
  reject_scripts "${tree}"
  run_step "${tree}" "${poisoned}" > "${dir}.out" 2>&1 || rc=$?
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
  run_step "${tree}" "${poisoned}" > "${dir}.out" 2>&1 || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "base-policy environment: ${label}: a base script saw a polluted or incomplete environment" >&2
    sed 's/^/  /' "${dir}.out" >&2
    exit 1
  fi
}

expect_rejects 'rejecting scripts, clean environment' no
expect_rejects 'rejecting scripts, RUBYOPT/RUBYLIB/BASH_ENV and a PATH shim planted' yes
expect_clean_environment 'environment witness, clean environment' no
expect_clean_environment 'environment witness, planted variables' yes

echo 'base-policy environment: planted RUBYOPT, RUBYLIB, BASH_ENV and PATH shims cannot make the base policy pass; only the allow-listed environment reaches it'
