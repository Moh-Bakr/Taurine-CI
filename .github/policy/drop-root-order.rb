# Root-removal ordering check (finding H2; see check_drop_root_order in lib.sh).
# Usage: ruby drop-root-order.rb <workflow.yml>
#
# In every job that enters the source-read environment, after the step that revokes the
# source token:
#  1. exactly one step calls the drop-root composite;
#  2. every step between the revoke and drop-root is a reviewed pre-root step: a listed
#     composite or Action, or plain shell that runs no project command (Docker and sudo are
#     allowed there, because that is where root-needing work belongs);
#  3. (cache ordering, docs/untrusted-readonly-cache.md P3) every actions/cache restore step, and every
#     combined actions/cache step, comes after drop-root, so after the revoke and the root removal, and
#     exists only in a source-read job (no job without the environment restores a cache);
#  3b. every restore gated to the untrusted ref (i) is preceded, after drop-root, only by reviewed
#     steps that run no source-controlled code (the shared composites, the toolchain composite, the
#     cache locate and verify steps, the suite-contract and Cargo-home steps, whose whole bodies are pinned, other cache restores), so
#     the token-holding restore cannot be reached through the environment by project code; and (ii) is
#     followed directly by its verifier, whose exact shape is pinned (its if terms, its with keys and
#     values, its cache-hit input taken from that restore's id, and no other step key), so it cannot be
#     neutered (a constant-false condition, a literal cache-hit, continue-on-error, another directory);
#  4. no workflow step after drop-root calls sudo, or Docker unless drop-root keeps Docker for
#     that job, and no composite called after drop-root contains sudo (the egress audit's
#     best-effort `sudo -n` fallbacks excepted).
require 'yaml'
require_relative 'cache-expression'

