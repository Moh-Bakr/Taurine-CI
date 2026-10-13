#!/usr/bin/env bash
# Synthetic subprocess fixtures only. This never executes Playwright or project JS.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ruby -rjson -rdigest -ropen3 -rrbconfig -rfileutils -rtmpdir -e '
  control = ARGV.fetch(0)
  producer = File.join(control, ".github/policy/playwright-case-evidence-producer.rb")
  producer_source = File.read(producer)
  Object.const_set(:OUTPUT_LIMIT, 8 * 1024 * 1024)
  Object.const_set(:TIMEOUT_SECONDS, 2 * 60 * 60)
  Object.const_set(:MAX_CASES, 250_000)
  Object.const_set(:CONTRACT_RESULT_COUNTS, %w[discovered executed passed failed flaky skipped ignored quarantined env_skipped].sort.freeze)
  Object.const_set(:CONTRACT_ERROR_CLASSES, %w[
    adapter_unsupported arguments_invalid case_collection_empty case_count_limit case_file_invalid invalid_input
    case_file_outside_root case_project_invalid case_status_invalid case_title_invalid collection_incomplete
    command_mismatch discovery_binding_invalid discovery_execution_mismatch duplicate_case_identity
    expected_shape_invalid expected_status_invalid identity_invalid identity_mismatch input_size_limit
    producer_failed producer_version_mismatch project_scope_mismatch report_count_mismatch report_digest_invalid
    report_project_mismatch report_shape_invalid report_status_mismatch reporter_errors_present
    schema_version_unsupported selection_invalid selection_mismatch tier_mismatch tool_version_mismatch
  ].sort.freeze)
  class ProducerError < StandardError; end
  Object.define_method(:reject!) { |code| raise ProducerError, code }
  bounded_methods = producer_source[/def run_bounded.*(?=\ndef checked_file)/m]
  raise "bounded runner method missing" unless bounded_methods
  TOPLEVEL_BINDING.eval(bounded_methods, producer, producer_source.lines.index { |line| line.start_with?("def run_bounded") } + 1)
  clock = Process.method(:clock_gettime)
  started = clock.call(Process::CLOCK_MONOTONIC)
  begin
    run_bounded([RbConfig.ruby, "-e", "Process.spawn(RbConfig.ruby, \"-e\", \"sleep 15\"); exit 0"],
      chdir: Dir.pwd, env: {"PATH" => ENV.fetch("PATH", "/usr/bin:/bin")}, timeout: 0.75)
    raise "bounded runner ignored inherited-pipe deadline"
  rescue ProducerError => error
    raise "wrong bounded runner error" unless error.message == "process_timeout"
  end
  raise "bounded runner exceeded pipe-drain deadline" if clock.call(Process::CLOCK_MONOTONIC) - started > 3

  valid_counts = {"discovered" => 1, "executed" => 1, "passed" => 1, "failed" => 0,
    "flaky" => 0, "skipped" => 0, "ignored" => 0, "quarantined" => 0, "env_skipped" => 0}
  valid_result = {"schema_version" => 1, "status" => "shadow_valid_unverified_producer", "counts" => valid_counts}
  safe_result = validate_contract_result!(0, valid_result)
  raise "validator result was not reconstructed safely" unless safe_result == valid_result && !safe_result.equal?(valid_result)
  blocked_counts = valid_counts.merge("passed" => 0, "failed" => 1)
  blocked_result = {"schema_version" => 1, "status" => "shadow_blocked", "counts" => blocked_counts}
  raise "blocked validator result was rejected" unless validate_contract_result!(1, blocked_result) == blocked_result
  [valid_result.merge("private_title" => "RAW_VALIDATOR_SENTINEL"),
    {"schema_version" => 1, "status" => "shadow_blocked", "error_class" => "reporter_failed", "raw" => "RAW_VALIDATOR_SENTINEL"},
    {"schema_version" => 1, "status" => "shadow_blocked", "error_class" => "UNKNOWN_RAW_SENTINEL"}].each do |bad_result|
    begin
      validate_contract_result!(bad_result["status"] == "shadow_valid_unverified_producer" ? 0 : 1, bad_result)
      raise "validator result with unknown fields or error class was accepted"
    rescue ProducerError => error
      raise "wrong validator result rejection" unless error.message == "validator_failed"
    end
  end
  begin
    validate_contract_result!(0, valid_result.merge("counts" => valid_counts.merge("passed" => -1)))
    raise "invalid validator count was accepted"
  rescue ProducerError => error
    raise "wrong validator count rejection" unless error.message == "validator_failed"
  end

  temp = File.realpath(Dir.mktmpdir("playwright-producer-fixtures-"))
  begin
    source = File.join(temp, "source")
    app = File.join(source, "taurine-desktop")
    mobile = File.join(source, "taurine-mobile")
    FileUtils.mkdir_p([File.join(app, "tests/e2e"), File.join(mobile, "tests/e2e"), File.join(source, "scripts/ci"), File.join(temp, "fake-bin"), File.join(temp, "runtime-tmp")])
    File.write(File.join(source, ".gitignore"), "node_modules/\n")
    File.write(File.join(app, ".gitignore"), "node_modules/\n")
    File.write(File.join(mobile, ".gitignore"), "node_modules/\n")
    File.write(File.join(app, "playwright.config.ts"), "export default {};\n")
    File.write(File.join(mobile, "playwright.config.ts"), "export default {};\n")
    test_file = File.join(app, "tests/e2e/smoke.spec.ts")
    File.write(test_file, "// synthetic fixture only\n")
    mobile_test_file = File.join(mobile, "tests/e2e/smoke.spec.ts")
    File.write(mobile_test_file, "// synthetic fixture only\n")
    locks = {
      "node_modules/@playwright/test" => ["1.62.0", "sha512-9zOJ6ZQRAena31MpOH9VSzIz8Ou3YJ/wtY/eQm5T2uhfhG7/U3COrMS8xOtUrZrp9OgdmzEnIYODye3nY1VqzA=="],
      "node_modules/playwright" => ["1.62.0", "sha512-Z14dG305dgaLu6foB1TXQagFiW8JfSUIUaUuPaKQ6NtBPKF1P/qXcqfh6c6K/icPqdy37JmjbiBXf6JNg6Sylw=="],
      "node_modules/playwright-core" => ["1.62.0", "sha512-nsNRyq0r2zsG8AcRHWknc9QRA5XCueC7gWMrs+Gx2tlZn9hcl8zudfh00lhJPY1DE7NmZ6bDsT9g2yey8mXljA=="]
    }
    lock = {"name" => "taurine-desktop", "lockfileVersion" => 3,
      "packages" => locks.transform_values { |version, integrity| {"version" => version, "integrity" => integrity} }}
    File.write(File.join(app, "package-lock.json"), JSON.generate(lock))
    mobile_locks = {
      "node_modules/@playwright/test" => ["1.62.1", "sha512-DTcUc8qii+cpHvtOwggMtBRMjKZHXYWdw8syRYu2vtzuq4Wxphqq4NfCs5Zt44L6mA8rfDfj+PHnxFc/FeK6mQ=="],
      "node_modules/playwright" => ["1.62.1", "sha512-0M+L3LAD8/nm554LOla9Ayx0j0tmFZ0FBcoQ7F1VuVHpM/XpiC8RcDzBQB8W5+hA8L22THxELzeF+2WcUzvcLg=="],
      "node_modules/playwright-core" => ["1.62.1", "sha512-wPYSwEBJY9GHraISXqyqtx0na0LpO3XEX7jNDhntbex7tzUS7kLnZsOlFruFJB4Hi/rhDMjXGqHewDZ68nYZVw=="]
    }
    mobile_lock = {"name" => "taurine-mobile", "lockfileVersion" => 3,
      "packages" => mobile_locks.transform_values { |version, integrity| {"version" => version, "integrity" => integrity} }}
    File.write(File.join(mobile, "package-lock.json"), JSON.generate(mobile_lock))
    manifest = {"schema_version" => 1, "suites" => {"synthetic" => {"include" => ["synthetic-only"]}}}
    File.write(File.join(source, "scripts/ci/suite-ownership.json"), JSON.generate(manifest))
    git_env = {"GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL,
      "GIT_AUTHOR_NAME" => "Synthetic Fixture", "GIT_AUTHOR_EMAIL" => "fixture@example.invalid",
      "GIT_COMMITTER_NAME" => "Synthetic Fixture", "GIT_COMMITTER_EMAIL" => "fixture@example.invalid"}
    [ ["init", "-q"], ["add", ".gitignore", "taurine-desktop", "taurine-mobile", "scripts/ci/suite-ownership.json"], ["commit", "-qm", "synthetic source"] ].each do |args|
      out, err, status = Open3.capture3(git_env, "git", "-C", source, *args)
      raise "synthetic git fixture failed" unless status.success?
    end
    source_sha = Open3.capture2("git", "-C", source, "rev-parse", "HEAD").first.strip
    control_sha = Open3.capture2("git", "-C", control, "rev-parse", "HEAD").first.strip
    canonical = lambda do |value|
      sort = lambda { |item|
        case item
        when Hash then item.keys.sort.each_with_object({}) { |key, out| out[key] = sort.call(item.fetch(key)) }
        when Array then item.map { |child| sort.call(child) }
        else item
        end
      }
      Digest::SHA256.hexdigest(JSON.generate(sort.call(value), ascii_only: true))
    end
    catalog = JSON.parse(File.read(File.join(control, ".github/ci-matrix.json"))).fetch("suite_catalog")

    {app => "1.62.0", mobile => "1.62.1"}.each do |app_root, version|
      ["@playwright/test", "playwright", "playwright-core"].each do |name|
        directory = File.join(app_root, "node_modules", name)
        FileUtils.mkdir_p(directory)
        File.write(File.join(directory, "package.json"), JSON.generate({"name" => name, "version" => version}))
      end
    end
    [app, mobile].each do |app_root|
      File.write(File.join(app_root, "node_modules/playwright/cli.js"), "// placeholder; the fake node never evaluates this file\n")
    end

    mode_file = File.join(temp, "fake-mode")
    log_file = File.join(temp, "fake-node-log.jsonl")
    fake_node = File.join(temp, "fake-bin/node")
    fake_body = <<~RUBY
      #!/usr/bin/env ruby
      require "json"
      require "fileutils"
      cli, *args = ARGV
      mode = File.read(#{mode_file.dump}).strip
      log = #{log_file.dump}
      File.open(log, "a", 0o600) do |f|
        f.puts(JSON.generate({"args" => args, "secret_inherited" => ENV.key?("SYNTHETIC_CASE_SECRET"),
          "path" => ENV.fetch("PATH"), "home" => ENV.fetch("HOME")}))
      end unless args == ["--version"]
      if args == ["--version"]
        version = JSON.parse(File.read(File.join(File.dirname(cli), "package.json"))).fetch("version")
        puts(mode == "wrong-version" ? "Version 9.9.9" : "Version \#{version}")
        exit 0
      end
      app_root = File.expand_path("../..", File.dirname(cli))
      test_file = File.join(app_root, "tests/e2e/smoke.spec.ts")
      project = args[args.index("--project") + 1]
      if args.include?("--list")
        report_path = ENV.fetch("TAURINE_CASE_EVIDENCE_REPORT_PATH")
        marker_path = ENV.fetch("TAURINE_CASE_EVIDENCE_COMPLETION_PATH")
        private_files = [report_path, marker_path].all? { |p| (File.stat(p).mode & 0o077).zero? }
        report = {"suites" => [{"file" => test_file, "specs" => [{"title" => "suite > forged private title",
          "file" => test_file, "tests" => [{"projectName" => project, "status" => "discovered", "results" => []}]}]}], "errors" => []}
        File.write(report_path, JSON.generate(report))
        status = mode == "reporter-failure" ? "failed" : "complete"
        File.write(marker_path, JSON.generate({"schema_version" => 1, "status" => status,
          "error_class" => (status == "failed" ? "reporter_callback_failed" : nil), "count" => 1}))
        log_private = File.open(log, "a", 0o600) { |f| f.puts(JSON.generate({"private_modes_ok" => private_files})) }
        exit 0
      end
      output = ENV.fetch("PLAYWRIGHT_JSON_OUTPUT_NAME")
      tests = [{"projectName" => project, "status" => "expected", "expectedStatus" => "passed", "results" => [{"status" => "passed"}]}]
      specs = [{"title" => "suite > forged private title", "file" => test_file, "tests" => tests}]
      if mode == "extra-case"
        specs << {"title" => "suite > extra forged case", "file" => test_file,
          "tests" => [{"projectName" => project, "status" => "expected", "expectedStatus" => "passed", "results" => [{"status" => "passed"}]}]}
      end
      report = {"stats" => {"expected" => specs.length, "skipped" => 0, "unexpected" => 0, "flaky" => 0},
        "suites" => [{"file" => test_file, "specs" => specs}]}
      File.write(output, JSON.generate(report))
      File.open(log, "a", 0o600) { |f| f.puts(JSON.generate({"private_modes_ok" => (File.stat(output).mode & 0o077).zero?})) }
      exit 0
    RUBY
    File.write(fake_node, fake_body)
    File.chmod(0o700, fake_node)
    File.write(mode_file, "normal")
    expected_path = File.join(temp, "expected.json")
    desktop_group = catalog.fetch("coverage_requirements").find { |row| row["id"] == "desktop-playwright-feedback-linux" }
    suite_ids = desktop_group.fetch("candidate_suite_ids")
    expected = {"schema_version" => 1, "source_sha" => source_sha, "control_sha" => control_sha,
      "manifest_digest" => canonical.call(manifest), "catalog_digest" => canonical.call(catalog),
      "selection_digest" => Digest::SHA256.hexdigest(JSON.generate(suite_ids.sort)), "selection_mode" => "full",
      "selected_suite_ids" => suite_ids, "runner_id" => "playwright-desktop",
      "config_id" => "desktop-playwright-projects", "tier" => "feedback", "platform" => "linux",
      "project" => "smoke", "tool_version" => "1.62.0", "repo_root" => source}
    File.write(expected_path, JSON.generate(expected), mode: "w", perm: 0o600)
    wrapper_env = {"PATH" => "#{File.dirname(fake_node)}:/usr/bin:/bin", "RUNNER_TEMP" => File.join(temp, "runtime-tmp"),
      "SYNTHETIC_CASE_SECRET" => "SYNTHETIC-SECRET-SENTINEL"}
    invoke = lambda do |*args|
      stdout, stderr, status = Open3.capture3(wrapper_env, RbConfig.ruby, producer, *args, chdir: control)
      raise "producer emitted stderr" unless stderr.empty?
      [stdout, status.exitstatus]
    end
    positive, positive_status = invoke.call(expected_path)
    result = JSON.parse(positive)
    raise "forged evidence was not explicitly unverified: exit=#{positive_status} result=#{result.inspect}" unless positive_status == 0 && result["status"] == "shadow_valid_unverified_producer"
    raise "private identity leaked" if positive.include?("forged private title") || positive.include?("smoke.spec.ts") || positive.match?(/[a-f0-9]{64}/)
    logs = File.readlines(log_file).map { |line| JSON.parse(line) }
    commands = logs.select { |entry| entry.key?("args") }
    raise "runner inherited a secret" unless commands.none? { |entry| entry["secret_inherited"] }
    raise "private output permissions were too broad" unless logs.select { |entry| entry.key?("private_modes_ok") }.all? { |entry| entry["private_modes_ok"] }
    raise "list command was not fixed" unless commands[0]["args"] == ["test", "--config", "playwright.config.ts", "--list", "--project", "smoke", "--reporter", File.join(control, ".github/policy/playwright-case-list-reporter.cjs")]
    raise "execution command was not fixed" unless commands[1]["args"] == ["test", "--config", "playwright.config.ts", "--project", "smoke", "--reporter", "json"]
    raise "producer temp data survived" unless Dir.children(File.join(temp, "runtime-tmp")).empty?

    partial_expected = expected.merge("selected_suite_ids" => [suite_ids.first],
      "selection_digest" => Digest::SHA256.hexdigest(JSON.generate([suite_ids.first])))
    File.write(expected_path, JSON.generate(partial_expected), mode: "w", perm: 0o600)
    partial, partial_status = invoke.call(expected_path)
    raise "partial suite set was called full" unless partial_status == 1 && JSON.parse(partial)["error_class"] == "selection_mismatch"
    File.write(expected_path, JSON.generate(expected), mode: "w", perm: 0o600)

    mobile_suite_ids = ["mobile.playwright.smoke.integration"]
    mobile_expected = expected.merge("source_sha" => source_sha, "selection_digest" => Digest::SHA256.hexdigest(JSON.generate(mobile_suite_ids.sort)),
      "selected_suite_ids" => mobile_suite_ids, "runner_id" => "playwright-mobile", "config_id" => "mobile-playwright-projects",
      "tier" => "smoke", "tool_version" => "1.62.1", "repo_root" => source)
    mobile_expected_path = File.join(temp, "mobile-expected.json")
    File.write(mobile_expected_path, JSON.generate(mobile_expected), mode: "w", perm: 0o600)
    mobile_positive, mobile_status = invoke.call(mobile_expected_path)
    raise "mobile adapter pin failed" unless mobile_status == 0 && JSON.parse(mobile_positive)["status"] == "shadow_valid_unverified_producer"
    mobile_commands = File.readlines(log_file).map { |line| JSON.parse(line) }.select { |entry| entry.key?("args") }.drop(2)
    raise "mobile argv was not fixed" unless mobile_commands[0]["args"] == ["test", "--config", "playwright.config.ts", "--list", "--project", "smoke", "--reporter", File.join(control, ".github/policy/playwright-case-list-reporter.cjs")] &&
      mobile_commands[1]["args"] == ["test", "--config", "playwright.config.ts", "--project", "smoke", "--reporter", "json"]

    bad_args, bad_args_status = invoke.call(expected_path, "--reporter=source-controlled")
    raise "arbitrary arguments were accepted" unless bad_args_status == 1 && JSON.parse(bad_args)["error_class"] == "arguments_invalid"
    File.write(mode_file, "extra-case")
    extra, extra_status = invoke.call(expected_path)
    extra_result = JSON.parse(extra)
    raise "extra execution identity did not block" unless extra_status == 1 && extra_result["error_class"] == "discovery_execution_mismatch"
    raise "extra identity leaked" if extra.include?("extra forged case") || extra.include?("smoke.spec.ts")
    File.write(mode_file, "reporter-failure")
    failed_reporter, failed_reporter_status = invoke.call(expected_path)
    raise "swallowed reporter failure was accepted" unless failed_reporter_status == 1 && JSON.parse(failed_reporter)["error_class"] == "reporter_failed"
    File.write(mode_file, "wrong-version")
    wrong_version, wrong_version_status = invoke.call(expected_path)
    raise "wrong runner version was accepted" unless wrong_version_status == 1 && JSON.parse(wrong_version)["error_class"] == "tool_version_mismatch"

    lock_path = File.join(app, "package-lock.json")
    lock = JSON.parse(File.read(lock_path)); lock["packages"]["node_modules/playwright"]["integrity"] = "sha512-tampered"
    File.write(lock_path, JSON.generate(lock))
    [["add", "taurine-desktop/package-lock.json"], ["commit", "-qm", "tampered synthetic lock pin"]].each do |args|
      _out, _err, status = Open3.capture3(git_env, "git", "-C", source, *args)
      raise "synthetic lock commit failed" unless status.success?
    end
    expected["source_sha"] = Open3.capture2("git", "-C", source, "rev-parse", "HEAD").first.strip
    File.write(expected_path, JSON.generate(expected), mode: "w", perm: 0o600)
    File.write(mode_file, "normal")
    bad_lock, bad_lock_status = invoke.call(expected_path)
    raise "altered source lock was accepted" unless bad_lock_status == 1 && JSON.parse(bad_lock)["error_class"] == "lock_binding_invalid"
    puts "Playwright producer: fixed argv, isolated env, lock binding, private files, reporter failure and parity mismatch fixtures passed"
  ensure
    FileUtils.remove_entry(temp) if File.exist?(temp)
  end
' "${root}"
