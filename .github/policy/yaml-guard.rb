# frozen_string_literal: true

# Shared YAML guards for the policy scripts (required, not run): duplicate mapping keys and the
# YAML 1.1 `on` / true spelling, found on the parsed AST because the loader resolves a duplicate
# silently to its last value and a bare `on` to true. A document that GitHub reads one way and
# Psych another is a way past any check that reads the parsed form, so these fail closed.
require 'yaml'

module YamlGuard
  module_function

  # One YAML key as the loader resolves it: a plain scalar by its YAML 1.1 type (so a bare `on`
  # is true), a quoted one as its string.
  def key_of(node)
    return node.value unless node.plain

    YAML.safe_load(node.value)
  rescue StandardError
    node.value
  end

  # Every duplicate mapping key in a node, by resolved key, and `on` next to true.
  def duplicate_keys(node, path, found)
    if node.is_a?(Psych::Nodes::Mapping)
      seen = {}
      node.children.each_slice(2) do |k, v|
        if k.is_a?(Psych::Nodes::Scalar)
          key = key_of(k)
        found << "#{path.join('.')}: a YAML merge key (<<) is not accepted: Psych and GitHub may resolve it differently" if k.value == '<<'
          folded = key.is_a?(String) ? key.downcase : key # GitHub reads keys case-insensitively
          found << "#{path.join('.')}: the key #{k.value.inspect} appears twice (keys are compared case-insensitively)" if seen.key?(folded)
          seen[folded] = true
        end
        duplicate_keys(v, path + [k.respond_to?(:value) ? k.value : '?'], found)
      end
      found << "#{path.join('.')}: both `on` and a bare on (read as true) are keys" if seen.key?(true) && seen.key?('on')
    elsif node.respond_to?(:children) && node.children
      node.children.each { |c| duplicate_keys(c, path, found) }
    end
  end

  # The duplicate-key findings of one file; a load error is itself a finding.
  def yaml_duplicates(path)
    found = []
    docs = Psych.parse_stream(File.read(path, encoding: 'UTF-8')).children
    # A second document is ignored by one reader and not by another; no policy file has one.
    found << "contains #{docs.size} YAML documents, not one" if docs.size > 1
    docs.each { |doc| duplicate_keys(doc.root, [], found) if doc.root }
    found
  rescue Psych::Exception => e
    ["cannot be parsed as YAML: #{e.class}"]
  end
end
