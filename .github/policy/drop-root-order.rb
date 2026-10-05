# Root-removal ordering check (finding H2; see check_drop_root_order in lib.sh).
# Usage: ruby drop-root-order.rb <workflow.yml>
#
# In every job that enters the source-read environment, after the step that revokes the
# source token:
#  1. exactly one step calls the drop-root composite;
#  2. every step between the revoke and drop-root is a reviewed pre-root step: a listed
#     composite or Action, or plain shell that runs no project command (Docker and sudo are
#     allowed there, because that is where root-needing work belongs);
#  3. no workflow step after drop-root calls sudo, or Docker unless drop-root keeps Docker for
#     that job, and no composite called after drop-root contains sudo (the egress audit's
#     best-effort `sudo -n` fallbacks excepted).
require 'yaml'

workflow = ARGV[0]
doc = YAML.safe_load(File.read(workflow), aliases: false)
DROP = './.github/actions/drop-root'
PRE_DROP_USES = [
  %r{\A\./\.github/actions/(egress-audit|timings|sanitize|concern-report|mobile-report|root-setup)\z},
  %r{\A\./\.github/actions/live-start-[a-z]+\z},
  # Only the Semgrep container run (checked below): the scanners themselves come after.
  %r{\A\./\.github/actions/scan-concern\z},
  %r{\Aactions/(setup-node|cache/restore)@[0-9a-f]{40}\z}
].freeze
PROJECT_COMMAND = /^\s*(sudo\s+)?(npm|npx|pnpm|yarn|node|cargo|rustup|rustc|dotnet|nuget|xcodebuild|xcrun|gradle|gradlew|make|cmake|pip|pip3|python|python3|ruby|brew|choco|vcpkg|bash\s+scripts\/|sh\s+scripts\/|\.\/scripts\/)(\s|$)/
SUDO = /(^|[\s;&|(`])sudo(\s|$)/
DOCKER = /(^|[\s;&|(`])docker\s/
SUDO_ALLOWED_COMPOSITES = %w[egress-audit].freeze

def code_lines(text)
  text.to_s.each_line.reject { |l| l.strip.start_with?('#') }
end

failures = []
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
