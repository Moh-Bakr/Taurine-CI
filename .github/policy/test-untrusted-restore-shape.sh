#!/usr/bin/env bash
# Rule N of check-cache-mode.rb (docs/untrusted-readonly-cache.md, Stage 2) accepts exactly one
# kind of cache restore off main: the two reviewed read-only untrusted restores, in the Linux
# concern workflow, behind a literal-false switch. This builds that reviewed shape from the
# repository's own Linux pair (nothing is read from outside the tree), proves it passes, and proves
# that every way of widening it is still refused. The tree carries no untrusted restore itself yet;
# the fixture adds the reviewed steps, so the rule is exercised before anything depends on it.
set -euo pipefail

policy=.github/policy
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/untrusted-restore-shape.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
concern=linux-validation-concern.yml
caller=linux-validation.yml

# The reviewed steps, verbatim: the exact pinned action, paths and keys the checker pins.
cat > "${work}/sources-step.yml" <<'YAML'
      - name: Restore cached third-party crate sources (untrusted, read-only)
        id: cargo-sources-untrusted
        if: ${{ github.ref == 'refs/heads/untrusted' && inputs.untrusted_readonly_cache && inputs.concern == 'rust-db' }}
        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: |
            ${{ steps.cargo-home.outputs.dir }}/registry/cache
          key: cargo-sources-v3-${{ runner.os }}-${{ hashFiles('src/Cargo.lock', 'src/taurine-backend/*/Cargo.lock', 'src/taurine-backend/vendor/*/Cargo.lock', 'src/vendor/*/Cargo.lock') }}

YAML
cat > "${work}/target-step.yml" <<'YAML'
      - name: Restore compiled third-party dependencies (untrusted, read-only)
        id: cargo-target-cache-untrusted
        if: ${{ github.ref == 'refs/heads/untrusted' && inputs.untrusted_readonly_cache && inputs.concern == 'rust-db' }}
        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: |
            ${{ steps.cargo-target.outputs.dir }}/debug/deps
            ${{ steps.cargo-target.outputs.dir }}/debug/build
            ${{ steps.cargo-target.outputs.dir }}/debug/.fingerprint
          key: ${{ steps.cargo-target.outputs.key }}

YAML
cat > "${work}/input.yml" <<'YAML'
      untrusted_readonly_cache:
        description: Restore the two reviewed Rust caches read-only on the untrusted ref, for rust-db only.
        required: false
        default: false
        type: boolean
YAML

# Insert text before the first line equal to the anchor (exactly one such line must exist).
insert_before() { # file anchor-line text-file
  ANCHOR="$2" TEXT="$3" ruby -e '
    path = ARGV.fetch(0); lines = File.read(path, encoding: "UTF-8").lines
    hits = lines.each_index.select { |i| lines[i].chomp == ENV.fetch("ANCHOR") }
    abort "untrusted restore fixture: anchor #{ENV.fetch("ANCHOR").inspect} found #{hits.length} times in #{path}" unless hits.length == 1
    lines.insert(hits.first, File.read(ENV.fetch("TEXT"), encoding: "UTF-8"))
    File.write(path, lines.join)
  ' "$1"
}

# Replace the text between two literal markers is avoided: every mutation is one exact literal swap,
# and a swap that matches nothing is a broken fixture, not a pass.
swap() { # file from to [occurrence: first|all]
  FROM="$2" TO="$3" WHICH="${4:-first}" ruby -e '
    path = ARGV.fetch(0); text = File.read(path, encoding: "UTF-8"); from = ENV.fetch("FROM")
    abort "untrusted restore fixture: #{from.inspect} not found in #{path}" unless text.include?(from)
    File.write(path, ENV["WHICH"] == "all" ? text.gsub(from) { ENV.fetch("TO") } : text.sub(from) { ENV.fetch("TO") })
  ' "$1"
}

build_reviewed() { # dir
  local d="$1"
  rm -rf "${d}"
  mkdir -p "${d}/.github/workflows" "${d}/docs"
  cp ".github/workflows/${concern}" ".github/workflows/${caller}" "${d}/.github/workflows/"
  cp docs/untrusted-readonly-cache.md "${d}/docs/"
  local c="${d}/.github/workflows/${concern}" l="${d}/.github/workflows/${caller}"
  # A tree that already carries the reviewed restores (the change that introduces them) is its own
  # reviewed shape: nothing is added, and the same weakenings are applied to its real steps.
  if grep -qF untrusted_readonly_cache "${c}"; then return 0; fi
  insert_before "${c}" '      suite_selection:' "${work}/input.yml"
  insert_before "${c}" '      - name: Restore cached third-party crate sources' "${work}/sources-step.yml"
  insert_before "${c}" '      - name: Restore compiled third-party dependencies' "${work}/target-step.yml"
  # Both callers pass the flag as a literal false (the callee default is never relied on).
  swap "${l}" '      concern: ${{ matrix.concern }}' '      untrusted_readonly_cache: false
      concern: ${{ matrix.concern }}' all
}

