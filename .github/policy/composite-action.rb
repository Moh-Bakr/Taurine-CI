# Composite-action structure check (see check_composite_action in lib.sh).
# Usage: ruby composite-action.rb <action.yml>

require 'yaml'
file = ARGV[0]
doc = YAML.safe_load(File.read(file), aliases: false)
failures = []
if file == '.github/actions/source-checkout/action.yml'
  # The private-source action: mint, then check out, then verify and revoke
  # under always(), no project command anywhere in it, skip-token-revoke on
  # the mint (the explicit step owns revocation) and no outputs at all, so
  # the token can never leave the action.
  steps = (doc['runs'] || {})['steps'] || []
  mint = steps.index { |st| st['uses'].to_s.start_with?('actions/create-github-app-token@') }
  checkout = steps.index { |st| st['uses'].to_s.start_with?('actions/checkout@') }
  revoke = steps.index { |st| st['run'].to_s.include?('installation/token') }
  if mint.nil? || checkout.nil? || revoke.nil? || !(mint < checkout && checkout < revoke)
    failures << "#{file}: steps must be mint, then checkout, then the revoking step"
  else
    failures << "#{file}: the revoking step must run under always()" unless steps[revoke]['if'].to_s.include?('always()')
    failures << "#{file}: the mint step must set skip-token-revoke: true" unless steps[mint].dig('with', 'skip-token-revoke') == true
  end
  failures << "#{file}: must not declare outputs" if doc.key?('outputs')
  steps.each do |st|
    st['run'].to_s.each_line do |line|
      failures << "#{file}: project command in the source-checkout action: #{line.strip[0, 50]}" if line =~ /^\s*(npm|npx|cargo|dotnet|xcodebuild|gradle|make|pip|brew|bash\s+scripts\/)(\s|$)/
    end
  end
end
runs = doc['runs'] || {}
failures << "#{file}: runs.using must be composite" unless runs['using'] == 'composite'
(runs['steps'] || []).each_with_index do |st, i|
  label = st['name'] || "step #{i + 1}"
  if st['run']
    failures << "#{file}: #{label.inspect} has no shell" unless st['shell']
    failures << "#{file}: #{label.inspect} interpolates an expression inside run (use env:)" if st['run'].include?('$' + '{{')
  end
end
unless failures.empty?
  warn failures.join("\n")
  exit 1
end
