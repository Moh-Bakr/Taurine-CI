#!/usr/bin/env bash
# Fixtures for the fail-fast suite-ownership check (refuse-unowned-tests.rb).
#
# The check runs at the start of every Linux concern job, after the token is revoked and root is
# dropped and before any project command, on data only: the generated ownership manifest and the
# tracked file names. These fixtures build synthetic repositories and prove it:
#   - accepts a tree where every in-scope test file matches a suite's include glob;
#   - refuses an added file and a renamed file the manifest does not cover, by count and reason class,
#     and prints no path, pattern or file name anywhere (stdout, stderr or the step summary);
#   - ignores the reviewed exempt trees, node_modules and non-test files, and skips a source with no
#     manifest (an older revision) without failing;
#   - fails closed on a malformed manifest and on a tree it cannot list;
#   - uses the collector's glob semantics exactly (`*` stays in a segment, `**` crosses).
# Run from the repository root (the policy workflow does).
set -euo pipefail
script="${PWD}/.github/policy/refuse-unowned-tests.rb"
collector="${PWD}/.github/policy/collect-suite-evidence.rb"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

new_repo() { # new_repo NAME: an empty repository at ${work}/NAME
  local repo="${work}/$1"
  mkdir -p "${repo}"
  git -C "${repo}" init -q
  git -C "${repo}" config user.email ci@example.invalid
  git -C "${repo}" config user.name ci
  git -C "${repo}" config commit.gpgsign false
  printf '%s' "${repo}"
}
add_file() { mkdir -p "$(dirname "$1/$2")"; echo "// $2" > "$1/$2"; }
commit_all() { git -C "$1" add -A; git -C "$1" commit -q -m fixture; }
write_manifest() { # write_manifest REPO JSON
  mkdir -p "$1/scripts/ci"
  printf '%s\n' "$2" > "$1/scripts/ci/suite-ownership.json"
}
run_check() { # run_check REPO: sets rc, out, err, summary
  : > "${work}/summary.md"
  rc=0
  GITHUB_STEP_SUMMARY="${work}/summary.md" ruby "${script}" "$1" >"${work}/out.txt" 2>"${work}/err.txt" || rc=$?
  out="$(cat "${work}/out.txt")"; err="$(cat "${work}/err.txt")"; summary="$(cat "${work}/summary.md")"
}
expect_rc() { [[ "${rc}" == "$2" ]] || { echo "ownership case '$1': exit ${rc}, wanted $2: ${out} ${err}" >&2; exit 1; }; }
expect_text() { # expect_text LABEL TEXT: in stdout or stderr
  grep -qF -- "$2" <<<"${out}${err}" || { echo "ownership case '$1': output lacks '$2': ${out} ${err}" >&2; exit 1; }
}
expect_absent() { # expect_absent LABEL TEXT: nowhere in any output
  if grep -qF -- "$2" <<<"${out}${err}${summary}"; then echo "ownership case '$1': output leaks '$2'" >&2; exit 1; fi
}

MANIFEST='{"schema_version":1,"suites":{"a.owner":{"feature":"a","include":["taurine-desktop/tests/e2e/a11y/**","taurine-desktop/src/features/rest/thing.test.ts"]},"b.owner":{"feature":"b","include":["taurine-desktop/src/**/*.test.tsx"]}}}'

# 1. Every in-scope test file is owned.
repo="$(new_repo owned)"
add_file "${repo}" taurine-desktop/tests/e2e/a11y/page.spec.ts
add_file "${repo}" taurine-desktop/tests/e2e/a11y/deep/nested.spec.ts
add_file "${repo}" taurine-desktop/src/features/rest/thing.test.ts
add_file "${repo}" taurine-desktop/src/features/rest/ui/view.test.tsx
write_manifest "${repo}" "${MANIFEST}"
commit_all "${repo}"
run_check "${repo}"; expect_rc owned 0
expect_text owned '4 test file(s) checked, every one has a suite owner'

