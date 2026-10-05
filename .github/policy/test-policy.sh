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
cache_expect_fail 'compiled cache restore re-enabled' 'disabled until ref isolation exists' \
  's/if: \$\{\{ false && (startsWith\(inputs\.concern, .rust-app-.\) \}\}\n        uses: actions\/cache\/restore)/if: \$\{\{ $1/'
cache_expect_fail 'compiled cache save re-enabled' 'disabled until ref isolation exists' \
  's/if: \$\{\{ false && (github\.ref == .refs\/heads\/main. && inputs\.concern == .rust-app-2. && [^\n]*cargo-target-strip\.outcome)/if: \$\{\{ $1/'
cache_expect_fail 'compiled cache gate re-opened by ||' 'disabled until ref isolation exists' \
  's/(if: \$\{\{ false && startsWith\(inputs\.concern, .rust-app-.\)) \}\}(\n        uses: actions\/cache\/restore)/$1 || true }}$2/'
cache_expect_fail 'compiled cache strip re-enabled' 'strip steps are disabled' \
  's/if: \$\{\{ false && (github\.ref == [^\n]*steps\.concern-rust\.outcome)/if: \$\{\{ $1/'
# Findings L1-L3: the source cache holds only the verified archives, saves under the restore's
# key, and the required save terms count only as exact top-level conjuncts.
cache_expect_fail 'the unverified registry index' 'Disallowed cache path line' \
  's#(            \$\{\{ steps\.cargo-home\.outputs\.dir \}\}/registry/cache\n)#$1            \${{ steps.cargo-home.outputs.dir }}/registry/index\n#'
cache_expect_fail 'the unverified git databases' 'Disallowed cache path line' \
  's#(            \$\{\{ steps\.cargo-home\.outputs\.dir \}\}/registry/cache\n)#$1            \${{ steps.cargo-home.outputs.dir }}/git/db\n#'
cache_expect_fail 'a source save key evaluated after project code' 'cache-primary-key' \
  's/key: \$\{\{ steps\.cargo-sources\.outputs\.cache-primary-key \}\}/key: cargo-sources-v3-\$\{\{ runner.os \}\}-\$\{\{ hashFiles(\x27src\/Cargo.lock\x27) \}\}/'
cache_expect_fail 'protected ancestry inside an always-true alternative' 'exact top-level term' \
  's/ && (steps\.verified-source\.outputs\.protected-ancestor == .true.) && steps\.cargo-sources/ \&\& ($1 || true) \&\& steps.cargo-sources/g'
cache_expect_fail 'protected ancestry negated' 'exact top-level term' \
  's/ && (steps\.verified-source\.outputs\.protected-ancestor == .true.) && steps\.cargo-sources/ \&\& !($1) \&\& steps.cargo-sources/g'
cache_expect_fail 'the main guard inside an always-true alternative' 'main branch as a top-level term' \
  's/if: \$\{\{ false && (github\.ref == .refs\/heads\/main.) && (\(inputs\.concern == .taurine-cli.)/if: \${{ false \&\& ($1 || true) \&\& $2/g'
# Finding H1 extended: the cargo source cache restore, its completion step and its save are off,
# and a setup action's built-in cache stays off.
cache_expect_fail 'cargo source restore re-enabled' 'cargo source cache is disabled' \
  's/if: \$\{\{ false && \((inputs\.concern == .taurine-cli.[^\n]*)\) \}\}(\n        uses: actions\/cache\/restore)/if: \$\{\{ $1 }}$2/'
cache_expect_fail 'cargo source restore gate re-opened by ||' 'cargo source cache is disabled' \
  's/(if: \$\{\{ false && \(inputs\.concern == .taurine-cli.[^\n]*\)) \}\}(\n        uses: actions\/cache\/restore)/$1 || true }}$2/'
cache_expect_fail 'cargo source save re-enabled' 'cargo source cache is disabled' \
  's/false && (github\.ref == [^\n]*\n        uses: actions\/cache\/save\@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6\.1\.0\n        with:\n          path: \|\n            \$\{\{ steps\.cargo-home)/$1/'
cache_expect_fail 'cargo source completion step re-enabled' 'cargo source cache is disabled' \
  's/false && (github\.ref == [^\n]*\n        shell: bash\n        run: \|\n          set -euo pipefail\n          while IFS= read -r lock)/$1/'
cache_expect_fail 'cargo source restore with no condition' 'cargo source cache is disabled' \
  's/\n        if: \$\{\{ false && \(inputs\.concern == .taurine-cli.[^\n]*\) \}\}(\n        uses: actions\/cache\/restore)/$1/'
# A built-in setup cache: setup-node without the opt-out, or a `cache:` input.
node_fixture="${base}/node-cache.yml"
for mutation in 's/^( +)package-manager-cache: false\n//m' 's/^( +)package-manager-cache: false$/$1package-manager-cache: false\n$1cache: npm/m'; do
  perl -0pe "${mutation}" .github/actions/node-setup/action.yml > "${node_fixture}"
  if (source "${policy}/check-cache-policy.sh"; check_builtin_cache_off "${node_fixture}") >/dev/null 2>&1; then
    echo "a setup-node built-in cache fixture should fail but passed" >&2
    exit 1
  fi
done
(source "${policy}/check-cache-policy.sh"; check_builtin_cache_off .github/actions/node-setup/action.yml) || { echo 'the reviewed setup-node step should pass' >&2; exit 1; }
echo 'cache policy fixtures: the compiled-dependency guards reject restore-keys, an unguarded save, an unreviewed path and a re-enabled cache'

