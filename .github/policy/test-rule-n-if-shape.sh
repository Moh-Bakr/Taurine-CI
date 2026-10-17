#!/usr/bin/env bash
# Rule N must inspect YAML scalar style: |- and >- can decode to one line, while
# clipping/keeping can leave whitespace around a wrapped expression. Neither may
# be normalized into an apparently safe main-only cache restore condition.
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rule-n-if-shape.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
checker=.github/policy/check-cache-mode.rb
shape_msg='has a block-scalar or multiline if'
cp .github/policy/cache-expression.rb "${work}/cache-expression.rb"
stage_2_msg="awaits the owner's Stage 2 decision"

fixture() { # file, if-lines, action (optional), job-key (optional)
  printf 'name: f\non:\n  workflow_dispatch:\npermissions: {}\njobs:\n  %s:\n    runs-on: ubuntu-24.04\n    steps:\n      - name: Cache fixture\n%s        uses: %s\n        with:\n          path: /tmp/x\n          key: k\n' \
    "${4:-a}" "$2" "${3:-actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9}" > "$1"
}

expect_pass() {
  ruby "$1" "$2" >"${work}/out" 2>"${work}/err" || {
    echo "rule N if-shape fixture '$3' should pass but failed:" >&2
    cat "${work}/err" >&2
    exit 1
  }
}

expect_fail() {
  if ruby "$1" "$2" >"${work}/out" 2>"${work}/err"; then
    echo "rule N if-shape fixture '$3' should fail but passed" >&2
    exit 1
  fi
  grep -qF -- "$4" "${work}/err" || {
    echo "rule N if-shape fixture '$3' failed with the wrong message:" >&2
    cat "${work}/err" >&2
    exit 1
  }
}

main_if=$'        if: ${{ github.ref == \'refs/heads/main\' }}\n'
untrusted_if=$'        if: ${{ github.ref == \'refs/heads/untrusted\' }}\n'
fixture "${work}/control.yml" "${main_if}"
expect_pass "${checker}" "${work}/control.yml" 'single-line main-only if'
# Quoting a single-line expression is safe too; scalar style is not inferred from text.
fixture "${work}/quoted.yml" $'        if: "${{ github.ref == \'refs/heads/main\' }}"\n'
expect_pass "${checker}" "${work}/quoted.yml" 'quoted single-line if'

# Remove the shape guard and restore the old whitespace normalization in a checker
# copy. Block fixtures must pass it, proving unrelated failures cannot satisfy this suite.
ruby -e '
  text = File.read(ARGV.fetch(0))
  mutated = text.sub(/      if block_scalar_ifs\.fetch\(path\).*?      end\n/m, "")
  abort "the if-shape refusal block was not found" unless mutated != text
  mutated = mutated.sub("CacheExpression.top_terms(value)", "CacheExpression.top_terms(value.is_a?(String) ? value.strip : value)")
  abort "the copy lost rule N" unless mutated.include?("awaits the owner\x27s Stage 2 decision")
  File.write(ARGV.fetch(1), mutated)
' "${checker}" "${work}/copy.rb"
fixture "${work}/untrusted.yml" "${untrusted_if}"
expect_fail "${work}/copy.rb" "${work}/untrusted.yml" 'untrusted restore via copy' "${stage_2_msg}"
fixture "${work}/ungated.yml" ''
expect_fail "${checker}" "${work}/ungated.yml" 'ungated restore' "${stage_2_msg}"

# Literal/folded, clip/strip/keep, explicit indentation and folded multi-line
# spellings all remain block scalars even if their decoded text has no newline.
for style in '|' '>' '|-' '>-' '|+' '>+' '|2-' '>2-'; do
  condition="$(printf '        if: %s\n          ${{ github.ref == '\''refs/heads/main'\'' }}\n' "${style}")"$'\n'
  for action in actions/cache/restore actions/cache; do
    fixture "${work}/block.yml" "${condition}" "${action}@55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
    expect_fail "${checker}" "${work}/block.yml" "${action} if ${style}" "${shape_msg}"
    expect_pass "${work}/copy.rb" "${work}/block.yml" "unguarded ${action} if ${style}"
  done
