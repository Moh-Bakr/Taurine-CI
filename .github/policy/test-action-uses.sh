#!/usr/bin/env bash
# Fixture tests for the Action reference check (check-action-uses.rb): the nine valid YAML
# spellings of `uses` that a text grep misses are refused, so are the other unreadable or unreviewed
# shapes, and the reviewed shapes pass. Then every guard in the script is mutated in a copy, and the
# fixture suite must fail on each mutant (a guard no fixture exercises is not tested). Run from the
# repository root.
set -euo pipefail

src="${PWD}/.github/policy"
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
sha=3d3c42e5aac5ba805825da76410c181273ba90b1
other=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "${dir}/fx"

# fixture NAME EXPECTATION BODY: EXPECTATION is `pass`, or `reject:TEXT` (stderr must contain TEXT).
# A step body is wrapped into a job; a body starting with `jobs:` or `runs:` is written as is.
fixture() {
  local name="$1" expect="$2" body="$3" file="${dir}/fx/$1.yml"
  case "${body}" in
    jobs:*|runs:*) printf '%s\n' "${body}" > "${file}" ;;
    *) printf 'name: t\non:\n  workflow_dispatch:\njobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n%s\n' "${body}" > "${file}" ;;
  esac
  printf '%s\t%s\n' "${name}" "${expect}" >> "${dir}/fx/index.tsv"
}

: > "${dir}/fx/index.tsv"
# --- accepted shapes ---
fixture ok-plain pass "      - uses: actions/checkout@${sha}"
fixture ok-quoted-value pass "      - uses: \"actions/checkout@${sha}\""
fixture ok-flow-map pass "      - {uses: actions/checkout@${sha}}"
fixture ok-local pass '      - uses: ./.github/actions/sanitize'
fixture ok-name-only pass '      - name: uses
        run: echo hi'
fixture ok-reusable-job pass 'jobs:
  j:
    uses: ./.github/workflows/linux-validation-concern.yml'
fixture ok-composite pass 'runs:
  using: composite
  steps:
    - uses: ./.github/actions/sanitize'
# --- today'"'"'s plain forms, refused ---
fixture tag reject:'full 40-character commit SHA' '      - uses: actions/checkout@v4'
fixture unreviewed-local reject:'Unreviewed or mutable' '      - uses: ./.github/actions/not-reviewed'
fixture unreviewed-pinned reject:'Unreviewed or mutable' "      - uses: actions/checkout@${other}"
fixture docker reject:'full 40-character commit SHA' '      - uses: docker://alpine:3'
# --- the nine spellings a grep escapes, all refused ---
fixture esc-double-quoted-key reject:'full 40-character' '      - "uses": actions/checkout@v4'
fixture esc-single-quoted-key reject:'full 40-character' "      - 'uses': actions/checkout@v4"
fixture esc-flow-map reject:'full 40-character' '      - {uses: actions/checkout@v4}'
fixture esc-flow-steps reject:'full 40-character' 'jobs:
  j:
    runs-on: ubuntu-24.04
    steps: [{uses: actions/checkout@v4}]'
fixture esc-value-next-line reject:'full 40-character' '      - uses:
          actions/checkout@v4'
fixture esc-space-before-colon reject:'full 40-character' '      - uses : actions/checkout@v4'
fixture esc-complex-key reject:'full 40-character' '      - ? uses
        : actions/checkout@v4'
fixture esc-escaped-key reject:'full 40-character' '      - "u\u0073es": actions/checkout@v4'
fixture esc-job-level-quoted reject:'Unreviewed or mutable' 'jobs:
  j:
    "uses": ./.github/workflows/not-reviewed.yml'
fixture esc-composite reject:'full 40-character' 'runs:
  using: composite
  steps:
    - {"uses": actions/checkout@v4}'
# --- unreadable shapes, refused ---
fixture alias reject:'cannot be loaded' '      - name: &r ./.github/actions/sanitize
        run: echo
      - uses: *r'
