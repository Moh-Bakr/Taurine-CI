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
  local label="$1" expected="${2:-}" output status
  set +e
  output="$(ruby .github/policy/check-dispatch-contracts.rb "${work}/tree" 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || { echo "${label}: weakened fixture passed dispatch contract policy" >&2; exit 1; }
  if [[ -n "${expected}" && "${output}" != *"${expected}"* ]]; then
    echo "${label}: rejected for the wrong reason: ${output}" >&2
    exit 1
  fi
}

reset_fixture
ruby .github/policy/check-dispatch-contracts.rb "${work}/tree" >/dev/null

# The PG8 reusable caller must propagate only the nested pre-flight permissions;
# its source-bearing leaf must remain least-privilege.
mutate_pg8_permission_scope() {
  local mutation="$1"
  reset_fixture
  ruby -ryaml -e '
    root = ARGV.fetch(0)
    workflow_path = File.join(root, ".github/workflows/pg8-measurement.yml")
    arm_path = File.join(root, ".github/workflows/pg8-measurement-arm.yml")
    workflow = YAML.safe_load_file(workflow_path, aliases: false)
    arm = YAML.safe_load_file(arm_path, aliases: false)
    case ARGV.fetch(1)
    when "caller-missing-actions" then workflow.fetch("jobs").fetch("measure").fetch("permissions").delete("actions")
    when "caller-actions-write" then workflow.fetch("jobs").fetch("measure").fetch("permissions")["actions"] = "write"
    when "preflight-missing-actions" then arm.fetch("jobs").fetch("preflight").fetch("permissions").delete("actions")
    when "measure-actions-read" then arm.fetch("jobs").fetch("measure").fetch("permissions")["actions"] = "read"
    end
    File.write(workflow_path, YAML.dump(workflow))
    File.write(arm_path, YAML.dump(arm))
  ' "${work}/tree" "${mutation}"
  case "${mutation}" in
    caller-missing-actions|caller-actions-write)
      expect_policy_rejects "PG8 nested permission ${mutation} mutation" 'reusable caller must grant exactly actions: read and contents: read' ;;
    preflight-missing-actions)
      expect_policy_rejects "PG8 nested permission ${mutation} mutation" 'nested pre-flight must request exactly actions: read and contents: read' ;;
    measure-actions-read)
      expect_policy_rejects "PG8 nested permission ${mutation} mutation" 'source-bearing measurement job must remain limited to contents: read' ;;
  esac
}
for mutation in caller-missing-actions caller-actions-write preflight-missing-actions measure-actions-read; do
  mutate_pg8_permission_scope "${mutation}"
done

# The candidate Stage 2 policy rejects the old seven-workflow set and accepts
# only the exact complete eight-workflow contract with PG8 present.
reset_fixture
ruby -rjson -e 'path=ARGV.fetch(0); d=JSON.parse(File.read(path)); d.fetch("dispatch_contracts").fetch("workflows").delete(".github/workflows/pg8-measurement.yml"); File.write(path,JSON.generate(d)); File.delete(File.join(File.dirname(path),"workflows","pg8-measurement.yml"))' "${work}/tree/.github/ci-matrix.json"
expect_policy_rejects 'old seven-workflow rollback after Stage 2 activation'

reset_fixture
cat > "${work}/tree/.github/workflows/pg8-measurement.yml" <<'YAML'
name: PostgreSQL DBX PG8 measurement
run-name: Taurine validation ${{ inputs.source_sha }} ${{ inputs.dispatch_key }}
on:
  workflow_dispatch:
    inputs:
      source_sha:
        description: Exact 40-character commit SHA to validate from private Taurine
        required: true
        type: string
      dispatch_key:
        description: Full SHA-256 key for this exact control revision and normalized inputs
        required: true
        type: string
