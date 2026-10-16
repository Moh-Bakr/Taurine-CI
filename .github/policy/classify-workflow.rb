# Does this workflow carry source access? Usage: ruby classify-workflow.rb WORKFLOW.yml
# Prints `source` or `dispatcher`, from the PARSED structure, never from indentation: re-indenting a
# job block changes no meaning to GitHub, so a line-anchored grep would let a source-bearing job
# hide from check_protected_source. A workflow counts as source when any job enters an environment,
# any step runs the source-checkout composite or mints an App token, or any `secrets.` or `vars.`
# reference appears anywhere but a reusable-call job's own `secrets:` map (the one place a
# dispatcher passes the reviewed key). A file that does not parse is source: the stricter check
# decides.
require 'yaml'

path = ARGV.fetch(0)
begin
  doc = YAML.safe_load(File.read(path, encoding: 'UTF-8'), aliases: false)
rescue StandardError
  puts 'source'
  exit 0
end
unless doc.is_a?(Hash) && doc['jobs'].is_a?(Hash)
  puts 'source'
  exit 0
end

def refs_secret?(node)
  case node
  when String then node.match?(/\b(secrets|vars)\./)
  when Hash then node.any? { |key, value| refs_secret?(key) || refs_secret?(value) }
  when Array then node.any? { |item| refs_secret?(item) }
  else false
  end
end

source = false
source = true if refs_secret?(doc.reject { |key, _| key == 'jobs' })
doc['jobs'].each_value do |job|
  unless job.is_a?(Hash)
    source = true
    next
  end
  source = true if job.key?('environment')
  call = job['uses'].to_s.start_with?('./.github/workflows/')
  body = call ? job.reject { |key, _| key == 'secrets' } : job
  source = true if refs_secret?(body)
  Array(job['steps']).each do |step|
    next unless step.is_a?(Hash)
    uses = step['uses'].to_s
    source = true if uses == './.github/actions/source-checkout' || uses.start_with?('actions/create-github-app-token')
  end
end
puts(source ? 'source' : 'dispatcher')