fixture non-string reject:'not a non-empty string' '      - uses: 5'
fixture list-value reject:'not a non-empty string' '      - uses: [actions/checkout]'
fixture non-mapping-step reject:'is not a mapping' '      - just a string'
fixture steps-not-list reject:'is not a list' 'jobs:
  j:
    steps: nope'
fixture duplicate-uses reject:'appears twice' '      - uses: actions/checkout@v4
        uses: ./.github/actions/sanitize'
fixture broken-yaml reject:'cannot be' '      - uses: [unclosed'
# A `uses` key the walk does not see (inside a block scalar) trips the textual guard.
fixture tripwire reject:'the parser and the text disagree' '      - name: n
        run: |
          uses: ./.github/actions/sanitize'

# run_suite DIR: run every fixture against DIR/check-action-uses.rb; prints the first failure.
run_suite() {
  local checker="$1/check-action-uses.rb" name expect out rc=0 failed=0
  while IFS=$'\t' read -r name expect; do
    rc=0; out="$(ruby "${checker}" "${dir}/fx/${name}.yml" 2>&1)" || rc=$?
    if [[ "${expect}" == pass ]]; then
      [[ "${rc}" -eq 0 ]] || { echo "fixture ${name}: refused, expected to pass: ${out}" >&2; failed=1; }
    else
      [[ "${rc}" -ne 0 ]] || { echo "fixture ${name}: passed, expected a refusal" >&2; failed=1; continue; }
      grep -qF -- "${expect#reject:}" <<<"${out}" || { echo "fixture ${name}: refused for the wrong reason (wanted '${expect#reject:}'): ${out}" >&2; failed=1; }
    fi
  done < "${dir}/fx/index.tsv"
  return "${failed}"
}

run_suite "${src}" || exit 1
echo "accepted and refused as expected: $(wc -l < "${dir}/fx/index.tsv" | tr -d ' ') fixtures"

# Each mutant weakens one guard in a copy of the script; the suite must fail on it.
mutant() { # LABEL OLD NEW
  rm -rf "${dir}/m"; mkdir "${dir}/m"
  cp "${src}/check-action-uses.rb" "${src}/yaml-guard.rb" "${src}/action-allowlist.rb" "${dir}/m/"
  OLD="$2" NEW="$3" ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("mutation text not found: #{ENV["OLD"][0, 70]}"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], s)' "${dir}/m/check-action-uses.rb"
  if run_suite "${dir}/m" >/dev/null 2>&1; then echo "MUTANT SURVIVED: $1" >&2; exit 1; fi
  echo "bites     $1"
}
mutant 'the SHA-pin rule removed' 'if !ref.start_with?('"'"'./'"'"') && !ref.match?(PINNED)' 'if false'
mutant 'the allow-list rule removed' 'elsif !ACTION_ALLOWLIST.include?(ref)' 'elsif false'
mutant 'the textual tripwire removed' 'if looking > refs.size' 'if false'
mutant 'the duplicate-key walk removed' 'findings = YamlGuard.yaml_duplicates(path)' 'findings = []'
mutant 'aliases accepted' 'YAML.safe_load(text, aliases: false)' 'YAML.safe_load(text, aliases: true)'
mutant 'a non-string value accepted' 'if value.is_a?(String) && !value.strip.empty?' 'if true'
mutant 'composite steps not read' "steps_of.call('runs', runs['steps']) if runs.is_a?(Hash)" 'nil'
mutant 'job steps not read' 'steps_of.call("jobs.#{id}", job['"'"'steps'"'"']) if job.is_a?(Hash)' 'nil'
mutant 'job-level uses not read' 'take.call("jobs.#{id}", job)' 'nil'
mutant 'a non-mapping step accepted' 'unless mapping.is_a?(Hash)' 'unless true'
mutant 'a non-list steps value accepted' 'else findings << "#{where}.steps is not a list"' 'else nil'
echo 'action-uses tests: every spelling is refused and every guard bites'
