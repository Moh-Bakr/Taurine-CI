#!/usr/bin/env ruby
# Static/synthetic-only fixture validator. It never loads Playwright or runs tests.
require 'digest'
require 'json'
require 'pathname'

FIXTURE_DIR = File.expand_path('case-evidence-assets', __dir__).freeze
EXPECTED = JSON.parse(File.binread(File.join(FIXTURE_DIR, 'expected-cases.json'))).freeze
WRAPPER = File.binread(File.join(__dir__, 'playwright-case-evidence-producer.rb'))

def require_fixture(condition, label)
  abort("playwright parity fixture invalid: #{label}") unless condition
end

# Absolute paths in the committed assets are checked structurally by
# check-case-evidence-assets.rb; a literal-string scan belongs nowhere near a
# rule about host strings, because it has to spell them out to work.

require_fixture(EXPECTED.is_a?(Hash) && EXPECTED.keys.sort == %w[
  all_pass callback_failure duplicate_identity outcomes runner_bindings schema_version
].sort, 'schema keys')
require_fixture(EXPECTED['schema_version'] == 1, 'schema version')

expected_runners = {
  'playwright-desktop' => {
    'config_id' => 'desktop-playwright-projects', 'version' => '1.62.0',
    'packages' => {
      'node_modules/@playwright/test' => 'sha512-9zOJ6ZQRAena31MpOH9VSzIz8Ou3YJ/wtY/eQm5T2uhfhG7/U3COrMS8xOtUrZrp9OgdmzEnIYODye3nY1VqzA==',
      'node_modules/playwright' => 'sha512-Z14dG305dgaLu6foB1TXQagFiW8JfSUIUaUuPaKQ6NtBPKF1P/qXcqfh6c6K/icPqdy37JmjbiBXf6JNg6Sylw==',
      'node_modules/playwright-core' => 'sha512-nsNRyq0r2zsG8AcRHWknc9QRA5XCueC7gWMrs+Gx2tlZn9hcl8zudfh00lhJPY1DE7NmZ6bDsT9g2yey8mXljA=='
    }
  },
  'playwright-mobile' => {
    'config_id' => 'mobile-playwright-projects', 'version' => '1.62.1',
    'packages' => {
      'node_modules/@playwright/test' => 'sha512-DTcUc8qii+cpHvtOwggMtBRMjKZHXYWdw8syRYu2vtzuq4Wxphqq4NfCs5Zt44L6mA8rfDfj+PHnxFc/FeK6mQ==',
      'node_modules/playwright' => 'sha512-0M+L3LAD8/nm554LOla9Ayx0j0tmFZ0FBcoQ7F1VuVHpM/XpiC8RcDzBQB8W5+hA8L22THxELzeF+2WcUzvcLg==',
      'node_modules/playwright-core' => 'sha512-wPYSwEBJY9GHraISXqyqtx0na0LpO3XEX7jNDhntbex7tzUS7kLnZsOlFruFJB4Hi/rhDMjXGqHewDZ68nYZVw=='
    }
  }
}.freeze

bindings = EXPECTED.fetch('runner_bindings')
require_fixture(bindings.is_a?(Array) && bindings.length == expected_runners.length, 'runner binding count')
bindings.each do |binding|
  require_fixture(binding.is_a?(Hash) && binding.keys.sort == %w[config_id packages runner_id version].sort, 'runner binding shape')
  expected = expected_runners[binding['runner_id']]
  require_fixture(expected && binding['config_id'] == expected['config_id'] && binding['version'] == expected['version'] &&
    binding['packages'] == expected['packages'], 'runner version/integrity pin')
  binding['packages'].each do |package, integrity|
    require_fixture(WRAPPER.include?("'#{package}' => '#{integrity}'"), 'binding differs from fixed producer adapter')
  end
end
require_fixture(bindings.map { |binding| binding['runner_id'] }.sort == expected_runners.keys.sort, 'runner set')

all_pass = EXPECTED.fetch('all_pass')
require_fixture(all_pass.is_a?(Hash) && all_pass.keys.sort == %w[cases config expected_outcome file platform scopes].sort &&
  all_pass['config'] == 'all-pass.config.cjs' && all_pass['file'] == 'all-pass.spec.cjs' &&
  all_pass['platform'] == 'linux' && all_pass['expected_outcome'] == 'passed', 'all-pass scope')