permissions: {}
jobs:
  plan:
    permissions:
      actions: read
      contents: read
    runs-on: ubuntu-24.04
    steps:
      - name: Check out public control plane
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          fetch-depth: 1
          persist-credentials: false
      - name: Verify the source-read deployment branches
        uses: ./.github/actions/environment-preflight
        with:
          github-token: ${{ github.token }}
      - name: Validate exact source SHA
        shell: bash
        env:
          REQUESTED_SOURCE_SHA: ${{ inputs.source_sha }}
        run: |
          set -euo pipefail
          if [[ ! "${REQUESTED_SOURCE_SHA}" =~ ^[0-9a-fA-F]{40}$ ]]; then
            echo 'source_sha must be a full 40-character hexadecimal commit SHA' >&2
            exit 1
          fi
      - name: Verify the coordinator dispatch identity
        shell: bash
        working-directory: ${{ github.workspace }}
        env:
          CI_WORKFLOW_PATH: .github/workflows/pg8-measurement.yml
          CI_SOURCE_SHA: ${{ inputs.source_sha }}
          CI_DISPATCH_KEY: ${{ inputs.dispatch_key }}
          CI_NORMALIZED_INPUTS: ${{ format('{{"source_sha":{0}}}', toJSON(inputs.source_sha)) }}
          CI_DISPATCH_CONTRACT_JSON: ''
          CI_GENERATE_ONLY: 'false'
          CI_CONTROL_REPOSITORY: ${{ github.repository }}
          CI_CONTROL_SHA: ${{ github.sha }}
          CI_CONTROL_REF: ${{ github.ref }}
        run: ruby .github/policy/dispatch-identity.rb
      - name: Refuse a duplicate dispatch
        shell: bash
        working-directory: ${{ github.workspace }}
        env:
          GH_TOKEN: ${{ github.token }}
          CI_WORKFLOW_PATH: .github/workflows/pg8-measurement.yml
          CI_SOURCE_SHA: ${{ inputs.source_sha }}
          CI_DISPATCH_KEY: ${{ inputs.dispatch_key }}
          CI_RUN_ID: ${{ github.run_id }}
        run: ruby .github/policy/refuse-duplicate-dispatch.rb
  measure:
    needs: [plan]
    permissions:
      actions: read
      contents: read
    uses: ./.github/workflows/pg8-measurement-arm.yml
    with:
      source_sha: ${{ inputs.source_sha }}
    secrets:
      SOURCE_READER_PRIVATE_KEY: ${{ secrets.SOURCE_READER_PRIVATE_KEY }}
YAML
ruby -rjson -e 'path=ARGV.fetch(0); data=JSON.parse(File.read(path)); workflows=data.fetch("dispatch_contracts").fetch("workflows"); workflows[".github/workflows/pg8-measurement.yml"]={"inputs"=>{"source_sha"=>{"type"=>"string","required"=>true,"format"=>"sha40","digest_include"=>true},"dispatch_key"=>{"type"=>"string","required"=>true,"format"=>"sha256","digest_include"=>false}}}; File.write(path,JSON.pretty_generate(data))' \
  "${work}/tree/.github/ci-matrix.json"
ruby .github/policy/check-dispatch-contracts.rb "${work}/tree" >/dev/null
cp "${work}/tree/.github/workflows/pg8-measurement.yml" "${work}/pg8-measurement.yml"
cp "${work}/tree/.github/ci-matrix.json" "${work}/ci-matrix-pg8.json"

# A schema extension, a matching matrix declaration, or a new entrypoint name
# cannot broaden the exact future contract.
reset_fixture
cp "${work}/pg8-measurement.yml" "${work}/tree/.github/workflows/pg8-measurement.yml"
cp "${work}/ci-matrix-pg8.json" "${work}/tree/.github/ci-matrix.json"
ruby -rjson -e 'path=ARGV.fetch(0); data=JSON.parse(File.read(path)); data.fetch("dispatch_contracts").fetch("workflows").fetch(".github/workflows/pg8-measurement.yml").fetch("inputs").fetch("source_sha")["format"]="short-sha"; File.write(path,JSON.pretty_generate(data))' \
  "${work}/tree/.github/ci-matrix.json"
