#!/usr/bin/env ruby
# No absolute path may be committed in a case-evidence asset.
#
# The recorded runner reports are real output from a real machine, and a real
# report is full of absolute paths: the runner binary in config.argv[0],
# rootDir, configFile, and anything a reporter error happens to quote. The
# recording step replaces the directories it knows about with placeholders,
# which is a step a person has to remember -- and one that was already missed
# once, shipping a developer machine's node path to a public repository.
#
# The check is structural on purpose. An earlier version of it scanned for a
# list of literal strings, which meant the check itself had to name the roots
# and the account it was looking for: the guard against host strings carried a
# host string. It also missed anything the list did not anticipate, and
# anything spelled differently -- `\/Users\/x` and `/Users` are the same
# path to a JSON parser and different text to a grep.
#
# So: parse each JSON asset, walk every key and string value, and refuse a
# string that is an absolute path in any of the three shapes, whatever root it
# names. Escapes are gone by then, because the parser resolved them. JavaScript
# assets are not parsed here, so they get the same shapes as a text scan, which
# is conservative but enough: they are small, reviewed, hand-written files.
#
# Usage: ruby check-case-evidence-assets.rb [directory]
require 'json'

# A leading placeholder is how a recorded path is meant to look. Anything else
# starting at a filesystem root is a leak.
PLACEHOLDERS = %w[__APP_ROOT__ __SCRATCH__].freeze

# POSIX absolute, Windows drive-absolute, UNC. Root-agnostic by design: a root
# this file does not know about is exactly what the literal list used to miss.
POSIX_ABSOLUTE = %r{\A/[^/]}.freeze
WINDOWS_ABSOLUTE = /\A[A-Za-z]:[\\\/]/.freeze
UNC_ABSOLUTE = /\A\\\\[^\\]/.freeze

# An absolute path quoted inside a longer string -- a message, a stack frame.
# The leading boundary must be whitespace, a quote or an opening bracket, which
# is what keeps base64 integrity values (`sha512-a/b/c`) from matching: their
# slashes always follow an alphanumeric character.
EMBEDDED_ABSOLUTE = %r{(?:\A|[\s"'`=(\[,])(/[A-Za-z0-9._+-]+){2,}}.freeze

def absolute?(value)
  return false unless value.is_a?(String)
  return false if PLACEHOLDERS.any? { |placeholder| value.start_with?(placeholder) }

  value.match?(POSIX_ABSOLUTE) || value.match?(WINDOWS_ABSOLUTE) || value.match?(UNC_ABSOLUTE) ||
    value.match?(EMBEDDED_ABSOLUTE)
end

def walk(value, trail, found)
  case value
  when Hash
    value.each do |key, child|
      found << ["#{trail}.#{key}", key] if absolute?(key)
      walk(child, "#{trail}.#{key}", found)
    end
  when Array
    value.each_with_index { |child, index| walk(child, "#{trail}[#{index}]", found) }
  when String
    found << [trail, value] if absolute?(value)
  end
  found
end

directory = ARGV.fetch(0, File.join(__dir__, 'case-evidence-assets'))
unless File.directory?(directory)
  warn "case-evidence assets: #{directory} is not a directory"
  exit 1
end

status = 0
Dir.glob(File.join(directory, '*')).sort.each do |path|
  name = File.basename(path)
  text = File.binread(path)
  found = []
  if name.end_with?('.json')
    begin
      walk(JSON.parse(text), '', found)
    rescue JSON::ParserError
      warn "case-evidence assets: #{name} is not valid JSON"
      status = 1
      next
    end
  else
    text.each_line.with_index(1) do |line, number|
      line.scan(/"([^"]*)"|'([^']*)'/) do |double, single|
        candidate = double || single
        found << ["line #{number}", candidate] if absolute?(candidate)
      end
    end
  end
  found.each do |trail, value|
    warn "case-evidence assets: #{name} #{trail} is an absolute path (#{value.inspect}); " \
      'recorded paths must use a committed placeholder'
    status = 1
  end
end

if status.zero?
  puts 'case evidence assets: no committed asset carries an absolute path'
end
exit status
