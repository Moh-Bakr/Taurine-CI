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

# The complete live roster is required; a stale 12-arm identity contract must
# fail because `engine=all` would otherwise select a different set of arms.
reset_fixture
ruby -rjson -e 'path=ARGV.fetch(0); data=JSON.parse(File.read(path)); data.fetch("dispatch_contracts").fetch("workflows").fetch(".github/workflows/live-proofs.yml").fetch("inputs").fetch("engine")["options"]=%w[doris starrocks db2 informix rocketmq iris postgres pg-dbx mysql mssql pgtls bastion]; File.write(path,JSON.pretty_generate(data))' \
  "${work}/tree/.github/ci-matrix.json"
expect_policy_rejects 'stale 12-arm live roster'

reset_fixture
ruby -rjson -e 'path=ARGV.fetch(0); data=JSON.parse(File.read(path)); data.fetch("dispatch_contracts").fetch("workflows").fetch(".github/workflows/live-proofs.yml").fetch("inputs").fetch("engine")["options"] << "unreviewed"; File.write(path,JSON.pretty_generate(data))' \
  "${work}/tree/.github/ci-matrix.json"
expect_policy_rejects 'unreviewed live engine'

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

reset_fixture
ruby -e 'path=ARGV.fetch(0); text=File.read(path); old=%q{matrix_json="$(jq -c . "${RUNNER_TEMP}/ci-matrix.json")"}; new=%q{matrix_json="$(jq -c '\'' .dispatch_contracts '\'' "${RUNNER_TEMP}/ci-matrix.json")"}; abort unless text.include?(old); File.write(path,text.sub(old,new))' \
  "${work}/tree/.github/workflows/weekly-validation.yml"
expect_policy_rejects 'scheduled helper dropping the suite catalog from its identity input'

reset_fixture
ruby -e 'path=ARGV.fetch(0); text=File.read(path); marker="      - name: Refuse a duplicate dispatch\n"; abort unless text.include?(marker); File.write(path,text.sub(marker, ""))' \
  "${work}/tree/.github/workflows/linux-validation.yml"
expect_policy_rejects 'a dispatcher losing its duplicate-dispatch guard'

reset_fixture
ruby -e 'path=ARGV.fetch(0); text=File.read(path); old=%q{run: ruby .github/policy/refuse-duplicate-dispatch.rb}; new=%q{run: ruby .github/policy/refuse-duplicate-dispatch.rb || true}; abort unless text.include?(old); File.write(path,text.sub(old,new))' \
  "${work}/tree/.github/workflows/linux-validation.yml"
expect_policy_rejects 'a duplicate-dispatch guard that cannot fail'

# Reproduce the deployed Linux Plan step with synthetic inputs. A valid selected opt-in
# concern must survive an empty set-difference, while an opt-in concern with its input off
# and an unknown name still fail closed.
reset_fixture
ruby -ryaml -e 'workflow=YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true); step=workflow.fetch("jobs").fetch("plan").fetch("steps").find { |row| row["id"] == "plan" }; abort unless step; File.write(ARGV.fetch(1), step.fetch("run"))' \
  .github/workflows/linux-validation.yml "${work}/plan.sh"