# The KeelDock NuGet cache: the reviewed concern passes; a re-enabled restore or save, a save
# without the protected-ancestry answer and a save key evaluated after project code fail. The
# policy recognises the concern by its repository path, so each fixture is checked from its own
# root under that path.
nuget_root="${base}/nuget"
mkdir -p "${nuget_root}/.github/workflows"
nuget_expect_fail() {
  local label="$1" needle="$2" expr="$3"
  perl -0pe "${expr}" .github/workflows/keeldock-validation-concern.yml > "${nuget_root}/.github/workflows/keeldock-validation-concern.yml"
  if (cd "${nuget_root}" && source "${policy}/check-cache-policy.sh" && check_cache_policy .github/workflows/keeldock-validation-concern.yml) >/dev/null 2>"${base}/err"; then
    echo "NuGet fixture '${label}' should fail but passed" >&2
    exit 1
  fi
  grep -qF -- "${needle}" "${base}/err" || { echo "NuGet fixture '${label}' failed with the wrong message:" >&2; cat "${base}/err" >&2; exit 1; }
}
(source "${policy}/check-cache-policy.sh"; check_cache_policy .github/workflows/keeldock-validation-concern.yml) || { echo 'the reviewed NuGet cache steps should pass' >&2; exit 1; }
nuget_expect_fail 'NuGet restore re-enabled' 'NuGet cache is disabled' \
  's/if: \$\{\{ false && (steps\.verified-source\.outcome)/if: \$\{\{ $1/'
nuget_expect_fail 'NuGet save re-enabled' 'NuGet cache is disabled' \
  's/if: \$\{\{ false && (github\.ref == .refs\/heads\/main. && steps\.verified-source\.outputs)/if: \$\{\{ $1/'
nuget_expect_fail 'NuGet save without protected ancestry' 'protected-ancestry answer' \
  's/ && steps\.verified-source\.outputs\.protected-ancestor == .true.//'
nuget_expect_fail 'NuGet save key after project code' 'cache-primary-key' \
  's/key: \$\{\{ steps\.nuget-packages\.outputs\.cache-primary-key \}\}/key: nuget-\$\{\{ runner.os \}\}-\$\{\{ hashFiles(\x27**\/packages.lock.json\x27) \}\}/'
echo 'cache policy fixtures: the NuGet guards reject a re-enabled cache, an unprotected save and a late save key'

# Root removal (finding H2): the reviewed protected workflows pass, and each drop-root rule
# rejects the one mutation it exists for. The fixture sits in a tree whose composites are this
# repository's own, so the composite sudo scan reads the real actions.
drop_root="${base}/drop-root"
mkdir -p "${drop_root}/.github/workflows"
ln -s "${PWD}/.github/actions" "${drop_root}/.github/actions"
drop_expect_fail() {
  local label="$1" source="$2" needle="$3" expr="$4"
  perl -0pe "${expr}" "${source}" > "${drop_root}/.github/workflows/fixture.yml"
  if ruby "${policy}/drop-root-order.rb" "${drop_root}/.github/workflows/fixture.yml" >/dev/null 2>"${base}/err"; then
    echo "drop-root fixture '${label}' should fail but passed" >&2
    exit 1
  fi
  grep -qF -- "${needle}" "${base}/err" || { echo "drop-root fixture '${label}' failed with the wrong message:" >&2; cat "${base}/err" >&2; exit 1; }
}
ruby "${policy}/drop-root-order.rb" .github/workflows/linux-validation-concern.yml || { echo 'the reviewed Linux concern should pass the drop-root rules' >&2; exit 1; }
drop_expect_fail 'no drop-root step' .github/workflows/ios-validation.yml 'exactly once' \
  's/        uses: \.\/\.github\/actions\/drop-root[^\n]*\n//'
drop_expect_fail 'a project command before drop-root' .github/workflows/ios-validation.yml 'project command before drop-root' \
  's/(      - name: Remove root before project code\n)/      - name: Early install\n        shell: bash\n        run: npm ci\n\n$1/'
drop_expect_fail 'an unreviewed composite before drop-root' .github/workflows/ios-validation.yml 'only reviewed pre-root steps' \
  's/(      - name: Remove root before project code\n)/      - name: Early setup\n        uses: .\/.github\/actions\/node-setup\n\n$1/'
drop_expect_fail 'a scanner before drop-root' .github/workflows/linux-validation-concern.yml 'only scanner: semgrep-container' \
  's/scanner: semgrep-container/scanner: all/'
drop_expect_fail 'sudo after drop-root' .github/workflows/ios-validation.yml 'calls sudo after drop-root' \
  's/(          rustup target add aarch64-apple-ios-sim\n)/$1          sudo true\n/'
drop_expect_fail 'docker after drop-root' .github/workflows/live-proof-arm.yml 'calls Docker after drop-root' \
  's/(          echo .vendor-fetch: passed.\n)/$1          docker ps\n/'
drop_expect_fail 'a sudo composite after drop-root' .github/workflows/android-validation.yml 'contains sudo and is called after drop-root' \
  's/(      - name: Remove root before project code\n        # Kept as \.\/ : the policy matches this exact form for local actions\.\n        uses: \.\/\.github\/actions\/drop-root[^\n]*\n)/$1\n      - name: Late privileged setup\n        uses: .\/.github\/actions\/root-setup\n        with:\n          concern: x\n/'
echo 'drop-root fixtures: a missing drop, project code or a setup composite before it, and sudo or Docker after it are rejected'
