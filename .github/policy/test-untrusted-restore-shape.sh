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
composite=.github/actions/rust-target-cache/action.yml

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
  mkdir -p "${d}/.github/actions/rust-target-cache"
  cp "${composite}" "${d}/${composite}"
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
pair() { run_policy "$1" ".github/workflows/${caller}" ".github/workflows/${concern}" "${composite}"; }

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
ruby "${policy}/check-cache-mode.rb" ".github/workflows/${caller}" ".github/workflows/${concern}" "${composite}" >/dev/null
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
# The flag lines are matched whatever their literal value (false, or true on a flipped tree).
flag_mutant() { # label needle ruby-replacement-of-the-first-flag-line ("" removes the line)
  local d="${work}/mutant"
  rm -rf "${d}"; cp -R "${reviewed}" "${d}"
  REPL="$3" ruby -e '
    path = ARGV.fetch(0); text = File.read(path, encoding: "UTF-8")
    re = /^      untrusted_readonly_cache: (?:false|true)\n/
    abort "untrusted restore fixture: no flag line in #{path}" unless text.match?(re)
    File.write(path, text.sub(re) { ENV["REPL"].empty? ? "" : "      untrusted_readonly_cache: #{ENV["REPL"]}\n" })
  ' "${d}/${l}"
  expect_fail "$1" "${d}" "$2"
}
flag_mutant 'a caller key omitted' 'must pass untrusted_readonly_cache explicitly' ''
flag_mutant 'the flag as an expression' 'must be a literal true or false' "\${{ inputs.source_sha != 'x' }}"
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
    re = /^      untrusted_readonly_cache: (?:false|true)$/
    at = text.index(re, start) or abort "flag not found in #{job}"
    text[at...(at + text[at..][re].length)] = "      untrusted_readonly_cache: true"
    File.write(path, text)
  ' "${true_tree}/${l}"
  # No spike record in the tree (a flipped tree carries one): each case adds what it needs.
  ruby -e 'f = ARGV.fetch(0); File.write(f, File.read(f, encoding: "UTF-8").lines.reject { |x| x.start_with?("Stage 2 enforcement spike result:") }.join)' "${true_tree}/docs/untrusted-readonly-cache.md"
}
record='Stage 2 enforcement spike result: GREEN run 12345678901 reviewed by a-person on 2026-10-20'
make_true validate-untrusted
expect_fail 'the flag true without the recorded spike' "${true_tree}" 'needs exactly one recorded green enforcement spike line'
printf '%s\n' "${record}" >> "${true_tree}/docs/untrusted-readonly-cache.md"
expect_pass 'the flag true with the recorded spike in the tree (no base available)' "${true_tree}"
ruby -e 'File.write(ARGV[1], File.read(ARGV[0], encoding: "UTF-8").lines.reject { |x| x.start_with?("Stage 2 enforcement spike result:") }.join)' docs/untrusted-readonly-cache.md "${work}/base-without-record.md"
cp "${work}/base-without-record.md" "${work}/base-with-record.md"; printf '%s\n' "${record}" >> "${work}/base-with-record.md"
out="$(CACHE_MODE_BASE_DOC="${work}/base-with-record.md" pair "${true_tree}")" || { echo "the flip with the record merged on the base should pass: ${out}" >&2; exit 1; }
for case in 'added|already merged on the base|base-without-record.md' 'unreadable|is not readable|missing.md'; do
  IFS='|' read -r label needle basefile <<< "${case}"
  out=""; rc=0
  out="$(CACHE_MODE_BASE_DOC="${work}/${basefile}" pair "${true_tree}")" || rc=$?
  [[ ${rc} -ne 0 && "${out}" == *"${needle}"* ]] || { echo "spike gate case '${label}' did not fail with '${needle}': ${out}" >&2; exit 1; }
done
printf '%s\n' 'Stage 2 enforcement spike result: GREEN run 99999999999 reviewed by a-person on 2026-10-20' > "${work}/base-altered.md"
cat "${work}/base-without-record.md" >> "${work}/base-altered.md"
out="$(CACHE_MODE_BASE_DOC="${work}/base-altered.md" pair "${true_tree}")" && { echo 'the flip with an altered record should fail' >&2; exit 1; }
[[ "${out}" == *'differs from the merged base record'* ]] || { echo "an altered record failed with the wrong message: ${out}" >&2; exit 1; }
make_true validate-main
printf '%s\n' "${record}" >> "${true_tree}/docs/untrusted-readonly-cache.md"
expect_fail 'the flag true on the main half, even with a record' "${true_tree}" 'may pass untrusted_readonly_cache: true'

