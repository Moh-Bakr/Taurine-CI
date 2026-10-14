#!/usr/bin/env bash
# Synthetic source/control repositories and a fake runner only; no app code or Playwright runs.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/playwright-pinned-parity-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/control/.github/policy/fixtures/playwright-case-parity" "$tmp/source" "$tmp/fake-bin"
cp "$root/.github/policy/playwright-pinned-parity-producer.rb" "$tmp/control/.github/policy/"
cp "$root/.github/policy/playwright-case-list-reporter.cjs" "$tmp/control/.github/policy/"
cp "$root/.github/policy/fixtures/playwright-case-parity/"* "$tmp/control/.github/policy/fixtures/playwright-case-parity/"

ruby -rjson -rfileutils -rrbconfig -e '
  control, source, fakebin = ARGV
  expected_path = File.join(control, ".github/policy/fixtures/playwright-case-parity/expected-cases.json")
  expected = JSON.parse(File.read(expected_path))
  expected.fetch("runner_bindings").each do |binding|
    app = binding.fetch("runner_id") == "playwright-desktop" ? "taurine-desktop" : "taurine-mobile"
    app_root = File.join(source, app)
    FileUtils.mkdir_p(File.join(app_root, "node_modules/playwright"))
    FileUtils.mkdir_p(File.join(app_root, "node_modules/@playwright/test"))
    FileUtils.mkdir_p(File.join(app_root, "node_modules/playwright-core"))
    File.write(File.join(app_root, ".gitignore"), "node_modules/\n")
    packages = {}
    binding.fetch("packages").each do |name, integrity|
      packages[name] = {"version" => binding.fetch("version"), "integrity" => integrity}
      package_dir = File.join(app_root, name)
      FileUtils.mkdir_p(package_dir)
      File.write(File.join(package_dir, "package.json"), JSON.generate({"version" => binding.fetch("version")}))
    end
    File.write(File.join(app_root, "package-lock.json"), JSON.generate({"packages" => packages}))
    File.write(File.join(app_root, "node_modules/playwright/cli.js"), "// synthetic CLI placeholder\n")
  end
  File.write(File.join(source, ".gitignore"), "node_modules/\n")
  FileUtils.mkdir_p(fakebin)
  File.write(File.join(fakebin, "node"), <<~RUBY)
    #!#{RbConfig.ruby}
    require "json"
    cli, *args = ARGV
    if args == ["--version"]
      puts(cli.include?("taurine-desktop") ? "Version 1.62.0" : "Version 1.62.1")
      exit 0
    end
    abort "fixed fake runner invocation missing" unless args.first == "test"
    config = args[args.index("--config") + 1]
    project = args[args.index("--project") + 1]
    list = args.include?("--list")
    names = case File.basename(config)
      when "all-pass.config.cjs"
        [["outer group", "inner group", "parameterized value alpha"],
         ["outer group", "inner group", "parameterized value beta"],
         ["outer group", "inner group", "shared title across projects"]]
      when "duplicate-identity.config.cjs"
        [["duplicate group", "part > leaf"], ["duplicate group > part", "leaf"]]
      when "outcomes.config.cjs"
        [["outcome group", "expected failure"], ["outcome group", "unexpected pass"], ["outcome group", "intentional skip"]]
      when "flaky.config.cjs"
        [["flaky group", "flaky retry"]]
      else
        abort "unknown fixed config"
      end
    fixture = File.basename(config).sub(/\\.config\\.cjs\\z/, ".spec.cjs")
    fixture_path = File.join(File.dirname(config), fixture)
    if list
      reporter = args[args.index("--reporter") + 1]
      if reporter.include?("callback-failure-reporter")
        File.write(ENV.fetch("TAURINE_PARITY_CALLBACK_SENTINEL"), "synthetic-onBegin-failure-v1")
        exit 1
      end
      specs = names.map do |parts|
        {"title" => parts.join(" > "), "file" => fixture_path,
         "tests" => [{"projectName" => project, "status" => "discovered", "results" => []}]}
      end
      File.write(ENV.fetch("TAURINE_CASE_EVIDENCE_REPORT_PATH"), JSON.generate({"errors" => [], "suites" => [{"file" => fixture_path, "specs" => specs}]}))
      File.write(ENV.fetch("TAURINE_CASE_EVIDENCE_COMPLETION_PATH"), JSON.generate({"schema_version" => 1, "status" => "complete", "error_class" => nil, "count" => names.length}))
      exit 0
    end
    records = case File.basename(config)
      when "all-pass.config.cjs"
        names.map { |parts| {"parts" => parts, "status" => "expected", "expectedStatus" => "passed", "attempts" => ["passed"]} }
      when "outcomes.config.cjs"
        [ {"parts" => names[0], "status" => "expected", "expectedStatus" => "failed", "attempts" => ["failed"]},
          {"parts" => names[1], "status" => "unexpected", "expectedStatus" => "failed", "attempts" => ["passed"]},
          {"parts" => names[2], "status" => "skipped", "expectedStatus" => "skipped", "attempts" => []} ]
      when "flaky.config.cjs"
        [{"parts" => names[0], "status" => "flaky", "expectedStatus" => "passed", "attempts" => ["failed", "passed"]}]
    end
    if File.basename(config) == "outcomes.config.cjs"
      case ENV["TAURINE_PARITY_TEST_OUTCOME_MUTATION"]
      when "extra"
        records << {"parts" => ["outcome group", "unlisted extra"], "status" => "expected", "expectedStatus" => "passed", "attempts" => ["passed"]}
      when "duplicate"
        records << Marshal.load(Marshal.dump(records.first))
      when "missing"
        records.pop
      end
    end
    root_suite = {"title" => fixture, "file" => fixture_path, "specs" => [], "suites" => []}
    records.each do |record|
      current = root_suite
      record.fetch("parts")[0...-1].each do |part|
        child = current["suites"].find { |entry| entry["title"] == part }
        unless child
          child = {"title" => part, "file" => fixture_path, "specs" => [], "suites" => []}
          current["suites"] << child
        end
        current = child
      end
      current["specs"] << {"title" => record.fetch("parts").last, "file" => fixture_path,
        "tests" => [{"projectName" => project, "status" => record.fetch("status"),
          "expectedStatus" => record.fetch("expectedStatus"),
          "results" => record.fetch("attempts").map { |status| {"status" => status} }}]}
    end
    stats = records.map { |record| record.fetch("status") }.map do |status|
      status == "expected" ? "expected" : (status == "unexpected" ? "unexpected" : status)
    end.tally
    report = {"errors" => [], "stats" => %w[expected skipped unexpected flaky].to_h { |key| [key, stats.fetch(key, 0)] },
      "suites" => [root_suite]}
    File.write(ENV.fetch("PLAYWRIGHT_JSON_OUTPUT_NAME"), JSON.generate(report))
    exit(File.basename(config) == "outcomes.config.cjs" ? 1 : 0)
  RUBY
  File.chmod(0o700, File.join(fakebin, "node"))
  git_env = {"GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL,
    "GIT_AUTHOR_NAME" => "Synthetic parity", "GIT_AUTHOR_EMAIL" => "parity@example.invalid",
    "GIT_COMMITTER_NAME" => "Synthetic parity", "GIT_COMMITTER_EMAIL" => "parity@example.invalid"}
  [["-C", control, "init", "-q"], ["-C", control, "add", "."], ["-C", control, "commit", "-qm", "fixed synthetic control"]].each do |args|
    system(git_env, "git", *args, out: File::NULL, err: File::NULL) || abort("synthetic control setup failed")
  end
  [["-C", source, "init", "-q"], ["-C", source, "add", "."], ["-C", source, "commit", "-qm", "fixed synthetic source"]].each do |args|
    system(git_env, "git", *args, out: File::NULL, err: File::NULL) || abort("synthetic source setup failed")
  end
