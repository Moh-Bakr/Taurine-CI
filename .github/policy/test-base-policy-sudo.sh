#!/usr/bin/env bash
# The base-policy step must refuse to run while passwordless sudo is available.
#
# That can only be shown where passwordless sudo exists: a hosted runner, before drop-root. The
# policy workflow runs this there with --require, so it fails rather than skips if it cannot
# exercise the rule. Anywhere else -- a developer machine, or the base-policy pass, which runs after
# drop-root -- there is nothing to show, and it says so instead of passing quietly.
#
# Run from the repository root. Usage: test-base-policy-sudo.sh [--require] [workflow-file]
set -euo pipefail

require=no
if [[ "${1:-}" == --require ]]; then
  require=yes
  shift
fi
workflow="${1:-.github/workflows/validate-public-changes.yml}"
step="Run the base commit's policy against this pull request"

if ! /usr/bin/sudo -n true 2>/dev/null; then
  if [[ "${require}" == yes ]]; then
    echo 'base-policy sudo: passwordless sudo is not available here, so the rule was not exercised' >&2
    exit 1
  fi
  echo 'base-policy sudo: NOT EXERCISED HERE -- no passwordless sudo to refuse; the policy job runs this before drop-root'
  exit 0
fi

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/base-policy-sudo-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
root="${PWD}"

ruby "${root}/.github/policy/extract-step.rb" "${workflow}" "${step}" run > "${work}/step.sh"
step_shell="$(ruby -ryaml -e '
  doc = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  found = doc.fetch("jobs").values.flat_map { |job| job.fetch("steps").select { |s| s["name"] == ARGV[1] } }
  abort "expected one step" unless found.length == 1
  print found.first.fetch("shell")
' "${workflow}" "${step}")"

# A base policy that would pass, so the only reason to fail is the sudo that is still there.
tree="${work}/tree"
policy="${tree}/base-policy/.github/policy"
mkdir -p "${policy}" "${tree}/.github/policy" "${work}/runner"
for name in check-pass.rb test-pass.rb; do printf 'exit 0\n' > "${policy}/${name}"; done
for name in check-pass.sh test-pass.sh lint.sh; do printf 'exit 0\n' > "${policy}/${name}"; done
git -C "${tree}/base-policy" init -q
git -C "${tree}/base-policy" config user.name 'Base Policy Fixture'
git -C "${tree}/base-policy" config user.email 'base-policy-fixture@example.invalid'
git -C "${tree}/base-policy" add -A
git -C "${tree}/base-policy" -c commit.gpgsign=false commit -qm 'base policy fixture'
base_sha="$(git -C "${tree}/base-policy" rev-parse HEAD)"

read -r -a shell_argv <<< "${step_shell}"
for i in "${!shell_argv[@]}"; do
  [[ "${shell_argv[i]}" != '{0}' ]] || shell_argv[i]="${work}/step.sh"
done
rc=0
(cd "${tree}" && env "RUNNER_TEMP=${work}/runner" GH_TOKEN=fixture-token "GITHUB_WORKSPACE=${tree}" \
  GITHUB_REPOSITORY=Moh-Bakr/Taurine-CI GITHUB_EVENT_NAME=pull_request "BASE_SHA=${base_sha}" \
  "${shell_argv[@]}") > "${work}/out" 2>&1 || rc=$?

if [[ "${rc}" -eq 0 ]]; then
  echo 'base-policy sudo: the step ran base scripts with passwordless sudo still available' >&2
  sed 's/^/  /' "${work}/out" >&2
  exit 1
fi
grep -qF 'passwordless sudo is still available' "${work}/out" || {
  echo 'base-policy sudo: the step failed, but not because sudo was still available' >&2
  sed 's/^/  /' "${work}/out" >&2
  exit 1
}
echo 'base-policy sudo: with passwordless sudo present, the step refuses to run any base script'