# Pull-request base pass: the base checkout is RUNNER_TEMP/base-policy. Present with its record document
# and unchanged: the flip passes. Present but without the document: refused (fail closed). Absent (the
# pull request's own pass): only a warning, the base-policy pass is the gate.
make_true validate-untrusted
printf '%s\n' "${record}" >> "${true_tree}/docs/untrusted-readonly-cache.md"
rt="${work}/rt"; rm -rf "${rt}"; mkdir -p "${rt}/base-policy/docs"
out="$(GITHUB_EVENT_NAME=pull_request RUNNER_TEMP="${rt}" pair "${true_tree}")" && { echo 'a pull-request pass whose base checkout lacks the record document should fail' >&2; exit 1; }
[[ "${out}" == *'base-policy checkout has no readable docs/untrusted-readonly-cache.md'* ]] || { echo "the missing base document failed with the wrong message: ${out}" >&2; exit 1; }
cp "${work}/base-with-record.md" "${rt}/base-policy/docs/untrusted-readonly-cache.md"
out="$(GITHUB_EVENT_NAME=pull_request RUNNER_TEMP="${rt}" pair "${true_tree}")" || { echo "a pull-request pass with the record on the base should pass: ${out}" >&2; exit 1; }
cp "${work}/base-without-record.md" "${rt}/base-policy/docs/untrusted-readonly-cache.md"
out="$(GITHUB_EVENT_NAME=pull_request RUNNER_TEMP="${rt}" pair "${true_tree}")" && { echo 'a pull-request pass that adds the record in the flipping diff should fail' >&2; exit 1; }
[[ "${out}" == *'already merged on the base'* ]] || { echo "adding the record in a pull request failed with the wrong message: ${out}" >&2; exit 1; }
rm -rf "${rt}"; mkdir -p "${rt}"
GITHUB_EVENT_NAME=pull_request RUNNER_TEMP="${rt}" pair "${true_tree}" >/dev/null || { echo 'a pull request own pass (no base checkout) should only warn' >&2; exit 1; }

# The producers of the restore's path and key are pinned: the Cargo home step, the locate step and the
# composite behind it (its outputs and the locate step's content hash).
cargo_home_line='        id: cargo-home'
mutant 'the Cargo-home step gains a source script' 'step cargo-home differs from the pinned shape' "${c}" '          set -euo pipefail
          dir="${CARGO_HOME:-${HOME}/.cargo}"' '          set -euo pipefail
          bash src/evil.sh
          dir="${CARGO_HOME:-${HOME}/.cargo}"'
mutant 'the Cargo-home step gains an env' 'step cargo-home differs from the pinned shape' "${c}" "${cargo_home_line}" "${cargo_home_line}
        env:
          CARGO_HOME: /tmp/elsewhere"
mutant 'the locate step swapped for another action' 'step cargo-target differs from the pinned' "${c}" '        uses: ./.github/actions/rust-target-cache  # zizmor: ignore[self-repository]
        with:
          mode: locate' '        uses: ./.github/actions/node-setup  # zizmor: ignore[self-repository]
        with:
          mode: locate'
mutant 'the locate step gains an env' 'step cargo-target differs from the pinned' "${c}" '        id: cargo-target
' '        id: cargo-target
        env:
          CARGO_TARGET_DIR: /tmp/x
'
mutant 'the locate step gains a with key' 'step cargo-target differs from the pinned' "${c}" '          mode: locate
' '          mode: locate
          dir: /tmp/x
'
mutant 'the locate step runs another mode' 'step cargo-target differs from the pinned' "${c}" '          mode: locate
' '          mode: save
'
mutant 'the composite output key redirected' "outputs must be exactly the locate step's outputs" "${composite}" 'value: ${{ steps.locate.outputs.key }}' 'value: ${{ inputs.group }}'
mutant 'the composite gains an output' "outputs must be exactly the locate step's outputs" "${composite}" 'outputs:
  dir:' 'outputs:
  extra:
    description: x
    value: y
  dir:'
mutant 'a pre-locate composite step writes GITHUB_ENV' 'may not write GITHUB_ENV or GITHUB_PATH' "${composite}" '        mkdir -p "${RUNNER_TEMP}/taurine-ci"' '        mkdir -p "${RUNNER_TEMP}/taurine-ci"
        echo "CARGO_TARGET_DIR=/tmp/planted" >> "$GITHUB_ENV"'
