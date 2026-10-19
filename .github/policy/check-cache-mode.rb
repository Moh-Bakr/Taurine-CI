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
#  L. a called workflow does not itself call a local reusable workflow: two-deep nesting (A calls
#     B calls C) is unsupported, because the saves and restores of C would escape the callee
#     classification below, so it fails closed;
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
#     The dispatch's `result` job needs both audits and passes run-result the exact
#     blocking-failures expression, so a failed audit cannot print PASS;
#  I. a job whose steps contain actions/cache/save is `write`;
#  J. a job whose steps contain actions/cache/restore (and no save) is `read` or `write`.
#  N. (Stage 2) a cache restore is main-only, or it is exactly one of the four reviewed read-only
#     untrusted restores (see REVIEWED_UNTRUSTED_RESTORES): Linux concern workflow only, rust-db and the
#     rust-app shards only, `actions/cache/restore` directly (never through a composite), its `if` the exact
#     top-level terms `github.ref == 'refs/heads/untrusted'`, `inputs.untrusted_readonly_cache` and
#     `(inputs.concern == 'rust-db' || startsWith(inputs.concern, 'rust-app-'))` and nothing else, `with` exactly `path` and `key`, the path and
#     the key the reviewed literals (a key never derives from a dispatch input, the head ref or any
#     other expression), and no other step key (no env, continue-on-error, timeout). Around it:
#     no `write` permission anywhere in the called workflow or in the untrusted half that calls it,
#     every caller is a read or write job, the flag a caller passes is a literal boolean, only the
#     read (untrusted) half may pass true, and true needs the recorded enforcement spike
#     (SPIKE_RECORD in docs/untrusted-readonly-cache.md).
# Always on, over every workflow and composite action given: `actions: write` (or write-all) is
# held to the two reviewed places (P7): cache-prune.yml, a main-only job with no environment, no
# secret and no local composite (it deletes cache entries, which cache-mode does not govern), and
# the weekly resolver's main-only dispatch job.
require 'yaml'
require 'json'
require 'digest'
require_relative 'cache-expression'

MAIN = "github.ref == 'refs/heads/main'".freeze
UNTRUSTED = "github.ref == 'refs/heads/untrusted'".freeze
REPOSITORY = "github.repository == 'Moh-Bakr/Taurine-CI'".freeze
MODES = %w[read write none].freeze
# What the dispatch's Result job passes to run-result so a failed untrusted cache scope audit (before
# or after the run) can never print a passing verdict.
BLOCKING_EXPR = %q(${{ (contains(fromJSON('["failure","cancelled"]'), needs.cache-audit.result) || contains(fromJSON('["failure","cancelled"]'), needs.cache-audit-after.result)) && '1' || '0' }}).freeze

UNTRUSTED_RESTORE_WORKFLOWS = %w[linux-validation-concern.yml].freeze
UNTRUSTED_FLAG = 'untrusted_readonly_cache'.freeze
# The reviewed concern term: rust-db and the rust-app shards (the Linux rust-app-1 to rust-app-3), one
# parenthesised conjunct. Never rust-packaging (cached on main, not restored untrusted), never the OpenSSL
# door concern (rust-tls-openssl, section 4.5), never a wider startsWith.
UNTRUSTED_CONCERN_TERM = "(inputs.concern == 'rust-db' || startsWith(inputs.concern, 'rust-app-'))".freeze
UNTRUSTED_RESTORE_TERMS = [UNTRUSTED, 'inputs.untrusted_readonly_cache', UNTRUSTED_CONCERN_TERM].freeze
PIN = 'actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9'.freeze
SOURCES_PATH = "${{ steps.cargo-home.outputs.dir }}/registry/cache\n".freeze
TARGET_PATH = "${{ steps.cargo-target.outputs.dir }}/debug/deps\n${{ steps.cargo-target.outputs.dir }}/debug/build\n${{ steps.cargo-target.outputs.dir }}/debug/.fingerprint\n".freeze
SOURCES_KEY = "cargo-sources-v3-${{ runner.os }}-${{ hashFiles('src/Cargo.lock', 'src/taurine-backend/*/Cargo.lock', 'src/taurine-backend/vendor/*/Cargo.lock', 'src/vendor/*/Cargo.lock') }}".freeze
TARGET_KEY = '${{ steps.cargo-target.outputs.key }}'.freeze
# The only untrusted restores that may exist: [path, key], nothing else is reviewed.
REVIEWED_UNTRUSTED_RESTORES = [[SOURCES_PATH, SOURCES_KEY], [TARGET_PATH, TARGET_KEY]].freeze
# A flag set true needs this exact line in docs/untrusted-readonly-cache.md: the green enforcement
# spike (section 7c) recorded by a person after reading the run, with its run id.
SPIKE_RECORD = /^Stage 2 enforcement spike result: GREEN run [0-9]{8,} reviewed by [A-Za-z0-9._-]+ on 20[0-9]{2}-[0-9]{2}-[0-9]{2}$/.freeze
STEP_KEYS = %w[name id if uses with].freeze

# Both cache checkers use the same string-aware, fail-closed expression parser.
def top_terms(value)
  CacheExpression.top_terms(value)
end

def requires?(value, term)
  terms = top_terms(value)
  !terms.nil? && terms.include?(term)
end

def read_text(path)
  File.read(path, encoding: 'UTF-8')
end

def load(path)
  YAML.safe_load(read_text(path), aliases: false) || {}
end