expect_policy_rejects 'future PG8 workflow schema drift'

reset_fixture
cp "${work}/pg8-measurement.yml" "${work}/tree/.github/workflows/pg8-measurement.yml"
cp "${work}/ci-matrix-pg8.json" "${work}/tree/.github/ci-matrix.json"
ruby -rjson -e 'path=ARGV.fetch(0); data=JSON.parse(File.read(path)); data.fetch("dispatch_contracts").fetch("workflows")[".github/workflows/unreviewed.yml"]={"inputs"=>{}}; File.write(path,JSON.pretty_generate(data))' \
  "${work}/tree/.github/ci-matrix.json"
expect_policy_rejects 'unreviewed ninth workflow'

reset_fixture
cp "${work}/pg8-measurement.yml" "${work}/tree/.github/workflows/pg8-measurement.yml"
cp "${work}/ci-matrix-pg8.json" "${work}/tree/.github/ci-matrix.json"
ruby -ryaml -e 'path=ARGV.fetch(0); doc=YAML.safe_load(File.read(path),aliases:false); job=doc.fetch("jobs").fetch("plan"); identity=job.fetch("steps").find { |step| step["name"]=="Verify the coordinator dispatch identity" }; identity.fetch("env")["CI_NORMALIZED_INPUTS"]="${{ format(\x27{{\"source_sha\":{0},\"mode\":{1}}}\x27, toJSON(inputs.source_sha), toJSON(inputs.mode)) }}"; File.write(path,YAML.dump(doc))' \
  "${work}/tree/.github/workflows/pg8-measurement.yml"
expect_policy_rejects 'future PG8 dispatch identity input drift'

# Final Stage 2 accepts only new13. The Stage 1 predecessor policy separately
# allows complete old12 during rollout; candidate policy must reject that old
# schema as well as every incomplete subset.
reset_fixture
ruby -rjson -e 'path=ARGV.fetch(0); data=JSON.parse(File.read(path)); data.fetch("dispatch_contracts").fetch("workflows").fetch(".github/workflows/live-proofs.yml").fetch("inputs").fetch("engine")["options"]=%w[doris starrocks db2 informix rocketmq iris postgres pg-dbx mysql mssql pgtls bastion]; File.write(path,JSON.pretty_generate(data))' \
  "${work}/tree/.github/ci-matrix.json"
expect_policy_rejects 'old12 rollback after Stage 2 activation'

reset_fixture
ruby -rjson -e 'path=ARGV.fetch(0); data=JSON.parse(File.read(path)); data.fetch("dispatch_contracts").fetch("workflows").fetch(".github/workflows/live-proofs.yml").fetch("inputs").fetch("engine")["options"]=%w[doris starrocks db2 informix rocketmq iris postgres mysql mssql pgtls bastion]; File.write(path,JSON.pretty_generate(data))' \
  "${work}/tree/.github/ci-matrix.json"
expect_policy_rejects 'stale 11-arm live roster'

# The exact complete new13 candidate schema is valid. Every proper subset
# missing any previously mandatory arm is refused below.
new13='["doris","starrocks","db2","informix","rocketmq","iris","postgres","pg-dbx","mysql","mssql","pgtls","tls-legacy","bastion"]'
reset_fixture
ruby -rjson -e 'path=ARGV.fetch(0); data=JSON.parse(File.read(path)); data.fetch("dispatch_contracts").fetch("workflows").fetch(".github/workflows/live-proofs.yml").fetch("inputs").fetch("engine")["options"]=JSON.parse(ARGV.fetch(1)); File.write(path,JSON.pretty_generate(data))' \
  "${work}/tree/.github/ci-matrix.json" "${new13}"
