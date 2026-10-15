#!/usr/bin/env bash
# The admission reconciliation, exercised against REAL pinned-runner output.
#
# The discovery reports and the execution report replayed here were produced by
# @playwright/test 1.62.0 against a synthetic app, not written by hand; see
# .github/policy/case-evidence-assets/real-runner-provenance.json. An earlier
# version of this harness invented a report shape the real runner never emits,
# and so encoded the very path bug it was supposed to catch.
#
# No Playwright, browser or app code runs here: a fake node replays the
# recorded reports, and the source repository is synthetic.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
assets="${root}/.github/policy/case-evidence-assets"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/case-evidence-admission-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

# A copy of the control tree, committed here, so the fixture can perturb a
# control-owned asset without touching the real checkout, and does not depend
# on that checkout being clean.
control="$tmp/control"
mkdir -p "$control"
cp -R "${root}/.github" "$control/.github"
git -C "$control" init -q
git -C "$control" config user.name 'Synthetic control'
git -C "$control" config user.email 'control@example.invalid'
git -C "$control" add -A
git -C "$control" commit -qm 'synthetic control'
control_sha="$(git -C "$control" rev-parse HEAD)"
admission="$control/.github/policy/case-evidence-admission.rb"

ruby -rjson -rfileutils -rrbconfig -rdigest -e '
  tmp, assets, root = ARGV
  source = File.join(tmp, "source")
  app = File.join(source, "taurine-desktop")
  replay = File.join(app, ".case-evidence-replay")
  FileUtils.mkdir_p([File.join(app, "tests/e2e/deep"), File.join(source, "scripts/ci"), replay, File.join(tmp, "fake-bin")])

  pins = {
    "node_modules/@playwright/test" => "sha512-9zOJ6ZQRAena31MpOH9VSzIz8Ou3YJ/wtY/eQm5T2uhfhG7/U3COrMS8xOtUrZrp9OgdmzEnIYODye3nY1VqzA==",
    "node_modules/playwright" => "sha512-Z14dG305dgaLu6foB1TXQagFiW8JfSUIUaUuPaKQ6NtBPKF1P/qXcqfh6c6K/icPqdy37JmjbiBXf6JNg6Sylw==",
    "node_modules/playwright-core" => "sha512-nsNRyq0r2zsG8AcRHWknc9QRA5XCueC7gWMrs+Gx2tlZn9hcl8zudfh00lhJPY1DE7NmZ6bDsT9g2yey8mXljA=="
  }
  packages = {}
  pins.each do |name, integrity|
    packages[name] = {"version" => "1.62.0", "integrity" => integrity}
    FileUtils.mkdir_p(File.join(app, name))
    File.write(File.join(app, name, "package.json"), JSON.generate({"version" => "1.62.0"}))
  end
  File.write(File.join(app, "package-lock.json"), JSON.generate({"packages" => packages}))
  File.write(File.join(app, "playwright.config.ts"), %q{export default { testDir: "./tests/e2e" };} + "\n")
  File.write(File.join(app, "node_modules/playwright/cli.js"), "// synthetic CLI placeholder\n")
  File.write(File.join(app, "tests/e2e/flows.spec.ts"), "// synthetic spec placeholder\n")
  File.write(File.join(app, "tests/e2e/deep/inner.spec.ts"), "// synthetic spec placeholder\n")
  File.write(File.join(source, "scripts/ci/suite-ownership.json"), JSON.generate({"version" => 1, "suites" => []}))

  # The recorded real reports, with the directory they were produced under
  # rebound to this synthetic app. The real list reporter resolves against the
  # runner working directory, which the producer passes as a realpath, so the
  # replayed paths must be realpaths too.
  app_real = File.realpath(app)
  %w[real-list-smoke.json real-list-critical.json real-list-shell-browser.json
     real-list-outcomes.json real-execution-feedback.json real-execution-outcomes.json].each do |name|
    text = File.read(File.join(assets, name)).gsub("__APP_ROOT__", app_real)
    File.write(File.join(replay, name), JSON.generate(JSON.parse(text)))
  end

  File.write(File.join(tmp, "fake-bin", "node"), <<~RUBY)
    #!#{RbConfig.ruby}
    require "json"
    cli, *args = ARGV
    abort "unexpected invocation" unless args.first == "test" && args.include?("--list")
    project = args[args.index("--project") + 1]
    app = File.expand_path("../..", File.dirname(cli))
    replay = File.join(app, ".case-evidence-replay")
    # The producer replaces the child environment with its own allowlist, so
    # this runner cannot be steered through an environment variable. That is
    # the point; the mode is read out of band, beside the checkout.
    # Beside the checkout, never inside it: a file in the source tree would
    # make it dirty, which the producer rejects in its own right.
    mode_file = File.join(File.dirname(File.dirname(app)), "mode")
    mode = File.exist?(mode_file) ? File.read(mode_file).strip : ""
    source_name = mode.start_with?("outcomes") ? "real-list-outcomes.json" : "real-list-\#{project}.json"
    report = JSON.parse(File.read(File.join(replay, source_name)))
    specs = report.fetch("suites").flat_map { |suite| suite.fetch("specs") }
    case mode
    when "discovery-extra"
      first = report["suites"][0]
      extra = Marshal.load(Marshal.dump(first["specs"][0]))
      extra["title"] = extra["title"] + " (never executed)"
      first["specs"] << extra
    when "discovery-missing"
      report["suites"][0]["specs"].pop
      report["suites"].reject! { |suite| suite["specs"].empty? }
    when "duplicate"
      first = report["suites"][0]
      first["specs"] << Marshal.load(Marshal.dump(first["specs"][0]))
    when "empty"
      report["suites"] = []
    end
    count = report.fetch("suites").sum { |suite| suite.fetch("specs").length }
    File.write(ENV.fetch("TAURINE_CASE_EVIDENCE_REPORT_PATH"), JSON.generate(report))
    unless mode == "marker-failed"
      File.write(ENV.fetch("TAURINE_CASE_EVIDENCE_COMPLETION_PATH"),
        JSON.generate({"schema_version" => 1, "status" => "complete", "error_class" => nil, "count" => count}))
    end
    exit 0
  RUBY
  File.chmod(0o700, File.join(tmp, "fake-bin", "node"))

  # The identities the suite-contract step publishes, recomputed the same way.
  def sort_json(value)
    case value
    when Hash then value.keys.sort.each_with_object({}) { |k, r| r[k] = sort_json(value.fetch(k)) }
    when Array then value.map { |i| sort_json(i) }
    else value
    end
  end
  catalog = JSON.parse(File.read(File.join(root, ".github/ci-matrix.json"))).fetch("suite_catalog")
  group = catalog.fetch("coverage_requirements").find { |g| g["id"] == "desktop-playwright-feedback-linux" }
  a11y = catalog.fetch("coverage_requirements").find { |g| g["id"] == "desktop-playwright-a11y-linux" }
  abort "a reviewed coverage group is missing" unless group && a11y
  File.write(File.join(tmp, "identity.env"), [
    "CI_EXPECTED_CATALOG_DIGEST=\x27#{Digest::SHA256.hexdigest(JSON.generate(sort_json(catalog), ascii_only: true))}\x27",
    "CI_EXPECTED_MANIFEST_DIGEST=\x27#{Digest::SHA256.hexdigest(JSON.generate(sort_json(JSON.parse(File.read(File.join(source, "scripts/ci/suite-ownership.json")))), ascii_only: true))}\x27",
    "CI_EXPECTED_SELECTED_SUITE_IDS=\x27#{JSON.generate(group.fetch("candidate_suite_ids"))}\x27",
    "A11Y_SELECTED_SUITE_IDS=\x27#{JSON.generate(a11y.fetch("candidate_suite_ids"))}\x27"
  ].join("\n") + "\n")