' "$tmp/control" "$tmp/source" "$tmp/fake-bin"

producer_status=0
control_sha="$(git -C "$tmp/control" rev-parse HEAD)"
source_sha="$(git -C "$tmp/source" rev-parse HEAD)"
run_producer() {
  env TAURINE_PARITY_EXPECTED_CONTROL_SHA="$control_sha" TAURINE_PARITY_EXPECTED_SOURCE_SHA="$source_sha" \
    PATH="$tmp/fake-bin:$PATH" "$@"
}
run_producer ruby "$tmp/control/.github/policy/playwright-pinned-parity-producer.rb" "$tmp/source" >"$tmp/result.json" || producer_status=$?
cat "$tmp/result.json"
[[ "$producer_status" -eq 0 ]] || { echo 'synthetic parity producer returned blocked status' >&2; exit 1; }
ruby -rjson -ropen3 -e '
  result = JSON.parse(File.read(ARGV.fetch(0)))
  expected = {"schema_version" => 1, "status" => "shadow_fixture_parity_unverified",
    "positive" => {"scopes" => 4, "cases" => 12},
    "negative" => {"checks" => 6, "expected" => 1, "blocked" => 5}}
  abort "synthetic harness summary mismatch" unless result == expected
' "$tmp/result.json"

ruby -rjson -ropen3 -e '
  source = File.read(ARGV.fetch(0))
  block = source[/def run_bounded.*(?=\ndef git_tool)/m]
  abort "bounded method missing" unless block
  Object.const_set(:OUTPUT_LIMIT, 1024 * 1024)
  Object.const_set(:PROCESS_TIMEOUT, 120)
  class ParityError < StandardError; end
  Object.define_method(:reject!) { |code| raise ParityError, code }
  TOPLEVEL_BINDING.eval(block, ARGV.fetch(0), source.lines.index { |line| line.start_with?("def run_bounded") } + 1)
  ruby = RbConfig.ruby
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  begin
    run_bounded([ruby, "-e", "Process.spawn(#{ruby.dump}, \"-e\", \"sleep 15\"); exit 0"],
      chdir: Dir.pwd, env: {"PATH" => "/usr/bin:/bin"}, timeout: 0.5)
    abort "pipe-drain descendant escaped deadline"
  rescue ParityError => error
    abort "wrong pipe-drain error" unless error.message == "process_timeout"
  end
  abort "pipe-drain deadline exceeded" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 3
  begin
    run_bounded([ruby, "-e", "STDOUT.write(\"x\" * 1200000)"], chdir: Dir.pwd,
      env: {"PATH" => "/usr/bin:/bin"}, timeout: 5)
    abort "output cap was ignored"
  rescue ParityError => error
    abort "wrong output-limit error" unless error.message == "process_output_limit"
  end