# Psych keeps the last of two equal keys and cache-mode is a case-sensitive key, so a job with
# `cache-mode: write` followed by `cache-mode: read` would be checked as read while GitHub may take
# either, and `Cache-Mode:` would be invisible to every rule. Refuse a duplicate key in any mapping
# and any key that is cache-mode in disguise (another case, an underscore, a space). Return the
# paths of block-scalar if values for rule N: safe_load loses their style, including when the
# strip chomping indicator (|- or >-) removes every newline from the decoded value.
def key_hygiene(path, failures)
  block_scalar_ifs = []
  # Resolve AST scalar keys exactly as safe_load does, including quoted/explicitly tagged
  # keys. Raw YAML 1.1 spellings such as on/yes and off/no become true and false.
  classes = Psych::ClassLoader::Restricted.new([], [])
  keys = Psych::Visitors::NoAliasRuby.new(Psych::ScalarScanner.new(classes), classes)
  walk = lambda do |node, location|
    if node.is_a?(Psych::Nodes::Mapping)
      seen = {}
      node.children.each_slice(2) do |key, value|
        if key.is_a?(Psych::Nodes::Scalar)
          name = key.value
          failures << "#{path}: duplicate key #{name.inspect} in one mapping" if seen.key?(keys.accept(key))
          seen[keys.accept(key)] = true
          failures << "#{path}: #{name.inspect} is cache-mode in disguise; the key is exactly cache-mode" if name.match?(/\Acache[\s_-]*mode\z/i) && name != 'cache-mode'
        end
        child_location = location + [key.is_a?(Psych::Nodes::Scalar) ? keys.accept(key) : nil]
        if key.is_a?(Psych::Nodes::Scalar) && key.value == 'if' && value.is_a?(Psych::Nodes::Scalar) &&
           [Psych::Nodes::Scalar::LITERAL, Psych::Nodes::Scalar::FOLDED].include?(value.style)
          block_scalar_ifs << child_location
        end
        walk.call(value, child_location)
      end
    elsif node.is_a?(Psych::Nodes::Sequence)
      node.children.each_with_index { |child, index| walk.call(child, location + [index]) }
    elsif node.respond_to?(:children) && node.children
      node.children.each { |child| walk.call(child, location) }
    end
  end
  walk.call(Psych.parse_stream(read_text(path)), [])
  block_scalar_ifs
end

# The cache kinds a list of steps can reach: :save, :restore or :combined (the plain actions/cache,
# whose post step saves), looking through local composite actions transitively. A composite may not
# use a cache at all (check_composite_action), so the walk is defence in depth for a rule that
# would otherwise rest on a text match.
def cache_kinds(steps, seen = [])
  kinds = []
  steps.each do |st|
    uses = st['uses'].to_s
    case uses
    when %r{\Aactions/cache/save(@|\z)} then kinds << :save
    when %r{\Aactions/cache/restore(@|\z)} then kinds << :restore
    when %r{\Aactions/cache(@|\z)} then kinds << :combined
    when %r{\A\./\.github/actions/[A-Za-z0-9_-]+\z}
      next if seen.include?(uses)
      file = File.join(uses.sub(%r{\A\./}, ''), 'action.yml')
      next unless File.exist?(file)
      inner = load(file).dig('runs', 'steps')
      kinds.concat(cache_kinds(Array(inner).select { |x| x.is_a?(Hash) }, seen + [uses]))
    end
  end
  kinds.uniq
end

def workflow_cache_kinds(doc)
  (doc['jobs'].is_a?(Hash) ? doc['jobs'] : {}).values.flat_map { |job| job.is_a?(Hash) ? cache_kinds(steps_of(job)) : [] }.uniq
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

# Workflows (basename) held to the staged rules F to J (every workflow with a dispatch trigger); the
# workflow pull request that adds `cache-mode` to a workflow adds its name here in the same change
# (docs/untrusted-readonly-cache.md, section 4.1). The always-on rules A to D and the
# actions: write rule need no entry. Fixtures pass their own list with --enforced-file.
ENFORCED_WORKFLOWS = %w[
  android-validation.yml
  cache-prune.yml
  ios-validation.yml
  linux-validation.yml
  live-proofs.yml
  macos-validation.yml
  orchestrate-validation.yml
  pg8-measurement.yml
  scorecard.yml
  source-read.yml
  validate-public-changes.yml
  weekly-validation.yml
  windows-validation.yml
].freeze
# macos-validation.yml joined the set when its matrix job became the reusable macos-validation-concern.yml
# and was split like Linux and Windows, which clears rule M's macOS refusal.

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

block_scalar_ifs = docs.keys.to_h { |path| [path, key_hygiene(path, failures)] }

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
  if called
    jobs.each do |name, job|
      next unless job.is_a?(Hash) && job['uses'].to_s.start_with?('./.github/workflows/')
      failures << "#{path}: job #{name} calls #{job['uses']} from a called workflow; nested reusable workflows are unsupported (their cache uses would escape the caller rules)"
    end
  end

  jobs.each do |name, job|
    next unless job.is_a?(Hash)
    mode = job['cache-mode']
    steps = steps_of(job)
    kinds = cache_kinds(steps)
    saves = kinds.include?(:save) || kinds.include?(:combined)
    restores = kinds.include?(:restore) || kinds.include?(:combined)
    unless mode.nil?
      check_value.call("job #{name}", mode)
      failures << "#{path}: job #{name}: a called workflow must not set cache-mode; it inherits its caller's grant" if called
      if mode == 'write' && !requires?(job['if'], MAIN)
        failures << "#{path}: job #{name}: cache-mode write needs the exact top-level term #{MAIN} in its if, with no unparenthesised ||"
      end
    end
    next unless enforced.include?(base)

    callee = job['uses'].to_s.start_with?('./.github/workflows/') ? job['uses'].to_s.sub(%r{\A\./}, '') : nil
    callee_kinds = callee && File.exist?(callee) ? workflow_cache_kinds(load(callee)) : []
    callee_saves = callee_kinds.include?(:save) || callee_kinds.include?(:combined)
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

  result = jobs['result']
  if result.is_a?(Hash)
    %w[cache-audit cache-audit-after].each do |needed|
      failures << "#{path}: the result job must need #{needed}, so a failed audit reaches the verdict" unless Array(result['needs']).include?(needed)
    end
    verdict_step = steps_of(result).find { |st| st['uses'].to_s == './.github/actions/run-result' }
    unless verdict_step && verdict_step.dig('with', 'blocking-failures') == BLOCKING_EXPR
      failures << "#{path}: the result job's run-result step must pass blocking-failures exactly as the reviewed audit expression, so a failed audit cannot print PASS"
    end
  else
    failures << "#{path}: the untrusted split needs a result job that carries the audits into the verdict"
  end
end

