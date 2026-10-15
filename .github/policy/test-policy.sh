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
env:
  SOURCE_REPOSITORY_ID: '1330267721'
  SOURCE_REPOSITORY_OWNER: Moh-Bakr
  SOURCE_REPOSITORY_NAME: Taurine
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
        with:
          source-sha: \${{ inputs.source_sha }}
          app-client-id: \${{ vars.SOURCE_READER_APP_ID }}
          app-private-key: \${{ secrets.SOURCE_READER_PRIVATE_KEY }}
          repository-id: \${{ env.SOURCE_REPOSITORY_ID }}
          repository-owner: \${{ env.SOURCE_REPOSITORY_OWNER }}
          repository-name: \${{ env.SOURCE_REPOSITORY_NAME }}
          check-protected-ancestry: 'true'
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
    - name: Mint read-only private-source token
      uses: actions/create-github-app-token@${sha}
      with:
        client-id: \${{ inputs.app-client-id }}
        private-key: \${{ inputs.app-private-key }}
        owner: \${{ inputs.repository-owner }}
        repositories: \${{ inputs.repository-name }}
        permission-contents: read
        skip-token-revoke: true
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

# Literal edits (no regex escaping): swap replaces the first occurrence of OLD with NEW and
# fails loudly when OLD is not there, so a fixture can never silently test nothing.
swap() { OLD="$3" NEW="$4" ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("fixture text not found: #{ENV["OLD"]}"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], s)' "$1/$2"; }
# The reviewed pre-flight (rule 6), on copies of two real dispatchers: one where the pre-flight
# is its own job, one whose concern job runs under always() beside the pre-flight's result.
preflight_tree() { local root; root="$(fresh "$1")"; cp .github/workflows/source-read.yml .github/workflows/linux-validation.yml "${root}/.github/workflows/"; echo "${root}"; }
root="$(preflight_tree preflight-good)"; expect_pass 'the reviewed pre-flight jobs' "${root}"
root="$(preflight_tree preflight-no-needs)"; swap "${root}" .github/workflows/source-read.yml '    needs: validate-input
' ''
expect_fail 'the protected job no longer needs the pre-flight' "${root}" 'must need the pre-flight job validate-input directly'
root="$(preflight_tree preflight-always)"; swap "${root}" .github/workflows/source-read.yml '    needs: validate-input
' '    needs: validate-input
    if: always()
'
expect_fail 'the protected job runs past a failed pre-flight' "${root}" 'may not run past a failed pre-flight'
root="$(preflight_tree preflight-or)"; swap "${root}" .github/workflows/linux-validation.yml "needs.validate-input.result == 'success' &&" "needs.validate-input.result == 'success' || true &&"
expect_fail 'the pre-flight result term reopened by ||' "${root}" 'may not run past a failed pre-flight'
root="$(preflight_tree preflight-term-gone)"; swap "${root}" .github/workflows/linux-validation.yml "needs.validate-input.result == 'success' &&" ''
expect_fail 'the pre-flight result term removed' "${root}" 'may not run past a failed pre-flight'
root="$(preflight_tree preflight-no-call)"; swap "${root}" .github/workflows/source-read.yml 'uses: ./.github/actions/environment-preflight' "uses: actions/checkout@${sha}"
expect_fail 'the pre-flight composite not called' "${root}" 'must call ./.github/actions/environment-preflight unconditionally'
root="$(preflight_tree preflight-skipped)"; swap "${root}" .github/workflows/source-read.yml '        uses: ./.github/actions/environment-preflight' "        if: false
        uses: ./.github/actions/environment-preflight"
expect_fail 'the pre-flight composite skipped' "${root}" 'must call ./.github/actions/environment-preflight unconditionally'
root="$(preflight_tree preflight-continue)"; swap "${root}" .github/workflows/linux-validation.yml '  validate-input:
' '  validate-input:
    continue-on-error: true
'
expect_fail 'the pre-flight continues on error' "${root}" 'must not continue on error'
root="$(preflight_tree preflight-renamed)"; swap "${root}" .github/workflows/source-read.yml '  validate-input:' '  checks:'
expect_fail 'the pre-flight job renamed away' "${root}" 'the reviewed pre-flight job validate-input is missing'
echo 'pre-flight fixtures (rule 6): a dropped needs, a run past failure, a skipped or missing environment check are rejected'

checkout_line="      - uses: actions/checkout@${sha}
"
add_after() { swap "$1" "$2" "$3" "$3$4"; }

# Whole-context reads (rule 7).
for leak in '${{ toJSON(secrets) }}' '${{ toJSON(vars) }}' '${{ toJSON(github) }}' "\${{ format('{0}', secrets) }}" '${{ secrets[matrix.name] }}' '${{ secrets.* }}' '${{ join(vars) }}'; do
  root="$(fresh whole-context)"; add_after "${root}" .github/workflows/ordinary.yml "${checkout_line}" "        env:
          LEAK: ${leak}
"
  expect_fail "a whole-context read (${leak})" "${root}" 'reads a whole secrets, vars or github context'
done
root="$(fresh bare-if)"; add_after "${root}" .github/workflows/ordinary.yml '  build:
' "    if: toJSON(vars) != '{}'
"
expect_fail 'a whole-context read in a bare if' "${root}" 'reads a whole secrets, vars or github context'
root="$(fresh whole-context-composite)"; add_after "${root}" .github/actions/demo/action.yml "    - uses: actions/checkout@${sha}
" '      with:
        token: ${{ toJSON(secrets) }}
'
expect_fail 'a whole-context read in a composite' "${root}" 'actions/demo/action.yml: an expression reads a whole'
root="$(fresh named-member)"; add_after "${root}" .github/workflows/ordinary.yml "${checkout_line}" "        env:
          OK: \${{ vars.SOURCE_READER_APP_ID }} \${{ matrix.vars }} \${{ format('secrets') }}
"
expect_pass 'named members and a quoted word are not whole-context reads' "${root}"

# The token mint is an exact allow-list; source-checkout calls are pinned (rule 8).
mint_case() {
  local label="$1" old="$2" new="$3"
  root="$(fresh mint)"; swap "${root}" .github/actions/source-checkout/action.yml "${old}" "${new}"
  expect_fail "a token mint outside the allow-list (${label})" "${root}" 'is not a reviewed `with:` map'
}
mint_case 'an extra permission' '        permission-contents: read
' '        permission-contents: read
        permission-secrets: read
'
mint_case 'contents write' 'permission-contents: read' 'permission-contents: write'
mint_case 'another owner' 'owner: ${{ inputs.repository-owner }}' 'owner: Moh-Bakr'
mint_case 'another repository' 'repositories: ${{ inputs.repository-name }}' 'repositories: Taurine,other'
mint_case 'no skip-token-revoke' '        skip-token-revoke: true
' ''
mint_case 'an unreviewed key' '        permission-contents: read
' '        permission-contents: read
        github-api-url: https://example.invalid
'
root="$(fresh app-id)"; swap "${root}" .github/actions/source-checkout/action.yml 'client-id:' 'app-id:'
expect_pass 'app-id is the reviewed alias of client-id' "${root}"
root="$(fresh mint-elsewhere)"; add_after "${root}" .github/workflows/ordinary.yml "${checkout_line}" "      - uses: actions/create-github-app-token@${sha}
"
expect_fail 'a mint in an unreviewed file' "${root}" 'ordinary.yml: token mint'
root="$(fresh no-mint)"; swap "${root}" .github/actions/source-checkout/action.yml "uses: actions/create-github-app-token@${sha}" "uses: actions/checkout@${sha}"
expect_fail 'the reviewed mint removed' "${root}" 'the reviewed token mint is missing'
checkout_case() {
  local label="$1" old="$2" new="$3" needle="${4:-must pass exactly the reviewed App settings}"
  root="$(fresh checkout-call)"; swap "${root}" .github/workflows/protected.yml "${old}" "${new}"
  expect_fail "a source-checkout call (${label})" "${root}" "${needle}"
}
checkout_case 'another repository id' 'repository-id: ${{ env.SOURCE_REPOSITORY_ID }}' "repository-id: '1377321992'"
checkout_case 'another owner' 'repository-owner: ${{ env.SOURCE_REPOSITORY_OWNER }}' 'repository-owner: someone'
checkout_case 'an extra input' "          check-protected-ancestry: 'true'
" "          check-protected-ancestry: 'true'
          app-scope: all
"
checkout_case 'a missing App key' '          app-private-key: ${{ secrets.SOURCE_READER_PRIVATE_KEY }}
' ''
checkout_case 'the workflow points at another repository' "  SOURCE_REPOSITORY_ID: '1330267721'" "  SOURCE_REPOSITORY_ID: '1377321992'" 'must pin SOURCE_REPOSITORY_ID, _OWNER and _NAME to the Taurine repository'
checkout_case 'the workflow renames the repository' '  SOURCE_REPOSITORY_NAME: Taurine' '  SOURCE_REPOSITORY_NAME: Other' 'must pin SOURCE_REPOSITORY_ID, _OWNER and _NAME'