' "$root/.github/policy/playwright-pinned-parity-producer.rb"

blocked() {
  expected="$1"
  shift
  output_file="$tmp/blocked.json"
  status=0
  env TAURINE_PARITY_EXPECTED_CONTROL_SHA="$control_sha" TAURINE_PARITY_EXPECTED_SOURCE_SHA="$source_sha" "$@" >"$output_file" || status=$?
  [[ "$status" -eq 1 ]] || { echo "expected fixed blocked result: $expected" >&2; exit 1; }
  ruby -rjson -e '
    result = JSON.parse(File.read(ARGV.fetch(0)))
    abort "unexpected fixed error" unless result["status"] == "shadow_fixture_parity_blocked" && result["error_class"] == ARGV.fetch(1)
  ' "$output_file" "$expected"
}

blocked arguments_invalid ruby "$tmp/control/.github/policy/playwright-pinned-parity-producer.rb" "$tmp/source" extra

mkdir -p "$tmp/tampered-bin"
ruby -e '
  source = File.read(ARGV.fetch(0))
  changed = source.sub("shared title across projects", "RAW_PRIVATE_SENTINEL")
  abort "fake runner mutation fixture not found" if changed == source
  File.write(ARGV.fetch(1), changed)
  File.chmod(0o700, ARGV.fetch(1))
' "$tmp/fake-bin/node" "$tmp/tampered-bin/node"
tampered_output="$tmp/tampered-result.json"
tampered_status=0
env TAURINE_PARITY_EXPECTED_CONTROL_SHA="$control_sha" TAURINE_PARITY_EXPECTED_SOURCE_SHA="$source_sha" \
  PATH="$tmp/tampered-bin:$PATH" ruby "$tmp/control/.github/policy/playwright-pinned-parity-producer.rb" "$tmp/source" >"$tampered_output" || tampered_status=$?
[[ "$tampered_status" -eq 1 ]] || { echo 'tampered synthetic report was accepted' >&2; exit 1; }
! rg -q 'RAW_PRIVATE_SENTINEL|/playwright-pinned-parity-test\.' "$tampered_output" || {
  echo 'synthetic private report detail escaped the producer output' >&2
  exit 1
}

ruby -rjson -e '
  path = ARGV.fetch(0)
  lock = JSON.parse(File.read(path))
  lock.fetch("packages").fetch("node_modules/playwright")["integrity"] = "sha512-synthetic-tamper"
  File.write(path, JSON.generate(lock))
' "$tmp/source/taurine-desktop/package-lock.json"
git -C "$tmp/source" add taurine-desktop/package-lock.json
GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME='Synthetic parity' GIT_AUTHOR_EMAIL='parity@example.invalid' \
GIT_COMMITTER_NAME='Synthetic parity' GIT_COMMITTER_EMAIL='parity@example.invalid' \
  git -C "$tmp/source" commit -qm 'synthetic wrong package integrity'
