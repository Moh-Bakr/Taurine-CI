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
#     come first. The two reviewed exceptions are listed below with their reason.
#  6. Every workflow that enters source-read on dispatch has its reviewed pre-flight job, which
#     calls the environment-preflight composite (the deployment branches must be exactly main
#     and untrusted) and does not continue on error; every job that calls a workflow, enters an
#     environment or receives a secret needs it directly and never runs past its failure (an
#     always(), failure() or cancelled() in its `if` is allowed only beside a top-level
#     `needs.<pre-flight>.result == 'success'` term).
#  7. No expression reads a whole context: no bare `secrets` or `vars` (so no toJSON(secrets),
#     format('{0}', vars), secrets[...] or secrets.*), and no toJSON(github), which carries the
#     job token. Only named members (secrets.NAME, vars.NAME) may be read.
#  8. Every create-github-app-token mint is one of the reviewed `with:` maps, key for key and
#     value for value (no extra permission-*, no other owner, repository or key). Every call of
#     the source-checkout composite passes the reviewed App settings and the workflow's own
#     SOURCE_REPOSITORY_* constants, which must be the Taurine repository's; only the checkout
#     shape (path, depth, filter, ancestry question) may vary.
#  9. Every drop-root call leaves keep-docker (and container-root) absent or set to the reviewed
#     expression for that file: an unconditional 'true' would keep root for every concern.
require 'yaml'

root = ARGV[0] || '.'
failures = []

# job-level exceptions to rule 5: [workflow file, job id] => reason
PROTECTED_JOB_EXEMPT = {
  ['keeldock-validation-concern.yml', 'validate'] => 'second private source: inline mint with its own stricter checks (check-keeldock.sh)',
  ['weekly-validation.yml', 'resolve'] => 'scheduled resolver: mints, reads one API value and revokes; checks nothing out by design (check-weekly.sh)'
}.freeze

