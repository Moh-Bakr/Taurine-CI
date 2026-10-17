# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require 'yaml'
require_relative 'cache-expression'

policy = File.expand_path(__dir__)
main = "github.ref == 'refs/heads/main'"
protected_source = "steps.verified-source.outputs.protected-ancestor == 'true'"
gate = "#{main} && #{protected_source}"

# These expressions are valid Actions syntax. Parentheses/operators in string literals
# must never hide a real OR or create a required conjunct from a function argument.
attacks = [
  "#{main} && '(' || true || ')'",
  "#{protected_source} && #{main} && '(' || true || ')'",
  "#{main} && #{protected_source} && '(' || true || ')'",
  "#{gate} && '(((' || true || ')))'",
  "#{gate} && 'it''s (' || true || ')''s'",
  "#{gate} && contains('(', ')') || true",
  "contains('(#{main.gsub("'", "''")})', 'x') || true",
  "(#{main} || true) && #{protected_source}",
  "!(#{main}) && #{protected_source}",
  "'#{main.gsub("'", "''")}' && #{protected_source}"
]
safe = [
  main,
  gate,
  "contains('é(é)', 'é') && #{gate}",
  "#{gate} && success()",
  "#{gate} && (inputs.concern == 'rust-db' || startsWith(inputs.concern, 'rust-'))",
  "#{gate} && contains(fromJSON('[\"(\",\")\",\"||\"]'), '(')",
  "#{gate} && ('(' == '(' || ')' == ')')",
  "#{gate} && contains('it''s ( && || )', 'it''s')",
  "#{gate} && !cancelled()",
  "#{gate} && needs['plan'].result == 'success'"
]
unsupported = [
  "#{gate} && (true", "#{gate})", "#{gate} && 'unterminated(",
  "#{gate} && true ||", "#{gate} &&", "#{gate} && ()", "#{gate} true",
  "#{gate} && inputs.rust ? true : false", "#{gate} && \"(\"",
  "#{gate} && success(,)", "#{gate} && true # )", "#{gate} && ${{ true }}",
  "#{gate} && 'line\n#{main}\nstring'", "#{gate} && (#{'(' * 70}true#{')' * 70})",
  "#{gate} && '#{'x' * 8192}'"
]

count = 0
(attacks.map { |text| [text, false] } + safe.map { |text| [text, true] } +
 unsupported.map { |text| [text, false] }).each do |text, expected|
  [text, "${{ #{text} }}"].each do |expression|
    terms = CacheExpression.top_terms(expression)
    actual = !terms.nil? && terms.include?(main)
    abort "parser guard mismatch for #{expression.inspect}" unless actual == expected
    _, error, status = Open3.capture3('bash', '-c', 'source "$1"; cond_requires "$2" "$3"',
                                    'fixture', "#{policy}/check-cache-policy.sh", "        if: #{expression}", main)
    abort "shell guard mismatch for #{expression.inspect}: #{error}" unless status.success? == expected
    count += 1
  end
end

# The CLI must reject an oversized input before trimming its if: prefix; reading only
# a valid prefix would otherwise hide an OR beyond the input limit.
prefix = "        if: #{main} && '"
oversized = prefix + ('x' * (8193 - prefix.bytesize - 1)) + "' || true"
_, error, status = Open3.capture3('bash', '-c', 'source "$1"; cond_requires "$2" "$3"',
                                'fixture', "#{policy}/check-cache-policy.sh", oversized, main)
abort "shell accepted a truncated condition: #{error}" if status.success?
count += 1

Dir.mktmpdir('cache-expression-fixtures-') do |dir|
  # Exercise both uses of the Ruby parser: the job write grant and restore Rule N.
  (attacks.map { |text| [text, false] } + safe.map { |text| [text, true] }).each do |text, expected|
    %w[restore write].each do |kind|
      job = { 'runs-on' => 'ubuntu-24.04', 'steps' => [] }
      if kind == 'write'
        job.merge!('cache-mode' => 'write', 'if' => "${{ #{text} }}")
      else
        job['steps'] << { 'if' => "${{ #{text} }}",
                          'uses' => 'actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9' }
      end
      file = File.join(dir, 'fixture.yml')
      File.write(file, { 'on' => 'workflow_dispatch', 'permissions' => {}, 'jobs' => { 'a' => job } }.to_yaml)
      _, error, status = Open3.capture3('ruby', "#{policy}/check-cache-mode.rb", file)
      abort "#{kind} checker mismatch for #{text.inspect}: #{error}" unless status.success? == expected
      unless expected
        message = kind == 'write' ? 'cache-mode write needs the exact top-level term' : 'is not main-only'
        abort "#{kind} refused for the wrong reason: #{error}" unless error.include?(message)
      end
      count += 1
    end
  end

  # The shell checker must reject a complete workflow whose cache conditions were opened
  # by this attack, and still accept its reviewed condition and safe nested alternatives.
  source = File.read('.github/workflows/linux-validation-concern.yml', encoding: 'UTF-8')
  [nil, " && '(' || true || ')'", " && ('(' == '(' || ')' == ')')"].each do |suffix|
    text = suffix ? source.gsub(/(if: \$\{\{ github\.ref == 'refs\/heads\/main'[^\n]*)( \}\})/) { "#{$1}#{suffix}#{$2}" } : source
    abort 'workflow fixture changed nothing' if suffix && text == source
    file = File.join(dir, 'concern.yml')
    File.write(file, text)
    _, error, status = Open3.capture3('bash', '-c', 'source "$1"; check_cache_policy "$2"',
                                    'fixture', "#{policy}/check-cache-policy.sh", file)
    expected = suffix.nil? || suffix.include?("'(' == '('")
    abort "workflow checker mismatch: #{error}" unless status.success? == expected
    abort "workflow refused for wrong reason: #{error}" if !expected && !error.include?('top-level term')
    count += 1
  end
end

puts "cache expression fixtures: #{count} parser/shell/checker checks passed"