# drop-root inputs are absent or the reviewed expression (rule 9).
reviewed_container="\${{ inputs.concern == 'e2e-visual' }}"
root="$(fresh container-root)"; cp .github/workflows/linux-validation-concern.yml "${root}/.github/workflows/"; expect_pass 'the reviewed container-root' "${root}"
swap "${root}" .github/workflows/linux-validation-concern.yml "container-root: ${reviewed_container}" "container-root: 'true'"
expect_fail 'an unconditional container-root' "${root}" 'drop-root container-root must be absent or the reviewed expression'
root="$(fresh keep-docker)"; cp .github/workflows/linux-validation-concern.yml "${root}/.github/workflows/"
swap "${root}" .github/workflows/linux-validation-concern.yml "container-root: ${reviewed_container}" "keep-docker: 'true'"
expect_fail 'an unreviewed keep-docker' "${root}" 'drop-root keep-docker must be absent or the reviewed expression'
reviewed_keep="\${{ inputs.engine == 'bastion' }}"
for keep in "'true'" 'true' '${{ true }}' "${reviewed_keep} || true"; do
  root="$(fresh keep-docker-arm)"; cp .github/workflows/live-proof-arm.yml "${root}/.github/workflows/"
  swap "${root}" .github/workflows/live-proof-arm.yml "keep-docker: ${reviewed_keep}" "keep-docker: ${keep}"
  expect_fail "keep-docker ${keep} in the live-proof arm" "${root}" 'drop-root keep-docker must be absent or the reviewed expression'
done
echo 'hardening fixtures: whole-context reads, unreviewed mints and source-checkout calls, and unreviewed drop-root inputs are rejected'

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
# Ref isolation: the compiled cache runs only on main for a protected source SHA.
cache_expect_fail 'compiled cache restore without the main guard' 'runs only on main for a protected source SHA' \
  's/if: \$\{\{ github\.ref == .refs\/heads\/main. && (steps\.verified-source\.outputs\.protected-ancestor == .true. && (?:\(startsWith\(inputs\.concern, .rust-app-.\)[^\n]*|startsWith\(inputs\.concern, .rust-app-.\)) \}\}\n        uses: actions\/cache\/restore)/if: \$\{\{ $1/'
cache_expect_fail 'compiled cache restore without protected ancestry' 'runs only on main for a protected source SHA' \
  's/(if: \$\{\{ github\.ref == .refs\/heads\/main. && )steps\.verified-source\.outputs\.protected-ancestor == .true. && ((?:\(startsWith\(inputs\.concern, .rust-app-.\)[^\n]*|startsWith\(inputs\.concern, .rust-app-.\)) \}\}\n        uses: actions\/cache\/restore)/$1$2/'
cache_expect_fail 'compiled cache gate re-opened by ||' 'runs only on main for a protected source SHA' \
  's/(if: \$\{\{ github\.ref == [^\n]*(?:\(startsWith\(inputs\.concern, .rust-app-.\)[^\n]*|startsWith\(inputs\.concern, .rust-app-.\))) \}\}(\n        uses: actions\/cache\/restore)/$1 || true }}$2/'
cache_expect_fail 'compiled cache strip without the main guard' 'strip step runs only on main' \
  's/if: \$\{\{ github\.ref == .refs\/heads\/main. && ((?:\(inputs\.concern == .rust-app-2.[^\n]*|inputs\.concern == .rust-app-2. && [^\n]*)steps\.concern-rust\.outcome)/if: \$\{\{ $1/'
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
  's/if: \$\{\{ (github\.ref == .refs\/heads\/main.) && (\(inputs\.concern == .taurine-cli.)/if: \${{ ($1 || true) \&\& $2/g'
# Ref isolation: the cargo source cache restore, its completion step and its save run only on
# main for a protected source SHA, and a setup action's built-in cache stays off.
cache_expect_fail 'cargo source restore without the main guard' 'cargo source cache runs only on main' \
  's/if: \$\{\{ github\.ref == .refs\/heads\/main. && (steps\.verified-source\.outputs\.protected-ancestor == .true. && \(inputs\.concern == .taurine-cli.[^\n]*\) \}\}\n        uses: actions\/cache\/restore)/if: \$\{\{ $1/'
cache_expect_fail 'cargo source restore gate re-opened by ||' 'cargo source cache runs only on main' \
  's/(if: \$\{\{ github\.ref == [^\n]*\(inputs\.concern == .taurine-cli.[^\n]*\)) \}\}(\n        uses: actions\/cache\/restore)/$1 || true }}$2/'
cache_expect_fail 'cargo source completion step without the main guard' 'cargo source cache runs only on main' \
  's/github\.ref == .refs\/heads\/main. && ([^\n]*\n        shell: bash\n        run: \|\n          set -euo pipefail\n          while IFS= read -r lock)/$1/'
cache_expect_fail 'cargo source restore with no condition' 'cargo source cache runs only on main' \
  's/\n        if: \$\{\{ github\.ref == [^\n]*\(inputs\.concern == .taurine-cli.[^\n]*\) \}\}(\n        uses: actions\/cache\/restore)/$1/'
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
echo 'cache policy fixtures: the cache guards reject restore-keys, an unguarded save, an unreviewed path and a cache step outside protected main'

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
drop_expect_fail 'docker after drop-root' .github/workflows/ios-validation.yml 'calls Docker after drop-root' \
  's/(          rustup target add aarch64-apple-ios-sim\n)/$1          docker ps\n/'
drop_expect_fail 'docker after drop-root once keep-docker is gone' .github/workflows/live-proof-arm.yml 'calls Docker after drop-root' \
  's/        with:\n          keep-docker: [^\n]*\n//; s/(          echo .vendor-fetch: passed.\n)/$1          docker ps\n/'
drop_expect_fail 'a sudo composite after drop-root' .github/workflows/android-validation.yml 'contains sudo and is called after drop-root' \
  's/(      - name: Remove root before project code\n        # Kept as \.\/ : the policy matches this exact form for local actions\.\n        uses: \.\/\.github\/actions\/drop-root[^\n]*\n)/$1\n      - name: Late privileged setup\n        uses: .\/.github\/actions\/root-setup\n        with:\n          concern: x\n/'
echo 'drop-root fixtures: a missing drop, project code or a setup composite before it, and sudo or Docker after it are rejected'

