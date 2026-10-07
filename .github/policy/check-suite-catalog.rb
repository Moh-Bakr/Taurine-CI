#!/usr/bin/env ruby
# Pin the public feature-suite contract independently of private source manifests.
require 'json'

FEATURES = %w[
  rest automation mock-docs database notes git sync vault tools search-navigation
  organization import-export observability shell-appearance ai design cli-orchestration
  integration
].freeze
RUNNER_CONFIGS = {
  'vitest-desktop' => %w[desktop-vitest-default],
  'vitest-mobile' => %w[mobile-vitest-default],
  'vitest-shared' => %w[shared-vitest-default],
  'playwright-desktop' => %w[desktop-playwright-projects],
  'playwright-mobile' => %w[mobile-playwright-projects],
  'nextest' => %w[root-workspace-nextest standalone-nextest],
  'cargo-doctest' => %w[root-workspace-doctest standalone-doctest],
  'cargo-test' => %w[root-workspace-nextest standalone-nextest],
  'node-orchestrate' => %w[orchestrate-node-suite],
  'policy-static' => %w[policy-contracts],
  'native-platform' => %w[native-platform-targets],
  'live-integration' => %w[live-arms],
  'benchmark' => %w[benchmark-configs],
  'design-probe' => %w[design-probes],
  'vendor-upstream' => %w[vendor-dispositions]
}.freeze
TIERS_BY_CONFIG = {
  'desktop-vitest-default' => %w[default],
  'mobile-vitest-default' => %w[default],
  'shared-vitest-default' => %w[default],
  'desktop-playwright-projects' => %w[feedback regression benchmark a11y visual],
  'mobile-playwright-projects' => %w[smoke critical regression],
  'root-workspace-nextest' => %w[domain db net app cli packaging android ios dbx tls-openssl],
  'standalone-nextest' => %w[standalone],
  'root-workspace-doctest' => %w[default],
  'standalone-doctest' => %w[standalone],
  'orchestrate-node-suite' => %w[default],
  'policy-contracts' => %w[default],
  'native-platform-targets' => %w[macos windows android ios],
  'live-arms' => %w[live],
  'benchmark-configs' => %w[decode devtools],
  'design-probes' => %w[frame visual],
  'vendor-dispositions' => %w[upstream excluded]
}.freeze
PLATFORMS = %w[linux macos windows android ios].freeze
PROJECTS_BY_CONFIG = {
  'desktop-vitest-default' => [], 'mobile-vitest-default' => [], 'shared-vitest-default' => [],
  'desktop-playwright-projects' => %w[smoke critical shell-browser bench a11y visual regression],
  'mobile-playwright-projects' => %w[smoke critical regression]
}.freeze
MOBILE_FEATURES = %w[
  rest mock-docs notes sync vault tools search-navigation organization shell-appearance
  integration
].freeze
SHARED_FEATURES = %w[
  rest database notes vault tools search-navigation organization import-export
  shell-appearance cli-orchestration integration
].freeze

class CatalogContractError < StandardError; end

def require_contract(condition)
  raise CatalogContractError unless condition
end