ruby .github/policy/check-dispatch-contracts.rb "${work}/tree" >/dev/null
for missing in doris starrocks db2 informix rocketmq iris postgres pg-dbx mysql mssql pgtls bastion; do
  reset_fixture
  ruby -rjson -e 'path=ARGV.fetch(0); data=JSON.parse(File.read(path)); options=data.fetch("dispatch_contracts").fetch("workflows").fetch(".github/workflows/live-proofs.yml").fetch("inputs").fetch("engine")["options"]; options << "tls-legacy"; options.delete(ARGV.fetch(1)); File.write(path,JSON.pretty_generate(data))' \
    "${work}/tree/.github/ci-matrix.json" "${missing}"
  expect_policy_rejects "new13 missing mandatory old arm ${missing}"
done

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

# Reproduce the actual Windows Plan step with the valid optional Rust concern.
# jq -r is required because jq -c represents an empty set-difference as `""`.
ruby -ryaml -e 'workflow=YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true); step=workflow.fetch("jobs").fetch("plan").fetch("steps").find { |row| row["id"] == "plan" }; abort unless step; File.write(ARGV.fetch(1), step.fetch("run"))' \
  .github/workflows/windows-validation.yml "${work}/windows-plan.sh"
run_windows_plan() {
  local label="$1" rust="$2" only="$3" expected_status="$4" status=0
  : >"${work}/windows-plan.out"
  : >"${work}/windows-plan.summary"
  (RUST_REQUESTED="${rust}" ONLY="${only}" GITHUB_OUTPUT="${work}/windows-plan.out" GITHUB_STEP_SUMMARY="${work}/windows-plan.summary" bash "${work}/windows-plan.sh") \
    >"${work}/windows-plan.stdout" 2>"${work}/windows-plan.stderr" || status=$?
  if [[ "${expected_status}" == success && "${status}" -ne 0 ]]; then
    echo "${label}: valid Windows Plan selection failed" >&2; exit 1
  elif [[ "${expected_status}" == reject && "${status}" -eq 0 ]]; then
    echo "${label}: invalid Windows Plan selection unexpectedly passed" >&2; exit 1
  fi
}
run_windows_plan 'full Windows Rust matrix' true '' success
ruby -rjson -e 'out=File.readlines(ARGV.fetch(0)).to_h { |line| key,value=line.chomp.split("=",2); [key,value] }; abort "wrong full Windows Rust matrix" unless JSON.parse(out.fetch("rust_matrix")) == {"concern"=>%w[rust-domain rust-db rust-net rust-ovpn rust-app-1 rust-app-2 rust-packaging rust-tls-openssl]}' "${work}/windows-plan.out"
run_windows_plan 'filtered Windows Rust concern' true rust-db success
ruby -rjson -e 'out=File.readlines(ARGV.fetch(0)).to_h { |line| key,value=line.chomp.split("=",2); [key,value] }; abort "valid rust-db concern was not selected" unless JSON.parse(out.fetch("rust_matrix")) == {"concern"=>["rust-db"]}' "${work}/windows-plan.out"
run_windows_plan 'unknown Windows concern' true rust-not-reviewed reject
grep -qF 'only: not a Windows concern of this dispatch' "${work}/windows-plan.stderr"
run_windows_plan 'Rust concern while Rust disabled' false rust-db reject
grep -qF 'only: not a Windows concern of this dispatch' "${work}/windows-plan.stderr"

# The strict stage-2 concern-table contract must reject the old expression again.
mkdir -p "${work}/strict-mode"
cp -R .github "${work}/strict-mode/"
ruby -e 'path=ARGV.fetch(0); text=File.read(path); current="${{ inputs.profile == '\''full'\'' && inputs.base_sha == '\'''\'' && inputs.only == '\'''\'' && '\''full'\'' || '\''partial'\'' }}"; old="${{ inputs.profile == '\''full'\'' && inputs.base_sha == '\'''\'' && '\''full'\'' || '\''partial'\'' }}"; abort "strict mode expression not found" unless text.include?(current); File.write(path,text.sub(current,old))' \
  "${work}/strict-mode/.github/workflows/linux-validation.yml"
