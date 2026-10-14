#!/usr/bin/env bash
# The bootstrap path guard admits the two reviewed PG8 policy Python files only.
set -euo pipefail

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
temp_root="$(mktemp -d)"
trap 'rm -rf "${temp_root}"' EXIT

new_fixture() {
  local root
  root="$(mktemp -d "${temp_root}/repo.XXXXXX")"
  mkdir -p "${root}/.github/policy"
  cp "${source_root}/.github/policy/check-repository.sh" "${root}/.github/policy/check-repository.sh"
  git -C "${root}" init -q
  git -C "${root}" config user.name 'Policy Fixture'
  git -C "${root}" config user.email 'policy-fixture@example.invalid'
  git -C "${root}" add .github/policy/check-repository.sh
  printf '%s\n' "${root}"
}

expect_pass() {
  local root="$1" label="$2"
  if ! (cd "${root}" && bash .github/policy/check-repository.sh) >/dev/null 2>&1; then
    echo "repository path fixture failed: ${label} should pass" >&2
    exit 1
  fi
}

expect_reject() {
  local root="$1" label="$2" expected="$3" output
  if output="$(cd "${root}" && bash .github/policy/check-repository.sh 2>&1)"; then
    echo "repository path fixture failed: ${label} unexpectedly passed" >&2
    exit 1
  fi
  if [[ "${output}" != *"${expected}"* ]]; then
    echo "repository path fixture failed: ${label} hit an unexpected rejection" >&2
    exit 1
  fi
}

reviewed="$(new_fixture)"
printf '# reviewed parser fixture\n' > "${reviewed}/.github/policy/pg8-measurement.py"
printf '# reviewed test fixture\n' > "${reviewed}/.github/policy/test-pg8-measurement.py"
git -C "${reviewed}" add .github/policy/pg8-measurement.py .github/policy/test-pg8-measurement.py
expect_pass "${reviewed}" 'the exact reviewed PG8 Python pair'

unreviewed="$(new_fixture)"
printf '# unreviewed helper\n' > "${unreviewed}/.github/policy/pg8-helper.py"
git -C "${unreviewed}" add .github/policy/pg8-helper.py
expect_reject "${unreviewed}" 'an unreviewed third Python policy file' 'Unexpected tracked path in the public CI repository'

private_source="$(new_fixture)"
mkdir -p "${private_source}/taurine-desktop/src"
printf 'source fixture\n' > "${private_source}/taurine-desktop/src/private.ts"
git -C "${private_source}" add taurine-desktop/src/private.ts
expect_reject "${private_source}" 'a private-source path' 'Unexpected tracked path in the public CI repository'

credential="$(new_fixture)"
mkdir -p "${credential}/docs"
printf 'GH_APP_PRIVATE_KEY=TEST_FIXTURE_SENTINEL\n' > "${credential}/docs/repository-fixture.md"
git -C "${credential}" add docs/repository-fixture.md
expect_reject "${credential}" 'credential material in an otherwise allowed document' 'A reusable source, signing, or deployment credential pattern was found'

assets="$(new_fixture)"
mkdir -p "${assets}/.github/policy/case-evidence-assets"
printf "'use strict';\n" > "${assets}/.github/policy/case-evidence-assets/playwright-case-list-reporter.cjs"
printf '{"suites":[]}\n' > "${assets}/.github/policy/case-evidence-assets/real-runner-list.json"
printf "module.exports = {};\n" > "${assets}/.github/policy/case-evidence-assets/all-pass.config.cjs"
printf "// spec\n" > "${assets}/.github/policy/case-evidence-assets/all-pass.spec.cjs"
git -C "${assets}" add .github/policy/case-evidence-assets
expect_pass "${assets}" 'the reviewed case-evidence asset directory'

for rejected in \
  'case-evidence-assets/nested/reporter.cjs' \
  'case-evidence-assets/Reporter.cjs' \
  'case-evidence-assets/reporter.ts' \
  'case-evidence-assets/reporter.js' \
  'case-evidence-assets/reporter.sh.cjs.ts' \
  'case-evidence-assets/reporter.ts.cjs' \
  'case-evidence-assets/secret.pem.json' \
  'case-evidence-assets/reporter.config.spec.cjs' \
  'other-assets/reporter.cjs'
do
  narrow="$(new_fixture)"
  mkdir -p "${narrow}/.github/policy/$(dirname "${rejected}")"
  printf 'fixture\n' > "${narrow}/.github/policy/${rejected}"
  git -C "${narrow}" add ".github/policy/${rejected}"
  expect_reject "${narrow}" "a path outside the reviewed asset exception: ${rejected}" 'Unexpected tracked path in the public CI repository'
done


