#!/usr/bin/env bash
# Interpreter batching must check every argument, fail closed on unreadable inputs and
# retain each composite's text/structure guards. No cross-file verdict is reused.
set -euo pipefail
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
source .github/policy/check-actions.sh
source .github/policy/check-cache-policy.sh
source .github/policy/lib.sh

printf 'runs:\n  using: composite\n  steps:\n    - uses: ./.github/actions/sanitize\n' > "${work}/good.yml"
printf 'runs:\n  using: composite\n  steps:\n    - uses: actions/checkout@v4\n' > "${work}/reference.yml"
printf 'runs:\n  using: composite\n  steps:\n    - run: echo fixture\n' > "${work}/shell.yml"
printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: echo vars.FIXTURE\n' > "${work}/text.yml"
printf 'runs: [unclosed\n' > "${work}/broken.yml"
printf 'runs:\n  using: composite\n  steps:\n    - uses: actions/setup-node@pin\n' > "${work}/builtin.yml"
cp "${work}/good.yml" "${work}/literal [x]* space.yml"

expect_fail() {
  local message="$1"; shift
  if ("$@") >"${work}/out" 2>&1; then
    echo "batch unexpectedly accepted: $*" >&2; exit 1
  fi
  grep -qF -- "${message}" "${work}/out" || { cat "${work}/out" >&2; exit 1; }
}
check_action_references "${work}/good.yml" "${work}/good.yml"
check_composite_action "${work}/good.yml" "${work}/good.yml"
check_action_references "${work}/literal [x]* space.yml" "${work}/good.yml"
check_composite_action "${work}/literal [x]* space.yml" "${work}/good.yml"
# Good files before/after a bad file must never hide it, including when last.
for position in first middle last; do
  for kind in reference shell text builtin broken missing; do
    bad="${work}/${kind}.yml"
    case "${position}" in
      first) files=("${bad}" "${work}/good.yml" "${work}/good.yml") ;;
      middle) files=("${work}/good.yml" "${bad}" "${work}/good.yml") ;;
      last) files=("${work}/good.yml" "${work}/good.yml" "${bad}") ;;
    esac
    case "${kind}" in
      reference) expect_fail 'full 40-character commit SHA' check_action_references "${files[@]}" ;;
      shell) expect_fail 'has no shell' check_composite_action "${files[@]}" ;;
      text) expect_fail 'may not use secrets' check_composite_action "${files[@]}" ;;
      builtin) expect_fail 'setup-node step without package-manager-cache: false' check_composite_action "${files[@]}" ;;
      broken) expect_fail 'Psych::' check_composite_action "${files[@]}" ;;
      missing) expect_fail 'No such file' check_composite_action "${files[@]}" ;;
    esac
  done
done
expect_fail 'No Action reference file to check.' check_action_references
expect_fail 'no composite file to check' check_composite_action
# Each file's failures are independent, even after the source-checkout special case.
check_composite_action .github/actions/source-checkout/action.yml "${work}/good.yml"
expect_fail 'has no shell' check_composite_action .github/actions/source-checkout/action.yml "${work}/shell.yml"

main="github.ref == 'refs/heads/main'"
protected="steps.verified-source.outputs.protected-ancestor == 'true'"
cond_requires "if: ${main} && ${protected}" "${main}" "${protected}"
for condition in "${main}" "${protected}" "${main} && (${protected} || true)" "${main} && ${protected} || true" "${main} && ("; do
  if cond_requires "if: ${condition}" "${main}" "${protected}"; then
    echo "combined guard accepted: ${condition}" >&2; exit 1
  fi
done
# Reverse the requirement order and retain quoted operators as data.
cond_requires "if: ${main} && ${protected} && contains('(', ')')" "${protected}" "${main}"
if cond_requires "if: ${main}"; then echo 'empty requirement accepted' >&2; exit 1; fi

echo 'policy batching: every argument and both conjuncts checked; malformed/missing inputs refused'
