#!/usr/bin/env bash
# Test the keyed failing-test identities against fixtures (owner decision 2026-10-18, option A)
#
# A public log may identify a FAILING test only as `failed-test-id: <16 hex>`, an HMAC of its file
# and title under a key held in the private source. This test runs the extractors of the shared
# sanitize and concern-report libraries over synthetic failure output and proves, for every
# runner shape: the published lines match one fixed grammar; no title, file, binary, thread name,
# assertion text or secret reaches the output; an id is stable across runs, timings and wrappers
# and differs between tests and between keys; the ruby and python3 implementations agree on a
# pinned vector; every failure mode of the key (absent, malformed, a symlink, an unreadable
# tool) prints counts only; and the source-checkout step that snapshots the key accepts only its
# fixed format, masks the key and never prints it.
# Run from the repository root (the policy workflow runs test-extractors.sh, which calls this).
set -euo pipefail
base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
dir="$(mktemp -d "${base%/}/keyed-ids.XXXXXX")"
trap 'rm -rf "${dir}"' EXIT
mkdir -p "${dir}/rt/taurine-ci"
awk "/cat > .*sanitize.sh.* <<'TCI_SANITIZE_LIBRARY'/{on=1; next} /^        TCI_SANITIZE_LIBRARY/{on=0} on" .github/actions/sanitize/action.yml | sed -E 's/^        //' > "${dir}/lib.sh"
awk "/cat > .*report.sh.* <<'TCI_REPORT_LIBRARY'/{on=1; next} /^        TCI_REPORT_LIBRARY/{on=0} on" .github/actions/concern-report/action.yml | sed -E 's/^        //' > "${dir}/report.sh"
[[ -s "${dir}/lib.sh" && -s "${dir}/report.sh" ]] || { echo 'the sanitize or report library was not found' >&2; exit 1; }

# A synthetic key (never a real one): the bytes 0x00..0x1f, key id k7.
key_hex='000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
other_hex='ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100'
printf 'key-id=k7\nkey=%s\n' "${key_hex}" > "${dir}/rt/taurine-ci/test-id-key"

# Pinned vectors: HMAC-SHA256(key, "taurine-test-id/v1" 0x1f kind 0x1f file 0x1f title)[0:16].
v_rust=7e68f94581f747d5       # rust    taurine-db::tests            queries::it_works
v_rust_name=c84f015d593f51d9  # rust-name (no file)                   queries::it_works
v_js=4f5080e98f1c1f0f         # js      taurine-desktop/src/a.test.ts Suite > does a thing
v_e2e=02b2c1599dc6923c        # e2e     e2e/a.spec.ts                 t
v_file=907b4a6102d0271d       # file    taurine-db/tests/x.rs         (empty title)
v_utf8=d4069f93924f080f       # js      taurine-desktop/src/é.test.ts ünï > ✓

grammar='^(test-id-key: k[0-9]{1,4}|failed-test-id: [0-9a-f]{16} status=(fail|signal|timeout|leak|flaky)|failed-tests-unidentified: [0-9]+|failed-test-ids: unavailable \(no keyed key or HMAC tool\); failing tests: [0-9]+)$'
fail() { echo "keyed test ids: $*" >&2; exit 1; }
run() { # run <key rt dir> <script...>: a clean shell with both libraries sourced
  local rt="$1"; shift
  RUNNER_TEMP="${rt}" bash -c 'set -euo pipefail; source "$1/lib.sh"; source "$1/report.sh"; shift; eval "$1"' _ "${dir}" "$*"
}
only_grammar() { # only_grammar <text>: every line is a published-id line
  local line
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ${grammar} ]] || fail "a line outside the published grammar: ${line}"
  done <<<"$1"
}
no_leak() { # no_leak <text> <pattern>
  if grep -qE "$2" <<<"$1"; then fail "output leaked a forbidden string ($2): $1"; fi
}
has() { grep -qF -- "$2" <<<"$1" || fail "expected '$2' in: $1"; }

