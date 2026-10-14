#!/usr/bin/env bash
# Synthetic source repository and a fake runner only; no Playwright, no browser,
# no app code. Exercises the admission producer's reconciliation: an exact
# discovery/execution match passes, and every way the two can disagree blocks.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/case-evidence-admission-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

ruby -rjson -rfileutils -rrbconfig -e '
  tmp = ARGV.fetch(0)
  source = File.join(tmp, "source")
  app = File.join(source, "taurine-desktop")
  FileUtils.mkdir_p([File.join(app, "tests/e2e"), File.join(tmp, "fake-bin")])
  version = "1.62.0"
  packages = {}
  %w[node_modules/@playwright/test node_modules/playwright node_modules/playwright-core].each do |name|
    packages[name] = {"version" => version}
    FileUtils.mkdir_p(File.join(app, name))
    File.write(File.join(app, name, "package.json"), JSON.generate({"version" => version}))
  end
  File.write(File.join(app, "package-lock.json"), JSON.generate({"packages" => packages}))
  File.write(File.join(app, "playwright.config.ts"), "export default {};\n")
  File.write(File.join(app, "node_modules/playwright/cli.js"), "// synthetic CLI placeholder\n")
  File.write(File.join(app, "tests/e2e/flows.spec.ts"), "// synthetic spec placeholder\n")

  # The fake runner answers only the fixed list command, writing the reporter
  # shape the control reporter produces plus its completion marker. Its mode
  # file lets the harness perturb exactly one thing at a time.
  File.write(File.join(tmp, "fake-bin", "node"), <<~RUBY)
    #!#{RbConfig.ruby}
    require "json"
    cli, *args = ARGV
    abort "unexpected invocation" unless args.first == "test" && args.include?("--list")
    project = args[args.index("--project") + 1]
    # The producer replaces the child environment with its own allowlist, so
    # the harness cannot steer this runner through an environment variable.
    # That is the point; the mode is read out of band, beside the checkout.
    app = File.dirname(File.dirname(File.dirname(cli)))
    mode_file = File.join(File.dirname(app), "mode")
    mode = File.exist?(mode_file) ? File.read(mode_file).strip : ""
    spec = File.join(app, "tests/e2e/flows.spec.ts")
    titles = ["flows > first case", "flows > second case"]
    titles << "flows > discovery only" if mode == "discovery-extra" && project == "smoke"
    titles = titles.first(1) if mode == "discovery-missing" && project == "smoke"
    titles = [titles.first, titles.first] if mode == "duplicate" && project == "smoke"
    specs = titles.map do |title|
      {"title" => title, "file" => spec,
       "tests" => [{"projectName" => project, "status" => "discovered", "results" => []}]}
    end
    report = {"suites" => [{"file" => spec, "specs" => specs}], "errors" => []}
    File.write(ENV.fetch("TAURINE_CASE_EVIDENCE_REPORT_PATH"), JSON.generate(report))
    unless mode == "marker-failed"
      File.write(ENV.fetch("TAURINE_CASE_EVIDENCE_COMPLETION_PATH"),
        JSON.generate({"schema_version" => 1, "status" => "complete", "error_class" => nil, "count" => specs.length}))
    end
    exit 0
  RUBY
  File.chmod(0o700, File.join(tmp, "fake-bin", "node"))
' "$tmp"

git -C "$tmp/source" init -q
git -C "$tmp/source" add -A
GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME='Synthetic admission' GIT_AUTHOR_EMAIL='admission@example.invalid' \
GIT_COMMITTER_NAME='Synthetic admission' GIT_COMMITTER_EMAIL='admission@example.invalid' \
  git -C "$tmp/source" commit -qm 'synthetic source'

# The execution report the reviewed concern command would have written: the
# same two cases per project, as Playwright's own JSON reporter nests them.
write_execution() {
  ruby -rjson -e '
    target, mode, *projects = ARGV
    make = lambda do |project, titles|
      titles.map do |title|
        {"title" => title,
         "tests" => [{"projectName" => project, "status" => "expected", "expectedStatus" => "passed",
                      "results" => [{"status" => "passed"}]}]}
      end
    end
    specs = []
    projects.each do |project|
      titles = ["first case", "second case"]
      titles << "execution only" if mode == "execution-extra" && project == "smoke"
      titles = titles.first(1) if mode == "execution-missing" && project == "smoke"
      specs.concat(make.call(project, titles))
    end
    specs.concat(make.call("rogue", ["first case"])) if mode == "rogue-project"
    total = specs.sum { |spec| spec.fetch("tests").length }
    total -= 1 if mode == "stats-wrong"
    report = {
      "suites" => [{"title" => "tests/e2e/flows.spec.ts", "file" => "tests/e2e/flows.spec.ts",
                    "suites" => [{"title" => "flows", "specs" => specs}]}],
      "errors" => [],
      "stats" => {"expected" => total, "skipped" => 0, "unexpected" => 0, "flaky" => 0}
    }
    File.write(target, JSON.generate(report))
  ' "$tmp/execution.json" "$1" "${@:2}"
}

