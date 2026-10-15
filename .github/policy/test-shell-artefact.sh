#!/usr/bin/env bash
# Fixtures for the shell-artefact library (the OpenSSL door gate and the artefact proof), the
# fixed-schema door lines in mobile-report, the per-ABI Android wiring and the weekly
# openssl-src cadence. Every case is a weakening that must be refused (or a control that must
# pass). Offline: `cargo`, `readelf` and the binaries are stand-ins. Run from the repository root.
# shellcheck disable=SC1091,SC2016 # literal snippets are evaluated later; libraries are extracted at run time
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/shell-artefact-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
# KEEP_GOING=1 reports every refused case instead of stopping at the first (used to show
# that each case fails against the tree before its fix).
failures=0
fail() {
  echo "shell-artefact fixtures: $*" >&2
  [[ "${KEEP_GOING:-}" == 1 ]] || exit 1
  failures=$((failures + 1))
}

extract_library() {
  ruby -ryaml -e '
    doc = YAML.safe_load(File.read(ARGV[0]), aliases: false)
    run = doc.fetch("runs").fetch("steps").map { |s| s["run"].to_s }.join("\n")
    body = run[/<<.TCI_[A-Z_]+.\n(.*?)\nTCI_[A-Z_]+\s*$/m, 1] or abort "no library in #{ARGV[0]}"
    puts body.gsub(/^        /, "")
  ' "$1"
}
extract_library .github/actions/sanitize/action.yml >"${work}/sanitize.sh"
extract_library .github/actions/mobile-report/action.yml >"${work}/mobile-report.sh"
extract_library .github/actions/shell-artefact/action.yml >"${work}/shell-artefact.sh"

# ---- a stand-in source checkout and toolchain --------------------------------------------
src="${work}/src"
mkdir -p "${src}/taurine-desktop/src-tauri" "${src}/taurine-mobile/src-tauri" "${work}/bin" "${work}/cargo-home"
printf '{"build":{"beforeBuildCommand":"x"}}\n' >"${src}/taurine-desktop/src-tauri/tauri.conf.json"
printf '{"build":{}}\n' >"${src}/taurine-mobile/src-tauri/tauri.conf.json"
printf '[[package]]\nname = "openssl-src"\nversion = "300.5.5+3.5.5"\n' >"${src}/Cargo.lock"

# cargo: `metadata` lists the two shells; `tree` answers from FAKE_TREE_<crate> per target
# (FAKE_ARMV7_BAD adds a non-door parent on armv7 only). `none` = cargo's "nothing to print".
cat >"${work}/bin/cargo" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == metadata ]]; then
  echo '{"packages":[{"name":"taurine-mobile"},{"name":"taurine-desktop"}],"target_directory":"/nonexistent"}'
  exit 0
fi
crate='' target=''
while (( $# )); do
  case "$1" in --invert) crate="$2"; shift ;; --target) target="$2"; shift ;; esac
  shift
done
mode="${FAKE_TREE:-door}"
if [[ "${mode}" == absent ]]; then
  echo "error: package ID specification \`${crate}\` did not match any packages" >&2; exit 101
fi
if [[ "${target}" == armv7-linux-androideabi && -n "${FAKE_ARMV7_BAD:-}" && "${crate}" == openssl-sys ]]; then
  printf '0openssl-sys v0.9.117\n1openssl v0.10.81\n1evil-sys v1.0.0\n'; exit 0
fi
case "${crate}" in
  openssl-sys) printf '0openssl-sys v0.9.117\n1openssl v0.10.81\n1taurine-tls-openssl v0.1.0 (path)\n1tokio-openssl v0.6.5\n' ;;
  openssl) printf '0openssl v0.10.81\n1taurine-db-dbx v0.1.0 (path)\n1taurine-tls-openssl v0.1.0 (path)\n1tokio-openssl v0.6.5\n' ;;
  tokio-openssl|taurine-tls-openssl) printf '0%s v0.1.0\n1taurine-db-dbx v0.1.0 (path)\n' "${crate}" ;;
  openssl-src) printf '0openssl-src v300.5.5+3.5.5\n' ;;
  *) echo "error: package ID specification \`${crate}\` did not match any packages" >&2; exit 101 ;;
