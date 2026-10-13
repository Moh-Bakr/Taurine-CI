#!/usr/bin/env bash
# Parse every shell run block in the PostgreSQL fixture action without executing it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
action="${repo_root}/.github/actions/live-start-pg/action.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

ruby -ryaml -e '
  action = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
  steps = action.fetch("runs").fetch("steps")
  count = 0
  steps.each_with_index do |step, index|
    next unless step.key?("run")
    abort "live-start-pg run block #{index} is empty" unless step.fetch("run").is_a?(String) && !step.fetch("run").empty?
    File.write(File.join(ARGV.fetch(1), "step-#{index}.sh"), step.fetch("run"))
    count += 1
  end
  abort "live-start-pg contains no shell run blocks" if count.zero?
  File.write(File.join(ARGV.fetch(1), "count"), count.to_s)
' "${action}" "${tmp}"

while IFS= read -r -d '' script; do
  bash -n "${script}"
done < <(find "${tmp}" -type f -name 'step-*.sh' -print0 | sort -z)

printf 'Shell syntax valid for %s live-start-pg run block(s).\n' "$(cat "${tmp}/count")"