' "$tmp" "$assets" "$root"

git -C "$tmp/source" init -q
git -C "$tmp/source" config user.name 'Synthetic admission'
git -C "$tmp/source" config user.email 'admission@example.invalid'
git -C "$tmp/source" add -A
GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME='Synthetic admission' GIT_AUTHOR_EMAIL='admission@example.invalid' \
GIT_COMMITTER_NAME='Synthetic admission' GIT_COMMITTER_EMAIL='admission@example.invalid' \
  git -C "$tmp/source" commit -qm 'synthetic source'
source_sha="$(git -C "$tmp/source" rev-parse HEAD)"
# shellcheck disable=SC1091
set -a; . "$tmp/identity.env"; set +a

execution_fixture() {
  ruby -rjson -e '
    target, source, mode = ARGV
    report = JSON.parse(File.read(source))
    w = lambda do |suites, &block|
      suites.each do |suite|
        (suite["specs"] || []).each { |spec| block.call(suite, spec) }
        w.call(suite["suites"] || [], &block)
      end
    end
    case mode
    when "execution-extra"
      w.call(report["suites"]) do |_suite, spec|
        next unless spec["title"] == "parameterized value alpha @smoke" && !report["__done"]
        report["__done"] = true
        @extra = Marshal.load(Marshal.dump(spec))
        @parent = _suite
      end
      @extra["title"] = "never discovered case @smoke"
      @parent["specs"] << @extra
      report.delete("__done")
      report["stats"]["expected"] += 1
    when "execution-missing"
      w.call(report["suites"]) { |suite, spec| suite["specs"].delete(spec) if spec["title"] == "parameterized value beta @smoke" }
      report["stats"]["expected"] -= 1
    when "rogue-project"
      w.call(report["suites"]) do |suite, spec|
        next unless spec["title"] == "parameterized value alpha @smoke"
        rogue = Marshal.load(Marshal.dump(spec))
        rogue["tests"].each { |t| t["projectName"] = "rogue" }
        rogue["title"] = "rogue project case @smoke"
        suite["specs"] << rogue unless suite["specs"].any? { |s| s["title"] == rogue["title"] }
        report["stats"]["expected"] += 1
      end
    when "all-skipped"
      total = 0
      w.call(report["suites"]) do |_suite, spec|
        spec["tests"].each do |test|
          test["status"] = "skipped"
          test["expectedStatus"] = "skipped"
          test["results"] = [{"status" => "skipped"}]
          total += 1
        end
      end
      report["stats"] = {"expected" => 0, "skipped" => total, "unexpected" => 0, "flaky" => 0}
    when "stats-wrong"
      report["stats"]["expected"] -= 1
    when "empty"
      report["suites"] = []
    end
    File.write(target, JSON.generate(report))
  ' "$tmp/execution.json" "$1" "${2:-}"
}

