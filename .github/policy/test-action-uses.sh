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

# --- container images (jobs.<id>.container, jobs.<id>.services.*.image) ---
fixture ok-container-digest pass 'jobs:
  j:
    container: alpine@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
fixture ok-container-map-digest pass 'jobs:
  j:
    container:
      image: alpine@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      options: --ipc=host'
fixture ok-service-digest pass 'jobs:
  j:
    services:
      db:
        image: postgres@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
fixture ok-container-expression pass "jobs:
  j:
    container: \${{ inputs.x == 'y' && fromJSON('{\"image\":\"mcr.example/pw@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"options\":\"--ipc=host\"}') || null }}"
fixture container-tag reject:'container image must be pinned' 'jobs:
  j:
    container: alpine:3'
fixture container-map-tag reject:'container image must be pinned' 'jobs:
  j:
    container:
      image: alpine:3'
fixture service-tag reject:'container image must be pinned' 'jobs:
  j:
    services:
      db:
        image: postgres:16'
fixture service-short-digest reject:'container image must be pinned' 'jobs:
  j:
    services:
      db:
        image: postgres@sha256:abc123'
fixture container-expression-unpinned reject:'container image must be pinned' "jobs:
  j:
    container: \${{ fromJSON('{\"image\":\"alpine:3\"}') }}"
fixture container-expression-opaque reject:'cannot be verified' 'jobs:
  j:
    container: ${{ inputs.image }}'
fixture container-non-string reject:'not a non-empty string' 'jobs:
  j:
    container: 5'
fixture container-map-no-image reject:'not a non-empty string' 'jobs:
  j:
    container:
      options: --ipc=host'
fixture services-not-mapping reject:'services is not a mapping' 'jobs:
  j:
    services: nope'
fixture service-not-mapping reject:'is not a mapping' 'jobs:
  j:
    services:
      db: postgres:16'

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
mutant 'the image digest rule removed' 'unless image.match?(DIGEST)' 'if false'
mutant 'an opaque image expression accepted' 'if images.empty?' 'if false'
mutant 'container images not walked' '  container_findings(doc, findings)
' ''
mutant 'services not walked' '    next unless job.key?('"'"'services'"'"')' '    next'
mutant 'a non-mapping service accepted' 'else findings << "jobs.#{id}.services.#{name} is not a mapping"' 'else nil'
mutant 'a non-list steps value accepted' 'else findings << "#{where}.steps is not a list"' 'else nil'

# --- no arguments: the script walks the tree itself and never passes having checked nothing ---
walk() { # DIR SCRIPT-DIR: run from DIR with no arguments
  ( cd "$1" && ruby "$2/check-action-uses.rb" 2>&1 )
}
mktree() { rm -rf "${dir}/tree"; mkdir -p "${dir}/tree/.github/workflows" "${dir}/tree/.github/actions/demo"; }
# walk_assertions SCRIPT-DIR: 0 when the no-argument walk behaves; prints the first failure otherwise.
walk_assertions() {
  local out
  mktree; cp "${dir}/fx/ok-plain.yml" "${dir}/tree/.github/workflows/a.yml"; cp "${dir}/fx/ok-composite.yml" "${dir}/tree/.github/actions/demo/action.yml"
  out="$(walk "${dir}/tree" "$1")" || { echo "refused a clean tree: ${out}" >&2; return 1; }
  grep -qF '2 file(s) checked' <<<"${out}" || { echo "did not report two files: ${out}" >&2; return 1; }
  cp "${dir}/fx/esc-flow-map.yml" "${dir}/tree/.github/workflows/b.yaml"
  if out="$(walk "${dir}/tree" "$1")"; then echo 'passed a tree with a bad .yaml workflow' >&2; return 1; fi
  grep -qF 'b.yaml' <<<"${out}" || { echo "did not name b.yaml: ${out}" >&2; return 1; }
  mktree
  if out="$(walk "${dir}/tree" "$1")"; then echo 'passed having checked nothing' >&2; return 1; fi
  grep -qF 'no workflow or composite file to check' <<<"${out}" || { echo "empty tree refused for the wrong reason: ${out}" >&2; return 1; }
}
walk_assertions "${src}" || { echo 'the no-argument walk does not behave' >&2; exit 1; }
echo 'accepted  a clean tree walked without arguments; refused an empty tree and a bad .yaml'
mutant_walk() { # LABEL OLD NEW: the assertions above must fail on the mutant
  rm -rf "${dir}/m"; mkdir "${dir}/m"
  cp "${src}/check-action-uses.rb" "${src}/yaml-guard.rb" "${src}/action-allowlist.rb" "${dir}/m/"
  OLD="$2" NEW="$3" ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("mutation text not found"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], s)' "${dir}/m/check-action-uses.rb"
  if walk_assertions "${dir}/m" >/dev/null 2>&1; then echo "MUTANT SURVIVED: $1" >&2; exit 1; fi
  echo "bites     $1"
}
mutant_walk 'the nothing-checked guard removed' "if files.empty?
  warn" 'if false
  warn'
mutant_walk '.yaml files left out of the walk' '{yml,yaml}' '{yml}'
mutant_walk 'composites left out of the walk' '{workflows,actions}' '{workflows}'
echo 'action-uses tests: every spelling is refused and every guard bites'
