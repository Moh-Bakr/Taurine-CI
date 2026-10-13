#!/usr/bin/env ruby
# Static/synthetic-only fixture validator. It never loads Playwright or runs tests.
require 'digest'
require 'json'
require 'pathname'

FIXTURE_DIR = File.expand_path('fixtures/playwright-case-parity', __dir__).freeze
EXPECTED = JSON.parse(File.binread(File.join(FIXTURE_DIR, 'expected-cases.json'))).freeze
WRAPPER = File.binread(File.join(__dir__, 'playwright-case-evidence-producer.rb'))

def require_fixture(condition, label)
  abort("playwright parity fixture invalid: #{label}") unless condition
end

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
require_fixture(all_pass.is_a?(Hash) && all_pass.keys.sort == %w[cases config expected_outcome file file_suite platform projects tier].sort &&
  all_pass['config'] == 'all-pass.config.cjs' && all_pass['file'] == 'all-pass.spec.cjs' &&
  all_pass['projects'] == %w[smoke critical] && all_pass['tier'] == 'feedback' &&
  all_pass['platform'] == 'linux' && all_pass['expected_outcome'] == 'passed', 'all-pass scope')
file_suite = all_pass.fetch('file_suite')
require_fixture(file_suite.is_a?(Hash) && file_suite.keys.sort == %w[file identity_uses title].sort &&
  file_suite['title'] == 'all-pass.spec.cjs' && file_suite['file'].end_with?('/all-pass.spec.cjs') &&
  file_suite['title'] != file_suite['file'] && file_suite['title'] == File.basename(file_suite['file']) &&
  file_suite['identity_uses'] == 'file',
  'distinct file suite title/path regression')
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
require_fixture(duplicate.is_a?(Hash) && duplicate.keys.sort == %w[config copies describe expected_disposition file project title].sort &&
  duplicate['config'] == 'duplicate-identity.config.cjs' && duplicate['file'] == 'duplicate-identity.spec.cjs' &&
  duplicate['project'] == 'smoke' && duplicate['copies'] == 2 &&
  duplicate['expected_disposition'] == 'duplicate_case_identity', 'duplicate fixture scope')
duplicate_source = File.binread(File.join(FIXTURE_DIR, duplicate.fetch('file')))
require_fixture(duplicate_source.scan("test('same case identity'").length == 2 && duplicate_source.include?(duplicate.fetch('describe').first),
  'duplicate fixture source')
bindings.each do |binding|
  tier = binding.fetch('runner_id') == 'playwright-desktop' ? 'feedback' : 'smoke'
  app = binding.fetch('runner_id') == 'playwright-desktop' ? 'taurine-desktop' : 'taurine-mobile'
  title = (duplicate.fetch('describe') + [duplicate.fetch('title')]).join(' > ')
  identity = [binding.fetch('runner_id'), binding.fetch('config_id'), tier, 'linux', duplicate.fetch('project'),
    "#{app}/.case-evidence-fixtures/#{duplicate.fetch('file')}", '', '', title]
  ids = Array.new(duplicate.fetch('copies')) { Digest::SHA256.hexdigest(JSON.generate(identity)) }
  require_fixture(ids.uniq.length == 1 && ids.length == 2, 'duplicate normalized identity collision')
end

outcomes = EXPECTED.fetch('outcomes')
require_fixture(outcomes.is_a?(Hash) && outcomes.keys.sort == %w[cases config file project].sort &&
  outcomes['config'] == 'outcomes.config.cjs' && outcomes['file'] == 'outcomes.spec.cjs' && outcomes['project'] == 'smoke',
  'outcome fixture scope')
outcome_source = File.binread(File.join(FIXTURE_DIR, outcomes.fetch('file')))
expected_outcomes = {
  'expected failure' => ['failed', ['failed'], 'expected', 'passed'],
  'unexpected pass' => ['failed', ['passed'], 'unexpected', 'blocked'],
  'flaky retry' => ['passed', %w[failed passed], 'flaky', 'blocked'],
  'intentional skip' => ['skipped', [], 'skipped', 'blocked']
}
require_fixture(outcomes['cases'].is_a?(Array) && outcomes['cases'].length == expected_outcomes.length, 'outcome case count')
outcomes['cases'].each do |entry|
  require_fixture(entry.is_a?(Hash) && entry.keys.sort == %w[aggregate attempts describe disposition expected_status title].sort,
    'outcome case shape')
  require_fixture(expected_outcomes[entry['title']] == [entry['expected_status'], entry['attempts'], entry['aggregate'], entry['disposition']],
    'outcome expectation')
  require_fixture(outcome_source.include?(entry['title']), 'outcome source title')
end
require_fixture(outcome_source.include?('test.fail();') && outcome_source.include?('testInfo.retry === 0') &&
  outcome_source.include?("test.skip('intentional skip'"), 'outcome source behavior')

callback = EXPECTED.fetch('callback_failure')
callback_source = File.binread(File.join(FIXTURE_DIR, callback.fetch('reporter')))
require_fixture(callback.keys.sort == %w[callback expected_completion_marker expected_disposition reporter].sort &&
  callback['callback'] == 'onBegin' && callback['expected_completion_marker'] == 'absent' &&
  callback['expected_disposition'] == 'blocked' && callback_source.include?('onBegin()') &&
  callback_source.include?('SYNTHETIC_REPORTER_CALLBACK_FAILURE'), 'callback failure fixture')

puts 'Playwright parity fixtures: static schema, exact runner pins, identities, outcomes, and callback-failure fixtures passed'
