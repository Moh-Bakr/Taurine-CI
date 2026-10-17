# frozen_string_literal: true

require 'json'
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
  "#{gate} && needs['plan'].result == 'success'",
  "#{gate} && fromJSON('[1,2]')[0] == 1",
  "#{gate} && format('{0}', join(needs.plan.outputs, ',')) != ''",
  "#{gate} && toJSON(github) != '' && endsWith(inputs.concern, '-db')",
  "#{gate} && hashFiles('Cargo.lock', '**/Cargo.toml') != ''",
  "#{gate} && true && false == false && null == null",
  "#{gate} && ALWAYS() && !FAILURE() && sUcCeSs() && CoNtAiNs('x', 'x')",
  "#{gate} && GITHUB.ref == 'refs/heads/main' && InPuTs.concern == 'rust-db'",
  "#{gate} && inputs.TRUE == inputs['true'] && inputs.False == inputs['false'] && inputs.nUlL == inputs['null']",
  "#{gate} && inputs['true'] == 'yes' && needs['plan']['result'] == 'success'",
  "#{gate} && ('}}' == '}}')"
]
unsupported = [
  "#{gate} && (true", "#{gate})", "#{gate} && 'unterminated(",
  "#{gate} && true ||", "#{gate} &&", "#{gate} && ()", "#{gate} true",
  "#{gate} && inputs.rust ? true : false", "#{gate} && \"(\"",
  "#{gate} && success(,)", "#{gate} && true # )", "#{gate} && ${{ true }}",
  "#{gate} && 'line\n#{main}\nstring'", "#{gate} && (#{'(' * 70}true#{')' * 70})",
  "#{gate} && '#{'x' * 8192}'",
  # Nonlowercase spellings are named values, not literals; none is a known context.
  *%w[TRUE True tRuE FALSE False fAlSe NULL Null nUlL].map { |name| "#{gate} && #{name} == #{name.downcase}" },
  "#{gate} && contains('x', TRUE)", "#{gate} && needs[False].result", "#{gate} && !nUlL",
  *%w[true.ref false.ref null.ref TRUE.ref 42.ref 0xff.ref 'x'.ref true[0] null['ref'] 'x'[0]
      success(true) always(1) failure(false) cancelled(null) contains() contains('x')
      contains('x','y','z') startsWith('x') endsWith() fromJSON() fromJSON('1','2')
      toJSON() toJSON(1,2) join() join('a','b','c') format() hashFiles() unknown()
      github() inputs.foo() (success)() true() contains success bogus.ref
      needs..plan needs.[0] needs[] needs[0,1] inputs.0 needs['x'](1)
      needs[inputs.foo,1] (true)(1) success()() true[0].ref].map { |suffix| "#{gate} && #{suffix}" },
  "#{gate} && format(#{(["'x'"] * 256).join(',')})",
  "#{gate} && hashFiles(#{(["'x'"] * 256).join(',')})",
  # Valid Actions forms intentionally outside this bounded subset (documented compatibility).
  "#{gate} && inputs.true", "#{gate} && inputs.false", "#{gate} && inputs.null",
  "#{gate} && needs[*].result", "#{gate} && needs.*.result",
  "#{gate} && case(true, 'a', 'b')"
]

# These are scalar values, not raw YAML: double-quoted YAML preserves every byte,
# including padding that TemplateReader would turn into a literal segment.
cases = (attacks.map { |text| [text, false] } + safe.map { |text| [text, true] } +
         unsupported.map { |text| [text, false] }).flat_map do |text, expected|
  [[text, expected], ["${{ #{text} }}", expected]]
end
cases.concat([
  ["#{gate} && '${{ true }}'", false],
  ["${{ true }} && #{gate}", false],
  ["#{gate} && ${{ true }}", false],
  ["${{ #{main} }} && ${{ #{protected_source} }}", false],
  ["${{ #{gate} }}literal", false],
  ["literal${{ #{gate} }}", false],
  ["${{ #{gate} && '${{ true }}' }}", false],
  ["${{ #{gate} }}${{ true }}", false],
  ["${{ #{gate} }} trailing }}", false],
  [" ${{ #{main} }} ", false],
  [" ${{ #{gate} }}", false],
  ["${{ #{gate} }} ", false],
  ["\t${{ #{gate} }}\t", false],
  ["${{\t#{gate}\t}}", true],
  [" \t#{gate}\t ", true]
])