expected_scopes = [
  ['playwright-desktop', 'desktop-playwright-projects', 'smoke', 'feedback', 'taurine-desktop'],
  ['playwright-desktop', 'desktop-playwright-projects', 'critical', 'feedback', 'taurine-desktop'],
  ['playwright-mobile', 'mobile-playwright-projects', 'smoke', 'smoke', 'taurine-mobile'],
  ['playwright-mobile', 'mobile-playwright-projects', 'critical', 'critical', 'taurine-mobile']
]
require_fixture(all_pass['scopes'].is_a?(Array) && all_pass['scopes'].length == expected_scopes.length, 'all-pass scope count')
all_pass['scopes'].each do |scope|
  require_fixture(scope.is_a?(Hash) && scope.keys.sort == %w[app_file config_id file_suite_title project runner_id tier].sort, 'all-pass scope shape')
  expected = expected_scopes.find { |row| row == [scope['runner_id'], scope['config_id'], scope['project'], scope['tier'], scope['app_file'].to_s.split('/').first] }
  require_fixture(expected && scope['app_file'] == "#{expected[4]}/.case-evidence-fixtures/all-pass.spec.cjs", 'adapter-specific all-pass scope')
  require_fixture(scope['file_suite_title'] == File.basename(scope['app_file']) && scope['file_suite_title'] != scope['app_file'],
    'file suite title/path distinction')
end
require_fixture(all_pass['scopes'].map { |scope| [scope['runner_id'], scope['project']] }.sort ==
  expected_scopes.map { |row| row.first(1) + [row[2]] }.sort, 'all-pass project registry')
require_fixture(all_pass['cases'].is_a?(Array) && all_pass['cases'].length == 3, 'all-pass case count')
all_pass_source = File.binread(File.join(FIXTURE_DIR, all_pass['file']))
all_pass_source = all_pass_source.force_encoding(Encoding::UTF_8)
all_pass['cases'].each do |entry|
  require_fixture(entry.is_a?(Hash) && entry.keys.sort == %w[describe title].sort &&
    entry['describe'].is_a?(Array) && entry['describe'].length == 2 && entry['title'].is_a?(String), 'all-pass case shape')
  entry['describe'].each { |title| require_fixture(all_pass_source.include?(title), 'nested describe fixture') }
  require_fixture(all_pass_source.include?(entry['title']) || entry['title'].start_with?('parameterized value '), 'all-pass title fixture')
end
require_fixture(all_pass_source.include?("['alpha', 'beta']") && all_pass_source.include?('shared title across projects'),
  'parameterized and cross-project source')
all_pass_projects = %w[smoke critical]
identity_rows = []
bindings.each do |binding|
  all_pass_projects.each do |project|
    tier = binding['runner_id'] == 'playwright-mobile' ? project : 'feedback'
    all_pass['cases'].each do |entry|
      title = (entry.fetch('describe') + [entry.fetch('title')]).join(' > ')
      app = binding.fetch('runner_id') == 'playwright-desktop' ? 'taurine-desktop' : 'taurine-mobile'
      relative_file = "#{app}/.case-evidence-fixtures/#{all_pass.fetch('file')}"
      identity_rows << Digest::SHA256.hexdigest(JSON.generate([
        binding.fetch('runner_id'), binding.fetch('config_id'), tier, all_pass.fetch('platform'), project,
        relative_file, '', '', title
      ]))
    end
  end
end
require_fixture(identity_rows.uniq.length == identity_rows.length, 'cross-project all-pass identity')

duplicate = EXPECTED.fetch('duplicate_identity')
require_fixture(duplicate.is_a?(Hash) && duplicate.keys.sort == %w[config expected_disposition expected_normalized_title expected_phase file paths project].sort &&
  duplicate['config'] == 'duplicate-identity.config.cjs' && duplicate['file'] == 'duplicate-identity.spec.cjs' &&
  duplicate['project'] == 'smoke' && duplicate['expected_disposition'] == 'duplicate_case_identity' &&
  duplicate['expected_phase'] == 'control_identity_normalization' && duplicate['paths'].is_a?(Array) && duplicate['paths'].length == 2,
  'duplicate fixture scope')
duplicate_source = File.binread(File.join(FIXTURE_DIR, duplicate.fetch('file')))
normalized_titles = duplicate['paths'].map do |path|
  require_fixture(path.is_a?(Hash) && path.keys.sort == %w[describe title].sort && path['describe'].is_a?(Array), 'duplicate path shape')
  require_fixture(path['describe'].all? { |part| !part.empty? } && !path['title'].empty?, 'nonempty path parts')
  (path['describe'] + [path['title']]).join(' > ')
