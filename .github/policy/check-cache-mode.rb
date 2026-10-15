# Cache-mode and actions: write policy (docs/untrusted-readonly-cache.md, P2 and P7).
# Usage: ruby check-cache-mode.rb [--enforced-file FILE] WORKFLOW.yml...
#
# GitHub's job-level `cache-mode` (read, write, write-only, none) is enforced by the cache token
# the runner receives (proved by the cache-mode spike, section 7a-result of the design). The
# rules below keep a later edit from widening it.
#
# Always on, for every workflow given:
#  A. every `cache-mode` value is the literal read, write or none (never write-only, never an
#     expression: GitHub rejects the `github` context there, and a computed value is unreviewable);
#  B. a workflow-level `cache-mode` is only `none`;
#  C. a called workflow (`on: workflow_call`) has no `cache-mode` at all, so it inherits its
#     caller's grant and can never widen it;
#  D. `cache-mode: write` only on a job whose `if:` has the exact top-level term
#     github.ref == 'refs/heads/main' (no unparenthesised ||).
# Staged, for the basenames in ENFORCED_WORKFLOWS (rules F to J):
#  F. workflow-level `cache-mode: none`;
#  G. every job that has an actions/cache step, or calls a local reusable workflow, declares its
#     own `cache-mode` (a job with no cache step inherits the workflow-level none);
#  H. a job that saves (its own steps, or the reusable workflow it calls) is `write` and gated to
#     main and never mentions the untrusted ref, and a sibling job with the same `uses` is
#     `read` and gated by the exact top-level term github.ref == 'refs/heads/untrusted'
#     (validate-main / validate-untrusted split: expressions are rejected, so the split is mandatory);
#  K. a validate-untrusted half (read, untrusted-gated, calling a saving workflow) needs the
#     `cache-audit` job directly and the exact top-level term needs.cache-audit.result == 'success';
#     `cache-audit` runs only on the untrusted ref, has no environment, no secret and only
#     actions: read and contents: read, and calls ./.github/actions/cache-scope-audit with
#     phase before; `cache-audit-after` needs cache-audit and every untrusted half, runs on the
#     untrusted ref and calls the composite with phase after;
#  I. a job whose steps contain actions/cache/save is `write`;
#  J. a job whose steps contain actions/cache/restore (and no save) is `read` or `write`.
# Always on, over every workflow and composite action given: `actions: write` (or write-all) is
# held to the two reviewed places (P7): cache-prune.yml, a main-only job with no environment, no
# secret and no local composite (it deletes cache entries, which cache-mode does not govern), and
# the weekly resolver's main-only dispatch job.
require 'yaml'

MAIN = "github.ref == 'refs/heads/main'".freeze
UNTRUSTED = "github.ref == 'refs/heads/untrusted'".freeze
REPOSITORY = "github.repository == 'Moh-Bakr/Taurine-CI'".freeze
MODES = %w[read write none].freeze

# The top-level conjuncts of an `if:` value, as check-cache-policy.sh's cond_top_terms: the
# ${{ }} wrapper is dropped, every parenthesised group is removed whole, and the rest is split on
# &&. Returns nil when an || remains at the top level.
def top_terms(value)
  return [] unless value.is_a?(String)
  flat = value.strip
  flat = flat[3..-3].strip if flat.start_with?('${{') && flat.end_with?('}}')
  nil while flat.gsub!(/\([^()]*\)/, '')
  return nil if flat.include?('||')
  flat.split('&&').map(&:strip)
end

def requires?(value, term)
  terms = top_terms(value)
  !terms.nil? && terms.include?(term)
end

def load(path)
  YAML.safe_load(File.read(path, encoding: 'UTF-8'), aliases: false) || {}
end

def triggers(doc)
  on = doc.key?('on') ? doc['on'] : doc[true]
  case on
  when Hash then on.keys.map(&:to_s)
  when Array then on.map(&:to_s)
  when String then [on]
  else []
  end
end

def steps_of(job)
  Array(job['steps']).select { |s| s.is_a?(Hash) }
end

def uses_of(steps, pattern)
  steps.any? { |s| s['uses'].to_s.match?(pattern) }
end

