#!/usr/bin/env bash
# Fixture tests for the universal rules (check-universal.rb) and the size limits
# (check-sizes.sh): each rule is shown to accept a compliant tree and to reject a tree that
# breaks only that rule. Run from the repository root.
set -euo pipefail

policy="${PWD}/.github/policy"
base="$(mktemp -d)"
trap 'rm -rf "${base}"' EXIT
sha=3d3c42e5aac5ba805825da76410c181273ba90b1

# A compliant tree: one ordinary workflow, one protected job, one composite.
good_tree() {
  local root="$1"
  mkdir -p "${root}/.github/workflows" "${root}/.github/actions/demo" "${root}/.github/actions/source-checkout"
  cat > "${root}/.github/workflows/ordinary.yml" <<YAML
name: ordinary
on:
  workflow_dispatch:
permissions: {}
jobs:
  build:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@${sha}
YAML
  cat > "${root}/.github/workflows/protected.yml" <<YAML
name: protected
on:
  workflow_dispatch:
permissions: {}
jobs:
  validate:
    runs-on: ubuntu-24.04
    environment: source-read
    steps:
      - uses: actions/checkout@${sha}
      - uses: ./.github/actions/timings
      - name: Validate input
        shell: bash
        run: test -n "\${INPUT}"
      - uses: ./.github/actions/source-checkout
      - name: Project work
        shell: bash
        run: npm ci
YAML
  cat > "${root}/.github/actions/demo/action.yml" <<YAML
name: demo
description: demo
runs:
  using: composite
  steps:
    - uses: actions/checkout@${sha}
YAML
  cat > "${root}/.github/actions/source-checkout/action.yml" <<YAML
name: source-checkout
description: demo
runs:
  using: composite
  steps:
    - shell: bash
      run: echo ok
YAML
}

expect_pass() {
  local label="$1" root="$2"
  ruby "${policy}/check-universal.rb" "${root}" >/dev/null 2>"${base}/err" || { echo "fixture '${label}' should pass but failed:" >&2; cat "${base}/err" >&2; exit 1; }
}
expect_fail() {
  local label="$1" root="$2" needle="$3"
  if ruby "${policy}/check-universal.rb" "${root}" >/dev/null 2>"${base}/err"; then
    echo "fixture '${label}' should fail but passed" >&2
    exit 1
  fi
  grep -qF -- "${needle}" "${base}/err" || { echo "fixture '${label}' failed with the wrong message:" >&2; cat "${base}/err" >&2; exit 1; }
}
fresh() { local root="${base}/$1"; rm -rf "${root}"; good_tree "${root}"; echo "${root}"; }
# Applies a perl substitution to one file of a fixture tree.
mutate() { perl -0pi -e "$3" "$1/$2"; }

root="$(fresh good)"; expect_pass 'compliant tree' "${root}"

root="$(fresh unpinned-tag)"; mutate "${root}" .github/workflows/ordinary.yml "s/actions\/checkout\@${sha}/actions\/checkout\@v4/"
expect_fail 'a tag reference' "${root}" 'not pinned to a full 40-character commit SHA'

root="$(fresh unpinned-branch)"; mutate "${root}" .github/workflows/ordinary.yml "s/actions\/checkout\@${sha}/actions\/checkout\@main/"
expect_fail 'a branch reference' "${root}" 'not pinned'

root="$(fresh short-sha)"; mutate "${root}" .github/workflows/ordinary.yml "s/actions\/checkout\@${sha}/actions\/checkout\@3d3c42e/"
expect_fail 'an abbreviated SHA' "${root}" 'not pinned'

root="$(fresh docker-ref)"; mutate "${root}" .github/workflows/ordinary.yml "s/actions\/checkout\@${sha}/docker:\/\/alpine:3.20/"
expect_fail 'a docker reference' "${root}" 'not pinned'

root="$(fresh composite-unpinned)"; mutate "${root}" .github/actions/demo/action.yml "s/actions\/checkout\@${sha}/actions\/checkout\@v4/"
expect_fail 'an unpinned composite step' "${root}" 'actions/demo/action.yml'

root="$(fresh no-permissions)"; mutate "${root}" .github/workflows/ordinary.yml 's/permissions: \{\}\n//'
expect_fail 'no top-level permissions' "${root}" 'no top-level `permissions: {}`'

root="$(fresh broad-permissions)"; mutate "${root}" .github/workflows/ordinary.yml 's/^permissions: \{\}/permissions: read-all/m'
expect_fail 'broad top-level permissions' "${root}" 'no top-level `permissions: {}`'

root="$(fresh prt)"; mutate "${root}" .github/workflows/ordinary.yml 's/  workflow_dispatch:/  pull_request_target:/'
expect_fail 'pull_request_target' "${root}" 'pull_request_target'