# --- Read-only untrusted restore, cache-mode and actions: write (docs/untrusted-readonly-cache.md) ---
# P1: the untrusted-ref restore gate. The base is the reviewed Linux concern plus one untrusted
# compiled-dependency restore and one untrusted source restore, with no restore-keys.
untrusted_base="${base}/untrusted-base.yml"
perl -0pe '
  my $pin = "actions/cache/restore\@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0";
  my $compiled = "      - name: Restore compiled third-party dependencies (untrusted, read-only)\n        id: cargo-target-cache-untrusted\n        if: \${{ github.ref == \x27refs/heads/untrusted\x27 && (startsWith(inputs.concern, \x27rust-app-\x27) || inputs.concern == \x27rust-db\x27 || inputs.concern == \x27rust-packaging\x27) }}\n        uses: $pin\n        with:\n          path: |\n            \${{ steps.cargo-target.outputs.dir }}/debug/deps\n            \${{ steps.cargo-target.outputs.dir }}/debug/build\n            \${{ steps.cargo-target.outputs.dir }}/debug/.fingerprint\n          key: \${{ steps.cargo-target.outputs.key }}\n\n";
  my $sources = "      - name: Restore cached third-party crate sources (untrusted, read-only)\n        id: cargo-sources-untrusted\n        if: \${{ github.ref == \x27refs/heads/untrusted\x27 && (inputs.concern == \x27taurine-cli\x27 || startsWith(inputs.concern, \x27rust-\x27) || inputs.concern == \x27scan-security\x27) }}\n        uses: $pin\n        with:\n          path: |\n            \${{ steps.cargo-home.outputs.dir }}/registry/cache\n          key: cargo-sources-v3-\${{ runner.os }}-\${{ hashFiles(\x27src/Cargo.lock\x27) }}\n\n";
  s/(      - name: Strip workspace crates from the restored dependency cache\n)/$compiled$1/;
  s/(      # Defence in depth: do not rely on cargo alone to notice a tampered archive\.)/$sources$1/;
' .github/workflows/linux-validation-concern.yml > "${untrusted_base}"
grep -qF 'untrusted, read-only' "${untrusted_base}" || { echo 'the untrusted restore fixture base was not built' >&2; exit 1; }
untrusted_expect_fail() {
  local label="$1" needle="$2" expr="$3"
  perl -0pe "${expr}" "${untrusted_base}" > "${cache_fixture}"
  if cmp -s "${untrusted_base}" "${cache_fixture}"; then echo "untrusted fixture '${label}' changed nothing" >&2; exit 1; fi
  if (source "${policy}/check-cache-policy.sh"; check_cache_policy "${cache_fixture}") >/dev/null 2>"${base}/err"; then
    echo "untrusted fixture '${label}' should fail but passed" >&2
    exit 1
  fi
  grep -qF -- "${needle}" "${base}/err" || { echo "untrusted fixture '${label}' failed with the wrong message:" >&2; cat "${base}/err" >&2; exit 1; }
}
(source "${policy}/check-cache-policy.sh"; check_cache_policy "${untrusted_base}") || { echo 'an untrusted restore with its own gate and no restore-keys should pass check-cache-policy.sh (check-cache-mode.rb decides whether its workflow is enforced)' >&2; exit 1; }
untrusted_gate='if: \$\{\{ github\.ref == .refs\/heads\/untrusted. && (\(startsWith\(inputs\.concern, .rust-app-.\)[^\n]*) \}\}\n        uses: actions\/cache\/restore\@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6\.1\.0\n        with:\n          path: \|\n            \$\{\{ steps\.cargo-target'
untrusted_expect_fail 'untrusted restore with no gate term' 'runs only on main for a protected source SHA' \
  "s/if: \\\$\\{\\{ github\\.ref == .refs\\/heads\\/untrusted. && (\\(startsWith\\(inputs\\.concern, .rust-app-.\\))/if: \\\$\\{\\{ \$1/"
untrusted_expect_fail 'untrusted gate re-opened by ||' 'runs only on main for a protected source SHA' \
  "s/(github\\.ref == .refs\\/heads\\/untrusted. && \\(startsWith\\(inputs\\.concern, .rust-app-.\\)[^\\n]*?) \\}\\}/\$1 || true }}/"
untrusted_expect_fail 'untrusted term inside an always-true alternative' 'runs only on main for a protected source SHA' \
  "s/if: \\\$\\{\\{ github\\.ref == .refs\\/heads\\/untrusted. && \\(startsWith\\(inputs\\.concern, .rust-app-./if: \\\$\\{\\{ (github.ref == 'refs\\/heads\\/untrusted' || true) \\&\\& (startsWith(inputs.concern, 'rust-app-/"
untrusted_expect_fail 'untrusted term negated' 'runs only on main for a protected source SHA' \
  "s/if: \\\$\\{\\{ github\\.ref == .refs\\/heads\\/untrusted. && \\(startsWith\\(inputs\\.concern, .rust-app-./if: \\\$\\{\\{ !(github.ref == 'refs\\/heads\\/untrusted') \\&\\& (startsWith(inputs.concern, 'rust-app-/"
untrusted_expect_fail 'untrusted restore carrying both gates' 'runs only on main for a protected source SHA' \
  "s/if: \\\$\\{\\{ github\\.ref == .refs\\/heads\\/untrusted. && \\(startsWith\\(inputs\\.concern, .rust-app-./if: \\\$\\{\\{ github.ref == 'refs\\/heads\\/untrusted' \\&\\& github.ref == 'refs\\/heads\\/main' \\&\\& steps.verified-source.outputs.protected-ancestor == 'true' \\&\\& (startsWith(inputs.concern, 'rust-app-/"
untrusted_expect_fail 'untrusted compiled restore with restore-keys' 'must not have restore-keys' \
  "s/(untrusted, read-only\\)\\n.*?          key: \\\$\\{\\{ steps\\.cargo-target\\.outputs\\.key \\}\\}\\n)/\$1          restore-keys: |\\n            cargo-target-\\n/s"
untrusted_expect_fail 'untrusted compiled restore with fail-on-cache-miss' 'Unexpected cache option' \
  "s/(untrusted, read-only\\)\\n.*?          key: \\\$\\{\\{ steps\\.cargo-target\\.outputs\\.key \\}\\}\\n)/\$1          fail-on-cache-miss: true\\n/s"
untrusted_expect_fail 'untrusted compiled restore with lookup-only' 'Unexpected cache option' \
  "s/(untrusted, read-only\\)\\n.*?          key: \\\$\\{\\{ steps\\.cargo-target\\.outputs\\.key \\}\\}\\n)/\$1          lookup-only: true\\n/s"
untrusted_expect_fail 'untrusted restore of an unreviewed path' 'Disallowed cache path line' \
  "s/(untrusted, read-only\\)\\n.*?)debug\\/build\\n/\$1debug\\n/s"
untrusted_expect_fail 'untrusted source restore with restore-keys' 'must have no restore-keys' \
  "s/(untrusted, read-only\\)\\n.*?          key: cargo-sources-v3-\\\$\\{\\{ runner\\.os \\}\\}-\\\$\\{\\{ hashFiles\\('src\\/Cargo\\.lock'\\) \\}\\}\\n)/\$1          restore-keys: |\\n            cargo-sources-v3-\\\$\\{\\{ runner.os \\}\\}-\\n/s"
# Saves, completion and strip-and-prove never take the untrusted ref.
untrusted_expect_fail 'a compiled save gated to untrusted instead of main' 'must require the main branch as a top-level term' \
  "s/(      - name: Save compiled third-party dependencies\\n        if: \\\$\\{\\{ )github\\.ref == .refs\\/heads\\/main./\$1github.ref == 'refs\\/heads\\/untrusted'/"
untrusted_expect_fail 'a compiled save that also names untrusted' 'must never mention the untrusted ref' \
  "s/(      - name: Save compiled third-party dependencies\\n        if: \\\$\\{\\{ github\\.ref == .refs\\/heads\\/main. && )/\$1github.ref != 'refs\\/heads\\/untrusted' \\&\\& /"
untrusted_expect_fail 'a source save that also names untrusted' 'must never mention the untrusted ref' \
  "s/(      - name: Save verified third-party crate sources\\n        if: \\\$\\{\\{ github\\.ref == .refs\\/heads\\/main. && )/\$1github.ref != 'refs\\/heads\\/untrusted' \\&\\& /"
untrusted_expect_fail 'a compiled save with no condition' 'must require the main branch as a top-level term' \
  "s/(      - name: Save compiled third-party dependencies\\n)        if: [^\\n]*\\n/\$1/"
untrusted_expect_fail 'a strip-and-prove step gated to untrusted' 'runs only on main for a protected source SHA' \
  "s/(      - name: Strip and prove the compiled dependency cache\\n        id: cargo-target-strip\\n        if: \\\$\\{\\{ )github\\.ref == .refs\\/heads\\/main./\$1github.ref == 'refs\\/heads\\/untrusted'/"
untrusted_expect_fail 'a source completion step gated to untrusted' 'runs only on main for a protected source SHA' \
  "s/(      - name: Complete the third-party source set before saving\\n        if: \\\$\\{\\{ )github\\.ref == .refs\\/heads\\/main./\$1github.ref == 'refs\\/heads\\/untrusted'/"
echo 'untrusted restore fixtures: only a gated, exact-keyed, read-only restore passes; a save, completion or strip step never takes the untrusted ref'

# P3: a cache restore comes after drop-root, never between the source revoke and root removal.
drop_expect_fail 'a cache restore between the revoke and drop-root' .github/workflows/linux-validation-concern.yml 'drop-root' \
  's/(      - name: Remove root before project code\n)/      - name: Early cache restore\n        uses: actions\/cache\/restore\@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: \/tmp\/x\n          key: k\n\n$1/'

# P2 and P7: cache-mode and actions: write.
mode_root="${base}/cache-mode"
mkdir -p "${mode_root}/.github/workflows"
printf '# fixture\n' > "${mode_root}/enforced.txt"
printf 'split.yml\n' > "${mode_root}/enforced-split.txt"
write_mode() { # file, content
  cat > "${mode_root}/.github/workflows/$1"
}
mode_run() { (cd "${mode_root}" && ruby "${policy}/check-cache-mode.rb" --enforced-file "${mode_root}/${ENFORCED:-enforced.txt}" ".github/workflows/$1") ; }
mode_expect_pass() { mode_run "$1" >/dev/null 2>"${base}/err" || { echo "cache-mode fixture '$2' should pass but failed:" >&2; cat "${base}/err" >&2; exit 1; }; }
mode_expect_fail() {
  local file="$1" label="$2" needle="$3"
  if mode_run "${file}" >/dev/null 2>"${base}/err"; then echo "cache-mode fixture '${label}' should fail but passed" >&2; exit 1; fi
  grep -qF -- "${needle}" "${base}/err" || { echo "cache-mode fixture '${label}' failed with the wrong message:" >&2; cat "${base}/err" >&2; exit 1; }
}
mode_wf() { # JOBS-YAML [WORKFLOW-LEVEL-LINE]
  printf 'name: f\non:\n  workflow_dispatch:\npermissions: {}\n%s\njobs:\n%s\n' "${2:-}" "$1"
}
main_if="if: \${{ github.ref == 'refs/heads/main' && github.repository == 'Moh-Bakr/Taurine-CI' }}"
mode_wf "  a:
    cache-mode: read
    runs-on: ubuntu-24.04
    steps:
      - run: true
  b:
    ${main_if}
    cache-mode: write
    runs-on: ubuntu-24.04
    steps:
      - run: true
  c:
    cache-mode: none
    runs-on: ubuntu-24.04
    steps:
      - run: true" 'cache-mode: none' | write_mode ok.yml
mode_expect_pass ok.yml 'read, a main-gated write and none, with a workflow-level none'
for bad in write-only 'write-all' '${{ github.ref }}' 'Write'; do
  mode_wf "  a:
    cache-mode: ${bad}
    runs-on: ubuntu-24.04
    steps:
      - run: true" | write_mode bad.yml
  mode_expect_fail bad.yml "cache-mode ${bad}" 'must be the literal read, write or none'
done
mode_wf "  a:
    cache-mode: read
    runs-on: ubuntu-24.04
    steps:
      - run: true" 'cache-mode: write' | write_mode bad.yml
mode_expect_fail bad.yml 'workflow-level write' 'a workflow-level cache-mode is only none'
mode_wf "  a:
    cache-mode: read
    runs-on: ubuntu-24.04
    steps:
      - run: true" 'cache-mode: read' | write_mode bad.yml
mode_expect_fail bad.yml 'workflow-level read' 'a workflow-level cache-mode is only none'
for cond in "" "if: \${{ github.ref == 'refs/heads/untrusted' }}" "if: \${{ github.ref == 'refs/heads/main' || github.ref == 'refs/heads/untrusted' }}" "if: \${{ github.ref == 'refs/heads/main' || true }}" "if: \${{ !(github.ref == 'refs/heads/main') }}" "if: \${{ (github.ref == 'refs/heads/main' || true) && github.repository == 'x' }}"; do
  mode_wf "  a:
    ${cond}
    cache-mode: write
    runs-on: ubuntu-24.04
    steps:
      - run: true" | write_mode bad.yml
  mode_expect_fail bad.yml "write gated by [${cond}]" 'cache-mode write needs the exact top-level term'
done
printf 'name: called\non:\n  workflow_call:\npermissions: {}\njobs:\n  a:\n    cache-mode: read\n    runs-on: ubuntu-24.04\n    steps:\n      - run: true\n' > "${mode_root}/.github/workflows/called.yml"
mode_expect_fail called.yml 'cache-mode in a called workflow' "a called workflow must not set cache-mode"
printf 'name: called\non:\n  workflow_call:\npermissions: {}\ncache-mode: none\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: true\n' > "${mode_root}/.github/workflows/called.yml"
mode_expect_fail called.yml 'workflow-level cache-mode in a called workflow' "a called workflow must not set cache-mode"
# Staged rules F to J, over a caller split.
cat > "${mode_root}/.github/workflows/split-concern.yml" <<'YAML'
name: concern
on:
  workflow_call:
permissions: {}
jobs:
  v:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9
YAML
write_split() { # main-job cache-mode, main-job if, untrusted-job cache-mode, untrusted-job if, workflow-level, untrusted-job extra-needs-and-if override, audit-job body override
  local unt_needs="${6-[cache-audit]}"
  cat > "${mode_root}/.github/workflows/split.yml" <<YAML
name: split
on:
  workflow_dispatch:
permissions: {}
${5-cache-mode: none}
jobs:
  validate-input:
    runs-on: ubuntu-24.04
    steps:
      - run: true
${7-$(audit_jobs)}
  validate-main:
    ${2}
    ${1}
    uses: ./.github/workflows/split-concern.yml
  validate-untrusted:
    needs: ${unt_needs}
    ${4}
    ${3}
    uses: ./.github/workflows/split-concern.yml
YAML
}
audit_jobs() {
  cat <<'YAML'
  cache-audit:
    if: ${{ github.ref == 'refs/heads/untrusted' && needs.validate-input.result == 'success' }}
    needs: [validate-input]
    runs-on: ubuntu-24.04
    permissions:
      actions: read
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - uses: ./.github/actions/cache-scope-audit
        with:
          github-token: ${{ github.token }}
          phase: before
  cache-audit-after:
    if: ${{ always() && github.ref == 'refs/heads/untrusted' }}
    needs: [cache-audit, validate-untrusted]
    runs-on: ubuntu-24.04
    permissions:
      actions: read
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - uses: ./.github/actions/cache-scope-audit
        with:
          github-token: ${{ github.token }}
          phase: after
  result:
    if: ${{ always() }}
    needs: [cache-audit, cache-audit-after, validate-main, validate-untrusted]
    runs-on: ubuntu-24.04
    steps:
      - uses: ./.github/actions/run-result
        with:
          blocking-failures: ${{ (contains(fromJSON('["failure","cancelled"]'), needs.cache-audit.result) || contains(fromJSON('["failure","cancelled"]'), needs.cache-audit-after.result)) && '1' || '0' }}
YAML
}
read_if="if: \${{ github.ref == 'refs/heads/untrusted' && needs.cache-audit.result == 'success' }}"
ENFORCED=enforced-split.txt
write_split 'cache-mode: write' "${main_if}" 'cache-mode: read' "${read_if}"
mode_expect_pass split.yml 'a validate-main / validate-untrusted split'
write_split 'cache-mode: write' "${main_if}" 'cache-mode: read' "${read_if}" ''
mode_expect_fail split.yml 'enforced workflow without workflow-level none' 'needs a workflow-level cache-mode: none'
write_split '' "${main_if}" 'cache-mode: read' "${read_if}"
mode_expect_fail split.yml 'caller job with no cache-mode' 'must declare its own cache-mode'
write_split 'cache-mode: read' "${main_if}" 'cache-mode: read' "${read_if}"
mode_expect_fail split.yml 'saving caller job that is only read' 'needs a sibling job'
write_split 'cache-mode: write' "${main_if}" 'cache-mode: write' "${read_if}"
mode_expect_fail split.yml 'untrusted half granted write' 'cache-mode write needs the exact top-level term'
write_split 'cache-mode: write' "${main_if}" 'cache-mode: read' "if: \${{ github.ref == 'refs/heads/main' }}"
mode_expect_fail split.yml 'untrusted half gated to main' 'needs a sibling job'
write_split 'cache-mode: write' "${main_if}" 'cache-mode: read' "if: \${{ github.ref == 'refs/heads/untrusted' || true }}"
mode_expect_fail split.yml 'untrusted half gate re-opened' 'needs a sibling job'
write_split 'cache-mode: write' "if: \${{ github.ref == 'refs/heads/main' && github.ref != 'refs/heads/untrusted' }}" 'cache-mode: read' "${read_if}"
mode_expect_fail split.yml 'main half naming untrusted' 'must not mention the untrusted ref'
write_split 'cache-mode: write' "${main_if}" '' "${read_if}"
mode_expect_fail split.yml 'untrusted half with no cache-mode' 'must declare its own cache-mode'
# K: the untrusted half needs the audit before it, and the audit jobs are exactly reviewed.
write_split 'cache-mode: write' "${main_if}" 'cache-mode: read' "${read_if}" 'cache-mode: none' ''
mode_expect_fail split.yml 'untrusted half without needs cache-audit' 'must need the cache-audit job directly'
write_split 'cache-mode: write' "${main_if}" 'cache-mode: read' "if: \${{ github.ref == 'refs/heads/untrusted' }}"
mode_expect_fail split.yml 'untrusted half without the audit success term' "needs.cache-audit.result == 'success'"
write_split 'cache-mode: write' "${main_if}" 'cache-mode: read' "${read_if}" 'cache-mode: none' '[cache-audit]' ''
mode_expect_fail split.yml 'no audit jobs at all' 'needs a cache-audit job'
audit_mutation() { # label needle perl-expr
  write_split 'cache-mode: write' "${main_if}" 'cache-mode: read' "${read_if}"
  perl -0pi -e "$3" "${mode_root}/.github/workflows/split.yml"
  mode_expect_fail split.yml "$1" "$2"
}
audit_mutation 'audit not limited to the untrusted ref' 'must run only on the untrusted ref' 's/if: \$\{\{ github\.ref == .refs\/heads\/untrusted. && needs\.validate-input/if: \${{ needs.validate-input/'
audit_mutation 'audit with an environment' 'no environment, no secrets' 's/(  cache-audit:\n)/$1    environment: source-read\n/'
audit_mutation 'audit with an extra permission' 'exactly actions: read and contents: read' 's/(      actions: read\n      contents: read\n    steps:\n      - uses: actions\/checkout\@[0-9a-f]+\n      - uses: .\/.github\/actions\/cache-scope-audit\n        with:\n          github-token: \$\{\{ github.token \}\}\n          phase: before)/      actions: read\n      contents: read\n      issues: write\n    steps:\n      - uses: actions\/checkout\@3d3c42e5aac5ba805825da76410c181273ba90b1\n      - uses: .\/.github\/actions\/cache-scope-audit\n        with:\n          github-token: \${{ github.token }}\n          phase: before/'
audit_mutation 'audit before-phase swapped' 'phase before' 's/phase: before/phase: after/'
audit_mutation 'audit running another command' 'only the public checkout and the audit composite' 's/(      - uses: .\/.github\/actions\/cache-scope-audit\n        with:\n          github-token: \$\{\{ github.token \}\}\n          phase: before\n)/$1      - run: true\n/'
audit_mutation 'after-audit not needing the untrusted half' 'must need validate-untrusted' 's/needs: \[cache-audit, validate-untrusted\]/needs: [cache-audit]/'
audit_mutation 'result not needing the after-audit' 'the result job must need cache-audit-after' 's/needs: \[cache-audit, cache-audit-after, validate-main, validate-untrusted\]/needs: [cache-audit, validate-main, validate-untrusted]/'
audit_mutation 'result not passing blocking-failures' 'must pass blocking-failures exactly' 's/\n          blocking-failures: [^\n]*\n/\n          selection-mode: full\n/'
audit_mutation 'result passing another blocking expression' 'must pass blocking-failures exactly' "s/ && '1' \|\| '0' \}\}/ \&\& '0' || '0' }}/"
audit_mutation 'no result job' 'needs a result job' 's/\n  result:\n    if: \$\{\{ always\(\) \}\}\n    needs: \[[^\n]*\]\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: .\/.github\/actions\/run-result\n        with:\n          blocking-failures: [^\n]*\n/\n/'
cat > "${mode_root}/.github/workflows/split.yml" <<YAML
name: split
on:
  workflow_dispatch:
permissions: {}
cache-mode: none
jobs:
  inline-save:
    cache-mode: read
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9
  inline-restore:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9
YAML
mode_expect_fail split.yml 'an inline save job that is only read' 'must be cache-mode write'
mode_expect_fail split.yml 'an inline restore job with no cache-mode' 'must declare its own cache-mode'
unset ENFORCED
# F1: an untrusted-ref cache step fails closed: its workflow, and every caller of it, must already
# be an enforced workflow, because without a cache-mode key a job keeps the default write grant.
many_run() { (cd "${mode_root}" && ruby "${policy}/check-cache-mode.rb" --enforced-file "${mode_root}/${ENFORCED:-enforced.txt}" "$@"); }
many_expect_fail() {
  local label="$1" needle="$2"; shift 2
  if many_run "$@" >/dev/null 2>"${base}/err"; then echo "cache-mode fixture '${label}' should fail but passed" >&2; exit 1; fi
  grep -qF -- "${needle}" "${base}/err" || { echo "cache-mode fixture '${label}' failed with the wrong message:" >&2; cat "${base}/err" >&2; exit 1; }
}
cat > "${mode_root}/.github/workflows/split-concern.yml" <<'YAML'
name: concern
on:
  workflow_call:
permissions: {}
jobs:
  v:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9
        if: ${{ github.ref == 'refs/heads/untrusted' }}
      - uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9
        if: ${{ github.ref == 'refs/heads/main' }}
YAML
read_if="if: \${{ github.ref == 'refs/heads/untrusted' && needs.cache-audit.result == 'success' }}"
ENFORCED=enforced-split.txt
write_split 'cache-mode: write' "${main_if}" 'cache-mode: read' "${read_if}"
many_run .github/workflows/split.yml .github/workflows/split-concern.yml >/dev/null 2>"${base}/err" || { echo 'an untrusted restore behind an enforced caller split should pass' >&2; cat "${base}/err" >&2; exit 1; }
ENFORCED=enforced.txt
many_expect_fail 'untrusted restore, caller not enforced' 'is not in ENFORCED_WORKFLOWS' .github/workflows/split.yml .github/workflows/split-concern.yml
many_expect_fail 'untrusted restore, no caller given' 'none was found' .github/workflows/split-concern.yml
printf 'name: lone\non:\n  workflow_dispatch:\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9\n        if: ${{ github.ref == '"'"'refs/heads/untrusted'"'"' }}\n' > "${mode_root}/.github/workflows/lone.yml"
many_expect_fail 'untrusted restore in a workflow nobody enforces' 'but is not in ENFORCED_WORKFLOWS' .github/workflows/lone.yml
printf 'lone.yml\n' > "${mode_root}/enforced-lone.txt"
ENFORCED=enforced-lone.txt
many_expect_fail 'untrusted restore in an enforced workflow without cache-mode' 'must declare its own cache-mode' .github/workflows/lone.yml
# M: an untrusted restore is refused while any workflow that can run on the untrusted ref is not enforced.
printf 'name: macish\non:\n  workflow_dispatch:\npermissions: {}\njobs:\n  validate:\n    if: ${{ github.ref == '"'"'refs/heads/main'"'"' || github.ref == '"'"'refs/heads/untrusted'"'"' }}\n    runs-on: ubuntu-24.04\n    steps:\n      - run: true\n' > "${mode_root}/.github/workflows/macish.yml"
write_split 'cache-mode: write' "${main_if}" 'cache-mode: read' "if: \${{ github.ref == 'refs/heads/untrusted' && needs.cache-audit.result == 'success' }}"
ENFORCED=enforced-split.txt
many_expect_fail 'an untrusted restore while an unenforced workflow can run on untrusted' 'can run on the untrusted ref without cache-mode enforcement' .github/workflows/split.yml .github/workflows/split-concern.yml .github/workflows/macish.yml
printf 'split.yml\nmacish.yml\n' > "${mode_root}/enforced-both.txt"
printf 'name: macish\non:\n  workflow_dispatch:\npermissions: {}\ncache-mode: none\njobs:\n  validate:\n    if: ${{ github.ref == '"'"'refs/heads/main'"'"' || github.ref == '"'"'refs/heads/untrusted'"'"' }}\n    runs-on: ubuntu-24.04\n    steps:\n      - run: true\n' > "${mode_root}/.github/workflows/macish.yml"
ENFORCED=enforced-both.txt
many_run .github/workflows/split.yml .github/workflows/split-concern.yml .github/workflows/macish.yml >/dev/null 2>"${base}/err" || { echo 'an untrusted restore with every untrusted-running workflow enforced should pass' >&2; cat "${base}/err" >&2; exit 1; }
unset ENFORCED
unset ENFORCED
# L: two-deep reusable nesting is unsupported and fails closed.
printf 'name: nested\non:\n  workflow_call:\npermissions: {}\njobs:\n  inner:\n    uses: ./.github/workflows/split-concern.yml\n' > "${mode_root}/.github/workflows/nested.yml"
many_expect_fail 'a called workflow that calls another' 'nested reusable workflows are unsupported' .github/workflows/nested.yml
# Duplicate and disguised keys, a plain actions/cache and a cache step hidden in a composite.
dup_wf() { printf 'name: d\non:\n  workflow_dispatch:\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-24.04\n%s\n    steps:\n      - run: true\n' "$1" > "${mode_root}/.github/workflows/dup.yml"; }
dup_wf $'    cache-mode: write\n    cache-mode: read'
many_expect_fail 'duplicate cache-mode keys' 'duplicate key "cache-mode"' .github/workflows/dup.yml
dup_wf $'    if: ${{ github.ref == \'refs/heads/main\' }}\n    if: ${{ github.ref == \'refs/heads/untrusted\' }}\n    cache-mode: read'
many_expect_fail 'duplicate if keys' 'duplicate key "if"' .github/workflows/dup.yml
for variant in 'Cache-Mode: read' 'cache_mode: read' 'CACHE-MODE: read' '"cache mode": read'; do
  dup_wf "    ${variant}"
  many_expect_fail "disguised key ${variant}" 'in disguise' .github/workflows/dup.yml
done
printf 'name: c\non:\n  workflow_dispatch:\npermissions: {}\ncache-mode: none\njobs:\n  a:\n    cache-mode: read\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9\n' > "${mode_root}/.github/workflows/combined.yml"
printf 'combined.yml\n' > "${mode_root}/enforced-combined.txt"
ENFORCED=enforced-combined.txt
many_expect_fail 'a plain actions/cache job that is only read' 'must be cache-mode write' .github/workflows/combined.yml
unset ENFORCED
mkdir -p "${mode_root}/.github/actions/hidden"
printf 'name: hidden\nruns:\n  using: composite\n  steps:\n    - uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9\n' > "${mode_root}/.github/actions/hidden/action.yml"
printf 'name: h\non:\n  workflow_dispatch:\npermissions: {}\ncache-mode: none\njobs:\n  a:\n    cache-mode: read\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: ./.github/actions/hidden\n' > "${mode_root}/.github/workflows/hidden.yml"
printf 'hidden.yml\n' > "${mode_root}/enforced-hidden.txt"
ENFORCED=enforced-hidden.txt
many_expect_fail 'a save hidden in a composite under a read job' 'must be cache-mode write' .github/workflows/hidden.yml
unset ENFORCED
# The plain actions/cache is refused by the cache policy as well.
perl -0pe 's/uses: actions\/cache\/restore\@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6\.1\.0\n        with:\n          path: \|\n            \$\{\{ steps\.cargo-target/uses: actions\/cache\@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: |\n            \${{ steps.cargo-target/' .github/workflows/linux-validation-concern.yml > "${cache_fixture}"
if cmp -s .github/workflows/linux-validation-concern.yml "${cache_fixture}"; then echo 'the plain actions/cache fixture changed nothing' >&2; exit 1; fi
if (source "${policy}/check-cache-policy.sh"; check_cache_policy "${cache_fixture}") >/dev/null 2>&1; then echo 'the plain actions/cache should be refused by the cache policy' >&2; exit 1; fi
echo 'cache-mode F1 fixtures: an untrusted-ref cache step needs its workflow and callers enforced; duplicate, disguised, plain and composite-hidden cache uses are caught'

# P7: actions: write.
mkdir -p "${mode_root}/p7"
cp .github/workflows/cache-prune.yml "${mode_root}/p7/cache-prune.yml"
p7_run() { ruby "${policy}/check-cache-mode.rb" --enforced-file "${mode_root}/enforced.txt" "$1"; }
p7_run "${mode_root}/p7/cache-prune.yml" >/dev/null || { echo 'the reviewed cache-prune workflow should pass the actions: write rules' >&2; exit 1; }
p7_run .github/workflows/weekly-validation.yml >/dev/null || { echo 'the reviewed weekly workflow should pass the actions: write rules' >&2; exit 1; }
p7_expect_fail() { # label needle perl-expr file
  local label="$1" needle="$2" expr="$3" name="$4" src="${5:-.github/workflows/$4}"
  perl -0pe "${expr}" "${src}" > "${mode_root}/p7/${name}"
  if cmp -s "${src}" "${mode_root}/p7/${name}"; then echo "actions: write fixture '${label}' changed nothing" >&2; exit 1; fi
  if p7_run "${mode_root}/p7/${name}" >/dev/null 2>"${base}/err"; then echo "actions: write fixture '${label}' should fail but passed" >&2; exit 1; fi
  grep -qF -- "${needle}" "${base}/err" || { echo "actions: write fixture '${label}' failed with the wrong message:" >&2; cat "${base}/err" >&2; exit 1; }
}
p7_expect_fail 'cache-prune without the main term' 'needs the exact top-level terms' \
  's/ && github\.ref == .refs\/heads\/main.//' cache-prune.yml
p7_expect_fail 'cache-prune main term re-opened by ||' 'needs the exact top-level terms' \
  's/(if: github\.repository == .Moh-Bakr\/Taurine-CI. && github\.ref == .refs\/heads\/main.)/$1 || true/' cache-prune.yml
p7_expect_fail 'cache-prune with an environment' 'must have no environment' \
  's/(    runs-on: ubuntu-24\.04\n)/    environment: source-read\n$1/' cache-prune.yml
p7_expect_fail 'cache-prune calling a local composite' 'no local composite' \
  's/(    steps:\n)/$1      - uses: .\/.github\/actions\/sanitize\n/' cache-prune.yml
p7_expect_fail 'cache-prune reading a secret' 'must read no secret' \
  's/(          GH_TOKEN: )\$\{\{ github\.token \}\}/$1\${{ secrets.X }}/' cache-prune.yml
p7_expect_fail 'cache-prune with workflow-level actions: write' 'not the whole workflow' \
  's/^permissions: \{\}$/permissions:\n  actions: write/m' cache-prune.yml
p7_expect_fail 'a weekly dispatch job without the main term' 'needs a job gated by the exact top-level term' \
  's/(  dispatch:\n    if: github\.repository == .Moh-Bakr\/Taurine-CI.) && github\.ref == .refs\/heads\/main./$1/' weekly-validation.yml
p7_expect_fail 'actions: write on the scorecard job' 'held to cache-prune.yml' \
  's/(      actions: )read/${1}write/' scorecard.yml
p7_expect_fail 'write-all on the scorecard job' 'held to cache-prune.yml' \
  's/    permissions:\n      contents: read\n      actions: read\n      checks: read\n      issues: read\n      pull-requests: read\n/    permissions: write-all\n/' scorecard.yml
echo 'cache-mode fixtures: literal read, write or none only; write only on main-gated jobs; none inside called workflows is refused; the caller split is required where a workflow saves; actions: write is held to the two reviewed places'

# The composite cache rule matches `actions/cache` as a whole path segment: this repository's own
# cache listing endpoint (`/actions/caches`) is allowed, the cache actions are not.
composite_probe="${base}/composite-probe.yml"
for text in 'uses: actions/cache/restore@x' 'uses: actions/cache/save@x' 'uses: actions/cache@x' 'uses: actions/cache' 'run: echo actions/cache'; do
  printf 'name: p\nruns:\n  using: composite\n  steps:\n    - %s\n' "${text}" > "${composite_probe}"
  if (source "${policy}/lib.sh"; source "${policy}/check-cache-policy.sh"; check_composite_action "${composite_probe}") >/dev/null 2>&1; then
    echo "a composite containing '${text}' should be refused" >&2; exit 1
  fi
done
(source "${policy}/lib.sh"; source "${policy}/check-cache-policy.sh"; check_composite_action .github/actions/cache-scope-audit/action.yml) || { echo 'the cache-scope-audit composite should pass the composite rules' >&2; exit 1; }
# The reviewed Linux and Windows dispatchers pass the enforced rules as shipped.
ruby "${policy}/check-cache-mode.rb" .github/workflows/linux-validation.yml .github/workflows/windows-validation.yml .github/workflows/linux-validation-concern.yml .github/workflows/windows-validation-concern.yml >/dev/null || { echo 'the reviewed Linux and Windows dispatchers should pass the cache-mode rules' >&2; exit 1; }
real_mode_fail() { # label needle perl-expr file
  mkdir -p "${mode_root}/real/.github/workflows"
  cp .github/workflows/linux-validation-concern.yml .github/workflows/windows-validation-concern.yml "${mode_root}/real/.github/workflows/"
  perl -0pe "$3" ".github/workflows/$4" > "${mode_root}/real/.github/workflows/$4"
  if cmp -s ".github/workflows/$4" "${mode_root}/real/.github/workflows/$4"; then echo "cache-mode fixture '$1' changed nothing" >&2; exit 1; fi
  if (cd "${mode_root}/real" && ruby "${policy}/check-cache-mode.rb" ".github/workflows/$4") >/dev/null 2>"${base}/err"; then echo "cache-mode fixture '$1' should fail but passed" >&2; exit 1; fi
  grep -qF -- "$2" "${base}/err" || { echo "cache-mode fixture '$1' failed with the wrong message:" >&2; cat "${base}/err" >&2; exit 1; }
}
real_mode_fail 'Linux workflow-level none dropped' 'needs a workflow-level cache-mode: none' 's/\ncache-mode: none\n/\n/' linux-validation.yml
real_mode_fail 'Linux validate-untrusted not read' 'cache-mode write needs the exact top-level term' 's/cache-mode: read\n/cache-mode: write\n/' linux-validation.yml
real_mode_fail 'Linux validate-untrusted without the audit need' 'must need the cache-audit job directly' 's/needs: \[validate-input, plan, select, cache-audit\]/needs: [validate-input, plan, select]/' linux-validation.yml
real_mode_fail 'Linux validate-main only read' 'needs a sibling job' 's/cache-mode: write\n/cache-mode: read\n/' linux-validation.yml
real_mode_fail 'Linux select caller without its explicit none' 'must declare its own cache-mode' 's/    cache-mode: none\n    uses: .\/.github\/workflows\/select-concerns.yml/    uses: .\/.github\/workflows\/select-concerns.yml/' linux-validation.yml
real_mode_fail 'Windows validate-rust-untrusted gated to main' 'needs a sibling job' "s/(  validate-rust-untrusted:\\n(?:.*\\n)*?    if: github\\.repository == 'Moh-Bakr\\/Taurine-CI' && github\\.ref == )'refs\\/heads\\/untrusted'/\$1'refs\\/heads\\/main'/" windows-validation.yml
real_mode_fail 'Windows validate-main downgraded to read' 'read-only without the exact top-level term' "s/(  validate-main:\\n(?:.*\\n)*?)    cache-mode: write\\n/\$1    cache-mode: read\\n/" windows-validation.yml
real_mode_fail 'Linux result without blocking-failures' 'must pass blocking-failures exactly' 's/\n          blocking-failures: [^\n]*\n/\n/' linux-validation.yml
real_mode_fail 'Windows result not needing the after-audit' 'the result job must need cache-audit-after' 's/(    needs: \[validate-main, validate-untrusted, validate-rust-main, validate-rust-untrusted, cache-audit), cache-audit-after\]\n    name: Result/$1]\n    name: Result/' windows-validation.yml
real_mode_fail 'Windows without the after-audit' 'needs a cache-audit-after job' 's/\n  cache-audit-after:\n/\n  cache-audit-later:\n/' windows-validation.yml
echo 'cache-mode real-tree fixtures: the reviewed Linux and Windows dispatchers pass; each weakening of the split, the audit or the explicit grants is refused'
printf 'name: p\nruns:\n  using: composite\n  steps:\n    - shell: bash\n      run: curl "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/actions/caches?ref=refs/heads/untrusted"\n' > "${composite_probe}"
(source "${policy}/lib.sh"; source "${policy}/check-cache-policy.sh"; check_composite_action "${composite_probe}") >/dev/null 2>&1 || { echo 'a composite that only reads the cache listing endpoint should pass the composite rules' >&2; exit 1; }

# Classification of the macOS workflow by shape (workflow-lists.sh): inline environment means a
# source workflow, none means a pure dispatcher; no other protected source workflow gains that
# freedom, so check_protected_source still refuses an environment-less one.
classify() { (source "${policy}/workflow-lists.sh"; classify_workflow "$1"); }
classify_root="${base}/classify"
mkdir -p "${classify_root}/.github/workflows"
printf 'jobs:\n  validate:\n    environment: source-read\n' > "${classify_root}/inline.yml"
printf 'jobs:\n  validate-main:\n    uses: ./.github/workflows/macos-validation-concern.yml\n' > "${classify_root}/dispatcher.yml"
(cd "${classify_root}" && mkdir -p .github/workflows && cp inline.yml .github/workflows/macos-validation.yml && [[ "$(classify .github/workflows/macos-validation.yml)" == source ]]) || { echo 'an inline macOS workflow must be classified as a source workflow' >&2; exit 1; }
(cd "${classify_root}" && cp dispatcher.yml .github/workflows/macos-validation.yml && [[ "$(classify .github/workflows/macos-validation.yml)" == dispatcher ]]) || { echo 'an environment-less macOS workflow must be classified as a dispatcher' >&2; exit 1; }
(cd "${classify_root}" && cp dispatcher.yml .github/workflows/source-read.yml && [[ "$(classify .github/workflows/source-read.yml)" == source ]]) || { echo 'an environment-less source-read workflow must stay a source workflow' >&2; exit 1; }
(cd "${classify_root}" && cp inline.yml .github/workflows/windows-validation.yml && [[ "$(classify .github/workflows/windows-validation.yml)" == dispatcher ]]) || { echo 'the Windows dispatcher must stay a dispatcher' >&2; exit 1; }
(cd "${classify_root}" && cp dispatcher.yml .github/workflows/macos-validation-concern.yml && [[ "$(classify .github/workflows/macos-validation-concern.yml)" == source ]]) || { echo 'the macOS concern workflow must be a source workflow' >&2; exit 1; }
# The macOS dispatcher must call the reviewed concern workflow once it is a dispatcher.
mac_dispatcher="${classify_root}/.github/workflows/macos-validation.yml"
write_mac() { # called workflow
  cat > "${mac_dispatcher}" <<YAML
name: macos
on:
  workflow_dispatch:
    inputs:
      source_sha:
        required: true
permissions: {}
jobs:
  plan:
    runs-on: ubuntu-24.04
    steps:
      - run: "[[ \"\${REQUESTED_SOURCE_SHA}\" =~ ^[0-9a-fA-F]{40}\$ ]]"
  validate-main:
    uses: ./.github/workflows/$1
    secrets:
      SOURCE_READER_PRIVATE_KEY: \${{ secrets.SOURCE_READER_PRIVATE_KEY }}
YAML
}
write_mac macos-validation-concern.yml
(cd "${classify_root}" && source "${policy}/lib.sh" && source "${policy}/workflow-lists.sh" && source "${policy}/check-cache-policy.sh" && source "${policy}/check-dispatchers.sh" && check_dispatcher .github/workflows/macos-validation.yml) >/dev/null 2>"${base}/err" || { echo 'a macOS dispatcher calling the reviewed concern workflow should pass' >&2; cat "${base}/err" >&2; exit 1; }
write_mac windows-validation-concern.yml
if (cd "${classify_root}" && source "${policy}/lib.sh" && source "${policy}/workflow-lists.sh" && source "${policy}/check-cache-policy.sh" && source "${policy}/check-dispatchers.sh" && check_dispatcher .github/workflows/macos-validation.yml) >/dev/null 2>"${base}/err"; then
  echo 'a macOS dispatcher calling another workflow should be refused' >&2; exit 1
fi
grep -qF 'must call the reviewed concern workflow' "${base}/err" || { echo 'the macOS dispatcher refusal has the wrong message' >&2; cat "${base}/err" >&2; exit 1; }
echo 'macOS classification fixtures: an inline job is a source workflow, an environment-less macOS workflow is a dispatcher that must call its reviewed concern workflow'

# P8: actionlint lacks the cache-mode key, so lint.sh ignores exactly that message and nothing else.
lint_ignores() { grep -oE "\-ignore '[^']*'" "$1"; }
expected_ignores="$(printf '%s\n' "-ignore 'SC2016:'" "-ignore 'SC2129:'" "-ignore '^unexpected key \"cache-mode\" for \"(job|workflow)\" section\\. '")"
[[ "$(lint_ignores .github/policy/lint.sh)" == "${expected_ignores}" ]] || { echo 'lint.sh must ignore exactly SC2016, SC2129 and the anchored cache-mode unexpected-key message' >&2; lint_ignores .github/policy/lint.sh >&2; exit 1; }
for extra in "-ignore 'syntax-check'" "-ignore 'unexpected key'" "-ignore 'cache-mode'"; do
  sed "s#^\"\${tools}/actionlint\" -ignore#\"\${tools}/actionlint\" ${extra} -ignore#" .github/policy/lint.sh > "${base}/lint-fixture.sh"
  [[ "$(lint_ignores "${base}/lint-fixture.sh")" != "${expected_ignores}" ]] || { echo "lint.sh fixture with ${extra} should differ from the reviewed ignores" >&2; exit 1; }
done
echo 'lint fixtures: only the anchored cache-mode message is ignored'

# Ref isolation freshness guard: the reviewed guard (inline in the source-checkout composite) is extracted and run against a stubbed compare API. identical and
# behind are accepted (behind with a warning naming the sync command); ahead, diverged and an
# unreadable answer are refused, and a run from main is not subject to the guard.
fresh_dir="${base}/freshness"
mkdir -p "${fresh_dir}/bin"
cat > "${fresh_dir}/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${*: -1}"
case "${url}" in
  */compare/main...*)
    case "${FAKE_COMPARE_STATUS}" in
      unreadable) exit 22 ;;
      *) printf '{"status":"%s","ahead_by":%s,"behind_by":%s}\n' "${FAKE_COMPARE_STATUS}" "${FAKE_AHEAD_BY:-0}" "${FAKE_BEHIND_BY:-0}" ;;
    esac ;;
  # What main changed since this commit (the files of compare <this>...main).
  */compare/"${GITHUB_SHA}"...main)
    files="${FAKE_FILES:-}"
    [[ -n "${files}" ]] || files='[{"filename":"docs/how-ci-works.md"}]'
    [[ "${files}" == unreadable ]] && exit 22
    printf '{"status":"ahead","files":%s}\n' "${files}" ;;
  *) exit 22 ;;