# Workflows (basename) held to the staged rules F to J (every workflow with a dispatch trigger but macOS); the
# workflow pull request that adds `cache-mode` to a workflow adds its name here in the same change
# (docs/untrusted-readonly-cache.md, section 4.1). The always-on rules A to D and the
# actions: write rule need no entry. Fixtures pass their own list with --enforced-file.
ENFORCED_WORKFLOWS = %w[
  android-validation.yml
  cache-prune.yml
  ios-validation.yml
  linux-validation.yml
  live-proofs.yml
  orchestrate-validation.yml
  pg8-measurement.yml
  scorecard.yml
  source-read.yml
  validate-public-changes.yml
  weekly-validation.yml
  windows-validation.yml
].freeze
# macos-validation.yml is deliberately absent: its matrix job runs inline and saves caches, so it
# cannot be split into validate-main / validate-untrusted until it becomes a reusable workflow
# (docs/untrusted-readonly-cache.md, section 6). Until then macOS keeps today's default grant.

enforced_file = nil
args = ARGV.dup
if args.first == '--enforced-file'
  args.shift
  enforced_file = args.shift
end
enforced = if enforced_file
  File.readlines(enforced_file).map(&:strip).reject { |l| l.empty? || l.start_with?('#') }
else
  ENFORCED_WORKFLOWS
end

failures = []
docs = {}
args.each { |path| docs[path] = load(path) }

docs.each do |path, doc|
  base = File.basename(path)
  composite = path.include?('/actions/')
  next if composite # composites carry no permissions or cache-mode keys of their own
  called = triggers(doc).include?('workflow_call')
  wf_mode = doc['cache-mode']
  jobs = doc['jobs'].is_a?(Hash) ? doc['jobs'] : {}

  check_value = lambda do |where, value|
    failures << "#{path}: #{where} cache-mode must be the literal read, write or none, not #{value.inspect}" unless MODES.include?(value)
  end

  unless wf_mode.nil?
    check_value.call('workflow-level', wf_mode)
    failures << "#{path}: a workflow-level cache-mode is only none (got #{wf_mode.inspect})" unless wf_mode == 'none'
    failures << "#{path}: a called workflow must not set cache-mode; it inherits its caller's grant" if called
  end

  untrusted_halves = []
  jobs.each do |name, job|
    next unless job.is_a?(Hash)
    mode = job['cache-mode']
    steps = steps_of(job)
    saves = uses_of(steps, %r{\Aactions/cache/save@})
    restores = uses_of(steps, %r{\Aactions/cache/restore@})
    unless mode.nil?
      check_value.call("job #{name}", mode)
      failures << "#{path}: job #{name}: a called workflow must not set cache-mode; it inherits its caller's grant" if called
      if mode == 'write' && !requires?(job['if'], MAIN)
        failures << "#{path}: job #{name}: cache-mode write needs the exact top-level term #{MAIN} in its if, with no unparenthesised ||"
      end
    end
    next unless enforced.include?(base)

    callee = job['uses'].to_s.start_with?('./.github/workflows/') ? job['uses'].to_s.sub(%r{\A\./}, '') : nil
    callee_text = callee && File.exist?(callee) ? File.read(callee, encoding: 'UTF-8') : ''
    callee_saves = callee_text.match?(%r{uses:\s*actions/cache/save@})
    caches = saves || restores || !callee.nil?
    if mode.nil? && caches
      failures << "#{path}: job #{name} restores, saves or calls a reusable workflow and must declare its own cache-mode"
    end
    if saves && mode != 'write'
      failures << "#{path}: job #{name} has a cache save step and must be cache-mode write, gated to main"
    end
    if restores && !saves && !%w[read write].include?(mode)
      failures << "#{path}: job #{name} has a cache restore step and must be cache-mode read or write"
    end
    next unless callee_saves || saves

    if mode == 'read' && callee && requires?(job['if'], UNTRUSTED)
      untrusted_halves << name
      failures << "#{path}: job #{name} (untrusted half) must need the cache-audit job directly" unless Array(job['needs']).include?('cache-audit')
      failures << "#{path}: job #{name} (untrusted half) needs the exact top-level term needs.cache-audit.result == 'success'" unless requires?(job['if'], "needs.cache-audit.result == 'success'")
    end
    if mode == 'read' && callee && !requires?(job['if'], UNTRUSTED)
      failures << "#{path}: job #{name} calls #{callee}, which saves, read-only without the exact top-level term #{UNTRUSTED}: it is not the validate-untrusted half, and main's validate-main half (a sibling job with cache-mode write gated to main) needs a sibling job"
    end
    failures << "#{path}: job #{name} calls #{callee}, which saves, and must be cache-mode write (main) or read (untrusted)" if callee && !%w[read write].include?(mode)
    if mode == 'write'
      failures << "#{path}: job #{name}: a saving job's if must not mention the untrusted ref" if job['if'].to_s.include?('untrusted')
      if callee
        twin = jobs.find do |other, spec|
          other != name && spec.is_a?(Hash) && spec['uses'] == job['uses'] && spec['cache-mode'] == 'read' && requires?(spec['if'], UNTRUSTED)
        end
        failures << "#{path}: job #{name} saves through #{callee} and needs a sibling job with the same uses, cache-mode read and the exact top-level term #{UNTRUSTED} (the validate-untrusted half of the split)" unless twin
      end
    end
  end

  next unless enforced.include?(base)
  next if called
  failures << "#{path}: an enforced workflow needs a workflow-level cache-mode: none" unless wf_mode == 'none'
  next if untrusted_halves.empty?

  audit_job = lambda do |job_name, phase, needs_all|
    job = jobs[job_name]
    unless job.is_a?(Hash)
      failures << "#{path}: the untrusted split needs a #{job_name} job"
      next
    end
    failures << "#{path}: job #{job_name} must run only on the untrusted ref (exact top-level term #{UNTRUSTED})" unless requires?(job['if'], UNTRUSTED)
    failures << "#{path}: job #{job_name} must have no environment, no secrets and no cache-mode" if job.key?('environment') || job.key?('secrets') || job.key?('cache-mode')
    failures << "#{path}: job #{job_name} must grant exactly actions: read and contents: read" unless job['permissions'] == { 'actions' => 'read', 'contents' => 'read' }
    needs_all.each { |n| failures << "#{path}: job #{job_name} must need #{n}" unless Array(job['needs']).include?(n) }
    steps = steps_of(job)
    audit_calls = steps.select { |st| st['uses'].to_s == './.github/actions/cache-scope-audit' }
    if audit_calls.length != 1 || audit_calls.first['with'] != { 'github-token' => '${{ github.token }}', 'phase' => phase }
      failures << "#{path}: job #{job_name} must call ./.github/actions/cache-scope-audit exactly once with the job token and phase #{phase}"
    end
    other = steps.reject { |st| %r{\Aactions/checkout@[0-9a-f]{40}\z}.match?(st['uses'].to_s) || st['uses'].to_s == './.github/actions/cache-scope-audit' }
    failures << "#{path}: job #{job_name} may run only the public checkout and the audit composite" unless other.empty?
  end
  audit_job.call('cache-audit', 'before', ['validate-input'].select { |n| jobs.key?(n) })
  audit_job.call('cache-audit-after', 'after', ['cache-audit'] + untrusted_halves)