run_admission() {
  concern="$1"
  # Each concern binds to its own reviewed coverage group.
  selected="$CI_EXPECTED_SELECTED_SUITE_IDS"
  [[ "$concern" == "e2e-a11y" ]] && selected="$A11Y_SELECTED_SUITE_IDS"
  rm -rf "$tmp/work"
  mkdir -p "$tmp/work"
  chmod 700 "$tmp/work"
  env -i PATH="$tmp/fake-bin:$(dirname "$(command -v ruby)"):$(dirname "$(command -v git)"):/usr/bin:/bin" HOME="$tmp" \
    CI_EXPECTED_SOURCE_SHA="$source_sha" \
    CI_EXPECTED_CONTROL_SHA="$control_sha" \
    CI_EXPECTED_MANIFEST_DIGEST="${MANIFEST_DIGEST_OVERRIDE-$CI_EXPECTED_MANIFEST_DIGEST}" \
    CI_EXPECTED_CATALOG_DIGEST="$CI_EXPECTED_CATALOG_DIGEST" \
    CI_EXPECTED_SELECTION_MODE=full \
    CI_EXPECTED_SELECTED_SUITE_IDS="$selected" \
    CI_PLATFORM=linux \
    ruby "$admission" "$concern" "$tmp/source" "$tmp/execution.json" "$tmp/work"
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

: > "$tmp/mode"
execution_fixture "$assets/real-execution-feedback.json"
positive_status=0
positive="$(run_admission e2e-critical)" || positive_status=$?
[[ "$positive_status" -eq 0 ]] || {
  echo "real 1.62.0 output did not reconcile: ${positive}" >&2
  exit 1
}
ruby -rjson -e '
  result = JSON.parse(ARGV.fetch(0))
  abort "real runner output did not reconcile: #{result.inspect}" unless result["status"] == "case_evidence_reconciled"
  abort "wrong concern" unless result["concern"] == "e2e-critical"
  projects = result.fetch("projects")
  abort "wrong project set" unless projects.map { |e| e.fetch("project") } == %w[smoke critical shell-browser]
  abort "wrong per-project counts" unless projects.map { |e| [e.fetch("discovered"), e.fetch("executed")] } == [[3, 3], [1, 1], [1, 1]]
  abort "wrong totals" unless result.fetch("counts") ==
    {"discovered" => 5, "executed" => 5, "passed" => 5, "retried_pass" => 0, "skipped" => 0}
' "$positive"
for leaked in 'parameterized value' 'inner.spec.ts' 'tests/e2e' 'outer group'; do
  if grep -Fq "$leaked" <<<"$positive"; then
    echo "private case detail escaped the admission output: ${leaked}" >&2
    exit 1
  fi
done
grep -Eq '[0-9a-f]{64}' <<<"$positive" && { echo 'a case identity digest escaped the admission output' >&2; exit 1; }

# A real retried pass and a real skip are reported, not treated as failures.
# Recorded as a single-project a11y run, so it replays against e2e-a11y.
echo outcomes > "$tmp/mode"
execution_fixture "$assets/real-execution-outcomes.json"
outcomes_status=0
outcomes="$(run_admission e2e-a11y)" || outcomes_status=$?
[[ "$outcomes_status" -eq 0 ]] || {
  echo "a real retried pass or skip was treated as a parity failure: ${outcomes}" >&2
  exit 1
}
ruby -rjson -e '
  result = JSON.parse(ARGV.fetch(0))
  abort "real outcomes did not reconcile: #{result.inspect}" unless result["status"] == "case_evidence_reconciled"
  counts = result.fetch("counts")
  abort "retried pass or skip was folded into passed: #{counts.inspect}" unless
    counts == {"discovered" => 3, "executed" => 3, "passed" => 1, "retried_pass" => 1, "skipped" => 1}
' "$outcomes"

: > "$tmp/mode"
# Every way discovery and execution can disagree, each with its own class.
execution_fixture "$assets/real-execution-feedback.json" execution-extra
expect_blocked 'an executed case that was never discovered' discovery_execution_mismatch
execution_fixture "$assets/real-execution-feedback.json" execution-missing
expect_blocked 'a discovered case that was never executed' discovery_execution_mismatch
execution_fixture "$assets/real-execution-feedback.json" rogue-project
expect_blocked 'a case belonging to no reviewed project' project_unexpected
execution_fixture "$assets/real-execution-feedback.json" stats-wrong
expect_blocked 'runner totals that disagree with the reconciled cases' stats_mismatch
execution_fixture "$assets/real-execution-feedback.json" empty
expect_blocked 'an empty execution report' execution_report_invalid

execution_fixture "$assets/real-execution-feedback.json"
echo discovery-extra > "$tmp/mode"
expect_blocked 'a discovered case that was never executed (discovery side)' discovery_execution_mismatch
echo discovery-missing > "$tmp/mode"
expect_blocked 'an executed case missing from discovery' discovery_execution_mismatch
echo duplicate > "$tmp/mode"
expect_blocked 'two discovered cases with one identity' duplicate_case_identity
echo empty > "$tmp/mode"
expect_blocked 'an unexpectedly empty discovered suite' reporter_failed
echo marker-failed > "$tmp/mode"
expect_blocked 'a reporter that wrote no completion marker' report_path_invalid

: > "$tmp/mode"
# The source repository must not be able to switch this gate off by removing
# the ownership manifest it owns.
MANIFEST_DIGEST_OVERRIDE='' expect_blocked 'a missing ownership manifest' manifest_absent

# The runner is pinned, not merely read: a lockfile bump blocks.
ruby -rjson -e '
  path = ARGV.fetch(0)
  lock = JSON.parse(File.read(path))
  lock.fetch("packages").fetch("node_modules/playwright")["version"] = "1.63.0"
  File.write(path, JSON.generate(lock))
' "$tmp/source/taurine-desktop/package-lock.json"
git -C "$tmp/source" add taurine-desktop/package-lock.json
GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME='Synthetic admission' GIT_AUTHOR_EMAIL='admission@example.invalid' \
GIT_COMMITTER_NAME='Synthetic admission' GIT_COMMITTER_EMAIL='admission@example.invalid' \
  git -C "$tmp/source" commit -qm 'synthetic lockfile bump'
source_sha="$(git -C "$tmp/source" rev-parse HEAD)"
expect_blocked 'an unreviewed runner version' runner_version_unpinned
git -C "$tmp/source" revert --no-edit HEAD >/dev/null
source_sha="$(git -C "$tmp/source" rev-parse HEAD)"

# A dirty source checkout is not the artifact that was validated.
printf 'stray\n' > "$tmp/source/stray.txt"
expect_blocked 'a dirty source checkout' source_checkout_dirty
rm -f "$tmp/source/stray.txt"

# The identities are checked against git, not taken on the word of the caller.
real_source_sha="$source_sha"
source_sha="$(printf 'a%.0s' {1..40})"
expect_blocked 'a source SHA that is not the checked-out commit' source_sha_mismatch
source_sha="$real_source_sha"

# A project in which every case skipped reconciles perfectly and ran nothing.
echo outcomes > "$tmp/mode"
execution_fixture "$assets/real-execution-outcomes.json" all-skipped
expect_blocked 'a project in which every case was skipped' project_executed_nothing e2e-a11y
: > "$tmp/mode"
execution_fixture "$assets/real-execution-feedback.json"

# The reporter runs inside Playwright on the runner, so its bytes are bound to
# the control commit: a modified copy is refused even though the file exists.
cp "$control/.github/policy/case-evidence-assets/playwright-case-list-reporter.cjs" "$tmp/reporter.keep"
printf '\n// modified after the control commit\n' >> "$control/.github/policy/case-evidence-assets/playwright-case-list-reporter.cjs"
expect_blocked 'a reporter modified after the control commit' reporter_binding_invalid
cp "$tmp/reporter.keep" "$control/.github/policy/case-evidence-assets/playwright-case-list-reporter.cjs"

# The sharded regression concerns are refused rather than quietly passed.
expect_blocked 'a sharded concern' concern_unsupported e2e-regression-1

echo 'Case evidence admission: real 1.62.0 discovery and execution reconcile; identity, pin, manifest and parity disagreements each block with their own class'