esac
STUB
chmod +x "${fresh_dir}/bin/curl"
for guard_file in .github/actions/source-checkout/action.yml; do
  ruby -ryaml -e '
    doc = YAML.safe_load(File.read(ARGV[0]), aliases: false)
    steps = doc.dig("runs", "steps") || doc["jobs"].values.flat_map { |j| j["steps"] || [] }
    run = steps.map { |s| s["run"].to_s }.find { |r| r.include?("refs/heads/untrusted ]]") && r.include?("compare/main") }
    abort "no freshness guard in #{ARGV[0]}" unless run
    File.write(ARGV[1], run)' "${guard_file}" "${fresh_dir}/guard.sh"
  freshness_run() {
    local ref="$1" status="$2" ahead="${3:-0}" behind="${4:-0}"
    : > "${fresh_dir}/summary"
    set +e
    PATH="${fresh_dir}/bin:${PATH}" GITHUB_REPOSITORY=Moh-Bakr/Taurine-CI GITHUB_REF="${ref}" \
      GITHUB_SHA=1111111111111111111111111111111111111111 GITHUB_API_URL=https://api.invalid \
      GITHUB_STEP_SUMMARY="${fresh_dir}/summary" CONTROL_PLANE_TOKEN=unused \
      REQUESTED_SOURCE_SHA=2222222222222222222222222222222222222222 REQUESTED_PLATFORM=linux \
      REQUESTED_CONCERN=unit REQUESTED_VULN_GATE=none \
      FAKE_COMPARE_STATUS="${status}" FAKE_AHEAD_BY="${ahead}" FAKE_BEHIND_BY="${behind}" FAKE_FILES="${FAKE_FILES:-}" \
      bash "${fresh_dir}/guard.sh" >"${fresh_dir}/out" 2>&1
    freshness_rc=$?
    set -e
  }
  freshness_run refs/heads/untrusted identical
  [[ "${freshness_rc}" -eq 0 ]] || { echo "${guard_file}: an identical untrusted should be accepted" >&2; cat "${fresh_dir}/out" >&2; exit 1; }
  freshness_run refs/heads/untrusted behind 0 3
  [[ "${freshness_rc}" -eq 0 ]] || { echo "${guard_file}: a behind untrusted should be accepted" >&2; cat "${fresh_dir}/out" >&2; exit 1; }
  grep -qF '3 commit(s) behind' "${fresh_dir}/summary" && grep -qF 'git push origin origin/main:refs/heads/untrusted' "${fresh_dir}/summary" \
    || { echo "${guard_file}: a behind untrusted should warn with the count and the sync command" >&2; cat "${fresh_dir}/summary" >&2; exit 1; }
  # Behind is accepted only while main has not changed .github/ since: a workflow, composite or
  # policy change (or a rename out of .github/), a list at the API's 300-file cap and an unreadable
  # list are all refused with the sync command.
  FAKE_FILES='[{"filename":"docs/a.md"},{"filename":"README-not-github.md"}]' freshness_run refs/heads/untrusted behind 0 2
  [[ "${freshness_rc}" -eq 0 ]] || { echo "${guard_file}: a behind untrusted with no .github/ change since should be accepted" >&2; cat "${fresh_dir}/out" >&2; exit 1; }
  many="$(ruby -rjson -e 'puts JSON.generate((1..300).map { |i| { "filename" => "docs/f#{i}.md" } })')"
  for changed in '[{"filename":".github/workflows/validation.yml"}]' '[{"filename":"docs/a.md"},{"filename":".github/policy/lib.sh"}]' \
    '[{"filename":"docs/x.yml","previous_filename":".github/actions/drop-root/action.yml"}]' "${many}" '{}' unreadable; do
    FAKE_FILES="${changed}" freshness_run refs/heads/untrusted behind 0 2
    [[ "${freshness_rc}" -ne 0 ]] && grep -qF 'git push origin origin/main:refs/heads/untrusted' "${fresh_dir}/out" \
      || { [[ "${changed}" == unreadable || "${changed}" == '{}' ]] && [[ "${freshness_rc}" -ne 0 ]]; } \
      || { echo "${guard_file}: a behind untrusted with main's later .github/ change (${changed:0:60}) should be refused with the sync command" >&2; cat "${fresh_dir}/out" >&2; exit 1; }
  done
  for refused in ahead diverged unreadable; do
    freshness_run refs/heads/untrusted "${refused}" 2 1
    [[ "${freshness_rc}" -ne 0 ]] || { echo "${guard_file}: a ${refused} untrusted should be refused" >&2; exit 1; }
  done
  freshness_run refs/heads/main ahead
  [[ "${freshness_rc}" -eq 0 ]] || { echo "${guard_file}: the guard must not apply to a run from main" >&2; cat "${fresh_dir}/out" >&2; exit 1; }