mkdir -p "${work}/plan-work/.github"
cp .github/ci-matrix.json "${work}/plan-work/.github/ci-matrix.json"
run_plan() {
  local label="$1" visual="$2" only="$3" expected_status="$4" status=0
  : > "${work}/plan.out"
  : > "${work}/plan.summary"
  (cd "${work}/plan-work" && GITHUB_OUTPUT="${work}/plan.out" GITHUB_STEP_SUMMARY="${work}/plan.summary" \
    PROFILE=full VISUAL="${visual}" GITLEAKS_HISTORY=false ONLY="${only}" bash "${work}/plan.sh") \
    >"${work}/plan.stdout" 2>"${work}/plan.stderr" || status=$?
  if [[ "${expected_status}" == success && "${status}" -ne 0 ]]; then
    echo "${label}: valid Plan selection failed: $(cat "${work}/plan.stderr")" >&2; exit 1
  elif [[ "${expected_status}" == reject && "${status}" -eq 0 ]]; then
    echo "${label}: invalid Plan selection unexpectedly passed" >&2; exit 1
  fi
}
run_plan 'visual only filter' true e2e-visual success
ruby -rjson -e 'out=File.readlines(ARGV.fetch(0)).to_h { |line| key,value=line.chomp.split("=",2); [key,value] }; abort "wrong planned matrix" unless JSON.parse(out.fetch("matrix")) == {"concern"=>["e2e-visual"]}; expected=JSON.parse(out.fetch("expected")); abort "visual absent from expected roster" unless expected.include?("e2e-visual"); abort "mandatory roster reduced" unless expected.length == JSON.parse(File.read(ARGV.fetch(1))).fetch("concerns").fetch("linux").count { |_, row| row["opt_in"].nil? } + 1; abort "opt-in identity missing" unless JSON.parse(out.fetch("optin")) == ["e2e-visual"]' \
  "${work}/plan.out" .github/ci-matrix.json
run_plan 'visual opt-in disabled' false e2e-visual reject
grep -qF 'only: not a concern of this dispatch' "${work}/plan.stderr"
run_plan 'unknown concern' true e2e-not-reviewed reject
grep -qF 'only: not a concern of this dispatch' "${work}/plan.stderr"
# Empty comma-separated members remain invalid at input validation; the Plan's split
# must never silently turn malformed input into an all-concerns or zero-concerns run.
ruby -ryaml -e 'workflow=YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true); step=workflow.fetch("jobs").fetch("validate-input").fetch("steps").find { |row| row["name"] == "Validate exact source SHA" }; abort unless step; File.write(ARGV.fetch(1), step.fetch("run"))' \
  .github/workflows/linux-validation.yml "${work}/validate-input.sh"
if REQUESTED_SOURCE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa REQUESTED_BASE_SHA='' REQUESTED_ONLY=, REQUESTED_SUITE_SELECTION='' bash "${work}/validate-input.sh" >"${work}/validate.stdout" 2>"${work}/validate.stderr"; then
  echo 'malformed empty only member unexpectedly passed input validation' >&2; exit 1
fi
grep -qF 'only must be a comma-separated list of concern names' "${work}/validate.stderr"
grep -Fq "inputs.only == ''" .github/workflows/linux-validation.yml || { echo 'only filter can be mislabeled full' >&2; exit 1; }

# The strict stage-2 concern-table contract must reject the old expression again.
mkdir -p "${work}/strict-mode"
cp -R .github "${work}/strict-mode/"
ruby -e 'path=ARGV.fetch(0); text=File.read(path); current="${{ inputs.profile == '\''full'\'' && inputs.base_sha == '\'''\'' && inputs.only == '\'''\'' && '\''full'\'' || '\''partial'\'' }}"; old="${{ inputs.profile == '\''full'\'' && inputs.base_sha == '\'''\'' && '\''full'\'' || '\''partial'\'' }}"; abort "strict mode expression not found" unless text.include?(current); File.write(path,text.sub(current,old))' \
  "${work}/strict-mode/.github/workflows/linux-validation.yml"
if (cd "${work}/strict-mode" && bash .github/policy/check-concern-table.sh) >"${work}/strict-mode.stdout" 2>"${work}/strict-mode.stderr"; then
  echo 'the old full/partial expression passed the strict policy' >&2; exit 1
fi
grep -qF 'run-result must use its reviewed explicit selection mode' "${work}/strict-mode.stderr"

echo 'dispatch contracts: Plan selection accepts valid visual opt-in, preserves partial only identity, and rejects disabled/unknown concerns'
echo 'dispatch contracts: strict stage-2 policy rejects the old Linux selection-mode expression'
echo 'dispatch contracts: mutations for conditional, bypassed and mismapped proofs were rejected'