esac
STUB
cat >"${work}/bin/readelf" <<'STUB'
#!/usr/bin/env bash
printf ' 0x0000000000000001 (NEEDED)             Shared library: [libc.so]\n'
[[ -n "${FAKE_NEEDED:-}" ]] && printf ' 0x0000000000000001 (NEEDED)             Shared library: [%s]\n' "${FAKE_NEEDED}"
exit 0
STUB
chmod +x "${work}/bin/cargo" "${work}/bin/readelf"

# An ELF-looking artefact carrying the given OpenSSL version strings.
artefact() {
  local file="${work}/$1"; shift
  printf '\177ELF' >"${file}"
  for version in "$@"; do printf '\0OpenSSL %s  27 Jan 2026\0' "${version}" >>"${file}"; done
  echo "${file}"
}

# Run a snippet with the libraries loaded, in the stand-in checkout, with a clean environment
# for the OpenSSL override names. Prints the snippet's combined output; returns its status.
run_lib() {
  (
    cd "${src}"
    export PATH="${work}/bin:${PATH}" RUNNER_TEMP="${work}/rt" GITHUB_STEP_SUMMARY="${work}/summary.md" CARGO_HOME="${work}/cargo-home"
    mkdir -p "${RUNNER_TEMP}"
    unset OPENSSL_DIR OPENSSL_NO_VENDOR OPENSSL_STATIC OPENSSL_LIB_DIR OPENSSL_INCLUDE_DIR
    source "${work}/sanitize.sh"; source "${work}/mobile-report.sh"; source "${work}/shell-artefact.sh"
    eval "$1"
  ) >"${work}/out" 2>&1
}
expect_pass() { run_lib "$2" || { cat "${work}/out" >&2; fail "$1: should pass"; }; }
expect_fail() {
  if run_lib "$2"; then cat "${work}/out" >&2; fail "$1: weakening accepted"; fi
  if [[ -n "${3:-}" ]] && ! grep -qF "$3" "${work}/out"; then cat "${work}/out" >&2; fail "$1: refused for the wrong reason"; fi
}

# ---- N1/N2: the artefact's distinct OpenSSL set, bound to the lock -------------------------
expect_pass 'present, exactly the locked 3.5.5' "artefact_check t '$(artefact a1 3.5.5)' debug present"
expect_pass 'absent, no OpenSSL at all' "artefact_check t '$(artefact a2)' debug absent"
expect_fail 'absent but a static OpenSSL copy' "artefact_check t '$(artefact a3 1.1.1w)' debug absent" 'the door is not in the graph'
expect_fail 'present plus a second copy' "artefact_check t '$(artefact a4 3.5.5 3.0.13)' debug present" 'expected exactly OpenSSL 3.5.5'
expect_fail 'present plus another 3.5 patch' "artefact_check t '$(artefact a5 3.5.5 3.5.4)' debug present" 'expected exactly OpenSSL 3.5.5'
expect_fail 'present, wrong patch only' "artefact_check t '$(artefact a6 3.5.4)' debug present" 'expected exactly OpenSSL 3.5.5'
expect_fail 'present, nothing linked' "artefact_check t '$(artefact a7)' debug present" 'expected exactly OpenSSL 3.5.5'
expect_fail 'dynamic libssl' "FAKE_NEEDED=libssl.so.3 artefact_check t '$(artefact a8 3.5.5)' debug present" 'dynamic OpenSSL dependency'

# ---- the gate itself -------------------------------------------------------------------------
expect_pass 'door-only graph' 'openssl_door_gate g taurine-mobile aarch64-linux-android'
expect_pass 'absent graph' 'FAKE_TREE=absent openssl_door_gate g taurine-mobile aarch64-linux-android'
expect_fail 'unknown package' 'openssl_door_gate g no-such-package -' 'did not resolve'