workflow = ARGV[0]
doc = YAML.safe_load(File.read(workflow), aliases: false)
DROP = './.github/actions/drop-root'
PRE_DROP_USES = [
  %r{\A\./\.github/actions/(egress-audit|timings|sanitize|concern-report|mobile-report|root-setup)\z},
  %r{\A\./\.github/actions/live-start-[a-z]+\z},
  # Only the Semgrep container run (checked below): the scanners themselves come after.
  %r{\A\./\.github/actions/scan-concern\z},
  # A cache restore is not here: it extracts with absolute paths as the job user, so it comes
  # after drop-root, never between the revoke and the root removal (docs/untrusted-readonly-cache.md, P3).
  %r{\Aactions/setup-node@[0-9a-f]{40}\z}
].freeze
PROJECT_COMMAND = /^\s*(sudo\s+)?(npm|npx|pnpm|yarn|node|cargo|rustup|rustc|dotnet|nuget|xcodebuild|xcrun|gradle|gradlew|make|cmake|pip|pip3|python|python3|ruby|brew|choco|vcpkg|bash\s+scripts\/|sh\s+scripts\/|\.\/scripts\/)(\s|$)/
SUDO = /(^|[\s;&|(`])sudo(\s|$)/
DOCKER = /(^|[\s;&|(`])docker\s/
SUDO_ALLOWED_COMPOSITES = %w[egress-audit].freeze

CACHE_USES = %r{\Aactions/cache(/restore)?@}
UNTRUSTED_REF = "github.ref == 'refs/heads/untrusted'"
UNTRUSTED_TERMS = [UNTRUSTED_REF, 'inputs.untrusted_readonly_cache', "inputs.concern == 'rust-db'"].freeze
# Steps that may sit between drop-root and an untrusted restore: they run no source-controlled code.
PRE_RESTORE_COMPOSITES = %w[sanitize concern-report shell-artefact rust-toolchain rust-target-cache verify-cargo-cache].freeze
# The two `run` steps that may sit ahead of an untrusted restore. Their whole body is pinned, not only
# their id: an id alone would let a source-controlled command (`bash src/evil.sh`) run with the cache
# token reachable. Every key but the free-text `name` must equal the pin exactly.
PRE_RESTORE_RUN_PINS = {
  'suite-contract' => {
    'id' => 'suite-contract',
    'shell' => 'bash',
    'working-directory' => '${{ github.workspace }}',
    'env' => { 'CONCERN' => '${{ inputs.concern }}', 'CI_SUITE_SELECTION' => '${{ inputs.suite_selection }}' },
    'run' => "set -euo pipefail\nruby .github/policy/suite-contract.rb .github/ci-matrix.json \"${CONCERN}\" \"${GITHUB_WORKSPACE}/src\" >> \"${GITHUB_OUTPUT}\"\n"
  },
  'cargo-home' => {
    'id' => 'cargo-home',
    'if' => "${{ inputs.concern == 'taurine-cli' || startsWith(inputs.concern, 'rust-') || inputs.concern == 'scan-security' }}",
    'shell' => 'bash',
    'run' => "set -euo pipefail\ndir=\"${CARGO_HOME:-${HOME}/.cargo}\"\nif command -v cygpath >/dev/null 2>&1; then\n  dir=\"$(cygpath -m \"${dir}\")\"\nfi\necho \"dir=${dir}\" >> \"${GITHUB_OUTPUT}\"\n"
  }
}.freeze

def pinned_run_step?(step)
  pin = PRE_RESTORE_RUN_PINS[step['id'].to_s]
  !pin.nil? && !step.key?('uses') && step.reject { |k, _| k == 'name' } == pin
end

def terms_equal?(value, wanted)
  terms = CacheExpression.top_terms(value)
  !terms.nil? && terms.sort == wanted.sort
end

# The pinned shape of the step after an untrusted restore; returns an error string or nil.
def verifier_error(restore, verifier)
  rid = restore['id']
  return 'the restore has no id for its verifier to name' unless rid.is_a?(String) && rid.match?(/\A[a-z0-9-]+\z/)
  return 'the verifier has keys other than name, if, uses and with' unless (verifier.keys - %w[name if uses with]).empty? && verifier.key?('with')
  return 'the verifier does not run on exactly the untrusted-restore terms' unless terms_equal?(verifier['if'], UNTRUSTED_TERMS)
  with = verifier['with']
  return 'the verifier has no with' unless with.is_a?(Hash)
  hit = "${{ steps.#{rid}.outputs.cache-hit }}"
  label = with['os-label']
  return 'the verifier os-label must be a plain literal' unless label.is_a?(String) && label.match?(/\A[A-Za-z]+\z/)
  path = restore.dig('with', 'path').to_s
  if path.include?('registry/cache')
    return 'the verifier is not verify-cargo-cache' unless verifier['uses'].to_s == './.github/actions/verify-cargo-cache'
    wanted = { 'sources-dir' => '${{ steps.cargo-home.outputs.dir }}', 'cache-hit' => hit, 'os-label' => label }
  elsif path.include?('debug/')
    return 'the verifier is not rust-target-cache in restored mode' unless verifier['uses'].to_s == './.github/actions/rust-target-cache'
    wanted = { 'mode' => 'restored', 'dir' => '${{ steps.cargo-target.outputs.dir }}', 'cache-hit' => hit, 'os-label' => label }
  else
    return 'the restore path is not a reviewed cache path'
  end
  with == wanted ? nil : "the verifier with must be exactly #{wanted.inspect}"
end

def code_lines(text)
  text.to_s.each_line.reject { |l| l.strip.start_with?('#') }
end

failures = []
(doc['jobs'] || {}).each do |job_id, job|
  next unless job.is_a?(Hash)
  env = job['environment']
  env_name = (env.is_a?(Hash) ? env['name'] : env).to_s
  source_read = env_name == 'source-read' || env_name == '$' + '{{ inputs.environment }}'
  (job['steps'] || []).each do |st|
    next unless st.is_a?(Hash) && st['uses'].to_s.match?(CACHE_USES) && !st['uses'].to_s.start_with?('actions/cache/save@')
    failures << "job #{job_id}: cache step #{st['name'].inspect} is in a job that does not enter the source-read environment; restores belong only to source-read jobs after drop-root" unless source_read
  end
end
root = File.expand_path('../..', File.dirname(File.expand_path(workflow)))
(doc['jobs'] || {}).each do |job_id, job|
  env = job['environment']
  env_name = (env.is_a?(Hash) ? env['name'] : env).to_s
  next unless env_name == 'source-read' || env_name == '$' + '{{ inputs.environment }}'
  steps = job['steps'] || []
  revoke_at = steps.index { |st| st['uses'].to_s == './.github/actions/source-checkout' }
  revoke_at ||= steps.index { |st| st['run'].to_s.include?('installation/token') }
  next if revoke_at.nil? # revocation-order.rb reports a job with no revoke
  drops = steps.each_index.select { |i| steps[i]['uses'].to_s == DROP }
  if drops.length != 1
    failures << "job #{job_id}: must call #{DROP} exactly once (found #{drops.length})"
    next
  end
  drop_at = drops.first
  if drop_at < revoke_at
    failures << "job #{job_id}: drop-root runs before the source token is revoked"
    next
  end
  keep_docker = !steps[drop_at].dig('with', 'keep-docker').to_s.strip.empty?
  steps[(revoke_at + 1)...drop_at].each do |st|
    label = st['name'].inspect
    if st['uses']
      unless PRE_DROP_USES.any? { |re| re.match?(st['uses'].to_s) }
        failures << "job #{job_id}: step #{label} (#{st['uses']}) runs before drop-root; only reviewed pre-root steps may"
      end
      if st['uses'].to_s == './.github/actions/scan-concern' && st.dig('with', 'scanner') != 'semgrep-container'
        failures << "job #{job_id}: step #{label} runs a scanner before drop-root; only scanner: semgrep-container may"
      end
    end
    code_lines(st['run']).each do |line|
      failures << "job #{job_id}: step #{label} runs a project command before drop-root: #{line.strip[0, 60]}" if PROJECT_COMMAND.match?(line)
    end
  end
  steps.each_with_index do |st, i|
    next unless st['uses'].to_s.match?(CACHE_USES) && !st['uses'].to_s.start_with?('actions/cache/save@')
    label = st['name'].inspect
    failures << "job #{job_id}: cache restore #{label} runs before the root removal (it must follow the source revoke and drop-root)" if i <= drop_at
    next unless st['if'].to_s.include?('refs/heads/untrusted')
    if i > drop_at
      steps[(drop_at + 1)...i].each do |before|
        uses = before['uses'].to_s
        ok = if uses.start_with?('./.github/actions/')
               name = uses.delete_prefix('./.github/actions/')
               PRE_RESTORE_COMPOSITES.include?(name) &&
                 (name != 'rust-target-cache' || %w[locate restored].include?(before.dig('with', 'mode')))
             elsif uses.start_with?('actions/cache/restore@')
               true
             else
               uses.empty? && pinned_run_step?(before)
             end
        failures << "job #{job_id}: step #{before['name'].inspect} runs before untrusted cache restore #{label} and is not a reviewed step that runs no source-controlled code (the restore holds the cache token; run project-controlled steps after it)" unless ok
      end
    end
    verifier = steps[i + 1]
    if st['uses'].to_s.start_with?('actions/cache/restore@') && verifier.is_a?(Hash)
      error = verifier_error(st, verifier)
      failures << "job #{job_id}: untrusted cache restore #{label} must be followed directly by its pinned verifier: #{error}" if error
    else
      failures << "job #{job_id}: untrusted cache restore #{label} must be a plain actions/cache/restore followed directly by its verifier"
    end
  end
  steps[(drop_at + 1)..].each do |st|
    label = st['name'].inspect
    code_lines(st['run']).each do |line|
      failures << "job #{job_id}: step #{label} calls sudo after drop-root: #{line.strip[0, 60]}" if SUDO.match?(line)
      failures << "job #{job_id}: step #{label} calls Docker after drop-root closed it: #{line.strip[0, 60]}" if !keep_docker && DOCKER.match?(line)
    end
    next unless (m = %r{\A\./\.github/actions/([a-z0-9-]+)\z}.match(st['uses'].to_s))
    next if SUDO_ALLOWED_COMPOSITES.include?(m[1])
    action = File.join(root, '.github/actions', m[1], 'action.yml')
    next unless File.file?(action)
    composite_steps = ((YAML.safe_load(File.read(action), aliases: false) || {})['runs'] || {})['steps'] || []
    if composite_steps.any? { |cs| code_lines(cs['run']).any? { |l| SUDO.match?(l) } }
      failures << "job #{job_id}: composite #{m[1]} contains sudo and is called after drop-root"
    end
  end
end
unless failures.empty?
  warn failures.join("\n")
  exit 1
end