run_policy() { # dir [files...]; env passes through
  local d="$1"
  shift
  (cd "${d}" && ruby "${OLDPWD}/${policy}/check-cache-mode.rb" "${@:-.github/workflows/${caller}}") 2>&1
}
pair() { run_policy "$1" ".github/workflows/${caller}" ".github/workflows/${concern}"; }

expect_pass() { # label dir
  local out rc=0
  out="$(pair "$2")" || rc=$?
  [[ ${rc} -eq 0 ]] || { echo "untrusted restore fixture '$1' should pass but failed:" >&2; echo "${out}" >&2; exit 1; }
}
expect_fail() { # label dir needle
  local out rc=0
  out="$(pair "$2")" || rc=$?
  [[ ${rc} -ne 0 ]] || { echo "untrusted restore fixture '$1' should fail but passed" >&2; exit 1; }
  [[ "${out}" == *"$3"* ]] || { echo "untrusted restore fixture '$1' failed with the wrong message (wanted '$3'):" >&2; echo "${out}" >&2; exit 1; }
}

reviewed="${work}/reviewed"
c=".github/workflows/${concern}"
l=".github/workflows/${caller}"

# The tree as it stands (no untrusted restore) passes, and so does the reviewed shape built from it.
unset CACHE_MODE_BASE_DOC GITHUB_EVENT_NAME
ruby "${policy}/check-cache-mode.rb" ".github/workflows/${caller}" ".github/workflows/${concern}" >/dev/null
build_reviewed "${reviewed}"
expect_pass 'the reviewed read-only untrusted restores behind a literal false' "${reviewed}"

mutant() { # label needle file from to [first|all]
  local d="${work}/mutant"
  rm -rf "${d}"; cp -R "${reviewed}" "${d}"
  swap "${d}/$3" "$4" "$5" "${6:-first}"
  expect_fail "$1" "${d}" "$2"
}
# A swap confined to one reviewed step (found by its id), so the same fixture works whether the step
# was added above or already existed in the tree.
step_mutant() { # label needle step-id from to
  local d="${work}/mutant"
  rm -rf "${d}"; cp -R "${reviewed}" "${d}"
  STEP="$3" FROM="$4" TO="$5" ruby -e '
    path = ARGV.fetch(0); lines = File.read(path, encoding: "UTF-8").lines
    at = lines.index { |l| l.chomp == "        id: #{ENV.fetch("STEP")}" } or abort "untrusted restore fixture: step #{ENV.fetch("STEP")} not found"
    first = at
    first -= 1 until lines[first].start_with?("      - name:")
    last = at
    last += 1 while last + 1 < lines.length && !lines[last + 1].start_with?("      - name:") && !lines[last + 1].start_with?("      # ")
    block = lines[first..last].join
    abort "untrusted restore fixture: #{ENV.fetch("FROM").inspect} not in step #{ENV.fetch("STEP")}" unless block.include?(ENV.fetch("FROM"))
    lines[first..last] = [block.sub(ENV.fetch("FROM")) { ENV.fetch("TO") }]
    File.write(path, lines.join)
  ' "${d}/${c}"
  expect_fail "$1" "${d}" "$2"
}
reviewed_msg='is not the reviewed read-only untrusted restore'
src=cargo-sources-untrusted
tgt=cargo-target-cache-untrusted
ug="github.ref == 'refs/heads/untrusted' && inputs.untrusted_readonly_cache && inputs.concern == 'rust-db'"