end

# P7: actions: write (or write-all) only where reviewed.
docs.each do |path, doc|
  base = File.basename(path)
  perms = []
  perms << [nil, doc['permissions']]
  (doc['jobs'].is_a?(Hash) ? doc['jobs'] : {}).each { |name, job| perms << [name, job['permissions']] if job.is_a?(Hash) }
  perms.each do |name, value|
    writes = value == 'write-all' || (value.is_a?(Hash) && value['actions'] == 'write')
    next unless writes
    where = name ? "job #{name}" : 'workflow-level permissions'
    job = name ? doc['jobs'][name] : nil
    case base
    when 'cache-prune.yml'
      if job.nil?
        failures << "#{path}: #{where}: actions: write is held to the prune job, not the whole workflow"
        next
      end
      terms = top_terms(job['if'])
      failures << "#{path}: job #{name}: actions: write needs the exact top-level terms #{REPOSITORY} and #{MAIN}" unless terms && terms.include?(MAIN) && terms.include?(REPOSITORY)
      failures << "#{path}: job #{name}: the cache-deleting job must have no environment" if job.key?('environment')
      failures << "#{path}: job #{name}: the cache-deleting job must use no local composite action" if steps_of(job).any? { |s| s['uses'].to_s.start_with?('./.github/actions/') }
      failures << "#{path}: the cache-deleting workflow must read no secret" if File.read(path, encoding: 'UTF-8').match?(/secrets\./)
    when 'weekly-validation.yml'
      if job.nil? || !requires?(job['if'], MAIN)
        failures << "#{path}: #{where}: actions: write (dispatch) needs a job gated by the exact top-level term #{MAIN}"
      end
    else
      failures << "#{path}: #{where}: actions: write is held to cache-prune.yml and the weekly dispatch job (it can delete cache entries, which cache-mode does not govern)"
    end
  end
end

if failures.empty?
  puts "cache-mode policy: #{docs.size} workflows checked"
else
  warn failures.uniq.join("\n")
  exit 1
end