root="$(fresh prt-flow)"; mutate "${root}" .github/workflows/ordinary.yml 's/on:\n  workflow_dispatch:/on: [push, pull_request_target]/'
expect_fail 'pull_request_target in a list' "${root}" 'pull_request_target'

root="$(fresh inherit)"
cat >> "${root}/.github/workflows/ordinary.yml" <<'YAML'
  call:
    uses: ./.github/workflows/protected.yml
    secrets: inherit
YAML
expect_fail 'secrets: inherit' "${root}" 'secrets: inherit'

root="$(fresh no-source-checkout)"; mutate "${root}" .github/workflows/protected.yml 's/      - uses: \.\/\.github\/actions\/source-checkout\n//'
expect_fail 'a protected job without the composite' "${root}" 'does not call the source-checkout composite'

root="$(fresh project-before)"; mutate "${root}" .github/workflows/protected.yml 's/(      - name: Validate input)/      - name: Early\n        shell: bash\n        run: npm ci\n$1/'
expect_fail 'a project command before the composite' "${root}" 'project command runs before the source-checkout composite'

root="$(fresh action-before)"; mutate "${root}" .github/workflows/protected.yml "s/(      - uses: \.\/\.github\/actions\/timings)/      - uses: actions\/setup-node\@${sha}\n\$1/"
expect_fail 'a setup action before the composite' "${root}" 'runs before the source-checkout composite'

root="$(fresh environment-input)"; mutate "${root}" .github/workflows/protected.yml 's/environment: source-read/environment: \$\{\{ inputs.environment \}\}/'
mutate "${root}" .github/workflows/protected.yml 's/      - uses: \.\/\.github\/actions\/source-checkout\n//'
expect_fail 'an environment-input job without the composite' "${root}" 'does not call the source-checkout composite'

# Size limits.
size_root="${base}/sizes"
mkdir -p "${size_root}/.github/workflows" "${size_root}/.github/actions"
printf 'name: x\n' > "${size_root}/.github/workflows/small.yml"
bash "${policy}/check-sizes.sh" "${size_root}" >/dev/null
awk 'BEGIN { for (i = 0; i < 450; i++) print "# line " i }' > "${size_root}/.github/workflows/medium.yml"
out="$(bash "${policy}/check-sizes.sh" "${size_root}")"
grep -qF 'large workflow file' <<<"${out}" || { echo 'a file over 400 lines should warn' >&2; exit 1; }
awk 'BEGIN { for (i = 0; i < 850; i++) print "# line " i }' > "${size_root}/.github/workflows/large.yml"
if bash "${policy}/check-sizes.sh" "${size_root}" >/dev/null 2>&1; then
  echo 'a file over 800 lines should fail' >&2
  exit 1
fi

echo 'policy fixtures: every universal rule and size limit accepts a compliant tree and rejects its violation'

# Cache policy: the reviewed Linux concern passes, and each compiled-dependency guard rejects
# the one mutation it exists for.
cache_fixture="${base}/cache.yml"
cache_expect_fail() {
  local label="$1" needle="$2" expr="$3"
  perl -0pe "${expr}" .github/workflows/linux-validation-concern.yml > "${cache_fixture}"
  if (source "${policy}/check-cache-policy.sh"; check_cache_policy "${cache_fixture}") >/dev/null 2>"${base}/err"; then
    echo "cache fixture '${label}' should fail but passed" >&2
    exit 1
  fi
  grep -qF -- "${needle}" "${base}/err" || { echo "cache fixture '${label}' failed with the wrong message:" >&2; cat "${base}/err" >&2; exit 1; }
}
(source "${policy}/check-cache-policy.sh"; check_cache_policy .github/workflows/linux-validation-concern.yml) || { echo 'the reviewed cache steps should pass' >&2; exit 1; }
cache_expect_fail 'target restore-keys' 'must not have restore-keys' \
  's/(          key: \$\{\{ steps\.cargo-target\.outputs\.key \}\}\n)/$1          restore-keys: |\n            cargo-target-\n/'
cache_expect_fail 'save without protected ancestry' 'protected-ancestry answer' \
  's/ && steps\.verified-source\.outputs\.protected-ancestor == .true.//g'
cache_expect_fail 'save without the proof' 'strip-and-prove step' \
  's/ && steps\.cargo-target-strip\.outcome == .success.//'
cache_expect_fail 'a target path outside the reviewed three' 'Disallowed cache path line' \
  's#outputs\.dir \}\}/debug/build#outputs.dir }}/debug#'
echo 'cache policy fixtures: the compiled-dependency guards reject restore-keys, an unguarded save and an unreviewed path'