def expected_frontend_groups
  groups = []
  groups << {
    'id' => 'desktop-vitest-default-linux', 'surface' => 'desktop', 'runner_token' => 'vitest',
    'runner' => 'vitest-desktop', 'config' => 'desktop-vitest-default', 'tier' => 'default',
    'features' => FEATURES, 'projects' => [], 'availability' => 'supported', 'mandatory' => true,
    'reason' => nil, 'concerns' => %w[desktop-shard-1 desktop-shard-2]
  }
  groups << {
    'id' => 'mobile-vitest-default-linux', 'surface' => 'mobile', 'runner_token' => 'vitest',
    'runner' => 'vitest-mobile', 'config' => 'mobile-vitest-default', 'tier' => 'default',
    'features' => MOBILE_FEATURES, 'projects' => [], 'availability' => 'supported', 'mandatory' => true,
    'reason' => nil, 'concerns' => %w[mobile-quality]
  }
  groups << {
    'id' => 'shared-vitest-default-linux', 'surface' => 'shared', 'runner_token' => 'vitest',
    'runner' => 'vitest-shared', 'config' => 'shared-vitest-default', 'tier' => 'default',
    'features' => SHARED_FEATURES, 'projects' => [], 'availability' => 'supported', 'mandatory' => true,
    'reason' => nil, 'concerns' => %w[contracts]
  }
  %w[feedback regression benchmark a11y visual].each do |tier|
    projects, availability, mandatory, reason, concerns = case tier
    when 'feedback'
      [%w[smoke critical shell-browser], 'supported', true, nil, %w[e2e-critical]]
    when 'regression'
      [%w[regression], 'supported', true, nil,
       %w[e2e-regression-1 e2e-regression-2 e2e-regression-3 e2e-regression-4]]
    when 'benchmark'
      [%w[bench], 'uncovered', false, 'hosted_route_missing', []]
    when 'a11y'
      [%w[a11y], 'supported', true, nil, %w[e2e-a11y]]
    when 'visual'
      [%w[visual], 'supported', false, nil, %w[e2e-visual]]
    end
    groups << {
      'id' => "desktop-playwright-#{tier}-linux", 'surface' => 'desktop', 'runner_token' => 'playwright',
      'runner' => 'playwright-desktop', 'config' => 'desktop-playwright-projects', 'tier' => tier,
      'features' => FEATURES, 'projects' => projects, 'availability' => availability, 'mandatory' => mandatory,
      'reason' => reason, 'concerns' => concerns
    }
  end
  %w[smoke critical regression].each do |tier|
    groups << {
      'id' => "mobile-playwright-#{tier}-linux", 'surface' => 'mobile', 'runner_token' => 'playwright',
      'runner' => 'playwright-mobile', 'config' => 'mobile-playwright-projects', 'tier' => tier,
      'features' => %w[integration], 'projects' => [tier], 'availability' => 'uncovered', 'mandatory' => true,
      'reason' => 'hosted_route_missing', 'concerns' => []
    }
  end
  groups
end

def expected_records
  suites = {}
  requirements = []
  expected_frontend_groups.each do |group|
    ids = group.fetch('features').map do |feature|
      id = "#{group.fetch('surface')}.#{group.fetch('runner_token')}.#{group.fetch('tier')}.#{feature}"
      suites[id] = {
        'id' => id, 'feature' => feature, 'tier' => group.fetch('tier'),
        'runner' => group.fetch('runner'), 'config' => group.fetch('config'), 'platforms' => %w[linux],
        'projects' => group.fetch('projects'), 'status' => 'candidate', 'mandatory' => false,
        'concerns' => group.fetch('concerns')
      }
      id
    end
    requirements << {
      'id' => group.fetch('id'), 'runner' => group.fetch('runner'), 'config' => group.fetch('config'),
      'tier' => group.fetch('tier'), 'platforms' => %w[linux], 'projects' => group.fetch('projects'),
      'feature_ids' => group.fetch('features'), 'candidate_suite_ids' => ids, 'mandatory' => group.fetch('mandatory'),
      'availability' => group.fetch('availability'), 'availability_reason' => group.fetch('reason'),
      'concerns' => group.fetch('concerns')
    }
  end
  [suites, requirements]
end

def valid_suite_id?(record)
  id = record['id']
  return false unless id.is_a?(String) && id.match?(/\A[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*){2,3}\z/)

  parts = id.split('.')
  runner = record['runner']
  feature = record['feature']
  tier = record['tier']
  layouts = {
    'vitest-desktop' => [%w[desktop vitest], 4],
    'vitest-mobile' => [%w[mobile vitest], 4],
    'vitest-shared' => [%w[shared vitest], 4],
    'playwright-desktop' => [%w[desktop playwright], 4],
    'playwright-mobile' => [%w[mobile playwright], 4],
    'nextest' => [%w[rust nextest], 4],
    'cargo-doctest' => [%w[rust doctest], 4],
    'cargo-test' => [%w[rust cargo-test], 4],
    'node-orchestrate' => [%w[node orchestrate], 4],
    'policy-static' => [%w[policy static], 4],
    'native-platform' => [%w[native platform], 4],
    'live-integration' => [%w[live integration], 4],
    'benchmark' => [%w[benchmark], 3],
    'design-probe' => [%w[design probe], 4],
    'vendor-upstream' => [%w[vendor upstream], 4]
  }
  prefix, length = layouts[runner]
  return false unless prefix && parts.length == length && parts[0, prefix.length] == prefix
  if length == 3
    parts[1] == tier && parts[2] == feature
  else
    parts[2] == tier && parts[3] == feature
  end
