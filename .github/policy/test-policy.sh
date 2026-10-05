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
for keep in "'true'" 'true' '${{ true }}' "\${{ inputs.concern == 'db-containers' || inputs.concern == 'apphost-cold-start' }} || true"; do
  root="$(fresh keep-docker-concern)"; cp .github/workflows/keeldock-validation-concern.yml "${root}/.github/workflows/"
  swap "${root}" .github/workflows/keeldock-validation-concern.yml "keep-docker: \${{ inputs.concern == 'db-containers' || inputs.concern == 'apphost-cold-start' }}" "keep-docker: ${keep}"
  expect_fail "keep-docker ${keep} in the Keel Dock concern" "${root}" 'drop-root keep-docker must be absent or the reviewed expression'
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
  's/if: \$\{\{ github\.ref == .refs\/heads\/main. && (steps\.verified-source\.outputs\.protected-ancestor == .true. && startsWith\(inputs\.concern, .rust-app-.\) \}\}\n        uses: actions\/cache\/restore)/if: \$\{\{ $1/'
cache_expect_fail 'compiled cache restore without protected ancestry' 'runs only on main for a protected source SHA' \
  's/(if: \$\{\{ github\.ref == .refs\/heads\/main. && )steps\.verified-source\.outputs\.protected-ancestor == .true. && (startsWith\(inputs\.concern, .rust-app-.\) \}\}\n        uses: actions\/cache\/restore)/$1$2/'
cache_expect_fail 'compiled cache gate re-opened by ||' 'runs only on main for a protected source SHA' \
  's/(if: \$\{\{ github\.ref == [^\n]*startsWith\(inputs\.concern, .rust-app-.\)) \}\}(\n        uses: actions\/cache\/restore)/$1 || true }}$2/'
cache_expect_fail 'compiled cache strip without the main guard' 'strip step runs only on main' \
  's/if: \$\{\{ github\.ref == .refs\/heads\/main. && (inputs\.concern == .rust-app-2. && [^\n]*steps\.concern-rust\.outcome)/if: \$\{\{ $1/'
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

# The KeelDock NuGet cache: the reviewed concern passes; a restore outside protected main, a save
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
nuget_expect_fail 'NuGet restore without the main guard' 'NuGet cache runs only on main' \
  's/if: \$\{\{ github\.ref == .refs\/heads\/main. && (steps\.verified-source\.outputs\.protected-ancestor == .true. && steps\.verified-source\.outcome)/if: \$\{\{ $1/'
nuget_expect_fail 'NuGet restore gate re-opened by ||' 'NuGet cache runs only on main' \
  's/(if: \$\{\{ github\.ref == [^\n]*steps\.verified-source\.outcome == .success.) \}\}/$1 || true }}/'
nuget_expect_fail 'NuGet save without protected ancestry' 'protected-ancestry answer' \
  's/ && steps\.verified-source\.outputs\.protected-ancestor == .true.( && steps\.nuget-packages\.outputs\.cache-hit)/$1/'
nuget_expect_fail 'NuGet save key after project code' 'cache-primary-key' \
  's/key: \$\{\{ steps\.nuget-packages\.outputs\.cache-primary-key \}\}/key: nuget-\$\{\{ runner.os \}\}-\$\{\{ hashFiles(\x27**\/packages.lock.json\x27) \}\}/'
echo 'cache policy fixtures: the NuGet guards reject a cache step outside protected main, an unprotected save and a late save key'

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

# Ref isolation freshness guard: the reviewed guard (inline in the source-checkout composite and
# in the KeelDock concern) is extracted and run against a stubbed compare API. identical and
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
for guard_file in .github/actions/source-checkout/action.yml .github/workflows/keeldock-validation-concern.yml; do
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
  for refused in ahead diverged unreadable; do
    freshness_run refs/heads/untrusted "${refused}" 2 1
    [[ "${freshness_rc}" -ne 0 ]] || { echo "${guard_file}: a ${refused} untrusted should be refused" >&2; exit 1; }
  done
  freshness_run refs/heads/main ahead
  [[ "${freshness_rc}" -eq 0 ]] || { echo "${guard_file}: the guard must not apply to a run from main" >&2; cat "${fresh_dir}/out" >&2; exit 1; }
done
echo 'freshness fixtures: untrusted behind or identical to main is accepted (behind warns); ahead, diverged and unreadable are refused'

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
