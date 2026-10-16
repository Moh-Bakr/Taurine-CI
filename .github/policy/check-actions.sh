#!/usr/bin/env bash
# Action references: every `uses` is a full commit SHA and an exact reviewed reference (sourced).
#
# The work is done by check-action-uses.rb on the parsed YAML (a text grep misses quoted keys, flow
# mappings, a value on the next line and other valid spellings); the reviewed allow-list is data in
# action-allowlist.rb, one line per entry.

check_action_references() {
  local here="${BASH_SOURCE[0]%/*}"
  ruby "${here}/check-action-uses.rb" "$1" || {
    echo "Action reference policy violated: $1" >&2
    exit 1
  }
}