# --- 1. The two implementations agree with each other and with the pinned vectors.
printf 'rust\ttaurine-db::tests\tqueries::it_works\nrust-name\t\tqueries::it_works\njs\ttaurine-desktop/src/a.test.ts\tSuite > does a thing\ne2e\te2e/a.spec.ts\tt\nfile\ttaurine-db/tests/x.rs\t\njs\ttaurine-desktop/src/é.test.ts\tünï > ✓\n' > "${dir}/vec.tsv"
printf '%s\n' "${v_rust}" "${v_rust_name}" "${v_js}" "${v_e2e}" "${v_file}" "${v_utf8}" > "${dir}/vec.expected"
implementations=0
if command -v ruby >/dev/null 2>&1; then
  RUBY_OUT="$(run "${dir}/rt" 'ruby -e "${TCI_TEST_ID_RUBY}" "${TCI_TEST_ID_KEY}" < "'"${dir}"'/vec.tsv"')"
  [[ "${RUBY_OUT}" == "$(cat "${dir}/vec.expected")" ]] || fail "the ruby implementation disagrees with the pinned vectors"
  implementations=$((implementations + 1))
fi
if command -v python3 >/dev/null 2>&1; then
  PY_OUT="$(run "${dir}/rt" 'python3 -I -c "${TCI_TEST_ID_PYTHON}" "${TCI_TEST_ID_KEY}" < "'"${dir}"'/vec.tsv"')"
  [[ "${PY_OUT}" == "$(cat "${dir}/vec.expected")" ]] || fail "the python3 implementation disagrees with the pinned vectors"
  implementations=$((implementations + 1))
fi
[[ "${implementations}" -ge 1 ]] || fail 'neither ruby nor python3 is available to test the HMAC'

# --- 2. A different key gives different ids (the key, not the name, decides the id).
mkdir -p "${dir}/rt2/taurine-ci"; printf 'key-id=k8\nkey=%s\n' "${other_hex}" > "${dir}/rt2/taurine-ci/test-id-key"
out2="$(run "${dir}/rt2" 'tci_hmac_ids < "'"${dir}"'/vec.tsv"')"
[[ "${out2}" != "$(cat "${dir}/vec.expected")" ]] || fail 'two different keys produced the same ids'
[[ "$(sort -u <<<"${out2}" | wc -l | tr -d ' ')" == 6 ]] || fail 'distinct tests collided under another key'

# --- 3. cargo-nextest: ANSI colour, timings, the progress counter and a retry line change nothing.
esc=$'\033'
cat > "${dir}/nextest.log" <<LOG
    Starting 4 tests across 2 binaries
        PASS [   0.011s] ( 1/4) taurine-db::tests queries::passes_fine