# Each weakening of the restore itself is refused as "not the reviewed restore".
step_mutant 'no flag term' "${reviewed_msg}" "${src}" 'inputs.untrusted_readonly_cache && ' ''
step_mutant 'no concern term' "${reviewed_msg}" "${tgt}" " && inputs.concern == 'rust-db'" ''
step_mutant 'widened to every Rust concern' "${reviewed_msg}" "${tgt}" "inputs.concern == 'rust-db'" "startsWith(inputs.concern, 'rust-')"
step_mutant 'widened to a second concern' "${reviewed_msg}" "${src}" "inputs.concern == 'rust-db'" "(inputs.concern == 'rust-db' || inputs.concern == 'rust-app-1')"
step_mutant 're-opened by ||' "${reviewed_msg}" "${src}" "inputs.concern == 'rust-db' }}" "inputs.concern == 'rust-db' || true }}"
step_mutant 'a dispatch-controlled extra term' "${reviewed_msg}" "${tgt}" "inputs.concern == 'rust-db' }}" "inputs.concern == 'rust-db' && inputs.source_sha != '' }}"
step_mutant 'gated to neither ref' "${reviewed_msg}" "${tgt}" "github.ref == 'refs/heads/untrusted' && " ''
step_mutant 'gated to main as well as the flag' "${reviewed_msg}" "${tgt}" "github.ref == 'refs/heads/untrusted'" "github.ref == 'refs/heads/main'"
step_mutant 'compiled key derived from a dispatch input' "${reviewed_msg}" "${tgt}" 'key: ${{ steps.cargo-target.outputs.key }}' 'key: cargo-${{ inputs.source_sha }}'
step_mutant 'sources key derived from the head ref' "${reviewed_msg}" "${src}" 'key: cargo-sources-v3-${{ runner.os }}-' 'key: cargo-sources-v3-${{ github.head_ref }}-'
step_mutant 'restore-keys on the compiled restore' "${reviewed_msg}" "${tgt}" '/debug/.fingerprint
          key: ${{ steps.cargo-target.outputs.key }}' '/debug/.fingerprint
          key: ${{ steps.cargo-target.outputs.key }}
          restore-keys: cargo-target-'
step_mutant 'an extra step key (continue-on-error)' "${reviewed_msg}" "${tgt}" '        id: cargo-target-cache-untrusted' '        id: cargo-target-cache-untrusted
        continue-on-error: true'
step_mutant 'an env on the restore step' "${reviewed_msg}" "${src}" '        id: cargo-sources-untrusted' '        id: cargo-sources-untrusted
        env:
          X: y'
step_mutant 'an unreviewed path (debug/build dropped)' "${reviewed_msg}" "${tgt}" '            ${{ steps.cargo-target.outputs.dir }}/debug/build
' ''
step_mutant 'a path inside the checkout' "${reviewed_msg}" "${src}" '${{ steps.cargo-home.outputs.dir }}/registry/cache' 'src'
step_mutant 'an unpinned action version' "${reviewed_msg}" "${src}" 'actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9' 'actions/cache/restore@v4'
# A save, or the combined actions/cache, on the untrusted ref is never the reviewed restore.
step_mutant 'the untrusted restore turned into a save' 'without the main-only gate' "${src}" 'uses: actions/cache/restore@' 'uses: actions/cache/save@'
step_mutant 'the untrusted restore turned into the combined cache' "${reviewed_msg}" "${src}" 'uses: actions/cache/restore@' 'uses: actions/cache@'

# Write capability beside the read-only cache.
mutant 'a write-capable token in the called workflow' 'must set no write permission' "${c}" '  validate:
    permissions:
      contents: read' '  validate:
    permissions:
      contents: read
      id-token: write'
mutant 'a write-capable token on the untrusted half' 'no write permission beside an untrusted restore' "${l}" '  validate-untrusted:
    permissions:
      contents: read' '  validate-untrusted:
    permissions:
      contents: read
      actions: write'
mutant 'the untrusted half granted cache-mode write' 'cache-mode write needs the exact top-level term' "${l}" '    cache-mode: read
    uses: ./.github/workflows/linux-validation-concern.yml' '    cache-mode: write
    uses: ./.github/workflows/linux-validation-concern.yml'

# The switch: a literal false in the callers, and a recorded spike before it may be true.
mutant 'a caller key omitted' 'must pass untrusted_readonly_cache explicitly' "${l}" '      untrusted_readonly_cache: false
' '' first
mutant 'the flag as an expression' 'must be a literal true or false' "${l}" '      untrusted_readonly_cache: false' "      untrusted_readonly_cache: \${{ inputs.source_sha != 'x' }}" first
mutant 'the callee default true' 'literal default false' "${c}" '        default: false
        type: boolean' '        default: true
        type: boolean'
mutant 'the flag referenced from an env value' 'outside the reviewed routes' "${c}" '      - name: Report concern duration
        if: ${{ always() }}' '      - name: Report concern duration
        if: ${{ always() }}
        env:
          X: ${{ inputs.untrusted_readonly_cache }}'
mutant 'the flag referenced from another step condition' 'outside the reviewed routes' "${c}" '      - name: Fetch pinned vendored sources
        if: ' '      - name: Fetch pinned vendored sources
        if: inputs.untrusted_readonly_cache || '

