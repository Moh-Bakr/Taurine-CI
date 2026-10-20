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
        if: ${{ github.ref == 'refs/heads/untrusted' && inputs.untrusted_readonly_cache && (inputs.concern == 'rust-db' || startsWith(inputs.concern, 'rust-app-')) }}
        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: |
            ${{ steps.cargo-home.outputs.dir }}/registry/cache
          key: cargo-sources-v3-${{ runner.os }}-${{ hashFiles('src/Cargo.lock', 'src/taurine-backend/*/Cargo.lock', 'src/taurine-backend/vendor/*/Cargo.lock', 'src/vendor/*/Cargo.lock') }}

YAML
cat > "${work}/target-step.yml" <<'YAML'
      - name: Restore compiled third-party dependencies (untrusted, read-only)
        id: cargo-target-cache-untrusted
        if: ${{ github.ref == 'refs/heads/untrusted' && inputs.untrusted_readonly_cache && (inputs.concern == 'rust-db' || startsWith(inputs.concern, 'rust-app-')) }}
        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: |
            ${{ steps.cargo-target.outputs.dir }}/debug/deps
            ${{ steps.cargo-target.outputs.dir }}/debug/build
            ${{ steps.cargo-target.outputs.dir }}/debug/.fingerprint
          key: ${{ steps.cargo-target.outputs.key }}