${esc}[31m        FAIL${esc}[0m [   0.011s] ( 2/4) taurine-db::tests queries::it_works
--- STDOUT:              taurine-db::tests queries::it_works ---
the secret value hunter2 and an assertion left: "SECRETLEFT"
--- STDERR:              taurine-db::tests queries::it_works ---
thread 'queries::it_works' panicked at taurine-db/tests/queries.rs:12:5:
     TRY 1 FAIL [   0.010s] taurine-db::tests queries::it_works
     SIGABRT [   2.000s] ( 3/4) taurine-db crash_in_secretcrate_module
     FLAKY 2/3 [   0.5s] ( 4/4) taurine-db::tests queries::flaky_secret_test
------------
     Summary [   2.5s] 4 tests run: 1 passed, 2 failed, 0 skipped
LOG
cat > "${dir}/nextest-other.log" <<LOG
        FAIL [  99.999s] taurine-db::tests queries::it_works
LOG
out="$(run "${dir}/rt" 'nextest_failures "'"${dir}"'/nextest.log"')"
only_grammar "${out}"
has "${out}" "test-id-key: k7"
has "${out}" "failed-test-id: ${v_rust} status=fail"
grep -qE 'failed-test-id: [0-9a-f]{16} status=signal' <<<"${out}" || fail 'the signal status was not reported'
grep -qE 'failed-test-id: [0-9a-f]{16} status=flaky' <<<"${out}" || fail 'the flaky status was not reported'
[[ "$(grep -c '^failed-test-id:' <<<"${out}")" == 3 ]] || fail "expected three failing-test ids, got: ${out}"
no_leak "${out}" 'queries|it_works|taurine-db|secret|hunter2|crash_in|tests|passes_fine|queries.rs'
out_other="$(run "${dir}/rt" 'nextest_failures "'"${dir}"'/nextest-other.log"')"
has "${out_other}" "failed-test-id: ${v_rust} status=fail"
# the failure recap in the summary and the detail extractor print no test name either
out="$(run "${dir}/rt" 'cargo_test_detail "'"${dir}"'/nextest.log" 2>&1')"
no_leak "${out}" 'queries|it_works|crash_in|flaky_secret|taurine-db|hunter2|SECRETLEFT'

# --- 4. libtest (cargo test): names only, so kind rust-name; the result line, the block header and the list.
cat > "${dir}/cargo.log" <<'LOG'
running 2 tests
test queries::it_works ... FAILED
test queries::fine ... ok

failures:

---- queries::it_works stdout ----
thread 'queries::it_works' panicked at taurine-db/tests/queries.rs:12:5:
assertion `left == right` failed
  left: "SECRETLEFT"

failures:
    queries::it_works

test result: FAILED. 1 passed; 1 failed; 0 ignored
LOG
out="$(run "${dir}/rt" 'failed_test_names "'"${dir}"'/cargo.log"')"
only_grammar "${out}"
has "${out}" "failed-test-id: ${v_rust_name} status=fail"
[[ "$(grep -c '^failed-test-id:' <<<"${out}")" == 1 ]] || fail 'the three places a libtest failure is named were not merged into one id'
no_leak "${out}" 'queries|it_works|SECRETLEFT'
out="$(run "${dir}/rt" 'cargo_test_detail "'"${dir}"'/cargo.log" 2>&1; cargo_detail "'"${dir}"'/cargo.log" 2>&1')"
no_leak "${out}" 'queries|it_works|SECRETLEFT'
has "${out}" 'test result: FAILED'

# --- 5. Panics: a keyed file id and a line, never the thread (test) name, the path or the message.
cat > "${dir}/panic.log" <<'LOG'
thread 'queries::it_works' panicked at taurine-db/tests/x.rs:12:5:
assertion `left == right` failed: SECRETMSG code=not_connected
  left: "SECRETLEFT"
thread 'other::secret_name' panicked at taurine-db/tests/y.rs:40:9:
explicit panic
LOG
out="$(run "${dir}/rt" 'panic_summary "'"${dir}"'/panic.log"')"
has "${out}" "file-id=${v_file}  line=12"
has "${out}" 'code=not_connected'
printf "thread 'a::b' panicked at /Users/alice/proj/z.rs:5:1:\nexplicit panic\n" > "${dir}/panic-abs.log"
out_abs="$(run "${dir}/rt" 'panic_summary "'"${dir}"'/panic-abs.log"')"
no_leak "${out_abs}" 'alice|Users|z\.rs|a::b'
grep -qE '^  panic  file-id=[0-9a-f]{16}  line=40  explicit panic$' <<<"${out}" || fail "a panic line has the wrong shape: ${out}"
no_leak "${out}" 'queries|it_works|secret|SECRET|[xy]\.rs|taurine-db|alice|Users'
mkdir -p "${dir}/rt0/taurine-ci"
out="$(run "${dir}/rt0" 'panic_summary "'"${dir}"'/panic.log"')"
has "${out}" 'file-id=unavailable  line=12'
no_leak "${out}" 'queries|it_works|secret|SECRET|[xy]\.rs|alice'

# --- 6. Vitest: paths are relative to the app root (as the real runner prints them), the project
# prefix, ANSI, a failed file load and the double print of a failure.
cat > "${dir}/vitest.log" <<LOG
${esc}[31m FAIL ${esc}[0m src/a.test.ts > Suite > does a thing
AssertionError: expected 'SECRETRECEIVED' to be 'SECRETEXPECTED'
 FAIL  |desktop| src/a.test.ts > Suite > does a thing
 FAIL  src/broken.test.ts [ src/broken.test.ts ]
 FAIL  src/é.test.ts > ünï > ✓
 FAIL  ../packages/x/src/b.test.ts > Shared > works
 Test Files  2 failed | 3 passed (5)
      Tests  3 failed | 40 passed (43)
LOG
out="$(run "${dir}/rt" 'test_failures "'"${dir}"'/vitest.log" taurine-desktop/ 2>&1')"
grep -vE '^( Test Files| *Tests) ' <<<"${out}" > "${dir}/vitest.ids"
only_grammar "$(cat "${dir}/vitest.ids")"
has "${out}" "failed-test-id: ${v_js} status=fail"
has "${out}" "failed-test-id: ${v_utf8} status=fail"
v_shared="$(printf 'js\tpackages/x/src/b.test.ts\tShared > works\n' | run "${dir}/rt" 'tci_hmac_ids')"
has "${out}" "failed-test-id: ${v_shared} status=fail"
[[ "$(grep -c '^failed-test-id:' <<<"${out}")" == 4 ]] || fail "expected four vitest ids (the repeat is one), got: ${out}"
has "${out}" 'Test Files  2 failed | 3 passed (5)'
has "${out}" 'Tests  3 failed | 40 passed (43)'
no_leak "${out}" 'a\.test|broken|Suite|does a thing|SECRET|desktop|AssertionError|ünï|Shared|works'

# --- 6b. nextest with retries as the real runner prints them: only `TRY n FAIL (i/n) binary name`
# for the last attempt of a failing test; a test that passed on a retry has a FLAKY line instead.
cat > "${dir}/nextest-try.log" <<LOG
TRY 1 FAIL (3/5) taurine-db-engine::dbx_route_dial the_kill_switch_refuses
TRY 2 FAIL (3/5) taurine-db-engine::dbx_route_dial the_kill_switch_refuses
TRY 1 FAIL (4/5) taurine-db::tests queries::flaky_one
FLAKY 2/3 [   0.5s] (4/5) taurine-db::tests queries::flaky_one
LOG
out="$(run "${dir}/rt" 'nextest_failures "'"${dir}"'/nextest-try.log"')"
only_grammar "${out}"
[[ "$(grep -c '^failed-test-id:' <<<"${out}")" == 2 ]] || fail "the retry log must give one failing and one flaky id, got: ${out}"
grep -qE 'status=fail' <<<"${out}" && grep -qE 'status=flaky' <<<"${out}" || fail 'the retry statuses are wrong'
no_leak "${out}" 'dbx_route|kill_switch|queries|flaky_one|taurine-db'

# --- 7. Playwright: ids from the JSON report only; counts for the console; a tab in a title is unidentified.
printf '{"suites":[{"specs":[{"title":"t","file":"e2e/a.spec.ts","line":3,"tests":[{"projectName":"visual","status":"unexpected","results":[{"error":{"message":"Screenshot comparison failed:\\n  1234 pixels (ratio 0.02) are different. SECRETTEXT"}}]},{"projectName":"critical","status":"unexpected","results":[{"error":{"message":"Error: expect(locator).toHaveText(expected)\\nLocator: getByRole(heading)\\nExpected string: Welcome\\nReceived string: Loading"}}]}]},{"title":"has\\ttab","file":"e2e/b.spec.ts","line":1,"tests":[{"projectName":"critical","status":"flaky","results":[]}]},{"title":"fine","file":"e2e/c.spec.ts","line":1,"tests":[{"projectName":"critical","status":"expected","results":[]}]}]}]}' > "${dir}/pw.json"
out="$(run "${dir}/rt" 'playwright_json_failures "'"${dir}"'/pw.json"')"
grep -v '^visual diffs:' <<<"${out}" > "${dir}/pw.ids"
only_grammar "$(cat "${dir}/pw.ids")"
has "${out}" "failed-test-id: ${v_e2e} status=fail"
has "${out}" 'failed-tests-unidentified: 1'
has "${out}" 'visual diffs: 1 screenshot mismatch(es) in 1 test(s), 1234 pixels differ'
no_leak "${out}" 'a\.spec|b\.spec|c\.spec|Locator|Welcome|Loading|SECRET|getByRole|has|tab|fine'
printf 'Running 3 tests\n  1) [critical] › e2e/a.spec.ts:3:5 › SECRETTITLE\n::error file=e2e/a.spec.ts,line=3,title=[critical] › SECRETTITLE::boom\n' > "${dir}/pw.log"
out="$(run "${dir}/rt" 'playwright_failures "'"${dir}"'/pw.log"')"
has "${out}" 'failing spec lines in the console output: 2'
no_leak "${out}" 'a\.spec|SECRET|critical|boom'

# --- 8. Fail closed: no key, a malformed key and a symlinked key print counts only.
for mode in absent malformed symlink emptyfile; do
  rt="${dir}/rt-${mode}"; mkdir -p "${rt}/taurine-ci"
  case "${mode}" in
    malformed) printf 'key-id=k7\nkey=not-hex\n' > "${rt}/taurine-ci/test-id-key" ;;
    symlink) ln -s "${dir}/rt/taurine-ci/test-id-key" "${rt}/taurine-ci/test-id-key" ;;
    emptyfile) : > "${rt}/taurine-ci/test-id-key" ;;
  esac
  out="$(run "${rt}" 'nextest_failures "'"${dir}"'/nextest.log"; test_failures "'"${dir}"'/vitest.log" 2>&1')"
  has "${out}" 'failed-test-ids: unavailable (no keyed key or HMAC tool); failing tests: '
  if grep -q 'failed-test-id: ' <<<"${out}"; then fail "an id was printed without a usable key (${mode})"; fi
  no_leak "${out}" 'queries|it_works|a\.test|Suite|crash_in|taurine-db'
done

# --- 9. The source-checkout step: fixed format only, masked, never printed, no file otherwise.
ruby -ryaml -e '
  doc = YAML.safe_load(File.read(".github/actions/source-checkout/action.yml"), aliases: false)
  step = doc["runs"]["steps"].find { |st| st["name"].to_s.start_with?("Snapshot the keyed test-ID key") } or abort("the key snapshot step is missing")
  File.write(ARGV[0], step["run"])
  abort("the key step must not interpolate an expression") if step["run"].include?("$" + "{{")
' "${dir}/snapshot.sh"
snapshot() { # snapshot <name> <content>: run the step against a checkout holding that key file
  local name="$1" content="$2" ws="${dir}/ws-$1"
  mkdir -p "${ws}/src/scripts/ci" "${ws}/rt"
  if [[ "${content}" != '@none' && "${content}" != '@symlink' && "${content}" != '@big' ]]; then printf '%b' "${content}" > "${ws}/src/scripts/ci/test-id-key.txt"; fi
  [[ "${content}" != '@symlink' ]] || ln -s "${dir}/rt/taurine-ci/test-id-key" "${ws}/src/scripts/ci/test-id-key.txt"
  [[ "${content}" != '@big' ]] || { printf 'taurine-test-id-key v1\nkey-id: k1\nkey: %s\n' "${key_hex}" > "${ws}/src/scripts/ci/test-id-key.txt"; head -c 5000 /dev/zero | tr '\0' 'a' >> "${ws}/src/scripts/ci/test-id-key.txt"; }
  (cd "${ws}" && GITHUB_WORKSPACE="${ws}" RUNNER_TEMP="${ws}/rt" CHECKOUT_PATH=src bash "${dir}/snapshot.sh") > "${ws}/out.txt" 2>&1 || fail "the key step failed for ${name}"
}
good="taurine-test-id-key v1\nkey-id: k7\nkey: ${key_hex}\n"
snapshot good "${good}"
[[ -f "${dir}/ws-good/rt/taurine-ci/test-id-key" ]] || fail 'a well-formed key was not snapshotted'
[[ "$(cat "${dir}/ws-good/rt/taurine-ci/test-id-key")" == "$(printf 'key-id=k7\nkey=%s' "${key_hex}")" ]] || fail 'the snapshot is not the normalised key'
[[ "$(grep -c "${key_hex}" "${dir}/ws-good/out.txt")" == 1 ]] || fail 'the key must appear exactly once in the step output (its add-mask command)'
grep -qxF "::add-mask::${key_hex}" "${dir}/ws-good/out.txt" || fail 'the key was not masked'
snapshot crlf "taurine-test-id-key v1\r\nkey-id: k7\r\nkey: ${key_hex}\r\n"
[[ -f "${dir}/ws-crlf/rt/taurine-ci/test-id-key" ]] || fail 'a CRLF key file was refused'
mode="$(stat -f '%Lp' "${dir}/ws-good/rt/taurine-ci/test-id-key" 2>/dev/null || stat -c '%a' "${dir}/ws-good/rt/taurine-ci/test-id-key")"
[[ "${mode}" == 600 ]] || fail "the snapshot mode is ${mode}, not 600"
snapshot none '@none'
snapshot symlink '@symlink'
snapshot big '@big'
# a symlinked scripts/ci directory pointing outside the checkout steers nothing
mkdir -p "${dir}/ws-dirlink/src/scripts" "${dir}/ws-dirlink/rt" "${dir}/outside"
printf 'taurine-test-id-key v1\nkey-id: k7\nkey: %s\n' "${key_hex}" > "${dir}/outside/test-id-key.txt"
ln -s "${dir}/outside" "${dir}/ws-dirlink/src/scripts/ci"
(cd "${dir}/ws-dirlink" && RUNNER_TEMP="${dir}/ws-dirlink/rt" CHECKOUT_PATH=src bash "${dir}/snapshot.sh") > "${dir}/ws-dirlink/out.txt" 2>&1 || fail 'the key step failed for a symlinked directory'
[[ ! -e "${dir}/ws-dirlink/rt/taurine-ci/test-id-key" ]] || fail 'a key behind a symlinked directory was snapshotted'
snapshot badid "taurine-test-id-key v1\nkey-id: ../x\nkey: ${key_hex}\n"
snapshot shortkey "taurine-test-id-key v1\nkey-id: k7\nkey: ${key_hex:0:62}\n"
snapshot upper "taurine-test-id-key v1\nkey-id: k7\nkey: $(tr 'a-f' 'A-F' <<<"${key_hex}")\n"
snapshot extra "taurine-test-id-key v1\nkey-id: k7\nkey: ${key_hex}\nextra: line\n"
snapshot inject "taurine-test-id-key v1\nkey-id: k7\nkey: ${key_hex}\n::set-env name=X::y\n"
snapshot header "taurine-test-id-key v2\nkey-id: k7\nkey: ${key_hex}\n"
for name in none symlink big badid shortkey upper extra inject header; do
  [[ ! -e "${dir}/ws-${name}/rt/taurine-ci/test-id-key" ]] || fail "a key file in the wrong format (${name}) was snapshotted"
  if grep -q "${key_hex}" "${dir}/ws-${name}/out.txt"; then fail "the key reached the step output for ${name}"; fi
done
# --- 10. The test-identity inventory: failed and flaky entries are keyed ids, never titles or paths,
# both from the collector's records and from the fallback that reads the runner report.
ruby -ryaml -e '
  doc = YAML.safe_load(File.read(".github/actions/linux-test-identities/action.yml"), aliases: false)
  step = doc["runs"]["steps"].find { |st| st["name"].to_s.start_with?("Publish test identities") } or abort("the identities step is missing")
  # The step lowercases the SHA with a bash 4 expansion; the SHA here is already lower-case, so the
  # expansion is dropped to let the fixture run under the bash 3.2 of a macOS developer machine.
  File.write(ARGV[0], step["run"].gsub("${REQUESTED_SOURCE_SHA,,}", "${REQUESTED_SOURCE_SHA}"))
' "${dir}/identities.sh"
identities() { # identities <name> <collector: ok|fail>: run the step against a fake workspace
  local name="$1" mode="$2" ws="${dir}/id-$1"
  mkdir -p "${ws}/src/taurine-desktop/node_modules/.bin" "${ws}/src/scripts/ci" "${ws}/rt/taurine-ci" "${ws}/rt/test-ids"
  (cd "${ws}/src" && git init -q . && git -c user.email=a@b -c user.name=t commit -q --allow-empty -m x)
  cp "${dir}/rt/taurine-ci/test-id-key" "${ws}/rt/taurine-ci/test-id-key"
  cp "${dir}/lib.sh" "${ws}/rt/taurine-ci/sanitize.sh"
  cp "${dir}/pw.json" "${ws}/rt/test-ids/e2e-critical.json"
  : > "${ws}/summary.md"
  if [[ "${mode}" == ok ]]; then
    cat > "${ws}/src/taurine-desktop/node_modules/.bin/vite-node" <<'STUB'
#!/usr/bin/env bash
printf '### Tests exercised by this run\n\n- 3 tests in 1 files.\n'
printf 'js\ttaurine-desktop/src/a.test.ts\tSuite > does a thing\tfail\njs\ttaurine-desktop/src/b.test.ts\tflaky one\tflaky\n' > "${TAURINE_TEST_IDS_DIR}/failed-records.tsv"
STUB
  else
    printf '#!/usr/bin/env bash\nexit 1\n' > "${ws}/src/taurine-desktop/node_modules/.bin/vite-node"
  fi
  chmod +x "${ws}/src/taurine-desktop/node_modules/.bin/vite-node"
  (cd "${ws}/src" && GITHUB_WORKSPACE="${ws}" RUNNER_TEMP="${ws}/rt" GITHUB_STEP_SUMMARY="${ws}/summary.md" CONCERN=desktop-shard-1 \
    REQUESTED_SOURCE_SHA="$(git rev-parse HEAD)" bash "${dir}/identities.sh") > "${ws}/out.txt" 2>&1 || { sed -n 1,20p "${ws}/out.txt" >&2; fail "the identities step failed (${name})"; }
}
identities collector ok
out="$(cat "${dir}/id-collector/summary.md")"
has "${out}" "failed-test-id: ${v_js} status=fail"
grep -qE 'failed-test-id: [0-9a-f]{16} status=flaky' <<<"${out}" || fail 'the collector flaky record was not keyed'
no_leak "${out}" 'a\.test|b\.test|Suite|does a thing|flaky one'
identities fallback fail
out="$(cat "${dir}/id-fallback/summary.md")"
has "${out}" "failed-test-id: ${v_e2e} status=fail"
has "${out}" 'failed-tests-unidentified: 1'
no_leak "${out}" 'a\.spec|b\.spec|Locator|Welcome|Loading|SECRET|has.tab|FAIL \['
echo "keyed test ids: ${implementations} HMAC implementation(s) agree with the pinned vectors; extractors, fail-closed paths and the key snapshot step checked"