PREFLIGHT = {
  '.github/workflows/linux-validation.yml' => 'validate-input',
  '.github/workflows/windows-validation.yml' => 'validate-input',
  '.github/workflows/keeldock-validation.yml' => 'validate-input',
  '.github/workflows/orchestrate-validation.yml' => 'validate-input',
  '.github/workflows/source-read.yml' => 'validate-input',
  '.github/workflows/live-proofs.yml' => 'plan',
  '.github/workflows/macos-validation.yml' => 'plan',
  '.github/workflows/android-validation.yml' => 'plan',
  '.github/workflows/ios-validation.yml' => 'plan'
}.freeze
RUNS_PAST_FAILURE = /\b(always|failure|cancelled)\s*\(/

# The top-level `&&` terms of an expression (the braces removed, parentheses respected).
def conjuncts(expr)
  text = expr.to_s.strip.sub(/\A\$\{\{/, '').sub(/\}\}\z/, '')
  terms, depth, cur, i = [], 0, +'', 0
  while i < text.length
    c = text[i]
    depth += 1 if c == '('
    depth -= 1 if c == ')'
    if depth.zero? && text[i, 2] == '&&'
      terms << cur.strip; cur = +''; i += 2; next
    end
    if depth.zero? && text[i, 2] == '||'
      return [] # a top-level || can reopen anything: no term is guaranteed
    end
    cur << c; i += 1
  end
  terms << cur.strip
end

E = '$' + '{{ '
INLINE_MINT = {
  'client-id' => "#{E}vars.SOURCE_READER_APP_ID }}",
  'private-key' => "#{E}secrets.SOURCE_READER_PRIVATE_KEY }}",
  'owner' => "#{E}env.SOURCE_REPOSITORY_OWNER }}",
  'repositories' => "#{E}env.SOURCE_REPOSITORY_NAME }}",
  'permission-contents' => 'read',
  'skip-token-revoke' => true
}.freeze
MINTS = {
  '.github/actions/source-checkout/action.yml' => [{
    'client-id' => "#{E}inputs.app-client-id }}",
    'private-key' => "#{E}inputs.app-private-key }}",
    'owner' => "#{E}inputs.repository-owner }}",
    'repositories' => "#{E}inputs.repository-name }}",
    'permission-contents' => 'read',
    'skip-token-revoke' => true
  }],
  '.github/workflows/keeldock-validation-concern.yml' => [INLINE_MINT],
  '.github/workflows/weekly-validation.yml' => [INLINE_MINT]
}.freeze
# The source-checkout call: these keys exactly, plus only the listed shape keys.
SOURCE_CHECKOUT_WITH = {
  'source-sha' => "#{E}inputs.source_sha }}",
  'app-client-id' => "#{E}vars.SOURCE_READER_APP_ID }}",
  'app-private-key' => "#{E}secrets.SOURCE_READER_PRIVATE_KEY }}",
  'repository-id' => "#{E}env.SOURCE_REPOSITORY_ID }}",
  'repository-owner' => "#{E}env.SOURCE_REPOSITORY_OWNER }}",
  'repository-name' => "#{E}env.SOURCE_REPOSITORY_NAME }}"
}.freeze
SOURCE_CHECKOUT_SHAPE = %w[path fetch-depth filter check-protected-ancestry].freeze
TAURINE_SOURCE = { 'SOURCE_REPOSITORY_ID' => '1330267721', 'SOURCE_REPOSITORY_OWNER' => 'Moh-Bakr', 'SOURCE_REPOSITORY_NAME' => 'Taurine' }.freeze
# drop-root inputs: file => input => reviewed values (absent is always allowed)
DROP_ROOT_WITH = {
  '.github/workflows/keeldock-validation-concern.yml' => { 'keep-docker' => ["#{E}inputs.concern == 'db-containers' || inputs.concern == 'apphost-cold-start' }}"] },
  '.github/workflows/live-proof-arm.yml' => { 'keep-docker' => ["#{E}inputs.engine == 'bastion' }}"] },
  '.github/workflows/linux-validation-concern.yml' => { 'container-root' => ["#{E}inputs.concern == 'e2e-visual' }}"] }
}.freeze

# Every expression in a parsed document: the inside of each `${{ }}`, and every `if:` value
# (which GitHub evaluates as an expression with or without the braces).
def expressions(node, key = nil, out = [])
  case node
  when Hash then node.each { |k, v| expressions(v, k.to_s, out) }
  when Array then node.each { |v| expressions(v, nil, out) }
  when String
    found = node.scan(/\$\{\{(.*?)\}\}/m).flatten
    found << node if key == 'if' && found.empty?
    out.concat(found)
  end
  out
end

def steps_of(doc, workflow)
  if workflow
    (doc['jobs'] || {}).flat_map { |_, job| job['steps'] || [] }
  else
    (doc['runs'] || {})['steps'] || []
  end
end

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

  # 7. no whole-context reads (string literals are removed before the scan)
  expressions(doc).each do |expr|
    code = expr.gsub(/'(?:[^']|'')*'/, "''")
    if code.match?(/(?<![.\w-])(secrets|vars)\b(?!\s*\.\s*[A-Za-z_])/) || code.match?(/\btoJSON\s*\(\s*github\s*\)/i)
      failures << "#{rel}: an expression reads a whole secrets, vars or github context: #{expr.strip[0, 60]}"
    end
  end

  # 8. reviewed token mints and source-checkout calls only
  steps = steps_of(doc, workflow)
  mints = steps.select { |st| st['uses'].to_s.start_with?('actions/create-github-app-token@') }
  failures << "#{rel}: the reviewed token mint is missing" if MINTS.key?(rel) && mints.empty?
  mints.each do |st|
    with = (st['with'] || {}).dup
    with['client-id'] = with.delete('app-id') if with.key?('app-id') && !with.key?('client-id')
    next if (MINTS[rel] || []).include?(with)
    failures << "#{rel}: token mint #{st['name'].inspect} is not a reviewed `with:` map (keys and values are an exact allow-list)"
  end
  checkouts = steps.select { |st| st['uses'].to_s == './.github/actions/source-checkout' }
  checkouts.each do |st|
    pinned = (st['with'] || {}).reject { |k, _| SOURCE_CHECKOUT_SHAPE.include?(k) }
    next if pinned == SOURCE_CHECKOUT_WITH
    failures << "#{rel}: source-checkout #{st['name'].inspect} must pass exactly the reviewed App settings and SOURCE_REPOSITORY_* constants (only #{SOURCE_CHECKOUT_SHAPE.join(', ')} may vary)"
  end
  if workflow && !checkouts.empty? && (doc['env'] || {}).select { |k, _| TAURINE_SOURCE.key?(k) } != TAURINE_SOURCE
    failures << "#{rel}: a workflow that calls source-checkout must pin SOURCE_REPOSITORY_ID, _OWNER and _NAME to the Taurine repository"
  end

  # 9. drop-root inputs absent or the reviewed expression
  steps.select { |st| st['uses'].to_s == './.github/actions/drop-root' }.each do |st|
    (st['with'] || {}).each do |input, value|
      next if ((DROP_ROOT_WITH[rel] || {})[input] || []).include?(value)
      failures << "#{rel}: drop-root #{input} must be absent or the reviewed expression, not #{value.inspect}"
    end
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

  # 6. the reviewed pre-flight gates every protected job
  if (pre = PREFLIGHT[rel])
    jobs = doc['jobs'] || {}
    if !jobs.key?(pre)
      failures << "#{rel}: the reviewed pre-flight job #{pre} is missing"
    else
      failures << "#{rel}: the pre-flight job #{pre} must not continue on error" if jobs[pre].key?('continue-on-error')
      unless (jobs[pre]['steps'] || []).any? { |st| st['uses'].to_s == './.github/actions/environment-preflight' && !st.key?('if') && !st.key?('continue-on-error') }
        failures << "#{rel}: the pre-flight job #{pre} must call ./.github/actions/environment-preflight unconditionally"
      end
      jobs.each do |job_id, job|
        next if job_id == pre || !(job['uses'] || job['environment'] || job['secrets'])
        failures << "#{rel}: job #{job_id} must need the pre-flight job #{pre} directly" unless Array(job['needs']).include?(pre)
        next unless job['if'].to_s.match?(RUNS_PAST_FAILURE)
        next if conjuncts(job['if']).include?("needs.#{pre}.result == 'success'")
        failures << "#{rel}: job #{job_id} may not run past a failed pre-flight (#{job['if'].to_s[0, 60]})"
      end
    end
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