if (cd "${work}/strict-mode" && bash .github/policy/check-concern-table.sh) >"${work}/strict-mode.stdout" 2>"${work}/strict-mode.stderr"; then
  echo 'the old full/partial expression passed the strict policy' >&2; exit 1
fi
grep -qF 'run-result must use its reviewed explicit selection mode' "${work}/strict-mode.stderr"

# PG8 must use the exact source SHA validation step before dispatch identity.
mutate_pg8_source_validator() {
  local mutation="$1"
  reset_fixture
  cp "${work}/pg8-measurement.yml" "${work}/tree/.github/workflows/pg8-measurement.yml"
  cp "${work}/ci-matrix-pg8.json" "${work}/tree/.github/ci-matrix.json"
  ruby -ryaml -e '
    path, mutation = ARGV
    doc = YAML.safe_load_file(path, aliases: false)
    steps = doc.fetch("jobs").fetch("plan").fetch("steps")
    source = steps.find { |step| step["name"] == "Validate exact source SHA" }
    identity = steps.find { |step| step["name"] == "Verify the coordinator dispatch identity" }
    case mutation
    when "missing" then steps.delete(source)
    when "reordered" then steps.delete(source); steps.insert(steps.index(identity) + 1, source)
    when "body" then source["run"] = source.fetch("run").sub("40-character hexadecimal", "short hexadecimal")
    when "binding" then source.fetch("env")["REQUESTED_SOURCE_SHA"] = "${{ inputs.dispatch_key }}"
    end
    File.write(path, YAML.dump(doc))
  ' "${work}/tree/.github/workflows/pg8-measurement.yml" "${mutation}"
  expect_policy_rejects "PG8 source SHA validator ${mutation} mutation"
}
for mutation in missing reordered body binding; do
  mutate_pg8_source_validator "${mutation}"
done

# The two exact PG8 local references are reviewed; adding a third reference stays blocked.
source .github/policy/check-actions.sh
printf '%s\n' 'jobs:' '  measure:' '    uses: ./.github/workflows/pg8-measurement-arm.yml' \
  '  action:' '    steps:' '      - name: approved action' '        uses: ./.github/actions/pg8-measurement' >"${work}/pg8-references.yml"
check_action_references "${work}/pg8-references.yml"
printf '%s\n' '      - name: unreviewed action' '        uses: ./.github/actions/pg8-unreviewed' >>"${work}/pg8-references.yml"
if (check_action_references "${work}/pg8-references.yml") >"${work}/action.stdout" 2>"${work}/action.stderr"; then
  echo 'unreviewed PG8 third local reference unexpectedly passed' >&2; exit 1
fi
grep -qF 'Unreviewed or mutable Action reference' "${work}/action.stderr"

# Removing the reusable-arm preflight map entry must not disable universal checking.
cp .github/policy/check-universal.rb "${work}/check-universal-mutated.rb"
ruby -e 'path=ARGV.fetch(0); text=File.read(path); entry="  '\''.github/workflows/pg8-measurement-arm.yml'\'' => '\''preflight'\'',\n"; abort "required PG8 arm mapping missing from fixture" unless text.include?(entry); File.write(path,text.sub(entry,""))' \
  "${work}/check-universal-mutated.rb"
if ruby "${work}/check-universal-mutated.rb" . >"${work}/universal.stdout" 2>"${work}/universal.stderr"; then
  echo 'missing PG8 arm preflight mapping unexpectedly passed universal policy' >&2; exit 1
fi
grep -qF 'the reviewed PG8 dispatcher and reusable arm must keep their exact preflight mappings' "${work}/universal.stderr"

echo 'dispatch contracts: Plan selection accepts valid visual opt-in, preserves partial only identity, and rejects disabled/unknown concerns'
echo 'dispatch contracts: strict stage-2 policy rejects the old Linux selection-mode expression'
echo 'dispatch contracts: source-SHA, local-reference, and PG8 preflight-mapping mutations were rejected'