# F1 (review of the policy half): the untrusted-ref cache gate relaxes check-cache-policy.sh's
# restore rule, and what makes that safe (cache-mode read on the job, the validate-main /
# validate-untrusted split, the audit) is enforced only for the workflows named in
# ENFORCED_WORKFLOWS. So the relaxation fails closed: a workflow with a cache step gated to the
# untrusted ref, and every workflow that calls it, must already be an enforced workflow. Without a
# cache-mode key a job gets the default write grant, and an untrusted restore under write could be
# shadowed by a planted entry.
any_untrusted_cache = false
docs.each do |path, doc|
  next if path.include?('/actions/')
  base = File.basename(path)
  untrusted_cache = (doc['jobs'].is_a?(Hash) ? doc['jobs'] : {}).values.any? do |job|
    job.is_a?(Hash) && steps_of(job).any? { |st| st['uses'].to_s.start_with?('actions/cache') && st['if'].to_s.include?('refs/heads/untrusted') }
  end
  next unless untrusted_cache

  any_untrusted_cache = true

  if triggers(doc).include?('workflow_call')
    callers = docs.select do |_other_path, other|
      (other['jobs'].is_a?(Hash) ? other['jobs'] : {}).values.any? { |job| job.is_a?(Hash) && job['uses'].to_s == "./.github/workflows/#{base}" }
    end
    failures << "#{path}: a cache step gated to the untrusted ref needs a caller in the enforced set, and none was found" if callers.empty?
    callers.each_key do |caller|
      next if enforced.include?(File.basename(caller))
      failures << "#{path}: has a cache step gated to the untrusted ref, but its caller #{File.basename(caller)} is not in ENFORCED_WORKFLOWS, so its jobs would keep the default write grant"
    end
  else
    failures << "#{path}: has a cache step gated to the untrusted ref but is not in ENFORCED_WORKFLOWS, so its jobs would keep the default write grant" unless enforced.include?(base)
  end
end

# M (hard precondition for any untrusted restore): while any workflow that can run on the untrusted
# ref has no cache-mode enforcement, it keeps the default write grant, so one of its jobs could plant a
# shadow entry between another workflow's scope audit and its restore. So an untrusted-gated cache
# step is refused while any non-called workflow with a job gated to the untrusted ref is outside
# ENFORCED_WORKFLOWS. Every workflow is enforced today, so M refuses nothing by itself; rule N below
# is the standing refusal.
if any_untrusted_cache
  docs.each do |path, doc|
    next if path.include?('/actions/') || triggers(doc).include?('workflow_call')
    runs_untrusted = (doc['jobs'].is_a?(Hash) ? doc['jobs'] : {}).values.any? { |job| job.is_a?(Hash) && job['if'].to_s.include?('refs/heads/untrusted') }
    next unless runs_untrusted
    next if enforced.include?(File.basename(path))
    failures << "#{path}: can run on the untrusted ref without cache-mode enforcement, so an untrusted cache restore is refused while it keeps the default write grant (split and enforce it first)"
  end
end

# N (Stage 2): no cache restore may run off main except the four reviewed read-only untrusted
# restores. Every restore step, whether it uses actions/cache/restore, the combined actions/cache or
# reaches one through a local composite, either carries the exact top-level term
# github.ref == 'refs/heads/main' in its own if and never mentions the untrusted ref, or it is
# exactly a reviewed untrusted restore (reviewed_untrusted_restore? below) in a workflow of
# UNTRUSTED_RESTORE_WORKFLOWS, whose surroundings the rules after this loop check. A restore gated to
# neither ref (so reachable on the untrusted ref), or gated to untrusted in any other shape, is refused,
# with no dependence on which workflows are enforced.
def reviewed_untrusted_restore?(st)
  return false unless (st.keys - STEP_KEYS).empty? && st['uses'].to_s == PIN
  with = st['with']
  return false unless with.is_a?(Hash) && with.keys.sort == %w[key path]
  return false unless REVIEWED_UNTRUSTED_RESTORES.include?([with['path'].to_s, with['key'].to_s])
  terms = top_terms(st['if'])
  !terms.nil? && terms.sort == UNTRUSTED_RESTORE_TERMS.sort
end

reviewed_restores = {}
docs.each do |path, doc|
  (doc['jobs'].is_a?(Hash) ? doc['jobs'] : {}).each do |name, job|
    next unless job.is_a?(Hash)
    Array(job['steps']).each_with_index do |st, index|
      next unless st.is_a?(Hash)
      kinds = cache_kinds([st])
      next unless kinds.include?(:restore) || kinds.include?(:combined)
      # Do not strip a block scalar down to an apparently main-only expression: surrounding
      # whitespace can turn a wrapped ${{ }} condition into a truthy string. Reject every block
      # style (even |- and >-, whose decoded value can be single-line), plus quoted newlines.
      if block_scalar_ifs.fetch(path).include?(['jobs', name, 'steps', index, 'if']) || st['if'].to_s.match?(/[\r\n]/)
        failures << "#{path}: job #{name}: cache restore step #{st['name'].inspect} has a block-scalar or multiline if; use a single-line main-only expression"
        next
      end
      next if requires?(st['if'], MAIN) && !st['if'].to_s.include?('untrusted')
      if UNTRUSTED_RESTORE_WORKFLOWS.include?(File.basename(path)) && reviewed_untrusted_restore?(st)
        (reviewed_restores[path] ||= []) << st
        next
      end
      failures << "#{path}: job #{name}: cache restore step #{st['name'].inspect} is not main-only (it needs the exact top-level term #{MAIN} in its own if and must not mention the untrusted ref) and is not the reviewed read-only untrusted restore (Linux concern workflow, rust-db and the rust-app shards, the exact terms, path and key of docs/untrusted-readonly-cache.md, Stage 2)"
    end
  end
end

# N2: around a reviewed untrusted restore. The called workflow holds no write permission anywhere
# (the cache grant is the caller's `cache-mode: read`; a write-capable GITHUB_TOKEN or id-token is a
# second way to reach a cache or a release), has no step that saves without the main-only gate, and
# declares the flag as a boolean with the literal default false. Every caller job is the read half
# (untrusted-gated) or the write half (main-gated), PASSES the flag as a literal boolean (an omitted key
# would leave the callee default in force), and only the read half may pass true, and then only with
# the recorded spike that was already merged (spike_gate below).
def write_permission?(value)
  value == 'write-all' || (value.is_a?(Hash) && value.values.any? { |v| v.to_s.include?('write') }) || (value.is_a?(String) && value.include?('write'))
end

def workflow_triggers_input(doc)
  on = doc.key?('on') ? doc['on'] : doc[true]
  on.is_a?(Hash) && on['workflow_call'].is_a?(Hash) && on['workflow_call']['inputs'].is_a?(Hash) ? on['workflow_call']['inputs'] : {}
