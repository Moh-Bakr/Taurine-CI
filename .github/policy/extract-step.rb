# Prints one named step of a workflow or composite, so a fixture runs the reviewed script itself
# rather than a copy of it. Usage:
#   ruby extract-step.rb <file> <step name> run            the step's `run:` script
#   ruby extract-step.rb <file> <step name> env <map.json> the environment the step sees, as
#        KEY=VALUE lines: the workflow's env, then the job's, then the step's. Every value that is
#        an expression must be a key of map.json (the fixture's stand-in for that expression);
#        any other expression fails, so a new input to the step cannot go untested.
# Fails when the step is missing or named more than once, so a renamed step cannot leave a
# fixture testing nothing.
require 'yaml'
require 'json'

file, name, part, map_file = ARGV
doc = YAML.safe_load(File.read(file), aliases: false) || {}
owners = if doc.dig('runs', 'steps')
           [[{}, doc['runs']['steps']]]
         else
           (doc['jobs'] || {}).values.map { |job| [job['env'] || {}, job['steps'] || []] }
         end
found = owners.flat_map { |job_env, steps| steps.select { |st| st['name'] == name }.map { |st| [job_env, st] } }
abort "#{file}: expected exactly one step named #{name.inspect}, found #{found.length}" unless found.length == 1
job_env, step = found.first
case part
when 'run'
  abort "#{file}: step #{name.inspect} has no run script" unless step['run'].is_a?(String)
  print step['run']
when 'env'
  map = JSON.parse(File.read(map_file))
  merged = (doc['env'] || {}).merge(job_env).merge(step['env'] || {})
  merged.each do |key, value|
    value = value.to_s
    if value.include?('${{')
      abort "#{file}: step #{name.inspect} env #{key} is an unreviewed expression: #{value}" unless map.key?(value)
      value = map[value]
    end
    abort "#{file}: env #{key} spans lines" if value.include?("\n")
    puts "#{key}=#{value}"
  end
else
  abort "unknown part #{part.inspect}"
end