# ---- N3: the gate must see the built feature set -------------------------------------------
printf '{"build":{"features":["door-extra"]}}\n' >"${src}/taurine-desktop/src-tauri/tauri.conf.uat.json"
expect_fail 'absent while linked (build.features)' 'FAKE_TREE=absent openssl_door_gate g taurine-desktop -' 'build.features or build.runner'
expect_fail 'door_in_graph under build.features' 'FAKE_TREE=absent door_in_graph taurine-desktop -'
printf '{"build":{"runner":"other-cargo"}}\n' >"${src}/taurine-desktop/src-tauri/tauri.conf.uat.json"
expect_fail 'build.runner' 'openssl_door_gate g taurine-desktop -' 'build.features or build.runner'
rm "${src}/taurine-desktop/src-tauri/tauri.conf.uat.json"
printf '{ build: {} }\n' >"${src}/taurine-mobile/src-tauri/tauri.ios.conf.json5"
expect_fail 'unchecked json5 config' 'openssl_door_gate g taurine-mobile -' 'json5/toml'
rm "${src}/taurine-mobile/src-tauri/tauri.ios.conf.json5"

# ---- N4: every Android ABI on its own target graph -----------------------------------------
expect_pass 'ABI mapping' '[[ "$(android_abi_triple armeabi-v7a)" == armv7-linux-androideabi && "$(android_abi_triple x86)" == i686-linux-android && "$(android_abi_triple arm64-v8a)" == aarch64-linux-android && "$(android_abi_triple x86_64)" == x86_64-linux-android ]]'
expect_pass 'aarch64 clean while armv7 differs' 'FAKE_ARMV7_BAD=1 openssl_door_gate g taurine-mobile aarch64-linux-android'
expect_fail 'armv7 non-door parent' 'FAKE_ARMV7_BAD=1 openssl_door_gate g taurine-mobile "$(android_abi_triple armeabi-v7a)"' 'evil-sys depends on openssl-sys'
native="$(ruby -ryaml -e '
  doc = YAML.safe_load(File.read(".github/workflows/android-validation.yml"), aliases: false)
  step = doc["jobs"]["validate"]["steps"].find { |s| s["name"] == "Run isolated Android validation concern" }
  puts step["run"][/android-native\)(.*?)\n\s*android-rust\)/m, 1]')"
grep -qF 'openssl_door_gate "android-${abi}-openssl-door-only" taurine-mobile "${triple}"' <<<"${native}" || fail 'android-native does not gate each built ABI on its own target'
grep -qF 'door="$(door_in_graph taurine-mobile "${triple}")"' <<<"${native}" || fail 'android-native does not judge each ABI on its own door state'
! grep -qF 'door_in_graph taurine-mobile aarch64-linux-android' <<<"${native}" || fail 'android-native judges every ABI with the aarch64 door state'

# ---- N5: door lines are a fixed schema -----------------------------------------------------
mkdir -p "${work}/rt"
printf '%s\n' 'running 3 tests' 'door-roots: MozillaFallback, 146 anchors' 'door-roots: Os, 2 anchors' \
  'door-roots: PrivateTextLeakAbc123' 'test result: ok. 3 passed; 0 failed; 0 ignored;' >"${work}/rt/lbl-1.log"
printf '%s\n' 'door-public-peer: roots Os, 140 anchors trailing' 'SecretHostNameXyz789' >"${work}/rt/lbl-2.log"
: >"${work}/summary.md"
expect_pass 'door lines' 'mobile_door_lines lbl'
grep -qxF 'lbl: door-roots: MozillaFallback, 146 anchors' "${work}/out" || fail 'a valid door-roots line was not surfaced'
[[ "$(grep -c 'door-roots:' "${work}/out")" -eq 1 ]] || fail 'more than one door-roots line was published'
grep -qF 'unrecognised door line dropped (3)' "${work}/out" || fail 'the dropped-line counter is wrong'
if grep -qE 'PrivateTextLeakAbc123|SecretHostNameXyz789|trailing' "${work}/out" "${work}/summary.md"; then
  fail 'free text from a device log reached the log or summary'