end

# The recorded spike must be merged before the flag is flipped, and the flipping change must not add or
# alter it (docs/untrusted-readonly-cache.md section 7c). The base side is the explicit
# CACHE_MODE_BASE_DOC, or, in the base-policy pass of a pull request (which runs this checker from main
# against the pull request's tree), the base checkout at RUNNER_TEMP/base-policy. In a pull request's
# own pass the base is unavailable and the base-policy pass is the gate; on a push (the merge) and
# locally the tree's own record is required.
def spike_gate(caller_path, name, failures)
  root = File.dirname(File.dirname(File.dirname(caller_path)))
  tree_doc = File.join(root, 'docs', 'untrusted-readonly-cache.md')
  tree_doc = 'docs/untrusted-readonly-cache.md' unless File.exist?(tree_doc)
  records = ->(file) { File.exist?(file) ? read_text(file).lines.map(&:chomp).select { |l| l.match?(SPIKE_RECORD) } : [] }
  tree = records.call(tree_doc)
  where = "#{caller_path}: job #{name}: #{UNTRUSTED_FLAG}: true"
  unless tree.length == 1
    failures << "#{where} needs exactly one recorded green enforcement spike line in docs/untrusted-readonly-cache.md (section 7c), found #{tree.length}"
    return
  end
  base_doc = ENV['CACHE_MODE_BASE_DOC']
  if base_doc.nil? && ENV['GITHUB_EVENT_NAME'] == 'pull_request' && ENV['RUNNER_TEMP']
    candidate = File.join(ENV['RUNNER_TEMP'], 'base-policy', 'docs', 'untrusted-readonly-cache.md')
    base_doc = candidate if File.exist?(candidate)
    # Fail closed: the base checkout is present (this is the base-policy pass) but its record document
    # is missing or unreadable, so the flip cannot be judged. Only a pull request's own pass, where no
    # base checkout exists at all, falls through to the warning below. A push and a local run (no
    # pull_request event) need the tree's own record, checked above, and have no base to compare.
    if base_doc.nil? && File.directory?(File.join(ENV['RUNNER_TEMP'], 'base-policy'))
      failures << "#{where}: the base-policy checkout has no readable docs/untrusted-readonly-cache.md, so the flip cannot be judged"
      return
    end
  end
  if base_doc.nil?
    warn "cache-mode policy: #{where}: no base document is available (a pull request's own pass); the base-policy pass judges the flip" if ENV['GITHUB_EVENT_NAME'] == 'pull_request'
    return
  end
  unless File.exist?(base_doc)
    failures << "#{where}: the base document #{base_doc} is not readable, so the flip cannot be judged"
    return
  end
  base = records.call(base_doc)
  failures << "#{where} needs the spike record already merged on the base: the base has #{base.length} record line(s), and a change may not add one in the same diff that flips the flag" unless base.length == 1
  failures << "#{where}: the spike record in this change differs from the merged base record; it may not be altered in the diff that flips the flag" if base.length == 1 && base.first != tree.first
end

# N2b: what an untrusted restore's path, key and environment depend on. The restore reads outputs of two
# producer steps (`cargo-home`, `cargo-target`), and anything that runs earlier in the job on the untrusted
# ref can change what those steps compute (the environment and path files, shims on PATH, the target
# directory, the toolchain that private source selects). So, for every job that carries a reviewed
# untrusted restore:
#  - every step that runs before the later producer is on a reviewed allowlist (reviewed_prefix_step?):
#    the control-plane checkout, the shared local actions, the pinned plain `run` steps, the producers,
#    steps gated to main alone (they never run on the untrusted ref), and the toolchain, cache-verify and
#    target-cache local actions, each only with a whole-file hash that is pinned and `with` values that are
#    the reviewed ones. No step that runs private-source code (`npm ci`, the vendor fetch) may precede them.
#  - the job and the workflow set no PATH, BASH_ENV, ENV, HOME, CARGO_*, RUSTC*, RUSTUP_* or NODE_OPTIONS
#    (`env:`), the container is exactly the reviewed digest-pinned expression and `defaults` is exactly
#    the reviewed `run.working-directory: src` (a different container or default shell/directory would
#    change what every step runs in).
#  - the producer steps and the steps between a producer and its restore pass the same allowlist, per job.
#  - the rust-target-cache composite is pinned as a whole file, with `locate` its first step.
# Changing a pinned file is a reviewed change of the constants below, in the same pull request.
CARGO_HOME_PIN = {
  'id' => 'cargo-home', 'shell' => 'bash',
  'run' => "set -euo pipefail\ndir=\"${CARGO_HOME:-${HOME}/.cargo}\"\nif command -v cygpath >/dev/null 2>&1; then\n  dir=\"$(cygpath -m \"${dir}\")\"\nfi\necho \"dir=${dir}\" >> \"${GITHUB_OUTPUT}\"\n"
}.freeze
TARGET_CACHE_ACTION = './.github/actions/rust-target-cache'.freeze
RUST_TARGET_CACHE_FILE_SHA256 = '3acf64ebbe28a924864235b3783894e0a09a1550e3b3c7527b404fbc86e1528d'.freeze
LOCATE_STEP_SHA256 = 'f0731f6e118740f65994e4a90b3a9c03f4e0f1c2b76c00a34ae1216232253c20'.freeze
# Whole action.yml hashes (canonical JSON of the parsed file) of every local action that may run before an
# untrusted restore, so none can be edited (or given a new write to GITHUB_ENV) without this table changing
# in the same reviewed pull request. Each name lists exactly the hash of the file as it is in this tree:
# batch 2 merged #365 and Wave C into rust-toolchain (verify-cargo-cache is #365's, timings is Wave C's),
# #360 (scan-lint) and Wave C into root-setup, and the keyed test ids into source-checkout, sanitize and
# concern-report. A pull request that changes one of these files replaces its hash here, in the same change.
# rust-toolchain is listed only at a version that refuses a `path` toolchain before it runs any rustc or cargo
# command (an earlier version let a checkout run a planted compiler with the runner's environment and path
# files in reach); the hash must also pass toolchain_guard_first? below. It applies only to a job that carries a
# reviewed untrusted restore.
LOCAL_ACTION_FILE_SHA256 = {
  'timings' => %w[ff475be9ed8faa47c3a218041c71505a17f0944fc4d32b9f25b08ae61fd59922],
  'source-checkout' => %w[ac95c29654593720210baa620edc335ecf49f33864f9d96deed73f1f296317b3],
  'egress-audit' => %w[c6c3ff33427b869f38f3dc83800ae92143233b2137922d67d2a2f75aa32f74b5],
  'root-setup' => %w[1f288c476f7598e3fd583b8116994c429c01e3dc30376ea2df1ae9e2affe1dce],
  'drop-root' => %w[2562fdd5b283364bb839c3a547dce05bbea76438ea47c2be5f7efe26942579dc],
  'sanitize' => %w[d93ddb3dcd9012ddadc5c347d83a3f9775e175729156c0457bf377cf30aaa737],
  'concern-report' => %w[49cd2af3e6c48d4e337de083a4bba64111d5578ca13c5ed33b35a187b7878273],
  'shell-artefact' => %w[7f32333abb9633e640ffafdb7e8a6e67d7dcb88474e98135a67cfa5759007e8a],
  'scan-concern' => %w[4fc5337688e8fbff7f62cb8dca21d3ea6a2e8f1593b49979a98adcb845e96306],
  'verify-cargo-cache' => %w[6c38bdfe714317107def1f7cc2c58c5a6293381950b685a3762b2d09de3c1b8a],
  'rust-toolchain' => %w[abec77339a4eba723358e2b8a1a0094a80db7545d92f223b0ddee9c1bea1cfec],
  'rust-target-cache' => [RUST_TARGET_CACHE_FILE_SHA256]
}.freeze
# The toolchain action's refusal of a `path` toolchain (and of every non-plain key), as the text between
# `toolchain_refuse() {` and the last call of `toolchain_check`, in the first step's decoded `run`.
TOOLCHAIN_GUARD_SHA256 = '6eb49f42a7f8ee1177bb05fe0e8f344173f7b751eb4758637fa7e8970eb7be43'.freeze
TOOLCHAIN_GUARD_LAST_CALL = "  [[ ! -f rust-toolchain ]] || toolchain_check rust-toolchain legacy\n".freeze