end
require_fixture(normalized_titles.uniq.length == 1 && normalized_titles.first == duplicate['expected_normalized_title'],
  'joined title collision')
require_fixture(duplicate_source.include?("test('part > leaf'") && duplicate_source.include?("test('leaf'") &&
  duplicate_source.include?("test.describe('duplicate group > part'"), 'duplicate fixture source')
bindings.each do |binding|
  tier = binding.fetch('runner_id') == 'playwright-desktop' ? 'feedback' : 'smoke'
  app = binding.fetch('runner_id') == 'playwright-desktop' ? 'taurine-desktop' : 'taurine-mobile'
  title = normalized_titles.first
  identity = [binding.fetch('runner_id'), binding.fetch('config_id'), tier, 'linux', duplicate.fetch('project'),
    "#{app}/.case-evidence-fixtures/#{duplicate.fetch('file')}", '', '', title]
  ids = normalized_titles.map { |normalized| Digest::SHA256.hexdigest(JSON.generate(identity[0, 8] + [normalized])) }
  require_fixture(ids.uniq.length == 1 && ids.length == 2, 'duplicate normalized identity collision')
end

outcomes = EXPECTED.fetch('outcomes')
require_fixture(outcomes.is_a?(Array) && outcomes.length == 2, 'outcome fixture scope count')
expected_outcomes = {
  'expected failure' => ['failed', ['failed'], 'expected', 'passed', 0, 'outcomes.spec.cjs'],
  'unexpected pass' => ['failed', ['passed'], 'unexpected', 'blocked', 0, 'outcomes.spec.cjs'],
  'intentional skip' => ['skipped', [], 'skipped', 'blocked', 0, 'outcomes.spec.cjs'],
  'flaky retry' => ['passed', %w[failed passed], 'flaky', 'blocked', 1, 'flaky.spec.cjs']
}
seen_outcome_titles = []
outcomes.each do |outcome_group|
  require_fixture(outcome_group.is_a?(Hash) && outcome_group.keys.sort == %w[cases config file project retries].sort &&
    outcome_group['project'] == 'smoke' && outcome_group['config'] == (outcome_group['file'] == 'flaky.spec.cjs' ? 'flaky.config.cjs' : 'outcomes.config.cjs'),
    'outcome group shape')
  outcome_source = File.binread(File.join(FIXTURE_DIR, outcome_group.fetch('file')))
  require_fixture(outcome_group['cases'].is_a?(Array), 'outcome cases')
  outcome_group['cases'].each do |entry|
    require_fixture(entry.is_a?(Hash) && entry.keys.sort == %w[aggregate attempts describe disposition expected_status title].sort,
      'outcome case shape')
    expected = expected_outcomes[entry['title']]
    require_fixture(expected == [entry['expected_status'], entry['attempts'], entry['aggregate'], entry['disposition'], outcome_group['retries'], outcome_group['file']],
      'outcome expectation/retry policy')
    require_fixture(outcome_source.include?(entry['title']), 'outcome source title')
    seen_outcome_titles << entry['title']
  end
end
outcome_source = File.binread(File.join(FIXTURE_DIR, 'outcomes.spec.cjs'))
flaky_source = File.binread(File.join(FIXTURE_DIR, 'flaky.spec.cjs'))
require_fixture(seen_outcome_titles.sort == expected_outcomes.keys.sort && outcome_source.include?('test.fail();') &&
  outcome_source.include?("test.skip('intentional skip'") && flaky_source.include?('testInfo.retry === 0') &&
  File.binread(File.join(FIXTURE_DIR, 'outcomes.config.cjs')).include?('retries: 0') &&
  File.binread(File.join(FIXTURE_DIR, 'flaky.config.cjs')).include?('retries: 1'), 'outcome source retry behavior')

callback = EXPECTED.fetch('callback_failure')
callback_source = File.binread(File.join(FIXTURE_DIR, callback.fetch('reporter')))
require_fixture(callback.keys.sort == %w[callback expected_completion_marker expected_disposition reporter].sort &&
  callback['callback'] == 'onBegin' && callback['expected_completion_marker'] == 'absent' &&
  callback['expected_disposition'] == 'blocked' && callback_source.include?('onBegin()') &&
  callback_source.include?('SYNTHETIC_REPORTER_CALLBACK_FAILURE'), 'callback failure fixture')

puts 'Playwright parity fixtures: static schema, exact runner pins, identities, outcomes, and callback-failure fixtures passed'