# 2. An added test file with no owner is refused by count and reason class; no name or path is printed.
add_file "${repo}" taurine-desktop/tests/e2e/secretarea/brand-new.spec.ts
commit_all "${repo}"
run_check "${repo}"; expect_rc added 1
expect_text added 'ownership_unowned'
expect_text added '1 of 5 test file(s) have no suite owner'
for leak in brand-new secretarea taurine-desktop/tests 'a11y/**' suite-ownership.json; do expect_absent added "${leak}"; done
grep -qF 'Suite ownership' <<<"${summary}" || { echo 'the refusal did not reach the step summary' >&2; exit 1; }

# 3. A renamed test file that leaves its owner's directory is refused (a rename is an add at the new path).
repo="$(new_repo renamed)"
add_file "${repo}" taurine-desktop/tests/e2e/a11y/page.spec.ts
write_manifest "${repo}" "${MANIFEST}"
commit_all "${repo}"
git -C "${repo}" mv taurine-desktop/tests/e2e/a11y/page.spec.ts taurine-desktop/tests/e2e/page-moved.spec.ts
commit_all "${repo}"
run_check "${repo}"; expect_rc renamed 1
expect_text renamed '1 of 1 test file(s) have no suite owner'
expect_absent renamed page-moved

# 4. Exempt trees, node_modules and non-test files are never counted.
repo="$(new_repo exempt)"
add_file "${repo}" taurine-desktop/tests/e2e/a11y/page.spec.ts
add_file "${repo}" skills/orchestrate/scripts/__tests__/a.test.mjs
add_file "${repo}" vendor/upstream/b.test.ts
add_file "${repo}" taurine-mobile/tests/e2e/journeys.spec.ts
add_file "${repo}" taurine-desktop/node_modules/pkg/c.test.js
add_file "${repo}" taurine-desktop/tests/e2e/helpers/support.ts
add_file "${repo}" taurine-desktop/src/readme.md
write_manifest "${repo}" "${MANIFEST}"
commit_all "${repo}"
run_check "${repo}"; expect_rc exempt 0
expect_text exempt '1 test file(s) checked'

# 5. A source with no ownership manifest (an older revision) is skipped, not failed.
repo="$(new_repo nomanifest)"
add_file "${repo}" taurine-desktop/tests/e2e/x.spec.ts
commit_all "${repo}"
run_check "${repo}"; expect_rc nomanifest 0
expect_text nomanifest 'skipped'

# 6. A manifest the check cannot read fails closed with a fixed reason class.
for bad in 'not json' '[]' '{"suites":[]}' '{"suites":{"a":{"include":"x"}}}' '{"suites":{"a":{"include":[1]}}}' \
           '{"suites":{"a":{"include":["/abs/**"]}}}' '{"suites":{"a":{"include":["../up/**"]}}}' '{"suites":{"a":{"include":[""]}}}'; do
  repo="$(new_repo bad)"
  add_file "${repo}" taurine-desktop/tests/e2e/x.spec.ts
  write_manifest "${repo}" "${bad}"
  commit_all "${repo}"
  run_check "${repo}"; expect_rc "malformed ${bad}" 1
  grep -qE 'reason (manifest_shape|manifest_glob)' <<<"${err}" || { echo "malformed manifest '${bad}': no fixed reason class: ${err}" >&2; exit 1; }
  rm -rf "${repo}"
done

# 7. A directory that is not a repository cannot be listed: fail closed.
mkdir -p "${work}/plain/scripts/ci"
printf '%s\n' "${MANIFEST}" > "${work}/plain/scripts/ci/suite-ownership.json"
run_check "${work}/plain"; expect_rc plain 1
expect_text plain 'reason file_list'

# 8. Glob semantics: `*` stays inside one segment, `**` crosses directories.
repo="$(new_repo globs)"
add_file "${repo}" taurine-desktop/src/x.test.tsx
add_file "${repo}" taurine-desktop/src/deep/er/y.test.tsx
write_manifest "${repo}" '{"suites":{"s":{"include":["taurine-desktop/src/*.test.tsx"]}}}'
commit_all "${repo}"
run_check "${repo}"; expect_rc 'single-star' 1
expect_text 'single-star' '1 of 2 test file(s) have no suite owner'
write_manifest "${repo}" '{"suites":{"s":{"include":["taurine-desktop/src/**"]}}}'
run_check "${repo}"; expect_rc 'double-star' 0
# The collector's own reading: `a/**/*.ts` needs a separator after the `**`, so it does not own `a/x.ts`.
write_manifest "${repo}" '{"suites":{"s":{"include":["taurine-desktop/src/**/*.test.tsx"]}}}'
run_check "${repo}"; expect_rc 'double-star-with-suffix' 1
expect_text 'double-star-with-suffix' '1 of 2 test file(s) have no suite owner'
# A literal dot is not a wildcard.
write_manifest "${repo}" '{"suites":{"s":{"include":["taurine-desktop/src/x.testXtsx","taurine-desktop/src/deep/**"]}}}'
run_check "${repo}"; expect_rc 'literal-dot' 1

