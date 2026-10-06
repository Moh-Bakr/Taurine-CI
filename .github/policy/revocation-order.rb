# Token-revocation ordering check (see check_revocation_order in lib.sh).
# Usage: ruby revocation-order.rb <workflow.yml>

require 'yaml'
workflow = ARGV[0]
doc = YAML.safe_load(File.read(workflow), aliases: false)
project_command = /^\s*(sudo\s+)?(npm|npx|pnpm|yarn|node|cargo|rustup|rustc|dotnet|nuget|xcodebuild|xcrun|gradle|gradlew|make|cmake|pip|pip3|python|python3|ruby|brew|docker|choco|vcpkg|bash\s+scripts\/|sh\s+scripts\/|\.\/scripts\/)(\s|$)/
allowed_before = [
  /\Aactions\/checkout@/,
  /\Aactions\/create-github-app-token@/,
  # The timer is a reviewed composite that only records a timestamp.
  /\A\.\/\.github\/actions\/timings\z/
]
failures = []
(doc['jobs'] || {}).each do |job_id, job|
  env = job['environment']
  env_name = env.is_a?(Hash) ? env['name'] : env
  # A reusable concern may take its environment as an input, so that expression counts as the source-read tier.
  next unless env_name == 'source-read' || env_name.to_s == '$' + '{{ inputs.environment }}'
  steps = job['steps'] || []
  revoke_at = steps.index { |st| st['run'].to_s.include?('installation/token') }
  # The source-checkout composite performs mint, checkout, verification and
  # revocation as one step; its own structure is enforced separately.
  revoke_at ||= steps.index { |st| st['uses'].to_s == './.github/actions/source-checkout' }
  if revoke_at.nil?
    failures << "job #{job_id}: no step revokes the source token (installation/token)"
    next
  end
  revoke = steps[revoke_at]
  unless revoke['uses'].to_s == './.github/actions/source-checkout' || revoke['if'].to_s.include?('always()')
    failures << "job #{job_id}: the revocation step #{revoke['name'].inspect} is not conditioned on always()"
  end
  steps[0...revoke_at].each do |st|
    if st['uses'] && allowed_before.none? { |re| re.match?(st['uses']) }
      failures << "job #{job_id}: step #{st['name'].inspect} uses #{st['uses']} before the token is revoked"
    end
    st['run'].to_s.each_line do |line|
      next if line.strip.start_with?('#')
      if project_command.match?(line)
        failures << "job #{job_id}: step #{st['name'].inspect} runs a project command before the token is revoked: #{line.strip[0, 60]}"
      end
    end
  end
end
unless failures.empty?
  warn failures.join("\n")
  exit 1
end