# true is accepted only on the untrusted half, only with a record already merged on the base.
true_tree="${work}/true"
make_true() { # which-job
  rm -rf "${true_tree}"; cp -R "${reviewed}" "${true_tree}"
  JOB="$1" ruby -e '
    path = ARGV.fetch(0); text = File.read(path, encoding: "UTF-8")
    job = ENV.fetch("JOB"); start = text.index("\n  #{job}:\n") or abort "job #{job} not found"
    flag = "      untrusted_readonly_cache: false"
    at = text.index(flag, start) or abort "flag not found in #{job}"
    text[at, flag.length] = "      untrusted_readonly_cache: true"
    File.write(path, text)
  ' "${true_tree}/${l}"
}
record='Stage 2 enforcement spike result: GREEN run 12345678901 reviewed by a-person on 2026-10-20'
make_true validate-untrusted
expect_fail 'the flag true without the recorded spike' "${true_tree}" 'needs exactly one recorded green enforcement spike line'
printf '%s\n' "${record}" >> "${true_tree}/docs/untrusted-readonly-cache.md"
expect_pass 'the flag true with the recorded spike in the tree (no base available)' "${true_tree}"
cp docs/untrusted-readonly-cache.md "${work}/base-without-record.md"
cp docs/untrusted-readonly-cache.md "${work}/base-with-record.md"; printf '%s\n' "${record}" >> "${work}/base-with-record.md"
out="$(CACHE_MODE_BASE_DOC="${work}/base-with-record.md" pair "${true_tree}")" || { echo "the flip with the record merged on the base should pass: ${out}" >&2; exit 1; }
for case in 'added|already merged on the base|base-without-record.md' 'unreadable|is not readable|missing.md'; do
  IFS='|' read -r label needle basefile <<< "${case}"
  out=""; rc=0
  out="$(CACHE_MODE_BASE_DOC="${work}/${basefile}" pair "${true_tree}")" || rc=$?
  [[ ${rc} -ne 0 && "${out}" == *"${needle}"* ]] || { echo "spike gate case '${label}' did not fail with '${needle}': ${out}" >&2; exit 1; }
done
printf '%s\n' 'Stage 2 enforcement spike result: GREEN run 99999999999 reviewed by a-person on 2026-10-20' > "${work}/base-altered.md"
cat docs/untrusted-readonly-cache.md >> "${work}/base-altered.md"
out="$(CACHE_MODE_BASE_DOC="${work}/base-altered.md" pair "${true_tree}")" && { echo 'the flip with an altered record should fail' >&2; exit 1; }
[[ "${out}" == *'differs from the merged base record'* ]] || { echo "an altered record failed with the wrong message: ${out}" >&2; exit 1; }
make_true validate-main
printf '%s\n' "${record}" >> "${true_tree}/docs/untrusted-readonly-cache.md"
expect_fail 'the flag true on the main half, even with a record' "${true_tree}" 'may pass untrusted_readonly_cache: true'

# The reviewed restore is accepted in the Linux concern workflow only: the same step in the macOS or
# Windows concern workflow is refused, and a main-gated restore elsewhere still passes untouched.
for other in macos-validation-concern.yml windows-validation-concern.yml; do
  d="${work}/other-${other%%-*}"
  rm -rf "${d}"; mkdir -p "${d}/.github/workflows" "${d}/docs"
  cp ".github/workflows/${other}" "${d}/.github/workflows/"
  cp docs/untrusted-readonly-cache.md "${d}/docs/"
  anchor="$(grep -n '^      - name: Restore cached third-party crate sources' ".github/workflows/${other}" | head -1 | cut -d: -f1)"
  [[ -n "${anchor}" ]] || { echo "untrusted restore fixture: no source restore step in ${other}" >&2; exit 1; }
  insert_before "${d}/.github/workflows/${other}" "$(sed -n "${anchor}p" ".github/workflows/${other}")" "${work}/sources-step.yml"
  out=""; rc=0
  out="$(cd "${d}" && ruby "${OLDPWD}/${policy}/check-cache-mode.rb" ".github/workflows/${other}" 2>&1)" || rc=$?
  [[ ${rc} -ne 0 && "${out}" == *"${reviewed_msg}"* ]] || { echo "the reviewed untrusted restore in ${other} should be refused: ${out}" >&2; exit 1; }
done

echo 'untrusted restore fixtures: the reviewed read-only restores pass; a widened term, key, path or step key, a save, a write token, an unrecorded or misplaced switch and any other workflow are refused'