done
echo 'freshness fixtures: untrusted identical to main, or behind it with no later .github/ change, is accepted (behind warns); a later .github/ change, ahead, diverged and unreadable are refused'

# Egress modes: the reviewed table passes; a Linux concern without Docker switched back to
# audit without a recorded reason fails, as do an unknown mode and a missing one; the same
# switch with an explicit reason passes.
egress_fixture="${base}/ci-matrix.json"
egress_mutate() { jq "$1" .github/ci-matrix.json > "${egress_fixture}"; }
egress_expect_fail() {
  local label="$1" filter="$2" needle="$3"
  egress_mutate "${filter}"
  if bash "${policy}/check-egress-modes.sh" "${egress_fixture}" >/dev/null 2>"${base}/err"; then
    echo "egress fixture '${label}' should fail but passed" >&2
    exit 1
  fi
  grep -qF -- "${needle}" "${base}/err" || { echo "egress fixture '${label}' failed with the wrong message:" >&2; cat "${base}/err" >&2; exit 1; }
}
bash "${policy}/check-egress-modes.sh" .github/ci-matrix.json >/dev/null || { echo 'the reviewed egress modes should pass' >&2; exit 1; }
egress_expect_fail 'contracts switched to audit without a reason' \
  '.concerns.linux.contracts.egress = "audit" | del(.concerns.linux.contracts.egress_audit_reason)' 'without an egress_audit_reason'
