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

echo 'repository path fixtures: exact PG8 parser/test pair allowed; third Python, private source, and credential material rejected'
