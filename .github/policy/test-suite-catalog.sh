#!/usr/bin/env bash
# Exercise the public suite-catalog contract using synthetic JSON mutations only.
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/suite-catalog-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

reset_fixture() {
  cp .github/ci-matrix.json "${work}/matrix.json"
}

expect_reject() {
  local label="$1" output status
  set +e
  output="$(ruby .github/policy/check-suite-catalog.rb "${work}/matrix.json" 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 && "${output}" == 'suite catalog: rejected invalid or unreviewed contract' ]] || {
    echo "${label}: invalid suite catalog passed or leaked an unreviewed value" >&2
    exit 1
  }
}

expect_accept() {
  local label="$1" output
  output="$(ruby .github/policy/check-suite-catalog.rb "${work}/matrix.json" 2>&1)" || {
    echo "${label}: reviewed catalog growth or monotonic promotion was rejected" >&2
    exit 1
  }
  [[ "${output}" == 'suite catalog: reviewed candidate bindings and coverage requirements match' ]] || {
    echo "${label}: checker did not return its fixed success class" >&2
    exit 1
  }
}

reset_fixture
ruby .github/policy/check-suite-catalog.rb "${work}/matrix.json" >/dev/null

reset_fixture
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["suite_catalog"]["suites"].pop; File.write(p,JSON.generate(d))' "${work}/matrix.json"
expect_reject 'removed mandatory-catalog candidate'

reset_fixture
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["suite_catalog"]["suites"][0]["runner"]="unreviewed-runner"; File.write(p,JSON.generate(d))' "${work}/matrix.json"
expect_reject 'mutable runner binding'

reset_fixture
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["suite_catalog"]["suites"][0]["mandatory"]=true; File.write(p,JSON.generate(d))' "${work}/matrix.json"
expect_reject 'candidate changed to a pass-bearing mandatory row'

reset_fixture
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["suite_catalog"]["coverage_requirements"].reject!{|r| r["id"]=="mobile-playwright-critical-linux"}; File.write(p,JSON.generate(d))' "${work}/matrix.json"
expect_reject 'removed required uncovered mobile route'

reset_fixture
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); r=d["suite_catalog"]["coverage_requirements"].find{|x| x["id"]=="mobile-playwright-smoke-linux"}; r["availability"]="supported"; r["availability_reason"]=nil; File.write(p,JSON.generate(d))' "${work}/matrix.json"
expect_accept 'route promoted after implementation'

reset_fixture
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); r=d["suite_catalog"]["coverage_requirements"].find{|x| x["id"]=="mobile-playwright-smoke-linux"}; r["mandatory"]=false; File.write(p,JSON.generate(d))' "${work}/matrix.json"
expect_reject 'required unhosted route demoted to optional'

reset_fixture
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); r=d["suite_catalog"]["coverage_requirements"].find{|x| x["id"]=="desktop-playwright-benchmark-linux"}; r["availability"]="supported"; r["availability_reason"]=nil; File.write(p,JSON.generate(d))' "${work}/matrix.json"
expect_accept 'optional benchmark route promotion'

reset_fixture
ruby -rjson -e '
  p=ARGV.fetch(0); d=JSON.parse(File.read(p)); c=d.fetch("suite_catalog")
  id="mobile.vitest.default.ai"
  c.fetch("suites") << {"id"=>id,"feature"=>"ai","tier"=>"default","runner"=>"vitest-mobile","config"=>"mobile-vitest-default","platforms"=>["linux"],"projects"=>[],"status"=>"candidate","mandatory"=>false,"concerns"=>["mobile-quality"]}
  r=c.fetch("coverage_requirements").find{|x| x["id"]=="mobile-vitest-default-linux"}
  r["feature_ids"] << "ai"
  r["candidate_suite_ids"] << id
  File.write(p,JSON.generate(d))
' "${work}/matrix.json"
expect_accept 'new suite candidate extends the existing config ownership group'

reset_fixture
ruby -rjson -e '
  p=ARGV.fetch(0); d=JSON.parse(File.read(p)); c=d.fetch("suite_catalog")
  id="mobile.vitest.default.ai"
  c.fetch("suites") << {"id"=>id,"feature"=>"ai","tier"=>"default","runner"=>"unreviewed-runner","config"=>"mobile-vitest-default","platforms"=>["linux"],"projects"=>[],"status"=>"candidate","mandatory"=>false,"concerns"=>["mobile-quality"]}
  r=c.fetch("coverage_requirements").find{|x| x["id"]=="mobile-vitest-default-linux"}
  r["feature_ids"] << "ai"
  r["candidate_suite_ids"] << id
  File.write(p,JSON.generate(d))
' "${work}/matrix.json"
expect_reject 'unreviewed runner/config pairing'

reset_fixture
ruby -rjson -e '
  p=ARGV.fetch(0); d=JSON.parse(File.read(p)); c=d.fetch("suite_catalog")
  r=c.fetch("coverage_requirements").find{|x| x["id"]=="mobile-vitest-default-linux"}.dup
  r["id"]="mobile-vitest-default-supplement-linux"
  c.fetch("coverage_requirements") << r
  File.write(p,JSON.generate(d))
' "${work}/matrix.json"
expect_reject 'duplicate execution group split across coverage rows'

reset_fixture
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["suite_catalog"]["suites"][0]["projects"]=["SYNTHETIC-PRIVATE-PATH"]; File.write(p,JSON.generate(d))' "${work}/matrix.json"
expect_reject 'unreviewed project value'

echo 'suite catalog: immutable roster, coverage, availability and runner bindings passed'