# The exact asset names the case-evidence activation ships. The exception
# exists to admit these and nothing wider, so the list is tracked here: if a
# later change to either side stops admitting one of them, this fails rather
# than the activation failing in its own base-policy step.
real_assets="$(new_fixture)"
mkdir -p "${real_assets}/.github/policy/case-evidence-assets"
for asset in \
  all-pass.config.cjs all-pass.spec.cjs callback-failure-reporter.cjs \
  duplicate-identity.config.cjs duplicate-identity.spec.cjs expected-cases.json \
  flaky.config.cjs flaky.spec.cjs outcomes.config.cjs outcomes.spec.cjs \
  playwright-case-list-reporter.cjs real-execution-feedback.json \
  real-execution-outcomes.json real-list-critical.json real-list-outcomes.json \
  real-list-shell-browser.json real-list-smoke.json real-runner-provenance.json
do
  case "${asset}" in
    *.json) printf '{}\n' > "${real_assets}/.github/policy/case-evidence-assets/${asset}" ;;
    *) printf "'use strict';\n" > "${real_assets}/.github/policy/case-evidence-assets/${asset}" ;;
  esac
done
git -C "${real_assets}" add .github/policy/case-evidence-assets
expect_pass "${real_assets}" 'every case-evidence asset name the activation ships'

# Four mutations of the new rule survived an earlier review because no fixture
# covered the path each one admits. One fixture per admitted path.
for rejected in \
  'case-evidence-assets/a.js.cjs' \
  'case-evidence-assets/a.mjs' \
  'case-evidence-assets/.hidden.cjs' \
  'case-evidence-assets/a.test.cjs' \
  'case-evidence-assets/a.config.spec.cjs' \
  'case-evidence-assets/a..cjs' \
  'case-evidence-assets/a.cjs/x.rb'
do
  mutant="$(new_fixture)"
  mkdir -p "${mutant}/.github/policy/$(dirname "${rejected}")"
  printf 'fixture\n' > "${mutant}/.github/policy/${rejected}"
  git -C "${mutant}" add ".github/policy/${rejected}"
  expect_reject "${mutant}" "a path the dropped anchors or a wider class would admit: ${rejected}" 'Unexpected tracked path in the public CI repository'
done

# Dropping the leading anchor would admit the same directory under any prefix.
unanchored="$(new_fixture)"
mkdir -p "${unanchored}/x/.github/policy/case-evidence-assets"
printf 'fixture\n' > "${unanchored}/x/.github/policy/case-evidence-assets/a.cjs"
git -C "${unanchored}" add x/.github/policy/case-evidence-assets/a.cjs
expect_reject "${unanchored}" 'the asset directory under another prefix' 'Unexpected tracked path in the public CI repository'

# The accepted compound pair, both extensions.
compound="$(new_fixture)"
mkdir -p "${compound}/.github/policy/case-evidence-assets"
printf "'use strict';\n" > "${compound}/.github/policy/case-evidence-assets/a.config.cjs"
printf '{}\n' > "${compound}/.github/policy/case-evidence-assets/a.spec.json"
git -C "${compound}" add .github/policy/case-evidence-assets
expect_pass "${compound}" 'the reviewed .config and .spec compound names'

# These assets execute on the runner, so only plain regular files are allowed.
symlinked="$(new_fixture)"
mkdir -p "${symlinked}/.github/policy/case-evidence-assets"
ln -s /etc/passwd "${symlinked}/.github/policy/case-evidence-assets/reporter.cjs"
git -C "${symlinked}" add .github/policy/case-evidence-assets/reporter.cjs
expect_reject "${symlinked}" 'a symlinked case-evidence asset' 'must be plain regular files'

executable="$(new_fixture)"
mkdir -p "${executable}/.github/policy/case-evidence-assets"
printf "'use strict';\n" > "${executable}/.github/policy/case-evidence-assets/reporter.cjs"
chmod 755 "${executable}/.github/policy/case-evidence-assets/reporter.cjs"
git -C "${executable}" add .github/policy/case-evidence-assets/reporter.cjs
expect_reject "${executable}" 'an executable case-evidence asset' 'must be plain regular files'

# The credential sweep used to skip the whole policy directory, which hid these
# data files. Both PEM header forms are covered: the qualified one was not
# matched by the previous pattern at all. Obviously fake keys, never real ones.
for leak in 'case-evidence-assets/leak.json' 'case-evidence-assets/leak.cjs'; do
  for header in '-----BEGIN RSA PRIVATE KEY-----' '-----BEGIN PRIVATE KEY-----' 'GH_APP_PRIVATE_KEY=TEST_FIXTURE_SENTINEL'; do
    planted="$(new_fixture)"
    mkdir -p "${planted}/.github/policy/case-evidence-assets"
    printf -- '%s\nTEST_FIXTURE_NOT_A_REAL_KEY\n' "${header}" > "${planted}/.github/policy/${leak}"
    git -C "${planted}" add ".github/policy/${leak}"
    expect_reject "${planted}" "credential material planted in ${leak} (${header})" 'A reusable source, signing, or deployment credential pattern was found'
  done
done

echo 'repository path fixtures: the PG8 pair, every shipped case-evidence asset name and the reviewed .config/.spec pair allowed; nested, prefixed, upper-case, hidden, other-extension, smuggled-extension and doubly-compound names, symlinked and executable assets, planted credentials, another directory, private source and starter documents rejected'