fi

# ---- N6: OpenSSL overrides that bypass the vendored build ----------------------------------
expect_pass 'no overrides' 'OPENSSL_SRC_PERL=/x refuse_openssl_overrides'
expect_fail 'OPENSSL_DIR in the job' 'export OPENSSL_DIR=/usr; refuse_openssl_overrides' 'job environment'
expect_fail 'target-prefixed NO_VENDOR' 'export X86_64_UNKNOWN_LINUX_GNU_OPENSSL_NO_VENDOR=1; refuse_openssl_overrides' 'job environment'
expect_fail 'gate under OPENSSL_STATIC' 'export OPENSSL_STATIC=1; openssl_door_gate g taurine-mobile -' 'overridden'
mkdir -p "${src}/.cargo" "${src}/taurine-mobile/.cargo"
printf '[env]\nOPENSSL_LIB_DIR = "/opt/lib"\n' >"${src}/.cargo/config.toml"
expect_fail 'root cargo config [env]' 'refuse_openssl_overrides' 'cargo config file'
rm "${src}/.cargo/config.toml"
printf '[env.AARCH64_LINUX_ANDROID_OPENSSL_INCLUDE_DIR]\nvalue = "/x"\n' >"${src}/taurine-mobile/.cargo/config"
expect_fail 'nested cargo config table' 'refuse_openssl_overrides' 'cargo config file'
rm "${src}/taurine-mobile/.cargo/config"
printf '[env]\nOPENSSL_DIR = "/x"\n' >"${work}/cargo-home/config.toml"
expect_fail 'CARGO_HOME config' 'refuse_openssl_overrides' 'cargo config file'
rm "${work}/cargo-home/config.toml"

# ---- N8: the weekly release-line cadence fails closed --------------------------------------
cadence="$(ruby -ryaml -e '
  doc = YAML.safe_load(File.read(".github/workflows/weekly-validation.yml"), aliases: false)
  run = doc["jobs"]["dispatch"]["steps"].map { |s| s["run"].to_s }.join("\n")
  puts run[/^openssl_cadence\(\) \{\n.*?^\}\n/m] || abort("openssl_cadence not found")')"
check_cadence() {
  local want="$1" latest="$2" list="$3" fail_flag="$4" note
  note="$(OPENSSL_LTS_END=2030-04-08 latest="${latest}" bash -c "${cadence}"$'\n''openssl_cadence uat "$1" "$2"' _ "${list}" "${fail_flag}" 2>/dev/null)"
  case "${want}" in
    fails) [[ "${note}" == *'fails this run'* ]] || fail "cadence passed: latest='${latest}' list='${list}' fail=${fail_flag}: ${note}" ;;
    passes) [[ "${note}" != *'fails this run'* ]] || fail "cadence failed: latest='${latest}' list='${list}' fail=${fail_flag}: ${note}" ;;
  esac
}
check_cadence passes 300.5.5+3.5.5 300.5.5+3.5.5 true
check_cadence fails 300.5.6+3.5.6 300.5.5+3.5.5 true
check_cadence fails '' 300.5.5+3.5.5 true
check_cadence fails 300.5.5+3.5.5 '' true
check_cadence fails 300.5.5+3.5.5 tip-unresolved true
check_cadence fails 300.5.5+3.5.5 fetch-failed,300.5.5+3.5.5 true
check_cadence fails 300.5.5+3.5.5 300.3.1+3.3.1 true
check_cadence passes '' '' false
check_cadence passes 300.5.6+3.5.6 300.5.5+3.5.5 false

[[ "${failures}" -eq 0 ]] || { echo "shell-artefact fixtures: ${failures} case(s) failed" >&2; exit 1; }
echo 'shell-artefact fixtures: lock-bound artefact proof, build-feature and OpenSSL-override refusals, per-ABI gating, fixed door lines and the fail-closed release cadence hold'
