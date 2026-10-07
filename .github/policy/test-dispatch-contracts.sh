#!/usr/bin/env bash
# Prove reviewed input bindings reject weakened dispatch proof steps and contract drift.
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dispatch-contracts-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

reset_fixture() {
  rm -rf "${work}/tree"
  mkdir -p "${work}/tree/.github"
  cp .github/ci-matrix.json "${work}/tree/.github/ci-matrix.json"
  cp -R .github/workflows "${work}/tree/.github/workflows"
}

expect_policy_rejects() {
  local label="$1" output status
  set +e
  output="$(ruby .github/policy/check-dispatch-contracts.rb "${work}/tree" 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || { echo "${label}: weakened fixture passed dispatch contract policy" >&2; exit 1; }
}

reset_fixture
ruby .github/policy/check-dispatch-contracts.rb "${work}/tree" >/dev/null

reset_fixture
ruby -e 'path=ARGV.fetch(0); text=File.read(path); marker="      - name: Verify the coordinator dispatch identity\n"; abort unless text.include?(marker); File.write(path,text.sub(marker, marker + "        if: false\n"))' \
  "${work}/tree/.github/workflows/linux-validation.yml"
expect_policy_rejects 'conditional proof'

reset_fixture
ruby -e 'path=ARGV.fetch(0); text=File.read(path); marker="      - name: Verify the coordinator dispatch identity\n        shell: bash\n"; abort unless text.include?(marker); File.write(path,text.sub(marker, marker + "        continue-on-error: true\n"))' \
  "${work}/tree/.github/workflows/linux-validation.yml"
expect_policy_rejects 'continue-on-error proof'

reset_fixture
ruby -e 'path=ARGV.fetch(0); text=File.read(path); marker="CI_GENERATE_ONLY: '\''false'\''"; abort unless text.include?(marker); File.write(path,text.sub(marker, "CI_GENERATE_ONLY: '\''true'\''"))' \
  "${work}/tree/.github/workflows/linux-validation.yml"
expect_policy_rejects 'generation-mode override'

reset_fixture
ruby -e 'path=ARGV.fetch(0); text=File.read(path); marker="toJSON(inputs.visual)"; abort unless text.include?(marker); File.write(path,text.sub(marker, "toJSON(inputs.gitleaks_history)"))' \
  "${work}/tree/.github/workflows/linux-validation.yml"
expect_policy_rejects 'swapped normalized input'

reset_fixture
ruby -rjson -e 'path=ARGV.fetch(0); data=JSON.parse(File.read(path)); data.fetch("dispatch_contracts").fetch("workflows").fetch(".github/workflows/linux-validation.yml").fetch("inputs").fetch("visual")["digest_include"]=false; File.write(path,JSON.pretty_generate(data))' \
  "${work}/tree/.github/ci-matrix.json"
expect_policy_rejects 'unbound declared input'

echo 'dispatch contracts: mutations for conditional, bypassed and mismapped proofs were rejected'