mutant 'a pre-locate composite step writes GITHUB_PATH' 'may not write GITHUB_ENV or GITHUB_PATH' "${composite}" '        mkdir -p "${RUNNER_TEMP}/taurine-ci"' '        mkdir -p "${RUNNER_TEMP}/taurine-ci"
        echo "/tmp/planted" | tee -a "${GITHUB_PATH}"'
mutant 'a pre-locate composite step is an action' 'must be a plain run step, not an action' "${composite}" '    - name: Install the compiled dependency cache helpers
' '    - name: Planted action
      uses: actions/checkout@v4
    - name: Install the compiled dependency cache helpers
'
mutant 'the composite locate step changed' 'no longer matches the reviewed content hash' "${composite}" '        echo "dir=${dir}" >> "${GITHUB_OUTPUT}"' '        echo "dir=${dir}" >> "${GITHUB_OUTPUT}"
        echo "dir=/tmp/planted" >> "${GITHUB_OUTPUT}"'
# The workflow policy passes workflows only: the composite is then read from the tree, and still checked.
out="$(run_policy "${reviewed}" ".github/workflows/${caller}" ".github/workflows/${concern}")" || { echo "the workflows alone (composite read from the tree) should pass: ${out}" >&2; exit 1; }
disk="${work}/disk-composite"; rm -rf "${disk}"; cp -R "${reviewed}" "${disk}"
swap "${disk}/${composite}" 'value: ${{ steps.locate.outputs.key }}' 'value: ${{ inputs.group }}'
out="$(run_policy "${disk}" ".github/workflows/${caller}" ".github/workflows/${concern}")" && { echo 'a changed composite read from the tree should fail' >&2; exit 1; }
[[ "${out}" == *"outputs must be exactly the locate step's outputs"* ]] || { echo "a composite read from the tree failed with the wrong message: ${out}" >&2; exit 1; }
no_composite="${work}/no-composite"; rm -rf "${no_composite}"; cp -R "${reviewed}" "${no_composite}"; rm "${no_composite}/${composite}"
out="$(run_policy "${no_composite}" ".github/workflows/${caller}" ".github/workflows/${concern}")" && { echo 'the restore without the composite among the checked files should fail' >&2; exit 1; }
[[ "${out}" == *'which could not be read'* ]] || { echo "a missing composite failed with the wrong message: ${out}" >&2; exit 1; }

# The flag's workflow_call route is exactly on.workflow_call.inputs.<flag>: the same key under outputs or
# secrets, or any deeper path, is another mention and is refused.
mutant 'the flag name as a workflow_call output' 'outside the reviewed routes' "${c}" '  workflow_call:
    inputs:' '  workflow_call:
    outputs:
      untrusted_readonly_cache:
        value: ${{ jobs.validate.result }}
    inputs:'
mutant 'the flag name as a workflow_call secret' 'outside the reviewed routes' "${c}" '    secrets:
      SOURCE_READER_PRIVATE_KEY:' '    secrets:
      untrusted_readonly_cache:
        required: false
      SOURCE_READER_PRIVATE_KEY:'
mutant 'the flag name nested inside its own input declaration' 'outside the reviewed routes' "${c}" '        required: false
        default: false
        type: boolean' '        required: false
        default: false
        type: boolean
        untrusted_readonly_cache: x'

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

# The whole test again on a flipped tree (flag true on the untrusted half with its record line), which is
# what the future flipping change looks like to the base pass: every case above must still hold there.
if [[ "${UNTRUSTED_SHAPE_CHILD:-}" != 1 ]]; then
  flipped="${work}/flipped"
  rm -rf "${flipped}"; mkdir -p "${flipped}"
  make_true validate-untrusted
  printf '%s\n' "${record}" >> "${true_tree}/docs/untrusted-readonly-cache.md"
  mkdir -p "${flipped}/.github" "${flipped}/docs"
  cp -R .github/workflows .github/actions "${flipped}/.github/"
  cp "${true_tree}/.github/workflows/${concern}" "${true_tree}/.github/workflows/${caller}" "${flipped}/.github/workflows/"
  cp "${true_tree}/${composite}" "${flipped}/${composite}"
  cp "${true_tree}/docs/untrusted-readonly-cache.md" "${flipped}/docs/"
  cp -R "${policy}" "${flipped}/.github/policy"
  (cd "${flipped}" && UNTRUSTED_SHAPE_CHILD=1 bash .github/policy/test-untrusted-restore-shape.sh >/dev/null) || { echo 'the untrusted restore fixtures failed on a flipped tree (flag true with its record)' >&2; exit 1; }
fi

echo 'untrusted restore fixtures: the reviewed read-only restores pass; a widened term, key, path or step key, a save, a write token, an unrecorded or misplaced switch and any other workflow are refused'
