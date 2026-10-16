# Structural rules for a protected dispatcher. Usage: ruby dispatcher-structure.rb WORKFLOW.yml
# Everything is read from the parsed workflow, never from indentation (see classify-workflow.rb):
#  - it is workflow_dispatch-only and declares a source_sha input;
#  - it never inherits secrets; every job that calls a workflow passes exactly one secret, the
#    source-reader App key, by name, and calls a local reusable workflow; no job that does not call
#    one reads a secret or variable or enters an environment;
#  - the source SHA is validated by the reviewed 40-hex regexp in the file, or by the pinned dispatch
#    identity proof, and only a workflow registered in check-dispatch-contracts.rb may rely on that
#    proof (the registry is what pins the proof step and its input schema).
require 'yaml'

path = ARGV.fetch(0)
text = File.read(path, encoding: 'UTF-8')
doc = YAML.safe_load(text, aliases: false)
failures = []
abort "#{path}: not a workflow mapping" unless doc.is_a?(Hash) && doc['jobs'].is_a?(Hash)

on = doc.key?('on') ? doc['on'] : doc[true]
triggers = on.is_a?(Hash) ? on.keys.map(&:to_s) : Array(on).map(&:to_s)
failures << "#{path}: the protected dispatcher must be workflow_dispatch-only (triggers: #{triggers.join(', ')})" unless triggers == ['workflow_dispatch']
inputs = on.is_a?(Hash) && on['workflow_dispatch'].is_a?(Hash) ? on['workflow_dispatch']['inputs'] : nil
failures << "#{path}: the protected dispatcher must require a full source SHA: declare a source_sha input" unless inputs.is_a?(Hash) && inputs.key?('source_sha')

KEY = { 'SOURCE_READER_PRIVATE_KEY' => '${{ secrets.SOURCE_READER_PRIVATE_KEY }}' }.freeze
def reads_secret?(node)
  case node
  when String then node.match?(/\b(secrets|vars)\./)
  when Hash then node.any? { |key, value| reads_secret?(key) || reads_secret?(value) }
  when Array then node.any? { |item| reads_secret?(item) }
  else false
  end
end

failures << "#{path}: a protected dispatcher must not read a secret or variable at workflow level" if reads_secret?(doc.reject { |key, _| key == 'jobs' })
doc['jobs'].each do |name, job|
  next failures << "#{path}: job #{name} is not a mapping" unless job.is_a?(Hash)
  failures << "#{path}: job #{name} must not inherit secrets" if job['secrets'] == 'inherit'
  if job.key?('uses')
    unless job['uses'].to_s.start_with?('./.github/workflows/')
      failures << "#{path}: job #{name} calls #{job['uses']}; a protected dispatcher calls only local reusable workflows"
    end
    unless job['secrets'] == KEY
      failures << "#{path}: job #{name} must pass exactly one secret, the App private key, by name: SOURCE_READER_PRIVATE_KEY: ${{ secrets.SOURCE_READER_PRIVATE_KEY }}"
    end
    failures << "#{path}: job #{name} (a reusable call) must not read a secret or variable outside its secrets map" if reads_secret?(job.reject { |key, _| key == 'secrets' })
  else
    failures << "#{path}: job #{name} must not read a secret or variable (only a reusable call passes the key)" if reads_secret?(job)
    failures << "#{path}: job #{name} must not enter an environment (the source jobs live in the reusable workflow)" if job.key?('environment')
  end
end

regexp = text.match?(/\^\[0-9a-fA-F\]\{40\}/)
unless regexp
  contracts = File.read(File.join(__dir__, 'check-dispatch-contracts.rb'), encoding: 'UTF-8')
  registered = (contracts[/DEPLOYED_WORKFLOWS = %w\[(.*?)\]/m, 1] || '').split
  registered << '.github/workflows/pg8-measurement.yml'
  identity = doc['jobs'].values.any? do |job|
    job.is_a?(Hash) && Array(job['steps']).any? { |step| step.is_a?(Hash) && step['run'].to_s.strip == 'ruby .github/policy/dispatch-identity.rb' }
  end
  rel = path.sub(%r{\A\./}, '')
  rel = rel[rel.index('.github/workflows/')..] if rel.include?('.github/workflows/')
  unless identity && registered.include?(rel)
    failures << "#{path}: the protected dispatcher must require a full source SHA: validate it with the reviewed regexp, or run the pinned dispatch identity proof and be registered in check-dispatch-contracts.rb"
  end
end

if failures.empty?
  exit 0
else
  warn failures.uniq.join("\n")
  exit 1
end