egress_expect_fail 'an audit exception with an empty reason' \
  '.concerns.linux.contracts.egress = "audit" | .concerns.linux.contracts.egress_audit_reason = " "' 'without an egress_audit_reason'
egress_expect_fail 'an unknown egress mode' '.concerns.linux.contracts.egress = "off"' 'must be "block" or "audit"'
egress_expect_fail 'a concern with no egress mode' 'del(.concerns.linux.contracts.egress)' 'must be "block" or "audit"'
egress_mutate '.concerns.linux.contracts.egress = "audit" | .concerns.linux.contracts.egress_audit_reason = "kept in audit while a named dependency is investigated"'
bash "${policy}/check-egress-modes.sh" "${egress_fixture}" >/dev/null || { echo 'an audit exception with its reason should pass' >&2; exit 1; }
echo 'egress-mode fixtures: audit without a recorded reason, an unknown mode and a missing mode are refused'

# Concurrency: a per-run group, no block, and an absent cancel-in-progress pass; a shared per-SHA
# group, a group without the run id and cancel-in-progress true fail.
conc_dir="${base}/concurrency"; mkdir -p "${conc_dir}"
conc_file() { printf 'name: x\non:\n  workflow_dispatch:\npermissions: {}\n%s\njobs:\n  a:\n    runs-on: ubuntu-24.04\n' "$1" > "${conc_dir}/$2.yml"; echo "${conc_dir}/$2.yml"; }
conc_pass() { bash "${policy}/check-concurrency.sh" "$1" >/dev/null 2>&1 || { echo "concurrency fixture '$2' should pass" >&2; exit 1; }; }
conc_fail() { if bash "${policy}/check-concurrency.sh" "$1" >/dev/null 2>"${base}/err"; then echo "concurrency fixture '$2' should fail but passed" >&2; exit 1; fi; grep -qF -- "$3" "${base}/err" || { echo "concurrency fixture '$2' failed with the wrong message" >&2; cat "${base}/err" >&2; exit 1; }; }
conc_pass "$(conc_file 'concurrency:
  group: wf-${{ inputs.source_sha }}-${{ github.run_id }}
  cancel-in-progress: false' per-run)" 'a per-run group'
conc_pass "$(conc_file '' none)" 'no concurrency block'
conc_pass "$(conc_file 'concurrency:
  group: wf-${{ github.run_id }}' no-cancel-key)" 'cancel-in-progress absent'
conc_fail "$(conc_file 'concurrency:
  group: wf-${{ github.workflow }}-${{ inputs.source_sha }}
  cancel-in-progress: false' shared)" 'a shared per-SHA group' 'github.run_id'
conc_fail "$(conc_file 'concurrency:
  group: weekly-validation
  cancel-in-progress: false' fixed)" 'a fixed group' 'github.run_id'
conc_fail "$(conc_file 'concurrency:
  group: wf-${{ github.run_id }}
  cancel-in-progress: true' cancelling)" 'cancel-in-progress true' 'cancel-in-progress'
echo 'concurrency fixtures: per-run groups pass; shared groups and cancel-in-progress true are refused'

bash .github/policy/test-repository.sh