YAML
# The toolchain action's refusal of a `path` toolchain, verbatim (the text #365 adds before any rustc runs):
# a tree whose action lacks it gets it here, so the fixtures run with the reviewed, hash-pinned action.
cat > "${work}/toolchain-guard.txt" <<'GUARDTEXT'
          # A `path` toolchain makes rustup resolve rustc to a directory of the private checkout,
          # so the next `rustc` (the compiled-cache locate step runs `rustc -vV` before the
          # untrusted restores) would execute source-controlled code. A grep for `path =` is
          # bypassed by quoted keys, inline tables and dotted keys, so the file is not searched
          # for the bad spelling: it is accepted only when every line is one of a short list of
          # plain forms (the [toolchain] header, channel/profile strings, components/targets
          # string arrays, comments). Anything else, including every spelling of `path`, an
          # inline table and a dotted key, is refused before any rustc runs.
          toolchain_refuse() {
            echo "rust-toolchain: $1 in ${2}; only channel, profile, components and targets as plain strings are accepted" >&2
            exit 1
          }
          toolchain_check() {
            local file="$1" kind="$2" line count=0 plain='' header=0 in_array=0
            local str='"[A-Za-z0-9._+-]*"'
            local items="${str}([[:space:]]*,[[:space:]]*${str})*[[:space:]]*,?[[:space:]]*"
            local re_header='^\[toolchain\][[:space:]]*(#.*)?$'
            local re_scalar="^(channel|profile)[[:space:]]*=[[:space:]]*${str}[[:space:]]*(#.*)?\$"
            local re_array="^(components|targets)[[:space:]]*=[[:space:]]*\\[[[:space:]]*(${items})?\\][[:space:]]*(#.*)?\$"
            local re_open='^(components|targets)[[:space:]]*=[[:space:]]*\[[[:space:]]*(#.*)?$'
            local re_item="^[[:space:]]*${items}(#.*)?\$"
            local re_close='^[[:space:]]*\][[:space:]]*(#.*)?$'
            local re_plain='^[A-Za-z0-9._+-]+$'
            # A channel of exactly `.` or `..` would name a directory, not a toolchain.
            local re_dots_channel='^channel[[:space:]]*=[[:space:]]*"\.{1,2}"'
            local re_dots_plain='^\.{1,2}$'
            while IFS= read -r line || [[ -n "${line}" ]]; do
              line="${line%$'\r'}"
              [[ "${line}" =~ ^[[:space:]]*(#.*)?$ ]] && continue
              count=$((count + 1))
              plain="${line}"
              if [[ "${line}" =~ ${re_dots_channel} ]] || [[ "${kind}" == legacy && count -eq 1 && "${line}" =~ ${re_dots_plain} ]]; then
                toolchain_refuse "a channel of . or .." "${file}"
              fi
              if (( in_array )); then
                if [[ "${line}" =~ ${re_close} ]]; then in_array=0
                elif [[ "${line}" =~ ${re_item} ]]; then :
                else toolchain_refuse "an unreadable array line" "${file}"; fi
              elif [[ "${line}" =~ ${re_header} ]]; then
                (( header == 0 && count == 1 )) || toolchain_refuse "a repeated or misplaced [toolchain] header" "${file}"
                header=1
              elif (( header )) && [[ "${line}" =~ ${re_scalar} || "${line}" =~ ${re_array} ]]; then :
              elif (( header )) && [[ "${line}" =~ ${re_open} ]]; then in_array=1
              elif [[ "${kind}" == legacy && count -eq 1 && "${line}" =~ ${re_plain} ]]; then :
              else toolchain_refuse "an unrecognised line" "${file}"; fi
            done < "${file}"
            (( in_array == 0 )) || toolchain_refuse "an unterminated array" "${file}"
            if (( header == 0 )); then
              # The legacy `rust-toolchain` file may be one plain channel name and nothing else.
              [[ "${kind}" == legacy && count -eq 1 && "${plain}" =~ ${re_plain} ]] || toolchain_refuse "a toolchain file that is neither a [toolchain] table nor a single channel name" "${file}"
            fi
          }
          [[ ! -f rust-toolchain.toml ]] || toolchain_check rust-toolchain.toml toml
          [[ ! -f rust-toolchain ]] || toolchain_check rust-toolchain legacy
GUARDTEXT
cat > "${work}/input.yml" <<'YAML'
      untrusted_readonly_cache:
        description: Restore the two reviewed Rust caches read-only on the untrusted ref, for rust-db and the rust-app shards only.
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
  local action
  for action in rust-target-cache verify-cargo-cache rust-toolchain timings source-checkout egress-audit root-setup drop-root sanitize concern-report shell-artefact scan-concern; do
    mkdir -p "${d}/.github/actions/${action}"
    cp ".github/actions/${action}/action.yml" "${d}/.github/actions/${action}/"
  done
  if ! grep -qF toolchain_check "${d}/.github/actions/rust-toolchain/action.yml"; then
    insert_before "${d}/.github/actions/rust-toolchain/action.yml" "          echo 'rust-toolchain: installing the toolchain pinned by the source'" "${work}/toolchain-guard.txt"
    reviewed_toolchain_hash="$(ruby -ryaml -rjson -rdigest -e '
      canon = lambda { |v| v.is_a?(Hash) ? v.map { |k, x| [k.to_s, canon.call(x)] }.sort_by(&:first).to_h : (v.is_a?(Array) ? v.map { |x| canon.call(x) } : v) }
      puts Digest::SHA256.hexdigest(JSON.generate(canon.call(YAML.safe_load(File.read(ARGV[0]), aliases: false))))
    ' "${d}/.github/actions/rust-toolchain/action.yml")"
    [[ "${reviewed_toolchain_hash}" == 04d9056e51c8ae6fbfd85ca149ca71e38d291809131a00a28a2444161a3cbda0 ]] || { echo "untrusted restore fixture: the guarded toolchain action no longer hashes to the reviewed value (${reviewed_toolchain_hash})" >&2; exit 1; }
  fi
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
  # Steps that run private-source code (`npm ci`, the vendor fetch) belong after the restores, not before
  # the producers of their path and key: move them to just before the Playwright install, after every restore and strip.
  ruby -e '
    path = ARGV.fetch(0); lines = File.read(path, encoding: "UTF-8").lines
    step_at = ->(name) { lines.index { |x| x.start_with?("      - name: #{name}") } or abort "untrusted restore fixture: step #{name} not found" }
    first_of = lambda do |i| # the step line, widened upwards over its own comment lines
      i -= 1 while i > 0 && lines[i - 1].start_with?("      #")
      i
    end
    names = ["Set up Node.js and install the locked JavaScript dependencies", "Fetch pinned vendored sources"]
    moved = names.map do |name|
      from = first_of.call(step_at.call(name))
      to = step_at.call(name) + 1
      to += 1 until to >= lines.length || lines[to].start_with?("      - name:") || lines[to].start_with?("      #")
      block = lines.slice!(from...to)
      block
    end
    anchor = first_of.call(step_at.call("Install the pinned Playwright browser"))
    lines.insert(anchor, *moved.flatten)
    File.write(path, lines.join)
  ' "${c}"
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
ct="(inputs.concern == 'rust-db' || startsWith(inputs.concern, 'rust-app-'))"
ug="github.ref == 'refs/heads/untrusted' && inputs.untrusted_readonly_cache && ${ct}"

# Each weakening of the restore itself is refused as "not the reviewed restore".
step_mutant 'no flag term' "${reviewed_msg}" "${src}" 'inputs.untrusted_readonly_cache && ' ''
step_mutant 'no concern term' "${reviewed_msg}" "${tgt}" " && ${ct}" ''
step_mutant 'widened to every Rust concern' "${reviewed_msg}" "${tgt}" "${ct}" "startsWith(inputs.concern, 'rust-')"
step_mutant 'widened to a second concern' "${reviewed_msg}" "${src}" "${ct}" "(inputs.concern == 'rust-db' || startsWith(inputs.concern, 'rust-app-') || inputs.concern == 'rust-packaging')"
step_mutant 're-opened by ||' "${reviewed_msg}" "${src}" "${ct} }}" "${ct} || true }}"
step_mutant 'a dispatch-controlled extra term' "${reviewed_msg}" "${tgt}" "${ct} }}" "${ct} && inputs.source_sha != '' }}"
# The rust-app extension is exactly rust-db and the rust-app-* shards: dropping rust-db, narrowing the
# prefix to one shard, a prefix that also matches the packaging concern, the OpenSSL door concern, or
# the same selector spelled in another case or form is a different step and is refused.
step_mutant 'the rust-app selector narrowed to one shard' "${reviewed_msg}" "${tgt}" "startsWith(inputs.concern, 'rust-app-')" "inputs.concern == 'rust-app-1'"
step_mutant 'rust-db dropped from the rust-app extension' "${reviewed_msg}" "${tgt}" "${ct}" "startsWith(inputs.concern, 'rust-app-')"
step_mutant 'the OpenSSL door concern added to the compiled restore' "${reviewed_msg}" "${tgt}" "${ct}" "(inputs.concern == 'rust-db' || startsWith(inputs.concern, 'rust-app-') || inputs.concern == 'rust-tls-openssl')"
step_mutant 'the OpenSSL door concern added to the sources restore' "${reviewed_msg}" "${src}" "${ct}" "(inputs.concern == 'rust-db' || startsWith(inputs.concern, 'rust-app-') || inputs.concern == 'rust-tls-openssl')"
step_mutant 'the packaging concern added to the compiled restore' "${reviewed_msg}" "${tgt}" "${ct}" "(inputs.concern == 'rust-db' || startsWith(inputs.concern, 'rust-app-') || inputs.concern == 'rust-packaging')"
step_mutant 'the rust-app prefix in another spelling' "${reviewed_msg}" "${tgt}" "startsWith(inputs.concern, 'rust-app-')" "startswith(inputs.concern, 'rust-app-')"
step_mutant 'the rust-app prefix negated' "${reviewed_msg}" "${tgt}" "${ct}" "!(inputs.concern == 'rust-tls-openssl')"
# A rust-app compiled restore without the main-scope key: a key that is not exactly the locate output
# (the key main's protected save wrote), a prefix fallback, or a key from another scope.
step_mutant 'a rust-app restore keyed apart from the main save' "${reviewed_msg}" "${tgt}" 'key: ${{ steps.cargo-target.outputs.key }}' 'key: cargo-target-v1-untrusted-${{ steps.cargo-target.outputs.key }}'
step_mutant 'a rust-app restore keyed by the run id' "${reviewed_msg}" "${tgt}" 'key: ${{ steps.cargo-target.outputs.key }}' 'key: cargo-target-v1-${{ github.run_id }}'
step_mutant 'a rust-app restore falling back to a prefix' "${reviewed_msg}" "${tgt}" '          key: ${{ steps.cargo-target.outputs.key }}' '          key: ${{ steps.cargo-target.outputs.key }}
          restore-keys: |
            cargo-target-v1-${{ runner.os }}-'
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
# On a step that carries no env of its own, in this tree or in a tree another fixture has already
# given an env to the duration step (a second env key is a duplicate key, refused before the rule runs).
mutant 'the flag referenced from an env value' 'outside the reviewed routes' "${c}" '      - name: Report observed egress
        if: always()
        continue-on-error: true' '      - name: Report observed egress
        if: always()
        continue-on-error: true
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
# A step inserted at an anchor line of a copy (the text is a literal block of whole lines).
insert_mutant() { # label needle file anchor-line text
  local d="${work}/mutant"
  rm -rf "${d}"; cp -R "${reviewed}" "${d}"
  printf '%s\n' "$5" > "${work}/inserted.yml"
  insert_before "${d}/$3" "$4" "${work}/inserted.yml"
  expect_fail "$1" "${d}" "$2"
}
loc_anchor='    - name: Locate the compiled dependency cache'
first_msg='the locate step must be the first step of the composite'
# The locate step is the composite's first step; anything before it is refused whatever it does.
insert_mutant 'a plain step before locate' "${first_msg}" "${composite}" "${loc_anchor}" '    - name: Early step
      shell: bash
      run: echo hi
'
insert_mutant 'an obfuscated GITHUB_ENV write before locate' "${first_msg}" "${composite}" "${loc_anchor}" '    - name: Early step
      shell: bash
      run: |
        v="GITHUB_E""NV"; echo "CARGO_TARGET_DIR=/tmp/planted" >> "${!v}"
'
insert_mutant 'a shim written into ~/.cargo/bin before locate' "${first_msg}" "${composite}" "${loc_anchor}" '    - name: Early step
      shell: bash
      run: |
        mkdir -p "${HOME}/.cargo/bin"
        printf "#!/bin/sh\necho planted\n" > "${HOME}/.cargo/bin/rustc"
        chmod +x "${HOME}/.cargo/bin/rustc"
'
insert_mutant 'a GITHUB_PATH write before locate' "${first_msg}" "${composite}" "${loc_anchor}" '    - name: Early step
      shell: bash
      run: echo "/tmp/planted" | tee -a "${GITHUB_PATH}"
'
insert_mutant 'an action before locate' "${first_msg}" "${composite}" "${loc_anchor}" '    - name: Early action
      uses: actions/checkout@v4
'
# locate present but moved after another step (the original order of the composite).
reorder="${work}/reorder"; rm -rf "${reorder}"; cp -R "${reviewed}" "${reorder}"
ruby -e '
  f = ARGV.fetch(0); lines = File.read(f, encoding: "UTF-8").lines
  a = lines.index { |l| l.start_with?("    - name: Locate the compiled dependency cache") }
  b = lines.index { |l| l.start_with?("    - name: Install the compiled dependency cache helpers") }
  c = lines.index { |l| l.start_with?("    - name: Strip workspace crates from the restored") }
  abort "reorder fixture: anchors not found" unless a && b && c && a < b && b < c
  File.write(f, (lines[0...a] + lines[b...c] + lines[a...b] + lines[c..]).join)
' "${reorder}/${composite}"
expect_fail 'locate moved after the helper step' "${reorder}" "${first_msg}"
insert_mutant 'a case-variant look-alike of the locate id' 'no other-case look-alike' "${composite}" '    - name: Install the compiled dependency cache helpers' '    - name: Look-alike
      id: Locate
      shell: bash
      run: echo hi
'
# Steps between a producer and its untrusted restore: unguarded ones are refused, main-gated ones pass.
insert_mutant 'an unguarded step between cargo-home and its untrusted restore' 'sits between cargo-home' "${c}" '      - name: Restore cached third-party crate sources (untrusted, read-only)' '      - name: Between steps
        shell: bash
        run: echo hi
'
insert_mutant 'an environment write between cargo-target and its untrusted restore' 'sits between cargo-target' "${c}" '      - name: Restore compiled third-party dependencies (untrusted, read-only)' '      - name: Between steps
        shell: bash
        run: echo "X=1" >> "${GITHUB_ENV}"
'
d_ok="${work}/between-ok"; rm -rf "${d_ok}"; cp -R "${reviewed}" "${d_ok}"
printf '%s\n' "      - name: Main-only step
        if: \${{ github.ref == 'refs/heads/main' }}
        shell: bash
        run: echo hi
" > "${work}/inserted.yml"
insert_before "${d_ok}/${c}" '      - name: Restore compiled third-party dependencies (untrusted, read-only)' "${work}/inserted.yml"
expect_pass 'a step gated to main between cargo-target and its untrusted restore' "${d_ok}"
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

# Everything before the producers is on a reviewed allowlist: project-code steps, unpinned run steps, a
# changed pinned step, tools redirected through env, container or defaults, and an altered pinned action.
allow_msg='is not on the reviewed allowlist'
home_anchor='      - name: Locate Cargo home for the third-party source cache'
insert_mutant 'a project-code install before the producers' "${allow_msg}" "${c}" "${home_anchor}" '      - name: Install the JavaScript dependencies early
        shell: bash
        run: npm ci
'
insert_mutant 'the vendor fetch before the producers' "${allow_msg}" "${c}" "${home_anchor}" '      - name: Fetch pinned vendored sources early
        shell: bash
        run: bash scripts/vendor-openvpn3.sh fetch
'
insert_mutant 'the node-setup action before the producers' "${allow_msg}" "${c}" "${home_anchor}" '      - name: Set up Node.js early
        uses: ./.github/actions/node-setup
'
insert_mutant 'a pinned run step name with a different body' "${allow_msg}" "${c}" "${home_anchor}" '      - name: Validate protected call input
        shell: bash
        run: echo "PATH=/tmp/evil:${PATH}" >> "${GITHUB_ENV}"
'
insert_mutant 'an unpinned third-party action before the producers' "${allow_msg}" "${c}" "${home_anchor}" '      - name: Early third-party action
        uses: actions/setup-node@v4
'
for key in PATH BASH_ENV HOME CARGO_HOME RUSTUP_TOOLCHAIN RUSTC_WRAPPER NODE_OPTIONS ENV; do
  mutant "a job env sets ${key}" "sets ${key}" "${c}" '    environment: source-read
' "    environment: source-read
    env:
      ${key}: /tmp/evil
"
  mutant "a workflow env sets ${key}" "workflow env sets ${key}" "${c}" '  SOURCE_REPOSITORY_NAME: Taurine
' "  SOURCE_REPOSITORY_NAME: Taurine
  ${key}: /tmp/evil
"
done
mutant 'a step env sets RUSTUP_TOOLCHAIN on the toolchain step' 'sets RUSTUP_TOOLCHAIN' "${c}" '        uses: ./.github/actions/rust-toolchain  # zizmor: ignore[self-repository]
' '        uses: ./.github/actions/rust-toolchain  # zizmor: ignore[self-repository]
        env:
          RUSTUP_TOOLCHAIN: /tmp/evil
'
mutant 'the job container changed' 'container must be absent or exactly the reviewed' "${c}" "container: \${{ inputs.concern == 'e2e-visual' &&" "container: \${{ inputs.concern == 'rust-db' &&"
mutant 'the job container replaced by an image' 'container must be absent or exactly the reviewed' "${c}" "    container: \${{ inputs.concern == 'e2e-visual'" '    container: ubuntu:latest
    x-unused: \${{ inputs.concern == '"'"'e2e-visual'"'"''
mutant 'the job defaults gain a shell' 'defaults must be absent or exactly' "${c}" '    defaults:
      run:
        working-directory: src' '    defaults:
      run:
        working-directory: src
        shell: sh'
mutant 'a workflow-level defaults' 'workflow-level `defaults` must not exist' "${c}" 'permissions: {}

env:' 'permissions: {}

defaults:
  run:
    shell: sh

env:'
mutant 'the toolchain action file altered' "${allow_msg}" ".github/actions/rust-toolchain/action.yml" 'Per-OS setup for the Rust concerns' 'Per-OS planted setup for the Rust concerns'
mutant 'the toolchain step gains a with key' "${allow_msg}" "${c}" "          concern: \${{ (inputs.concern == 'scan-security' || inputs.concern == 'scan-lint') && 'rust-app' || inputs.concern }}" "          concern: \${{ (inputs.concern == 'scan-security' || inputs.concern == 'scan-lint') && 'rust-app' || inputs.concern }}
          extra: x"

# Every shared local action that runs ahead of the producers is pinned as a whole file and by its exact
# `with`; a changed file, an added input or a changed value is refused.
for action in timings source-checkout egress-audit root-setup drop-root sanitize concern-report shell-artefact scan-concern verify-cargo-cache rust-toolchain; do
  d="${work}/action-${action}"; rm -rf "${d}"; cp -R "${reviewed}" "${d}"
  ruby -e 'f = ARGV.fetch(0); t = File.read(f, encoding: "UTF-8"); n = t.sub(/\Aname: /) { "name: planted " }; abort "untrusted restore fixture: no name line in #{f}" if n == t; File.write(f, n)' "${d}/.github/actions/${action}/action.yml"
  if [[ "${action}" == verify-cargo-cache ]]; then
    # only reached from a step between cargo-home and its restore
    printf '%s\n' "      - name: Verify restored crate archives (early)
        uses: ./.github/actions/verify-cargo-cache
        with:
          sources-dir: \${{ steps.cargo-home.outputs.dir }}
          cache-hit: \${{ steps.cargo-sources.outputs.cache-hit }}
          os-label: Linux
" > "${work}/inserted.yml"
    insert_before "${d}/${c}" '      - name: Restore cached third-party crate sources (untrusted, read-only)' "${work}/inserted.yml"
  fi
  expect_fail "the ${action} action file altered" "${d}" "${allow_msg}"
done
with_mutant() { # label from to
  mutant "$1" "${allow_msg}" "${c}" "$2" "$3"
}
with_mutant 'source-checkout gains a path input' "          check-protected-ancestry: 'true'" "          check-protected-ancestry: 'true'
          path: ."
with_mutant 'source-checkout ancestry check turned off' "          check-protected-ancestry: 'true'" "          check-protected-ancestry: 'false'"
with_mutant 'timings given another mode' '          mode: start' '          mode: end'
with_mutant 'drop-root keeps root in the container' "          container-root: \${{ inputs.concern == 'e2e-visual' }}" '          container-root: true'
with_mutant 'root-setup given another concern' '          concern: ${{ inputs.concern }}' '          concern: rust-db'
with_mutant 'egress audit given another phase' '          phase: enforce' '          phase: stop'
with_mutant 'the control-plane checkout gains a path' '          persist-credentials: false' '          persist-credentials: false
          path: elsewhere'
with_mutant 'the control-plane checkout gains a repository' '          persist-credentials: false' '          persist-credentials: false
          repository: someone/else'
with_mutant 'the control-plane checkout gains a ref' '          persist-credentials: false' '          persist-credentials: false
          ref: refs/heads/other'
with_mutant 'the control-plane checkout gains a token' '          persist-credentials: false' '          persist-credentials: false
          token: ${{ secrets.OTHER }}'
with_mutant 'the control-plane checkout keeps credentials' '          persist-credentials: false' '          persist-credentials: true'
mutant 'a job gains services' 'services must be absent beside an untrusted restore' "${c}" '    environment: source-read
' '    environment: source-read
    services:
      db:
        image: postgres
'
# main's unguarded toolchain action (the guard text removed) is refused: it runs rustc/cargo from src
# through the rustup proxy before anything refuses a `path` toolchain.
unguarded="${work}/unguarded"; rm -rf "${unguarded}"; cp -R "${reviewed}" "${unguarded}"
ruby -e '
  f = ARGV.fetch(0); t = File.read(f, encoding: "UTF-8")
  a = t.index("          # A `path` toolchain makes rustup resolve rustc") or abort "untrusted restore fixture: guard text not found"
  e = "          [[ ! -f rust-toolchain ]] || toolchain_check rust-toolchain legacy\n"
  b = t.index(e) + e.length
  File.write(f, t[0...a] + t[b..])
' "${unguarded}/.github/actions/rust-toolchain/action.yml"
! grep -qF toolchain_check "${unguarded}/.github/actions/rust-toolchain/action.yml" || { echo 'untrusted restore fixture: the guard was not removed' >&2; exit 1; }
expect_fail "main's unguarded toolchain action" "${unguarded}" "${allow_msg}"
# A rustc call ahead of the guard text: the action no longer hashes to a reviewed value.
late="${work}/late-guard"; rm -rf "${late}"; cp -R "${reviewed}" "${late}"
swap "${late}/.github/actions/rust-toolchain/action.yml" '          # A `path` toolchain makes rustup resolve rustc' '          rustc --version
          # A `path` toolchain makes rustup resolve rustc'
expect_fail 'a rustc call ahead of the guard' "${late}" "${allow_msg}"
mutant 'the locate step stops using the rustup-selected compiler' 'no longer matches the reviewed content hash' "${composite}" '        rustc_path="$(rustup which rustc)"' '        rustc_path="$(command -v rustc)"'

# Composite steps after locate are covered by the whole-file pin.
mutant 'the helper step writes GITHUB_ENV' 'whole file must match the reviewed content hash' "${composite}" '        mkdir -p "${RUNNER_TEMP}/taurine-ci"' '        mkdir -p "${RUNNER_TEMP}/taurine-ci"
        echo "RUSTFLAGS=-Cplanted" >> "${GITHUB_ENV}"'
mutant 'the helper step gains an if that skips it' 'whole file must match the reviewed content hash' "${composite}" '    - name: Install the compiled dependency cache helpers
' '    - name: Install the compiled dependency cache helpers
      if: ${{ inputs.mode == '"'"'never'"'"' }}
'
mutant 'a strip step gains continue-on-error' 'whole file must match the reviewed content hash' "${composite}" '    - name: Prove the compiled dependency cache holds no workspace crate
' '    - name: Prove the compiled dependency cache holds no workspace crate
      continue-on-error: true
'

# A hash-pinned cache verifier may sit between cargo-home and its untrusted restore; a changed file, an
# extra with key, an env or a wrong directory is refused.
verify_step='      - name: Verify restored crate archives (early)
        if: ${{ inputs.concern == '"'"'rust-db'"'"' }}
        uses: ./.github/actions/verify-cargo-cache
        with:
          sources-dir: ${{ steps.cargo-home.outputs.dir }}
          cache-hit: ${{ steps.cargo-sources.outputs.cache-hit }}
          os-label: Linux
'
sources_anchor='      - name: Restore cached third-party crate sources (untrusted, read-only)'
v_ok="${work}/verify-ok"; rm -rf "${v_ok}"; cp -R "${reviewed}" "${v_ok}"
printf '%s\n' "${verify_step}" > "${work}/inserted.yml"
insert_before "${v_ok}/${c}" "${sources_anchor}" "${work}/inserted.yml"
expect_pass 'a hash-pinned verifier between cargo-home and the untrusted restore' "${v_ok}"
v_bad="${work}/verify-bad"; rm -rf "${v_bad}"; cp -R "${v_ok}" "${v_bad}"
ruby -e 'f = ARGV.fetch(0); t = File.read(f, encoding: "UTF-8"); File.write(f, t.sub(/\Aname: /) { "name: planted " })' "${v_bad}/.github/actions/verify-cargo-cache/action.yml"
cmp -s "${v_ok}/.github/actions/verify-cargo-cache/action.yml" "${v_bad}/.github/actions/verify-cargo-cache/action.yml" && { echo 'untrusted restore fixture: the verifier file was not changed' >&2; exit 1; }
expect_fail 'a verifier whose action file hash does not match' "${v_bad}" "${allow_msg}"
verify_variant() { # label from to
  local d="${work}/verify-$1"
  rm -rf "${d}"; cp -R "${v_ok}" "${d}"
  swap "${d}/${c}" "$2" "$3" first
  expect_fail "the pinned verifier with a changed $1" "${d}" "${allow_msg}"
}
verify_variant with-key '          os-label: Linux' '          os-label: Linux
          extra: x'
verify_variant env '        uses: ./.github/actions/verify-cargo-cache' '        uses: ./.github/actions/verify-cargo-cache
        env:
          X: y'
verify_variant dir '          sources-dir: ${{ steps.cargo-home.outputs.dir }}' '          sources-dir: /tmp/elsewhere'
verify_variant hit '          cache-hit: ${{ steps.cargo-sources.outputs.cache-hit }}' '          cache-hit: "true"'

# The check is per job: a producer that lives in another job does not satisfy a restore here.
other_job="${work}/other-job"; rm -rf "${other_job}"; cp -R "${reviewed}" "${other_job}"
swap "${other_job}/${c}" '        id: cargo-home
' '        id: cargo-home-renamed
'
printf '\n  other:\n    runs-on: ubuntu-24.04\n    steps:\n      - id: cargo-home\n        shell: bash\n        run: echo hi\n' >> "${other_job}/${c}"
expect_fail 'the producer lives in another job' "${other_job}" 'needs exactly one step with id cargo-home (found 0)'

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

# The rust-app shards' untrusted compiled restore (and the rust-db one) never holds compiled OpenSSL: the
# restore-time strip that follows it carries deny-door, and nothing may sit between them. The strip has no
# id (its verifier pin forbids one), so each case is a literal swap or an insertion at its name line.
strip_name='      - name: Strip workspace crates from the restored dependency cache (untrusted, read-only)'
door_msg="must be followed directly by the restore-time strip with deny-door: 'true'"
mutant 'door outputs not stripped: deny-door dropped from the untrusted strip' "${door_msg}" "${c}" "          deny-door: 'true'
" ''
mutant 'door outputs not stripped: deny-door false' "${door_msg}" "${c}" "          deny-door: 'true'" "          deny-door: 'false'"
mutant 'door outputs not stripped: deny-door an expression' "${door_msg}" "${c}" "          deny-door: 'true'" "          deny-door: \${{ inputs.source_sha != '' }}"
insert_mutant 'a step between the untrusted compiled restore and its door strip' "${door_msg}" "${c}" "${strip_name}" '      - name: Between restore and strip
        if: ${{ github.ref == '"'"'refs/heads/untrusted'"'"' }}
        shell: bash
        run: echo hi
'
mutant 'the untrusted strip loses its untrusted terms' "${door_msg}" "${c}" "${strip_name}
        if: \${{ github.ref == 'refs/heads/untrusted' && inputs.untrusted_readonly_cache && ${ct} }}" "${strip_name}
        if: \${{ github.ref == 'refs/heads/untrusted' }}"
mutant 'the door strip of the composite reduced to the plain strip' 'whole file must match the reviewed content hash' "${composite}" 'classify_lock "${sets}" door; else' 'classify_lock "${sets}"; else'
# A rust-app shard (or rust-db) saving from the untrusted ref: the save is main-only, never under the untrusted terms.
save_if_rust_app="\${{ github.ref == 'refs/heads/untrusted' && inputs.untrusted_readonly_cache && ${ct} }}"
save_step="      - name: Save compiled third-party dependencies (untrusted)
        if: ${save_if_rust_app}
        uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: |
            \${{ steps.cargo-target.outputs.dir }}/debug/deps
          key: \${{ steps.cargo-target.outputs.key }}
"
insert_mutant 'a rust-app untrusted restore with a save beside it' 'must not save a cache from the same job without the main-only gate' "${c}" '      - name: Complete the third-party source set before saving' "${save_step}"
insert_mutant 'rust-app-2 saving from the untrusted ref' 'must not save a cache from the same job without the main-only gate' "${c}" '      - name: Complete the third-party source set before saving' "      - name: Save compiled third-party dependencies (untrusted rust-app-2)
        if: \${{ github.ref == 'refs/heads/untrusted' && inputs.concern == 'rust-app-2' }}
        uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: |
            \${{ steps.cargo-target.outputs.dir }}/debug/deps
          key: \${{ steps.cargo-target.outputs.key }}
"
# Ordering: the compiled restore reads the locate step's dir and key, so it runs after locate, and nothing
# unpinned runs between them. A step moved above locate, and an unpinned step between, are both refused.
mv_mutant() { # label needle step-name-to-move anchor-step-name (the moved block lands before the anchor)
  local d="${work}/mutant"
  rm -rf "${d}"; cp -R "${reviewed}" "${d}"
  MOVE="$3" BEFORE="$4" ruby -e '
    path = ARGV.fetch(0); lines = File.read(path, encoding: "UTF-8").lines
    start = ->(name) { lines.index { |x| x.chomp == "      - name: #{name}" } or abort "untrusted restore fixture: step #{name} not found" }
    first = start.call(ENV.fetch("MOVE"))
    last = first + 1
    last += 1 until last >= lines.length || lines[last].start_with?("      - name:") || lines[last].start_with?("      # ")
    block = lines.slice!(first...last)
    lines.insert(start.call(ENV.fetch("BEFORE")), *block)
    File.write(path, lines.join)
  ' "${d}/${c}"
  expect_fail "$1" "${d}" "$2"
}
mv_mutant 'a rust-app untrusted restore moved before locate' 'must run before the untrusted restore cargo-target-cache-untrusted' 'Restore compiled third-party dependencies (untrusted, read-only)' 'Locate the compiled dependency cache'
insert_mutant 'an unpinned step between locate and the compiled restore' 'sits between cargo-target and the untrusted restore cargo-target-cache-untrusted' "${c}" '      - name: Restore compiled third-party dependencies' '      - name: Plant a shim
        shell: bash
        run: echo hi
'

# check-cache-groups.rb (main-only compiled-cache groups) skips exactly the reviewed untrusted restores of the
# Linux concern workflow: its three steps carry exactly the reviewed `if` terms and are restores or the
# restore-time strip. A widened term, a save, a strip in another mode, or the same step in another workflow
# is still a compiled-cache step there and is refused.
groups_run() { # dir workflow-file
  (cd "$1" && ruby "${OLDPWD}/${policy}/check-cache-groups.rb" "$2") 2>&1
}
out="$(groups_run "${reviewed}" "${c}")" || { echo "check-cache-groups should accept the reviewed untrusted restores: ${out}" >&2; exit 1; }
groups_mutant() { # label step-id from to
  local d="${work}/groups-mutant" o rc=0
  rm -rf "${d}"; cp -R "${reviewed}" "${d}"
  STEP="$2" FROM="$3" TO="$4" ruby -e '
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
  o="$(groups_run "${d}" "${c}")" || rc=$?
  [[ ${rc} -ne 0 && "${o}" == *'the cache steps other than the reviewed crate-sources pair must be exactly one each of'* ]] || { echo "check-cache-groups fixture '$1' should be refused as a compiled-cache step, got: ${o}" >&2; exit 1; }
}
groups_mutant 'the untrusted compiled restore gains a term' cargo-target-cache-untrusted "${ct} }}" "${ct} && inputs.source_sha != '' }}"
groups_mutant 'the untrusted compiled restore widened to every Rust concern' cargo-target-cache-untrusted "${ct} }}" "startsWith(inputs.concern, 'rust-') }}"
groups_mutant 'the untrusted compiled restore gains the OpenSSL door concern' cargo-target-cache-untrusted "${ct} }}" "(inputs.concern == 'rust-db' || startsWith(inputs.concern, 'rust-app-') || inputs.concern == 'rust-tls-openssl') }}"
groups_mutant 'the untrusted compiled restore becomes a save' cargo-target-cache-untrusted 'actions/cache/restore@' 'actions/cache/save@'
groups_mutant 'the untrusted sources restore becomes a combined cache step' cargo-sources-untrusted 'actions/cache/restore@' 'actions/cache@'
groups_mutant 'the untrusted sources restore loses the flag term' cargo-sources-untrusted "inputs.untrusted_readonly_cache && " ''
for other in macos-validation-concern.yml windows-validation-concern.yml; do
  d="${work}/groups-other-${other%%-*}"
  rm -rf "${d}"; mkdir -p "${d}/.github/workflows"
  cp ".github/workflows/${other}" "${d}/.github/workflows/"
  anchor="$(grep -n '^      - name: Restore cached third-party crate sources' ".github/workflows/${other}" | head -1 | cut -d: -f1)"
  insert_before "${d}/.github/workflows/${other}" "$(sed -n "${anchor}p" ".github/workflows/${other}")" "${work}/sources-step.yml"
  rc=0; o="$(groups_run "${d}" ".github/workflows/${other}")" || rc=$?
  [[ ${rc} -ne 0 ]] || { echo "check-cache-groups should refuse the untrusted restore in ${other}" >&2; exit 1; }
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
  cp "${true_tree}/.github/actions/rust-toolchain/action.yml" "${flipped}/.github/actions/rust-toolchain/action.yml"
  cp "${true_tree}/docs/untrusted-readonly-cache.md" "${flipped}/docs/"
  cp -R "${policy}" "${flipped}/.github/policy"
  (cd "${flipped}" && UNTRUSTED_SHAPE_CHILD=1 bash .github/policy/test-untrusted-restore-shape.sh >/dev/null) || { echo 'the untrusted restore fixtures failed on a flipped tree (flag true with its record)' >&2; exit 1; }
fi

echo 'untrusted restore fixtures: the reviewed read-only restores pass; a widened term, key, path or step key, a save, a write token, an unrecorded or misplaced switch and any other workflow are refused'