end

def validate_new_suite(record, matrix)
  keys = %w[config concerns feature id mandatory platforms projects runner status tier].sort
  require_contract(record.is_a?(Hash) && record.keys.sort == keys)
  require_contract(FEATURES.include?(record['feature']) && valid_suite_id?(record))
  require_contract(RUNNER_CONFIGS.fetch(record['runner'], []).include?(record['config']))
  require_contract(TIERS_BY_CONFIG.fetch(record['config'], []).include?(record['tier']))
  require_contract(record['status'] == 'candidate' && record['mandatory'] == false)
  require_contract(record['platforms'].is_a?(Array) && !record['platforms'].empty? &&
                   record['platforms'].all? { |platform| PLATFORMS.include?(platform) } &&
                   record['platforms'].uniq == record['platforms'])
  allowed_projects = PROJECTS_BY_CONFIG[record['config']] || []
  require_contract(record['projects'].is_a?(Array) &&
                   record['projects'].all? { |project| allowed_projects.include?(project) } &&
                   record['projects'].uniq == record['projects'])
  all_concerns = matrix.fetch('concerns', {}).values.flat_map { |per_platform| per_platform.keys }
  require_contract(record['concerns'].is_a?(Array) && record['concerns'].all? { |concern| all_concerns.include?(concern) } &&
                   record['concerns'].uniq == record['concerns'])
end

def validate_new_requirement(record, suites, matrix)
  keys = %w[availability availability_reason candidate_suite_ids config concerns feature_ids id mandatory platforms projects runner tier].sort
  require_contract(record.is_a?(Hash) && record.keys.sort == keys)
  require_contract(record['id'].is_a?(String) && record['id'].match?(/\A[a-z][a-z0-9-]{1,95}\z/))
  require_contract(RUNNER_CONFIGS.fetch(record['runner'], []).include?(record['config']))
  require_contract(TIERS_BY_CONFIG.fetch(record['config'], []).include?(record['tier']))
  require_contract(record['mandatory'] == true || record['mandatory'] == false)
  require_contract(record['platforms'].is_a?(Array) && !record['platforms'].empty? &&
                   record['platforms'].all? { |platform| PLATFORMS.include?(platform) } &&
                   record['platforms'].uniq == record['platforms'])
  allowed_projects = PROJECTS_BY_CONFIG[record['config']] || []
  require_contract(record['projects'].is_a?(Array) &&
                   record['projects'].all? { |project| allowed_projects.include?(project) } &&
                   record['projects'].uniq == record['projects'])
  require_contract(record['candidate_suite_ids'].is_a?(Array) && record['candidate_suite_ids'].uniq == record['candidate_suite_ids'])
  require_contract(record['feature_ids'].is_a?(Array) && record['feature_ids'].uniq == record['feature_ids'] &&
                   record['feature_ids'].all? { |feature| FEATURES.include?(feature) })
  require_contract(record['concerns'].is_a?(Array) && record['concerns'].uniq == record['concerns'])
  all_concerns = matrix.fetch('concerns', {}).values.flat_map { |per_platform| per_platform.keys }
  require_contract(record['concerns'].all? { |concern| all_concerns.include?(concern) })

  case record['availability']
  when 'supported'
    require_contract(record['availability_reason'].nil? && !record['candidate_suite_ids'].empty?)
  when 'uncovered'
    reasons = %w[hosted_route_missing no_standalone_target not_validated environment_unavailable]
    require_contract(reasons.include?(record['availability_reason']) && !record['candidate_suite_ids'].empty?)
    # The sole reviewed optional uncovered config is the desktop browser benchmark project.
    require_contract(record['mandatory'] || record['id'] == 'desktop-playwright-benchmark-linux')
  when 'excluded'
    require_contract(record['availability_reason'] == 'upstream_policy_excluded' && !record['mandatory'] &&
                     record['candidate_suite_ids'].empty? && record['feature_ids'].empty?)
  when 'not_applicable'
    require_contract(record['availability_reason'] == 'not_applicable' && !record['mandatory'] &&
                     record['candidate_suite_ids'].empty? && record['feature_ids'].empty?)
  else
    require_contract(false)
  end

  require_contract(record['candidate_suite_ids'].all? { |id| suites.key?(id) })
  rows = record['candidate_suite_ids'].map { |id| suites.fetch(id) }
  require_contract(!rows.empty? || %w[excluded not_applicable].include?(record['availability']))
  if rows.any?
    require_contract(rows.all? do |row|
      row['runner'] == record['runner'] && row['config'] == record['config'] && row['tier'] == record['tier'] &&
        row['platforms'] == record['platforms'] && row['projects'] == record['projects'] &&
        record['concerns'] == row['concerns']
    end)
    require_contract(rows.map { |row| row['feature'] }.sort == record['feature_ids'].sort)
  end