count = 0
cases.each do |expression, expected|
  terms = CacheExpression.top_terms(expression)
  actual = !terms.nil? && terms.include?(main)
  abort "parser guard mismatch for #{expression.inspect}" unless actual == expected
  # Check each guard independently in the shell adapter, as well as main-only Rule N.
  [main, protected_source].each do |term|
    _, error, status = Open3.capture3('bash', '-c', 'source "$1"; cond_requires "$2" "$3"',
                                    'fixture', "#{policy}/check-cache-policy.sh",
                                    "        if: #{expression.to_json}", term)
    want = !terms.nil? && terms.include?(term)
    abort "shell guard mismatch for #{expression.inspect}: #{error}" unless status.success? == want
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
  cases.each do |text, expected|
    %w[restore write].each do |kind|
      job = { 'runs-on' => 'ubuntu-24.04', 'steps' => [] }
      if kind == 'write'
        job.merge!('cache-mode' => 'write', 'if' => text)
      else
        job['steps'] << { 'if' => text,
                          'uses' => 'actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9' }
      end
      file = File.join(dir, 'fixture.yml')
      File.write(file, { 'on' => 'workflow_dispatch', 'permissions' => {}, 'jobs' => { 'a' => job } }.to_yaml)
      _, error, status = Open3.capture3('ruby', "#{policy}/check-cache-mode.rb", file)
      abort "#{kind} checker mismatch for #{text.inspect}: #{error}" unless status.success? == expected
      unless expected
        message = if kind == 'write'
                    'cache-mode write needs the exact top-level term'
                  elsif text.match?(/[\r\n]/)
                    'has a block-scalar or multiline if'
                  else
                    'is not main-only'
                  end
        abort "#{kind} refused for the wrong reason: #{error}" unless error.include?(message)
      end
      count += 1
    end
  end

  # The shell checker must reject a complete workflow whose cache conditions were opened
  # by this attack, and still accept its reviewed condition and safe nested alternatives.
  source = File.read('.github/workflows/linux-validation-concern.yml', encoding: 'UTF-8')
  [nil, " && '(' || true || ')'", " && ('(' == '(' || ')' == ')')",
   " && true.ref", " && success(true)", " && contains()",
   " && TRUE == true", " && fAlSe == false", " && Null == null"].each do |suffix|
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

  template_mutations = [
    ->(value) { " #{value} " },
    ->(value) { value.delete_prefix('${{ ').delete_suffix(' }}') + " && '${{ true }}'" }
  ]
  template_mutations.each do |mutate|
    changed = source.gsub(/^(\s*if:) (\$\{\{ github\.ref == 'refs\/heads\/main'[^\n]* \}\})$/) do
      "#{$1} #{mutate.call($2).to_json}"
    end
    abort 'template workflow fixture changed nothing' if changed == source
    file = File.join(dir, 'template.yml')
    File.write(file, changed)
    _, error, status = Open3.capture3('bash', '-c', 'source "$1"; check_cache_policy "$2"',
                                    'fixture', "#{policy}/check-cache-policy.sh", file)
    abort "workflow template accepted: #{error}" if status.success?
    abort "workflow template refused for wrong reason: #{error}" unless error.include?('top-level term')
    count += 1
  end

  # Replay every deployed condition which contains the reviewed exact main term through
  # both adapters. This is compatibility evidence for current guards, not full conformance.
  deployed = []
  walk = lambda do |node|
    case node
    when Hash
      deployed << node['if'] if node['if'].is_a?(String) && node['if'].include?(main)
      node.each_value { |value| walk.call(value) }
    when Array then node.each { |value| walk.call(value) }
    end
  end
  Dir.glob('.github/{workflows,actions}/**/*.yml').each do |file|
    walk.call(YAML.safe_load(File.read(file), aliases: false))
  end
  deployed.uniq.each do |condition|
    terms = CacheExpression.top_terms(condition)
    abort "deployed condition refused: #{condition.inspect}" if terms.nil?
    next unless terms.include?(main) # Dispatch eligibility may group main OR untrusted.
    _, error, status = Open3.capture3('bash', '-c', 'source "$1"; cond_requires "$2" "$3"',
                                    'fixture', "#{policy}/check-cache-policy.sh",
                                    "        if: #{condition.to_json}", main)
    abort "deployed shell main guard refused: #{error}" unless status.success?
    count += 1
  end
  abort 'no deployed main guards tested' if deployed.empty?

end

puts "cache expression fixtures: #{count} parser/shell/checker checks passed"
