# Rules every workflow and composite in the repository must satisfy, whatever its trust tier.
# Usage: ruby check-universal.rb [root]   (root defaults to the current directory)
#
#  1. Every non-local `uses:` is pinned to a full 40-character commit SHA (no tag, branch or
#     docker:// reference).
#  2. Every workflow declares `permissions: {}` at the top level, so each job must ask for
#     exactly what it needs.
#  3. No workflow uses the `pull_request_target` trigger.
#  4. No workflow passes `secrets: inherit`.
#  5. Every job that enters the source-read environment calls the source-checkout composite,
#     and nothing that runs project code precedes it: only the public checkout (needed to
#     reach the local composites), the timer composite and plain-shell input validation may
#     come first. The reviewed exception is listed below with their reason.
require 'yaml'

root = ARGV[0] || '.'
failures = []

# job-level exceptions to rule 5: [workflow file, job id] => reason
PROTECTED_JOB_EXEMPT = {
  ['weekly-validation.yml', 'resolve'] => 'scheduled resolver: mints, reads one API value and revokes; checks nothing out by design (check-weekly.sh)'
}.freeze

PIN = /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.\/-]+)?@[0-9a-f]{40}\z/
ALLOWED_BEFORE_CHECKOUT = [
  /\Aactions\/checkout@[0-9a-f]{40}\z/,
  /\A\.\/\.github\/actions\/timings\z/
].freeze
PROJECT_COMMAND = /^\s*(sudo\s+)?(npm|npx|pnpm|yarn|node|cargo|rustup|rustc|dotnet|nuget|xcodebuild|xcrun|gradle|gradlew|make|cmake|pip|pip3|python|python3|ruby|brew|docker|choco|vcpkg|bash\s+scripts\/|sh\s+scripts\/|\.\/scripts\/)(\s|$)/

files = Dir.glob(File.join(root, '.github/workflows/*.yml')) + Dir.glob(File.join(root, '.github/actions/*/action.yml'))
files.sort.each do |file|
  rel = file.sub(%r{\A#{Regexp.escape(root)}/?}, '')
  text = File.read(file, encoding: 'UTF-8')
  doc = YAML.safe_load(text, aliases: false) || {}
  workflow = rel.start_with?('.github/workflows/')

  # 1. pinned uses (workflow steps and job-level reusable calls, and composite steps)
  uses = []
  if workflow
    (doc['jobs'] || {}).each_value do |job|
      uses << job['uses'] if job['uses']
      (job['steps'] || []).each { |st| uses << st['uses'] if st['uses'] }
    end
  else
    ((doc['runs'] || {})['steps'] || []).each { |st| uses << st['uses'] if st['uses'] }
  end
  uses.each do |ref|
    next if ref.start_with?('./')
    failures << "#{rel}: `uses: #{ref}` is not pinned to a full 40-character commit SHA" unless ref.match?(PIN)
  end
  next unless workflow

  # 2. permissions: {} at the top level
  failures << "#{rel}: no top-level `permissions: {}`" unless doc['permissions'] == {}

  # 3. pull_request_target (parsed trigger keys; a flow-style `on: [..]` list is parsed too)
  triggers = doc['on'] || doc[true] || {}
  keys = triggers.is_a?(Hash) ? triggers.keys.map(&:to_s) : Array(triggers).map(&:to_s)
  failures << "#{rel}: uses the pull_request_target trigger" if keys.include?('pull_request_target')

  # 4. secrets: inherit
  (doc['jobs'] || {}).each do |job_id, job|
    failures << "#{rel}: job #{job_id} passes `secrets: inherit`" if job['secrets'] == 'inherit'
  end

  # 5. protected jobs start with the source-checkout composite
  (doc['jobs'] || {}).each do |job_id, job|
    env = job['environment']
    env_name = (env.is_a?(Hash) ? env['name'] : env).to_s
    next unless env_name == 'source-read' || env_name == '$' + '{{ inputs.environment }}'
    next if PROTECTED_JOB_EXEMPT.key?([File.basename(rel), job_id])
    steps = job['steps'] || []
    at = steps.index { |st| st['uses'].to_s == './.github/actions/source-checkout' }
    if at.nil?
      failures << "#{rel}: protected job #{job_id} does not call the source-checkout composite"
      next
    end
    steps[0...at].each do |st|
      if st['uses'] && ALLOWED_BEFORE_CHECKOUT.none? { |re| re.match?(st['uses'].to_s) }
        failures << "#{rel}: protected job #{job_id}: #{st['uses']} runs before the source-checkout composite"
      end
      st['run'].to_s.each_line do |line|
        next if line.strip.start_with?('#')
        failures << "#{rel}: protected job #{job_id}: a project command runs before the source-checkout composite: #{line.strip[0, 50]}" if PROJECT_COMMAND.match?(line)
      end
    end
  end
end

unless failures.empty?
  warn failures.join("\n")
  exit 1
end
puts "universal rules: #{files.length} files checked"