source_sha="$(git -C "$tmp/source" rev-parse HEAD)"
blocked lock_binding_invalid env PATH="$tmp/fake-bin:$PATH" ruby "$tmp/control/.github/policy/playwright-pinned-parity-producer.rb" "$tmp/source"
git -C "$tmp/source" checkout -q HEAD^ -- taurine-desktop/package-lock.json
git -C "$tmp/source" add taurine-desktop/package-lock.json
GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME='Synthetic parity' GIT_AUTHOR_EMAIL='parity@example.invalid' \
GIT_COMMITTER_NAME='Synthetic parity' GIT_COMMITTER_EMAIL='parity@example.invalid' \
  git -C "$tmp/source" commit -qm 'restore synthetic valid package integrity'
source_sha="$(git -C "$tmp/source" rev-parse HEAD)"

cp "$tmp/fake-bin/node" "$tmp/fake-bin/node.baseline"
for mutation in extra duplicate missing; do
  ruby -e 'path, mutation = ARGV; source = File.read(path); needle = %q{case ENV["TAURINE_PARITY_TEST_OUTCOME_MUTATION"]}; abort "mutation seam missing" unless source.include?(needle); File.write(path, source.sub(needle, "case #{mutation.dump}")); File.chmod(0700, path)' "$tmp/fake-bin/node" "$mutation"
  status=0
  output_file="$tmp/outcome-$mutation.json"
  env TAURINE_PARITY_EXPECTED_CONTROL_SHA="$control_sha" TAURINE_PARITY_EXPECTED_SOURCE_SHA="$source_sha" PATH="$tmp/fake-bin:$PATH" \
    ruby "$tmp/control/.github/policy/playwright-pinned-parity-producer.rb" "$tmp/source" >"$output_file" || status=$?
  [[ "$status" -eq 1 ]] || { echo "outcome mutation was accepted: $mutation" >&2; exit 1; }
  ruby -rjson -e 'result=JSON.parse(File.read(ARGV.fetch(0))); abort "wrong outcome mutation disposition: #{result.inspect}" unless result["status"] == "shadow_fixture_parity_blocked" && %w[fixture_outcome_mismatch report_shape_invalid].include?(result["error_class"])' "$output_file"
  cp "$tmp/fake-bin/node.baseline" "$tmp/fake-bin/node"
done

printf '#!/bin/sh\nprintf called > %q\nexec %q "$@"\n' "$tmp/runner-was-called" "$(command -v ruby)" >"$tmp/tampered-bin/node"
chmod 700 "$tmp/tampered-bin/node"
status=0
env TAURINE_PARITY_EXPECTED_CONTROL_SHA="0000000000000000000000000000000000000000" TAURINE_PARITY_EXPECTED_SOURCE_SHA="$source_sha" \
  PATH="$tmp/tampered-bin:$PATH" ruby "$tmp/control/.github/policy/playwright-pinned-parity-producer.rb" "$tmp/source" >"$tmp/control-sha-mismatch.json" || status=$?
[[ "$status" -eq 1 && ! -e "$tmp/runner-was-called" ]] || { echo 'control SHA mismatch reached a child process' >&2; exit 1; }
ruby -rjson -e 'result=JSON.parse(File.read(ARGV.fetch(0))); abort "wrong control SHA disposition" unless result["error_class"] == "control_sha_mismatch"' "$tmp/control-sha-mismatch.json"
status=0
env TAURINE_PARITY_EXPECTED_CONTROL_SHA="$control_sha" TAURINE_PARITY_EXPECTED_SOURCE_SHA="0000000000000000000000000000000000000000" \
  PATH="$tmp/tampered-bin:$PATH" ruby "$tmp/control/.github/policy/playwright-pinned-parity-producer.rb" "$tmp/source" >"$tmp/source-sha-mismatch.json" || status=$?
[[ "$status" -eq 1 && ! -e "$tmp/runner-was-called" ]] || { echo 'source SHA mismatch reached a child process' >&2; exit 1; }
ruby -rjson -e 'result=JSON.parse(File.read(ARGV.fetch(0))); abort "wrong source SHA disposition" unless result["error_class"] == "source_sha_mismatch"' "$tmp/source-sha-mismatch.json"

echo 'Pinned Playwright parity producer: synthetic fixtures and bounded-child tests passed'