run_admission() {
  concern="$1"
  rm -rf "$tmp/work"
  mkdir -p "$tmp/work"
  chmod 700 "$tmp/work"
  # Keep the ruby that runs this harness on PATH: the contract needs a modern
  # one, and /usr/bin/ruby is ancient on some developer machines.
  env -i PATH="$tmp/fake-bin:$(dirname "$(command -v ruby)"):/usr/bin:/bin" HOME="$tmp" \
    CI_EXPECTED_SOURCE_SHA="$(git -C "$tmp/source" rev-parse HEAD)" \
    CI_EXPECTED_CONTROL_SHA="$(printf 'b%.0s' {1..40})" \
    CI_EXPECTED_MANIFEST_DIGEST="$(printf 'c%.0s' {1..64})" \
    CI_EXPECTED_CATALOG_DIGEST="$(printf 'd%.0s' {1..64})" \
    CI_EXPECTED_SELECTION_MODE=full \
    CI_EXPECTED_SELECTED_SUITE_IDS='["desktop.e2e.flows"]' \
    CI_PLATFORM=linux \
    ruby "$root/.github/policy/case-evidence-admission.rb" "$concern" "$tmp/source" "$tmp/execution.json" "$tmp/work"
}

expect_blocked() {
  label="$1"
  want="$2"
  concern="${3:-e2e-critical}"
  status=0
  out="$(run_admission "$concern")" || status=$?
  [[ "$status" -eq 1 ]] || { echo "admission accepted ${label}" >&2; exit 1; }
  ruby -rjson -e '
    result = JSON.parse(ARGV.fetch(0))
    abort "wrong disposition for #{ARGV.fetch(2)}: #{result.inspect}" unless
      result["status"] == "case_evidence_blocked" && result["error_class"] == ARGV.fetch(1)
  ' "$out" "$want" "$label"
}

: > "$tmp/source/mode"
write_execution '' smoke critical shell-browser
positive="$(run_admission e2e-critical)"
ruby -rjson -e '
  result = JSON.parse(ARGV.fetch(0))
  abort "reconciliation did not pass: #{result.inspect}" unless result["status"] == "case_evidence_reconciled"
  abort "wrong concern" unless result["concern"] == "e2e-critical"
  projects = result.fetch("projects")
  abort "wrong project set" unless projects.map { |entry| entry.fetch("project") } == %w[smoke critical shell-browser]
  abort "wrong per-project counts" unless projects.all? { |entry| entry.fetch("discovered") == 2 && entry.fetch("executed") == 2 }
  abort "wrong totals" unless result.fetch("counts") == {"discovered" => 6, "executed" => 6}
' "$positive"
# Nothing identifying may reach the summary this output feeds.
for leaked in 'first case' 'flows.spec.ts' 'tests/e2e'; do
  if grep -Fq "$leaked" <<<"$positive"; then
    echo "private case detail escaped the admission output: ${leaked}" >&2
    exit 1
  fi
done
grep -Eq '[0-9a-f]{64}' <<<"$positive" && { echo 'a case identity digest escaped the admission output' >&2; exit 1; }

# A case the runner executed but never discovered, and the reverse. Both are
# the completeness failure this gate exists to catch.
write_execution 'execution-extra' smoke critical shell-browser
expect_blocked 'an executed case that was never discovered' contract_rejected
write_execution 'execution-missing' smoke critical shell-browser
expect_blocked 'a discovered case that was never executed' contract_rejected

write_execution '' smoke critical shell-browser
echo discovery-extra > "$tmp/source/mode"
expect_blocked 'a discovered case that was never executed (discovery side)' contract_rejected
echo discovery-missing > "$tmp/source/mode"
expect_blocked 'an executed case missing from discovery' contract_rejected
echo duplicate > "$tmp/source/mode"
expect_blocked 'two discovered cases with one identity' contract_rejected
echo marker-failed > "$tmp/source/mode"
expect_blocked 'a reporter that wrote no completion marker' report_path_invalid

: > "$tmp/source/mode"
write_execution 'rogue-project' smoke critical shell-browser
expect_blocked 'a case belonging to no reviewed project' project_unexpected

write_execution 'stats-wrong' smoke critical shell-browser
expect_blocked 'runner totals that disagree with the reconciled cases' stats_mismatch

# An unexpectedly empty suite must never read as a clean reconciliation.
write_execution '' smoke critical shell-browser
ruby -rjson -e 'File.write(ARGV.fetch(0), JSON.generate({"suites" => [], "errors" => []}))' "$tmp/execution.json"
expect_blocked 'an empty execution report' execution_report_invalid

# The sharded regression concerns are not reconciled, and asking for one is an
# error rather than a quiet pass.
write_execution '' regression
expect_blocked 'a sharded concern' concern_unsupported e2e-regression-1

echo 'Case evidence admission: exact discovery/execution reconciliation, project completeness, and every disagreement blocked'