end

def validate_catalog(matrix)
  catalog = matrix.fetch('suite_catalog')
  require_contract(catalog.is_a?(Hash) && catalog.keys.sort == %w[coverage_requirements suites version])
  require_contract(catalog['version'] == 1)
  pinned_suites, pinned_requirements = expected_records
  actual_suites = catalog['suites']
  actual_requirements = catalog['coverage_requirements']
  require_contract(actual_suites.is_a?(Array) && actual_requirements.is_a?(Array))
  require_contract(actual_suites.length >= pinned_suites.length && actual_requirements.length >= pinned_requirements.length)
  suite_ids = actual_suites.map { |record| record.is_a?(Hash) ? record['id'] : nil }
  requirement_ids = actual_requirements.map { |record| record.is_a?(Hash) ? record['id'] : nil }
  require_contract(suite_ids.uniq.length == suite_ids.length && requirement_ids.uniq.length == requirement_ids.length)
  actual_suites.each do |record|
    expected = pinned_suites[record.is_a?(Hash) ? record['id'] : nil]
    if expected
      require_contract(record.is_a?(Hash) && record.keys.sort == expected.keys.sort && record == expected)
    else
      validate_new_suite(record, matrix)
    end
  end
  actual_by_id = actual_suites.to_h { |record| [record['id'], record] }
  require_contract(pinned_suites.all? { |id, record| actual_by_id[id] == record })
  actual_by_id = actual_suites.to_h { |record| [record['id'], record] }
  actual_requirements.each do |record|
    expected = pinned_requirements.find { |row| row['id'] == (record.is_a?(Hash) ? record['id'] : nil) }
    if expected
      require_contract(record.is_a?(Hash) && record.keys.sort == expected.keys.sort)
      keys = expected.keys - %w[availability availability_reason mandatory candidate_suite_ids feature_ids]
      require_contract(keys.all? { |key| record[key] == expected[key] })
      require_contract(record['mandatory'] == true || record['mandatory'] == false)
      require_contract((expected['candidate_suite_ids'] - record['candidate_suite_ids']).empty?)
      require_contract((expected['feature_ids'] - record['feature_ids']).empty?)
      require_contract(record['mandatory'] == true || expected['mandatory'] == false)
      if expected['availability'] == 'supported'
        require_contract(record['availability'] == 'supported' && record['availability_reason'].nil?)
      elsif expected['availability'] == 'uncovered'
        require_contract(%w[uncovered supported].include?(record['availability']))
        expected_reason = record['availability'] == 'supported' ? nil : expected['availability_reason']
        require_contract(record['availability_reason'] == expected_reason)
      else
        require_contract(record['availability'] == expected['availability'] && record['availability_reason'] == expected['availability_reason'])
      end
    end
    validate_new_requirement(record, actual_by_id, matrix)
  end
  require_contract(pinned_requirements.all? { |expected| requirement_ids.include?(expected['id']) })
  execution_groups = actual_requirements.map do |record|
    [record.fetch('runner'), record.fetch('config'), record.fetch('tier'), record.fetch('platforms').sort, record.fetch('projects').sort]
  end
  require_contract(execution_groups.uniq.length == execution_groups.length)
  candidate_ids = actual_requirements.flat_map { |record| record.fetch('candidate_suite_ids') }
  require_contract(candidate_ids.uniq.length == candidate_ids.length && candidate_ids.sort == actual_by_id.keys.sort)
end

begin
  path = ARGV.fetch(0, '.github/ci-matrix.json')
  matrix = JSON.parse(File.read(path))
  validate_catalog(matrix)
  puts 'suite catalog: reviewed candidate bindings and coverage requirements match'
rescue CatalogContractError, JSON::ParserError, KeyError, TypeError, NoMethodError, SystemCallError
  warn 'suite catalog: rejected invalid or unreviewed contract'
  exit 1
end