done
fixture "${work}/folded-lines.yml" $'        if: >-\n          ${{ github.ref == \'refs/heads/main\'\n          && success() }}\n'
expect_fail "${checker}" "${work}/folded-lines.yml" 'folded multi-line expression' "${shape_msg}"
expect_pass "${work}/copy.rb" "${work}/folded-lines.yml" 'unguarded folded expression'
fixture "${work}/quoted-newline.yml" $'        if: "${{ github.ref == \'refs/heads/main\' }}\\n"\n'
expect_fail "${checker}" "${work}/quoted-newline.yml" 'escaped newline in quoted if' "${shape_msg}"
fixture "${work}/quoted-return.yml" $'        if: "${{ github.ref == \'refs/heads/main\' }}\\r"\n'
expect_fail "${checker}" "${work}/quoted-return.yml" 'escaped carriage return in quoted if' "${shape_msg}"

# Raw AST keys must resolve exactly like safe_load: YAML 1.1 boolean aliases,
# quoted strings, and explicit tags must all retain their condition style metadata.
for job in on off yes no ON OFF YES NO true false '"on"' '"off"' '!!str on' '!!str off' '!!bool on' '!!bool off' 12 null; do
  for style in '|-' '>-'; do
    condition="$(printf '        if: %s\n          ${{ github.ref == '\''refs/heads/main'\'' }}\n' "${style}")"$'\n'
    fixture "${work}/resolved-key.yml" "${condition}" '' "${job}"
    expect_fail "${checker}" "${work}/resolved-key.yml" "job ${job} if ${style}" "${shape_msg}"
    expect_pass "${work}/copy.rb" "${work}/resolved-key.yml" "unguarded job ${job} if ${style}"
    fixture "${work}/resolved-key.yml" "${main_if}" '' "${job}"
    expect_pass "${checker}" "${work}/resolved-key.yml" "job ${job} single-line control"
  done
done

# Keep aliases refused; no style metadata may be inherited invisibly from an anchor.
fixture "${work}/alias.yml" $'        if: *condition\n'
ruby - "${work}/alias.yml" <<'RUBY'
path = ARGV.fetch(0)
File.write(path, "condition: &condition |-\n  ${{ github.ref == 'refs/heads/main' }}\n" + File.read(path))
RUBY
expect_fail "${checker}" "${work}/alias.yml" 'aliased block condition' 'alias'

# A cache reached through a local composite has the same gate on its calling step.
mkdir -p "${work}/tree/.github/actions/cache-wrapper"
cp "${checker}" "${work}/tree/checker.rb"
cp .github/policy/cache-expression.rb "${work}/tree/cache-expression.rb"
printf 'runs:\n  using: composite\n  steps:\n    - uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9\n' \
  > "${work}/tree/.github/actions/cache-wrapper/action.yml"
fixture "${work}/tree/wrapper.yml" $'        if: |-\n          ${{ github.ref == \'refs/heads/main\' }}\n' './.github/actions/cache-wrapper'
(cd "${work}/tree" && expect_fail checker.rb wrapper.yml 'composite cache call' "${shape_msg}")
fixture "${work}/tree/wrapper.yml" "${main_if}" './.github/actions/cache-wrapper'
(cd "${work}/tree" && expect_pass checker.rb wrapper.yml 'main-only composite cache call')

# Metadata lookup must stay aligned with job/step identity across unrelated steps.
fixture "${work}/multiple.yml" $'        if: |-\n          ${{ github.ref == \'refs/heads/main\' }}\n'
ruby -e 'path=ARGV.fetch(0); text=File.read(path); File.write(path,text.sub("    steps:\n", "    steps:\n      - run: echo fixture\n"))' "${work}/multiple.yml"
expect_fail "${checker}" "${work}/multiple.yml" 'restore after unrelated step' "${shape_msg}"

# Non-cache steps and save-only steps are outside this restore-specific rule.
for action in actions/checkout actions/cache/save; do
  fixture "${work}/other.yml" $'        if: |-\n          ${{ github.ref == \'refs/heads/main\' }}\n' "${action}@55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
  expect_pass "${checker}" "${work}/other.yml" "${action} outside rule N"
done

ruby .github/policy/test-cache-expressions.rb

echo 'rule N if shape: block styles, chomping, quoted newlines, combined/composite restores and guard falsification passed'