# 9. The check's glob is the collector's glob: the two implementations agree on every shape in use.
ruby -e '
  def grab(path)
    text = File.read(path)
    src = text[/^def glob_regex\(glob\)\n.*?^end\n/m] or abort "no glob_regex in #{path}"
    mod = Module.new
    mod.module_eval(src)
    mod.instance_method(:glob_regex).bind(Object.new.extend(mod))
  end
  a = grab(ARGV.fetch(0)); b = grab(ARGV.fetch(1))
  globs = %w[a/** a/*.ts a/**/*.ts a/b.spec.ts **/x a/*/b.ts a/b.c*]
  paths = %w[a/x.ts a/b/x.ts a/b/c/x.ts a/b.spec.ts x a/x/b.ts a/bXspec.ts a/b.cd a/b.c a/b/c.ts]
  globs.product(paths).each do |glob, path|
    abort "glob #{glob} disagrees on #{path}" unless a.call(glob).match?(path) == b.call(glob).match?(path)
  end
' "${script}" "${collector}"

# 9b. A glob outside plain path characters is refused with the fixed reason manifest_glob, and nothing of the
# glob is printed: not the text, not an error class, not a backtrace. The unclosed bracket would otherwise make
# the regular expression compiler quote the pattern.
for hostile in 'secret-private-dir/[unclosed' 'secret-private-dir/(open' 'secret-private-dir/a?b' 'secret-private-dir/{a,b}' 'secret-private-dir/a b' 'secret-private-dir/a\b' 'secret-private-dir/a|b' 'secret-private-dir/$x'; do
  repo="$(new_repo hostile)"
  add_file "${repo}" taurine-desktop/tests/e2e/x.spec.ts
  ruby -rjson -e 'File.write(ARGV[1], JSON.generate({"suites" => {"s" => {"include" => [ARGV[0]]}}}))' "${hostile}" "${repo}/manifest.json"
  mkdir -p "${repo}/scripts/ci"; mv "${repo}/manifest.json" "${repo}/scripts/ci/suite-ownership.json"
  commit_all "${repo}"
  run_check "${repo}"; expect_rc "hostile glob ${hostile}" 1
  expect_text "hostile glob ${hostile}" 'reason manifest_glob'
  for leak in secret-private-dir unclosed Regexp 'from /' '.rb:' Error; do expect_absent "hostile glob ${hostile}" "${leak}"; done
  rm -rf "${repo}"
done
# The characters the manifest really uses, plus @ + and -, are plain path characters and are accepted.
repo="$(new_repo plainchars)"
add_file "${repo}" 'taurine-desktop/src/@scope/pkg+x-y/a_b.test.ts'
write_manifest "${repo}" '{"suites":{"s":{"include":["taurine-desktop/src/@scope/pkg+x-y/**"]}}}'
commit_all "${repo}"
run_check "${repo}"; expect_rc plainchars 0

# 9c. A file name that is not valid text (written straight into the index, as a file system that refuses such
# names cannot hold it) is counted like any other: it neither crashes the matcher nor reaches the log.
repo="$(new_repo badbytes)"
add_file "${repo}" taurine-desktop/tests/e2e/a11y/page.spec.ts
write_manifest "${repo}" "${MANIFEST}"
commit_all "${repo}"
blob="$(printf 'x' | git -C "${repo}" hash-object -w --stdin)"
git -C "${repo}" update-index --add --cacheinfo "100644,${blob},taurine-desktop/tests/e2e/secretarea/$(printf 'bad\377name').spec.ts"
git -C "${repo}" update-index --add --cacheinfo "100644,${blob},notes/$(printf 'plain\377').txt"
run_check "${repo}"; expect_rc badbytes 1
expect_text badbytes '1 of 2 test file(s) have no suite owner'
expect_absent badbytes secretarea

# 9d. The manifest must be a plain file: a symbolic link to a readable file is refused, not followed.
repo="$(new_repo linkedmanifest)"
add_file "${repo}" taurine-desktop/tests/e2e/a11y/page.spec.ts
mkdir -p "${repo}/scripts/ci"
printf '%s\n' "${MANIFEST}" > "${work}/elsewhere.json"
ln -s "${work}/elsewhere.json" "${repo}/scripts/ci/suite-ownership.json"
commit_all "${repo}"
run_check "${repo}"; expect_rc linkedmanifest 1
expect_text linkedmanifest 'reason manifest_shape'
# a directory in its place is refused too
repo="$(new_repo dirmanifest)"
add_file "${repo}" taurine-desktop/tests/e2e/a11y/page.spec.ts
mkdir -p "${repo}/scripts/ci/suite-ownership.json"; echo x > "${repo}/scripts/ci/suite-ownership.json/f"
commit_all "${repo}"
run_check "${repo}"; expect_rc dirmanifest 1
expect_text dirmanifest 'reason manifest_shape'

# 9e. An unforeseen error prints a fixed reason class only: a stand-in raising an error whose message names a
# secret directory must leave none of it, nor its class or backtrace, in any output.
repo="$(new_repo internal)"
add_file "${repo}" taurine-desktop/tests/e2e/a11y/page.spec.ts
write_manifest "${repo}" "${MANIFEST}"
commit_all "${repo}"
cat > "${work}/boom.rb" <<'BOOM'
require 'open3'
module Open3
  def self.capture2(*)
    raise ArgumentError, 'secret-private-dir exploded'
  end
end
BOOM
: > "${work}/summary.md"; rc=0
GITHUB_STEP_SUMMARY="${work}/summary.md" ruby -r "${work}/boom.rb" "${script}" "${repo}" >"${work}/out.txt" 2>"${work}/err.txt" || rc=$?
out="$(cat "${work}/out.txt")"; err="$(cat "${work}/err.txt")"; summary="$(cat "${work}/summary.md")"
expect_rc internal 1
expect_text internal 'reason internal'
for leak in secret-private-dir exploded ArgumentError 'from /' '.rb:'; do expect_absent internal "${leak}"; done

# 10. The wiring: the check is a step of every Linux concern job (no condition, never tolerated), after the
# token revocation (the source checkout) and the root drop, and before any dependency install, toolchain
# setup, scanner or project command, so a refusal arrives in the seconds after the checkout.
ruby -ryaml -e '
  steps = YAML.safe_load(File.read(".github/workflows/linux-validation-concern.yml"), aliases: false).fetch("jobs").fetch("validate").fetch("steps")
  at = ->(name) { steps.index { |s| s["name"] == name } or abort("step missing: #{name}") }
  check = at.call("Refuse test files with no suite owner before any build")
  step = steps.fetch(check)
  abort "the ownership step must run for every concern, unconditionally and never tolerated" if step.key?("if") || step.key?("continue-on-error")
  abort "the ownership step must run exactly the reviewed command" unless step["run"].to_s.include?("ruby .github/policy/refuse-unowned-tests.rb \"${GITHUB_WORKSPACE}/src\"") && step["shell"] == "bash"
  checkout = steps.index { |s| s["uses"].to_s == "./.github/actions/source-checkout" } or abort "no source checkout"
  drop = steps.index { |s| s["uses"].to_s == "./.github/actions/drop-root" } or abort "no drop-root"
  abort "the ownership check must follow the source checkout and the root drop" unless checkout < drop && drop < check
  %w[node-setup rust-toolchain vendor-fetch linux-concern-js linux-concern-e2e linux-concern-rust].each do |action|
    steps.each_with_index do |s, i|
      abort "#{action} (step #{i}) runs before the ownership check" if s["uses"].to_s == "./.github/actions/#{action}" && i < check
    end
  end
  abort "the early check must come after the suite contract snapshot, in the same pre-build window" unless at.call("Read the suite contract for this concern") < check
'
echo 'suite ownership check: owned, added, renamed, exempt, missing-manifest, malformed and glob cases behave as specified; no path is ever printed'