# True when the action's first step carries the reviewed guard and calls both checks before it runs any
# rustup, rustc or cargo command (comment lines are not commands).
def toolchain_guard_first?(doc)
  step = Array(doc.dig('runs', 'steps')).first
  run = step.is_a?(Hash) ? step['run'].to_s : ''
  start = run.index('  toolchain_refuse() {')
  stop = run.index(TOOLCHAIN_GUARD_LAST_CALL)
  return false unless start && stop && start < stop
  return false unless Digest::SHA256.hexdigest(run[start...(stop + TOOLCHAIN_GUARD_LAST_CALL.length)]) == TOOLCHAIN_GUARD_SHA256
  code = run.lines.reject { |l| l.strip.start_with?('#') }.join
  tool = code.index(/(^|[\s;(&|`])(rustup|rustc|cargo)\s/)
  toml = code.index('toolchain_check rust-toolchain.toml toml')
  legacy = code.index('toolchain_check rust-toolchain legacy')
  !tool.nil? && !toml.nil? && !legacy.nil? && toml < tool && legacy < tool
end

# The exact `with` of each shared local action (the canonical JSON of the step's whole `with`, an absent
# `with` counting as {}), by name. egress-audit appears in two phases; timings only at the start of the job.
PREFIX_ACTION_WITH_SHA256 = {
  'timings' => %w[d40321da9156f08b91b3fc4365a68317b0172bb0838462cc27c054e4a0391fe4],
  'source-checkout' => %w[ca094fba0d5cf639b86a79a80a9606c6ae3627b276405e107804327def4c2251],
  'egress-audit' => %w[
    0425e778b9fce98006d5531cb64bb8bb50a56c8cad1a75093d899733921fc6b7
    a010edbb307c54ebe97a693ad92bfe06f9298824825a0284b11936d465f7475f
  ],
  'scan-concern' => %w[71c7bea029bd1a9231abf6373a5d518bb45d2fa2cb449b10adb0dc01484dda5f],
  'root-setup' => %w[422c143f47d2ac7910b7348b5b4e00f68ccbf86e5f9cfa1d51d350d089bb2b92],
  'drop-root' => %w[7fea94b67beba935a17fd01ddee06f63266769df67633ff6f39a64eddb434652],
  'sanitize' => %w[44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a],
  'concern-report' => %w[44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a],
  'shell-artefact' => %w[44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a]
}.freeze
# The plain `run` steps ahead of the producers, by name; each is allowed only with a pinned body (the whole
# step but its name hashes to a listed value).
PREFIX_RUN_STEP_SHA256 = {
  'Validate protected call input' => %w[624c9205f6916c4655ad74b5696f61106a738aa4a132bcd2b48c2be5f308b90d],
  'Install jq and Ruby in the visual container' => %w[31b233667e9d4321de83ef2d88b058544421b485da66a0b7f121935b6dc25b16],
  'Select the egress mode' => %w[40289952cb6c982cc79cd49ea9fbbe9a8e96833c5918b8f7e71ad8d6b3d7ee8a],
  'Read the suite contract for this concern' => %w[6ea7f99c7b3ff6f95440e3e1636ecf867b0a9a47338519a328a9905950870995],
  'Refuse test files with no suite owner before any build' => %w[b7fcf77c374702efd68183b00329bb0a09c4277bb63df553b82728fff19137b1]
}.freeze
REVIEWED_CONTAINER_SHA256 = '1681a3dd8f4a7b43784aac2160f99c2524bc5af526d87cf8dc0ecb11ee1e4f49'.freeze
REVIEWED_DEFAULTS = { 'run' => { 'working-directory' => 'src' } }.freeze
FORBIDDEN_ENV_KEY = /\A(PATH|BASH_ENV|ENV|HOME|CARGO_.*|RUSTC.*|RUSTUP_.*|NODE_OPTIONS)\z/i
PINNED_CHECKOUT = %r{\Aactions/checkout@[0-9a-f]{40}\z}
# The control-plane checkout: a pinned commit with exactly these inputs (no repository, path, ref or token).
CHECKOUT_WITH = { 'fetch-depth' => 1, 'persist-credentials' => false }.freeze
CACHE_HIT_REF = /\A\$\{\{ steps\.[a-z0-9-]+\.outputs\.cache-hit \}\}\z/

def canonical_json(value)
  case value
  when Hash then value.map { |k, v| [k.to_s, canonical_json(v)] }.sort_by(&:first).to_h
  when Array then value.map { |v| canonical_json(v) }
  else value
  end
end

def canonical_hash(value)
  Digest::SHA256.hexdigest(JSON.generate(canonical_json(value)))
end

# The parsed action.yml of a local action: from the files given, else from the workflow's own tree.
def local_action_doc(path, docs, name)
  rel = ".github/actions/#{name}/action.yml"
  doc = docs.find { |k, _| k.end_with?(rel) }&.last
  return doc if doc.is_a?(Hash)
  root = File.dirname(File.dirname(File.dirname(path)))
  file = File.join(root, rel)
  file = rel unless File.file?(file)
  File.file?(file) ? (load(file) rescue nil) : nil
end

def local_action_hash(path, docs, name)
  doc = local_action_doc(path, docs, name)
  doc.is_a?(Hash) ? canonical_hash(doc) : nil
end

# A hash-pinned local action step with only the reviewed keys and `with` values (no env, no
# continue-on-error, no other step key), or false.
def pinned_local_action_step?(path, docs, st)
  action = st['uses'].to_s
  return false unless action.start_with?('./.github/actions/')
  name = action.delete_prefix('./.github/actions/')
  wanted = LOCAL_ACTION_FILE_SHA256[name]
  # The egress audit alone is best-effort by design (continue-on-error); no other action may be.
  allowed_keys = %w[name id if uses with] + (name == 'egress-audit' ? %w[continue-on-error] : [])
  return false unless wanted && (st.keys - allowed_keys).empty?
  return false unless wanted.include?(local_action_hash(path, docs, name))
  with = st['with']
  with = {} if with.nil?
  return false unless with.is_a?(Hash)
  case name
  when *PREFIX_ACTION_WITH_SHA256.keys
    PREFIX_ACTION_WITH_SHA256[name].include?(canonical_hash(with))
  when 'rust-toolchain'
    toolchain_guard_first?(local_action_doc(path, docs, name)) &&
      with == { 'concern' => "${{ (inputs.concern == 'scan-security' || inputs.concern == 'scan-lint') && 'rust-app' || inputs.concern }}" }
  when 'verify-cargo-cache'
    with.keys.sort == %w[cache-hit os-label sources-dir] && with['sources-dir'] == '${{ steps.cargo-home.outputs.dir }}' &&
      with['cache-hit'].to_s.match?(CACHE_HIT_REF) && with['os-label'].to_s.match?(/\A[A-Za-z]+\z/)
  else # rust-target-cache: a mode and the reviewed inputs, nothing else
    (with.keys - %w[mode group features dir cache-hit os-label deny-door]).empty? && %w[locate restored save].include?(with['mode']) &&
      (!with.key?('deny-door') || (with['mode'] == 'restored' && %w[true false].include?(with['deny-door']))) &&
      with.fetch('dir', '${{ steps.cargo-target.outputs.dir }}') == '${{ steps.cargo-target.outputs.dir }}' &&
      (!with.key?('cache-hit') || with['cache-hit'].to_s.match?(CACHE_HIT_REF)) && with['os-label'].to_s.match?(/\A[A-Za-z]+\z/)
  end
end

def reviewed_prefix_step?(path, docs, st)
  return true if %w[cargo-home cargo-target].include?(st['id']) # their exact shape is checked on its own
  return true if requires?(st['if'], MAIN) && !st['if'].to_s.include?('untrusted') # never runs on the untrusted ref
  return true if reviewed_untrusted_restore?(st)
  action = st['uses'].to_s
  return true if action.match?(PINNED_CHECKOUT) && (st.keys - %w[name id if uses with]).empty? && st['with'] == CHECKOUT_WITH
  if action.empty? && st.key?('run')
    wanted = PREFIX_RUN_STEP_SHA256[st['name'].to_s]
    return !wanted.nil? && wanted.include?(canonical_hash(st.reject { |k, _| k == 'name' }))
  end
  pinned_local_action_step?(path, docs, st)
end

def producer_step_failures(path, doc, docs, failures)
  jobs = doc['jobs'].is_a?(Hash) ? doc['jobs'] : {}
  restores = [['cargo-sources-untrusted', 'cargo-home'], ['cargo-target-cache-untrusted', 'cargo-target']]
  bad_env = lambda do |where, env|
    next unless env.is_a?(Hash)
    env.each_key { |k| failures << "#{path}: #{where} sets #{k}, which could redirect the untrusted restore's tools or paths" if k.to_s.match?(FORBIDDEN_ENV_KEY) }
  end
  bad_env.call('the workflow env', doc['env'])
  failures << "#{path}: a workflow-level `defaults` must not exist beside an untrusted restore" if doc.key?('defaults')
  jobs.each do |job_name, job|
    next unless job.is_a?(Hash)
    steps = steps_of(job).grep(Hash)
    next unless steps.any? { |st| restores.any? { |rid, _| st['id'] == rid } }
    bad_env.call("job #{job_name} env", job['env'])
    container = job['container']
    unless container.nil? || (container.is_a?(String) && Digest::SHA256.hexdigest(container) == REVIEWED_CONTAINER_SHA256)
      failures << "#{path}: job #{job_name}: the container must be absent or exactly the reviewed digest-pinned expression"
    end
    failures << "#{path}: job #{job_name}: services must be absent beside an untrusted restore (a service container shares the job's network and volumes)" unless job['services'].nil?
    unless job['defaults'].nil? || job['defaults'] == REVIEWED_DEFAULTS
      failures << "#{path}: job #{job_name}: defaults must be absent or exactly the reviewed run.working-directory: src"
    end
    one = lambda do |id|
      found = steps.select { |st| st['id'] == id }
      failures << "#{path}: job #{job_name}: the untrusted restore needs exactly one step with id #{id} (found #{found.length})" unless found.length == 1
      found.length == 1 ? found.first : nil
    end
    if (home = one.call('cargo-home'))
      rest = home.reject { |k, _| %w[name if].include?(k) }
      failures << "#{path}: step cargo-home differs from the pinned shape its untrusted restore path depends on" unless rest == CARGO_HOME_PIN
    end
    if (target = one.call('cargo-target'))
      with = target['with']
      shape_ok = (target.keys - %w[name id if uses with]).empty? && target['uses'].to_s == TARGET_CACHE_ACTION && with.is_a?(Hash) &&
                 with.keys.sort == %w[features group mode os-label] && with['mode'] == 'locate' &&
                 with['os-label'].is_a?(String) && with['os-label'].match?(/\A[A-Za-z]+\z/)
      failures << "#{path}: step cargo-target differs from the pinned rust-target-cache locate shape its untrusted restore path and key depend on" unless shape_ok
    end
    ids = steps.map { |st| st['id'] }
    last = restores.map { |_, pid| ids.index(pid) }.compact.max || 0
    steps.first(last).each do |st|
      bad_env.call("step #{st['name'].inspect} env", st['env'])
      next if reviewed_prefix_step?(path, docs, st)
      failures << "#{path}: job #{job_name}: step #{st['name'].inspect} runs before the producers of the untrusted restore and is not on the reviewed allowlist (it could change the environment, PATH or files their outputs depend on; project-code steps belong after the restores)"
    end
    restores.each do |rid, pid|
      ri = ids.index(rid)
      pi = ids.index(pid)
      next if ri.nil? || pi.nil?
      failures << "#{path}: job #{job_name}: step #{pid} must run before the untrusted restore #{rid} that uses its outputs" if pi > ri
      next if pi > ri
      steps[(pi + 1)...ri].each do |st|
        next if reviewed_prefix_step?(path, docs, st)
        failures << "#{path}: job #{job_name}: step #{st['name'].inspect} sits between #{pid} and the untrusted restore #{rid}: it must be gated to main alone or be a reviewed, hash-pinned step"
      end
    end
    # The compiled restore is followed directly by its restore-time strip, which carries deny-door: the
    # strip removes every OpenSSL door crate output (section 4.5), so a job that restores for the rust-app
    # shards or rust-db never holds compiled OpenSSL. A missing, moved or weakened strip is refused.
    if (ti = ids.index('cargo-target-cache-untrusted'))
      strip = steps[ti + 1]
      hit = '${{ steps.cargo-target-cache-untrusted.outputs.cache-hit }}'
      strip_ok = strip.is_a?(Hash) && (strip.keys - %w[name id if uses with]).empty? && strip['uses'].to_s == TARGET_CACHE_ACTION &&
                 top_terms(strip['if'])&.sort == UNTRUSTED_RESTORE_TERMS.sort && strip['with'].is_a?(Hash) &&
                 strip['with'].reject { |k, _| k == 'os-label' } == { 'mode' => 'restored', 'dir' => '${{ steps.cargo-target.outputs.dir }}', 'cache-hit' => hit, 'deny-door' => 'true' } &&
                 strip['with']['os-label'].to_s.match?(/\A[A-Za-z]+\z/)
      failures << "#{path}: job #{job_name}: the untrusted compiled restore must be followed directly by the restore-time strip with deny-door: 'true' on exactly the untrusted-restore terms (compiled OpenSSL door output is never restored into an untrusted job)" unless strip_ok
    end
  end

  # The composite behind `cargo-target`: read from the files given, or else from the workflow's own tree
  # (the workflow policy passes workflows only).
  composite = local_action_doc(path, docs, 'rust-target-cache')
  unless composite.is_a?(Hash)
    failures << "#{path}: the untrusted restore depends on the rust-target-cache composite, which could not be read"
    return
  end
  action_path = '.github/actions/rust-target-cache/action.yml'
  failures << "#{action_path}: the whole file must match the reviewed content hash its untrusted restore depends on (every step after locate runs before the restore reads the outputs)" unless canonical_hash(composite) == RUST_TARGET_CACHE_FILE_SHA256
  outputs = composite['outputs']
  outputs_ok = outputs.is_a?(Hash) && outputs.keys.sort == %w[dir key] &&
               outputs['dir'].is_a?(Hash) && outputs['dir']['value'] == '${{ steps.locate.outputs.dir }}' &&
               outputs['key'].is_a?(Hash) && outputs['key']['value'] == '${{ steps.locate.outputs.key }}'
  failures << "#{action_path}: the dir and key outputs must be exactly the locate step's outputs" unless outputs_ok
  composite_steps = Array(composite.dig('runs', 'steps')).grep(Hash)
  # Any id that is `locate` in another case counts as a second locate step, so a look-alike cannot stand in.
  look_alikes = composite_steps.select { |st| st['id'].to_s.casecmp?('locate') }
  locate = look_alikes.select { |st| st['id'] == 'locate' }
  if look_alikes.length != 1 || locate.length != 1
    failures << "#{action_path}: expected exactly one step with id locate, and no other-case look-alike (found #{look_alikes.length})"
    return
  end
  # STRUCTURAL: `locate` is the first step of the composite, so nothing in it can run before it. The
  # whole-file hash above covers the steps after it; this keeps the rule explicit and the message clear.
  if composite_steps.first.equal?(locate.first)
    body = locate.first.reject { |k, _| %w[name if id].include?(k) }
    failures << "#{action_path}: the locate step no longer matches the reviewed content hash its untrusted restore depends on" unless canonical_hash(body) == LOCATE_STEP_SHA256
  else
    failures << "#{action_path}: the locate step must be the first step of the composite (index 0): any step before it could change how it computes dir and key"
  end
  # Defence in depth only: no other step may name the runner's environment or path files.
  composite_steps.each do |st|
    next if st.equal?(locate.first)
    failures << "#{action_path}: step #{st['name'].to_s.inspect} may not write GITHUB_ENV or GITHUB_PATH" if JSON.generate(st).match?(/GITHUB_(ENV|PATH)/i)
  end
end

reviewed_restores.each_key do |path|
  doc = docs.fetch(path)
  producer_step_failures(path, doc, docs, failures)
  base = File.basename(path)
  failures << "#{path}: a workflow with an untrusted restore must set no write permission at workflow level" if write_permission?(doc['permissions'])
  declared = workflow_triggers_input(doc)[UNTRUSTED_FLAG]
  unless declared.is_a?(Hash) && declared['type'] == 'boolean' && declared['default'] == false && declared['required'] == false
    failures << "#{path}: input #{UNTRUSTED_FLAG} must be declared type boolean, required false, with the literal default false (got #{declared.inspect})"
  end
  (doc['jobs'].is_a?(Hash) ? doc['jobs'] : {}).each do |name, job|
    next unless job.is_a?(Hash)
    failures << "#{path}: job #{name}: a workflow with an untrusted restore must set no write permission (a write-capable token beside a read-only cache)" if write_permission?(job['permissions'])
    next unless cache_kinds(steps_of(job)).any? { |k| %i[save combined].include?(k) }
    failures << "#{path}: job #{name}: a workflow with an untrusted restore must not save a cache from the same job without the main-only gate" unless Array(job['steps']).select { |st| st.is_a?(Hash) && cache_kinds([st]).any? { |k| %i[save combined].include?(k) } }.all? { |st| requires?(st['if'], MAIN) && !st['if'].to_s.include?('untrusted') }
  end
  callers = docs.select do |other_path, other|
    !other_path.include?('/actions/') && (other['jobs'].is_a?(Hash) ? other['jobs'] : {}).values.any? { |job| job.is_a?(Hash) && job['uses'].to_s == "./.github/workflows/#{base}" }
  end
  callers.each do |caller_path, caller_doc|
    failures << "#{caller_path}: a workflow-level write permission beside an untrusted restore" if write_permission?(caller_doc['permissions'])
    caller_doc['jobs'].each do |name, job|
      next unless job.is_a?(Hash) && job['uses'].to_s == "./.github/workflows/#{base}"
      mode = job['cache-mode']
      failures << "#{caller_path}: job #{name} calls #{base}, which has an untrusted restore, and must be cache-mode read (untrusted half) or write (main half), not #{mode.inspect}" unless %w[read write].include?(mode)
      failures << "#{caller_path}: job #{name}: no write permission beside an untrusted restore (a write-capable token)" if write_permission?(job['permissions'])
      with = job['with'].is_a?(Hash) ? job['with'] : {}
      unless with.key?(UNTRUSTED_FLAG)
        failures << "#{caller_path}: job #{name} calls #{base} and must pass #{UNTRUSTED_FLAG} explicitly as a literal true or false (an omitted key leaves the callee's default in force)"
        next
      end
      flag = with[UNTRUSTED_FLAG]
      unless [true, false].include?(flag)
        failures << "#{caller_path}: job #{name}: #{UNTRUSTED_FLAG} must be a literal true or false, never an expression or an input (got #{flag.inspect})"
        next
      end
      next unless flag
      unless mode == 'read' && requires?(job['if'], UNTRUSTED)
        failures << "#{caller_path}: job #{name}: only the read-only untrusted half (cache-mode read, the exact top-level term #{UNTRUSTED}) may pass #{UNTRUSTED_FLAG}: true"
      end
      spike_gate(caller_path, name, failures)
    end
  end
end

# N3: the flag is reachable only through the reviewed routes: its declaration in the called workflow, the
# `with` key of a job that calls that workflow, and the `if` of a step whose terms are exactly the reviewed
# untrusted-restore terms. Any other mention, in any workflow or composite given, is refused (an env
# value, a matrix entry, another step's if, a composite input).
def flag_mentions(node, path, found)
  case node
  when Hash
    node.each do |k, v|
      found << [path + [k], :key] if k.to_s.include?(UNTRUSTED_FLAG)
      flag_mentions(v, path + [k], found)
    end
  when Array
    node.each_with_index { |v, i| flag_mentions(v, path + [i], found) }
  when String
    found << [path, :value] if node.include?(UNTRUSTED_FLAG)
  end
end

docs.each do |path, doc|
  base = File.basename(path)
  found = []
  flag_mentions(doc, [], found)
  next if found.empty?
  is_callee = UNTRUSTED_RESTORE_WORKFLOWS.include?(base)
  found.each do |where, kind|
    ok =
      if kind == :key && where.length == 4 && ['on', true].include?(where[0]) && where[1] == 'workflow_call' && where[2] == 'inputs' && where[3] == UNTRUSTED_FLAG
        is_callee
      elsif kind == :key && where.length == 4 && where[0] == 'jobs' && where[2] == 'with' && where[3] == UNTRUSTED_FLAG
        job = doc.dig('jobs', where[1])
        job.is_a?(Hash) && UNTRUSTED_RESTORE_WORKFLOWS.any? { |w| job['uses'].to_s == "./.github/workflows/#{w}" }
      elsif kind == :value && is_callee && where.length == 5 && where[0] == 'jobs' && where[2] == 'steps' && where[4] == 'if'
        terms = top_terms(doc.dig('jobs', where[1], 'steps', where[3], 'if'))
        !terms.nil? && terms.sort == UNTRUSTED_RESTORE_TERMS.sort
      else
        false
      end
    failures << "#{path}: #{UNTRUSTED_FLAG} is mentioned at #{where.map(&:to_s).join('.')} outside the reviewed routes (its declaration, a caller's with key, and the if of a step with exactly the reviewed untrusted-restore terms)" unless ok
  end
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
      failures << "#{path}: the cache-deleting workflow must read no secret" if read_text(path).match?(/secrets\./)
    when 'weekly-validation.yml'
      if job.nil? || !requires?(job['if'], MAIN)
        failures << "#{path}: #{where}: actions: write (dispatch) needs a job gated by the exact top-level term #{MAIN}"
      end
    else
      failures << "#{path}: #{where}: actions: write is held to cache-prune.yml and the weekly dispatch job (it can delete cache entries, which cache-mode does not govern)"
    end
  end
end

# The policy gate never restores or saves a cache: base-pass runs the base commit's policy over a
# pull request's tree, so it holds exactly cache-mode: none (not read, and never write).
docs.each do |path, doc|
  next unless File.basename(path) == 'validate-public-changes.yml'
  job = doc['jobs'].is_a?(Hash) ? doc['jobs']['base-pass'] : nil
  unless job.is_a?(Hash)
    failures << "#{path}: job base-pass is missing or renamed; the policy gate's job must exist and declare cache-mode: none"
    next
  end
  failures << "#{path}: job base-pass must declare cache-mode: none; the policy gate never restores or saves a cache" unless job['cache-mode'] == 'none'
end

if failures.empty?
  puts "cache-mode policy: #{docs.size} workflows checked"
else
  warn failures.uniq.join("\n")
  exit 1
end
