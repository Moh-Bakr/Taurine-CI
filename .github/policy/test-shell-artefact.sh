#!/usr/bin/env bash
# Fixtures for the shell-artefact library (the OpenSSL door gate and the artefact proof), the
# fixed-schema door lines in mobile-report and the per-ABI Android wiring. Every case is a
# weakening that must be refused (or a control that must pass). Offline: `cargo`, `readelf` and the binaries are stand-ins. Run from the repository root.
# shellcheck disable=SC1091,SC2016,SC2015,SC2059 # literal snippets and byte fixtures are evaluated later; libraries are extracted at run time
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/shell-artefact-test.XXXXXX")"
trap 'if [[ -n "${unreadable:-}" ]]; then chmod u+rwx "${unreadable}" 2>/dev/null || true; fi; rm -rf "${work}"' EXIT
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
    puts body
  ' "$1"
}
extract_library .github/actions/sanitize/action.yml >"${work}/sanitize.sh"
extract_library .github/actions/mobile-report/action.yml >"${work}/mobile-report.sh"
extract_library .github/actions/concern-report/action.yml >"${work}/concern-report.sh"
extract_library .github/actions/shell-artefact/action.yml >"${work}/shell-artefact.sh"
mkdir -p "${work}/rt/taurine-ci"
extract_library .github/actions/shell-config/action.yml >"${work}/rt/taurine-ci/shell-config.sh"

# ---- a stand-in source checkout and toolchain --------------------------------------------
src="${work}/src"
mkdir -p "${src}/taurine-desktop/src-tauri" "${src}/taurine-mobile/src-tauri" "${work}/bin" "${work}/cargo-home"
printf '{"build":{"beforeBuildCommand":"x"}}\n' >"${src}/taurine-desktop/src-tauri/tauri.conf.json"
printf '{"build":{}}\n' >"${src}/taurine-mobile/src-tauri/tauri.conf.json"
crates_io='registry+https://github.com/rust-lang/crates.io-index'
# The root lock: the four door crates as crates.io packages (source and checksum).
write_lock() {
  local crate version
  : >"${src}/Cargo.lock"
  for crate in openssl:0.10.81 openssl-src:300.5.5+3.5.5 openssl-sys:0.9.117 tokio-openssl:0.6.5; do
    version="${crate#*:}"; crate="${crate%%:*}"
    printf '[[package]]\nname = "%s"\nversion = "%s"\nsource = "%s"\nchecksum = "%064d"\n\n' "${crate}" "${version}" "${crates_io}" 0 >>"${src}/Cargo.lock"
  done
}
write_lock

# cargo: `metadata` lists the two shells; `tree` answers from FAKE_TREE_<crate> per target
# (FAKE_ARMV7_BAD adds a non-door parent on armv7 only). `none` = cargo's "nothing to print".
# The real cargo (for the toy-workspace fixtures) is found before the stand-in shadows it.
# The base-policy job runs this with PATH fixed to the system directories and an empty HOME, and
# hands in a root-owned toolchain cargo as TCI_REAL_CARGO (rustup's proxy is unreachable there);
# that cargo finds its rustc beside it. Anywhere else, the cargo on PATH is used.
real_cargo="${TCI_REAL_CARGO:-$(command -v cargo || true)}"
if [[ -n "${TCI_REAL_CARGO:-}" && -z "${RUSTC:-}" && -x "$(dirname "${TCI_REAL_CARGO}")/rustc" ]]; then
  RUSTC="$(dirname "${TCI_REAL_CARGO}")/rustc"
  export RUSTC
fi
unset TCI_REAL_CARGO
# The fixtures run with their own HOME, so rustup's toolchain home is fixed here first.
export RUSTUP_HOME="${RUSTUP_HOME:-${HOME}/.rustup}"
[[ -n "${real_cargo}" ]] || { echo 'shell-artefact fixtures: cargo is required for the real-cargo built-graph fixtures' >&2; exit 1; }
cat >"${work}/bin/cargo" <<'STUB'
#!/usr/bin/env bash
[[ -n "${TCI_REAL_CARGO:-}" ]] && exec "${TCI_REAL_CARGO}" "$@"
if [[ "$1" == fetch ]]; then
  cache="${CARGO_HOME}/registry/cache/index.crates.io-0000"
  [[ "${FAKE_FETCH:-}" == none ]] && exit 0
  mkdir -p "${cache}"; cp "${FAKE_UPSTREAM}"/*.crate "${cache}/" 2>/dev/null || true
  if [[ "${FAKE_FETCH:-}" == decoy ]]; then mkdir -p "${CARGO_HOME}/registry/cache/zzz-mirror"; printf 'bad\n' >"${CARGO_HOME}/registry/cache/zzz-mirror/openssl-src-300.5.5+3.5.5.crate"; fi
  exit 0
fi
if [[ "$1" == metadata ]]; then
  if [[ " $* " == *" --all-features "* && -n "${FAKE_META_ALL:-}" ]]; then cat "${FAKE_META_ALL}"; exit 0; fi
  if [[ " $* " == *" --no-deps "* ]]; then
    echo '{"packages":[{"name":"taurine-mobile"},{"name":"taurine-desktop"}],"target_directory":"/nonexistent"}'
    exit 0
  fi
  # The resolved door crates: from the registry, or (FAKE_META=vendor) a vendored directory.
  root="${CARGO_HOME}/registry/src/index.crates.io-0000/"
  [[ "${FAKE_META:-}" == vendor ]] && root="${PWD}/vendor/"
  jq -cn --arg src 'registry+https://github.com/rust-lang/crates.io-index' --arg root "${root}" \
    '{packages: [("openssl-src","openssl-sys","openssl","tokio-openssl") | {name: ., source: $src, manifest_path: ($root + . + "/Cargo.toml")}]}'
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
  openssl) printf '0openssl v0.10.81\n1taurine-db-dbx v0.1.0 (path)\n1taurine-tls-openssl v0.1.0 (path)\n1tokio-openssl v0.6.5\n'; [[ -n "${FAKE_MYSQL_OPENSSL:-}" ]] && printf '1taurine-mysql-async v0.1.0 (path)\n'; true ;;
  tokio-openssl|taurine-tls-openssl)
    printf '0%s v0.1.0\n1taurine-db-dbx v0.1.0 (path)\n' "${crate}"
    # FAKE_MYSQL_PARENT adds the vendored MySQL fork as a direct parent; FAKE_TOKIO_BAD an unrelated crate.
    [[ "${crate}" == tokio-openssl && -n "${FAKE_MYSQL_PARENT:-}" ]] && printf '1taurine-mysql-async v0.1.0 (path)\n'
    [[ "${crate}" == tokio-openssl && -n "${FAKE_TOKIO_BAD:-}" ]] && printf '1evil-sys v1.0.0\n'
    true ;;
  openssl-src) printf '0openssl-src v300.5.5+3.5.5\n'; [[ -n "${FAKE_SRC_BAD:-}" ]] && printf '1evil-sys v1.0.0\n'; true ;;
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
    export PATH="${work}/bin:${PATH}" RUNNER_TEMP="${work}/rt" GITHUB_STEP_SUMMARY="${work}/summary.md" CARGO_HOME="${work}/cargo-home" FAKE_UPSTREAM="${work}/upstream" HOME="${work}/home"
    mkdir -p "${RUNNER_TEMP}" "${HOME}"
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

# mutant <label> <library: config|artefact> <old> <new> <pass|fail> <snippet>: with <old> replaced
# by <new> in the extracted library (it must be there), the snippet's reviewed verdict must no
# longer hold: a case that passes must fail, a weakening that is refused must be accepted. Proves
# the fixture would see that edit, without running the whole suite again.
mutant() {
  local label="$1" file="${work}/shell-artefact.sh" verdict="$5" snippet="$6"
  [[ "$2" == config ]] && file="${work}/rt/taurine-ci/shell-config.sh"
  cp "${file}" "${work}/mutant.keep"
  OLD="$3" NEW="$4" ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("mutation text not found: #{ENV["OLD"][0, 80]}"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], s)' "${file}" ||
    { cp "${work}/mutant.keep" "${file}"; fail "${label}: the mutation no longer applies"; return 0; }
  if run_lib "${snippet}"; then
    [[ "${verdict}" == fail ]] || { cat "${work}/out" >&2; fail "mutant survived: ${label}"; }
  else
    [[ "${verdict}" == pass ]] || { cat "${work}/out" >&2; fail "mutant survived: ${label}"; }
  fi
  cp "${work}/mutant.keep" "${file}"
}

# A Windows runner's tools, for the cases that name it: Git Bash's cygpath, and the native Windows
# Python that tci_python finds there, which cannot open an MSYS path (`/d/a/...`). The stand-in
# cygpath -m marks a path NATIVE:, and the stand-in Python refuses any path argument or stdin path
# that was not converted, then hands the converted ones to the real Python.
real_python="$(command -v python3)"
mkdir -p "${work}/winbin"
cat >"${work}/winbin/cygpath" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -m)
    if [[ "$2" == *"${FAKE_CYGPATH_SUFFIX:-}" ]]; then
      case "${FAKE_CYGPATH_MODE:-}" in
        fail) exit 1 ;;
        empty) exit 0 ;;
        fail-output) printf 'NATIVE:%s\n' "$2"; exit 1 ;;
      esac
    fi
    printf 'NATIVE:%s\n' "$2" ;;
  *) printf '%s\n' "$2" ;;
esac
STUB
cat >"${work}/winbin/python3" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == -c && "\$2" == 'import tomllib' ]]; then exec '${real_python}' "\$@"; fi
args=()
for arg in "\$@"; do
  case "\${arg}" in
    NATIVE:*) args+=("\${arg#NATIVE:}") ;;
    /*) echo 'native-python: an MSYS path cannot be opened' >&2; exit 1 ;;
    *) args+=("\${arg}") ;;
  esac
done
if [[ "\$2" == *sys.stdin* ]]; then
  input="\$(cat)"
  while IFS= read -r line; do
    [[ -z "\${line}" || "\${line}" == NATIVE:* ]] || { echo 'native-python: an MSYS path cannot be opened' >&2; exit 1; }
  done <<<"\${input}"
  printf '%s\n' "\${input}" | sed 's/^NATIVE://' | '${real_python}' "\${args[@]}"
  exit "\$?"
fi
exec '${real_python}' "\${args[@]}"
STUB
chmod +x "${work}/winbin/cygpath" "${work}/winbin/python3"
windows="PATH='${work}/winbin':\${PATH}"

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
expect_pass 'the MySQL fork wrapping tokio-openssl' 'FAKE_MYSQL_PARENT=1 openssl_door_gate g taurine-mobile aarch64-linux-android'
expect_fail 'the MySQL fork with a direct openssl edge (S1 gate)' 'FAKE_MYSQL_OPENSSL=1 openssl_door_gate g taurine-mobile -' 'taurine-mysql-async depends on openssl outside the OpenSSL door'
expect_fail 'another crate depending on tokio-openssl (S1 gate)' 'FAKE_TOKIO_BAD=1 openssl_door_gate g taurine-mobile -' 'evil-sys depends on tokio-openssl outside the OpenSSL door'
mutant 'the shell list re-widened: the MySQL fork allowed on openssl' artefact "openssl) echo 'tokio-openssl taurine-tls-openssl taurine-db-dbx' ;;" "openssl) echo 'tokio-openssl taurine-tls-openssl taurine-db-dbx taurine-mysql-async' ;;" fail 'FAKE_MYSQL_OPENSSL=1 openssl_door_gate g taurine-mobile -'
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
grep -qxF 'lbl: door lines dropped: yes' "${work}/out" || fail 'the dropped-line report is not the fixed yes/no'
if grep -qE 'dropped.*[0-9]' "${work}/out" "${work}/summary.md"; then fail 'a source-chosen count was published'; fi
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
# The Windows packaging concern: the source's own root cargo config, which the parent walk names by
# its absolute MSYS path, must reach the native Windows Python in a form it can open. Before the
# conversion every Windows run refused a clean config as "does not parse".
printf '[env]\nLIBSQLITE3_FLAGS = { value = "SQLITE_ENABLE_MATH_FUNCTIONS", force = false }\n' >"${src}/.cargo/config.toml"
expect_pass 'a clean root cargo config read by a native Windows Python' "${windows}; refuse_openssl_overrides"
mutant 'the cargo config paths handed to Python unconverted' config 'converted="$(tci_native_path "${file}")"' 'converted="${file}"' pass "${windows}; refuse_openssl_overrides"
printf '[env]\nOPENSSL_DIR = "/x"\n' >"${src}/.cargo/config.toml"
expect_fail 'an override in the root cargo config, on Windows' "${windows}; refuse_openssl_overrides" 'sets an OpenSSL override'
# Exercise the real reporting wrapper: its || rc=$? suppresses errexit inside the refusal.
# The mixed case deliberately converts a clean config first, then loses the override-bearing one.
expect_conversion_failure() {
  expect_fail "$1" "$2"
  grep -qF 'openssl-overrides: FAILED - a cargo config path could not be converted' "${work}/rt/path-conversion.log" ||
    fail "$1: refused for a reason other than the failed conversion"
  if grep -qF 'openssl-overrides: none' "${work}/rt/path-conversion.log"; then
    fail "$1: published a successful override check"
  fi
}
conversion_loop="$(cat <<'GUARD'
while IFS= read -r file; do
    if ! converted="$(tci_native_path "${file}")" || [[ -z "${converted}" ]]; then
      echo 'openssl-overrides: FAILED - a cargo config path could not be converted' >&2
      return 1
    fi
    configs+="${converted}"$'\n'
  done < <(tci_cargo_configs)
GUARD
)"
conversion_pipeline='configs="$(tci_cargo_configs | while IFS= read -r file; do tci_native_path "${file}"; done | sort -u)"'
for mode in fail empty fail-output; do
  conversion_setup="${windows}; export FAKE_CYGPATH_MODE='${mode}' FAKE_CYGPATH_SUFFIX='/.cargo/config.toml'; source '${work}/concern-report.sh';"
  conversion_only="${conversion_setup} tci_cargo_configs() { printf '%s\\n' '${src}/.cargo/config.toml'; }; run_quiet path-conversion refuse_openssl_overrides"
  expect_conversion_failure "${mode}: the only config conversion fails under run_quiet" "${conversion_only}"
  mutant "${mode}: the original pipeline loses the only config" config "${conversion_loop}" "${conversion_pipeline}" fail "${conversion_only}"
  printf '[env]\nLIBSQLITE3_FLAGS = "SQLITE_ENABLE_MATH_FUNCTIONS"\n' >"${src}/taurine-mobile/.cargo/config"
  conversion_mixed="${conversion_setup} tci_cargo_configs() { printf '%s\\n' '${src}/taurine-mobile/.cargo/config' '${src}/.cargo/config.toml'; }; run_quiet path-conversion refuse_openssl_overrides"
  expect_conversion_failure "${mode}: a clean conversion before a failed one under run_quiet" "${conversion_mixed}"
  mutant "${mode}: the original pipeline checks only the surviving clean config" config "${conversion_loop}" "${conversion_pipeline}" fail "${conversion_mixed}"
  rm "${src}/taurine-mobile/.cargo/config"
done
echo 'shell-artefact fixtures: failed, empty and failing-with-output conversions refused under run_quiet; failed-only and mixed-path mutants caught'
rm "${src}/.cargo/config.toml"

# ---- C1: the door crates must be the crates.io packages -----------------------------------
expect_pass 'crates.io provenance' 'door_provenance p'
sed_lock() { ruby -e 'path = ARGV[0]; File.write(path, File.read(path).sub(ARGV[1]) { ARGV[2] })' "${src}/Cargo.lock" "$1" "$2"; }
sed_lock "source = \"${crates_io}\"
checksum = \"$(printf '%064d' 0)\"

[[package]]
name = \"openssl-sys\"" '[[package]]
name = "openssl-sys"'
expect_fail '[patch] path fork (no source, no checksum)' 'openssl_door_gate g taurine-mobile -' 'is not the crates.io package'
write_lock
sed_lock "source = \"${crates_io}\"" 'source = "git+https://example.invalid/openssl-src?rev=1#1"'
expect_fail 'git source' 'door_provenance p' 'is not the crates.io package'
write_lock
printf '[[package]]\nname = "openssl"\nversion = "0.10.81"\nreplace = "openssl 0.10.81 (path)"\n' >>"${src}/Cargo.lock"
expect_fail '[replace]' 'door_provenance p' 'is not the crates.io package'
write_lock
expect_fail 'directory source replacement' 'FAKE_META=vendor door_provenance p' 'does not resolve to the crates.io registry copy'

# ---- C2: CI owns the build's argv ----------------------------------------------------------
# The CLI: @tauri-apps/cli/tauri.js run by CI's node, .bin/tauri resolving to it, registry lock.
tdir="${src}/taurine-desktop"
mkdir -p "${tdir}/node_modules/.bin" "${tdir}/node_modules/@tauri-apps/cli" "${tdir}/node_modules/@tauri-apps/cli-linux-x64-gnu"
printf '{"name":"d","scripts":{"tauri":"tauri"}}\n' >"${tdir}/package.json"
cat >"${tdir}/node_modules/@tauri-apps/cli/tauri.js" <<'STUB'
#!/usr/bin/env node
const env = process.env;
console.log(`tauri-argv: ${process.argv.slice(2).join(" ")} | cwd=${require("path").basename(process.cwd())} | config=${env.TAURI_CONFIG || "unset"} | other=${env.TAURI_EXTRA || "unset"} | user=${require("path").basename(env.npm_config_userconfig || "unset")} | global=${require("path").basename(env.npm_config_globalconfig || "unset")}`);
STUB
chmod +x "${tdir}/node_modules/@tauri-apps/cli/tauri.js"
ln -s ../@tauri-apps/cli/tauri.js "${tdir}/node_modules/.bin/tauri"
write_npm_lock() {
  jq -n --arg r1 "${1-https://registry.npmjs.org/@tauri-apps/cli/-/cli-2.12.0.tgz}" --arg i1 "${2-sha512-AAAA}" \
    '{lockfileVersion: 3, packages: {"node_modules/@tauri-apps/cli": {resolved: $r1, integrity: $i1},
      "node_modules/@tauri-apps/cli-linux-x64-gnu": {resolved: "https://registry.npmjs.org/@tauri-apps/cli-linux-x64-gnu/-/x.tgz", integrity: "sha512-BBBB"}}}' >"${tdir}/package-lock.json"
}
write_npm_lock
# npm is a stand-in that reports what it was given (the base-policy job has no npm on its fixed
# PATH); what reaches npm is what reaches the CLI.
cat >"${work}/bin/npm" <<'STUB'
#!/usr/bin/env bash
echo "npm-argv: $* | cwd=$(basename "${PWD}") | config=${TAURI_CONFIG:-unset} | other=${TAURI_EXTRA:-unset} | user=$(basename "${npm_config_userconfig:-unset}") | global=$(basename "${npm_config_globalconfig:-unset}")"
STUB
chmod +x "${work}/bin/npm"
expect_pass 'tauri_cli' 'TAURI_CONFIG={} TAURI_EXTRA=1 tauri_cli taurine-desktop build --debug'
grep -qxF 'npm-argv: run --ignore-scripts tauri -- build --debug | cwd=taurine-desktop | config=unset | other=unset | user=empty-npmrc-user | global=empty-npmrc-global' "${work}/out" || fail 'tauri_cli did not run the CLI with only CI arguments, no TAURI_* environment and CI-owned npm config'
printf 'script-shell=/bin/evil\n' >"${work}/home/.npmrc"
expect_fail 'a ~/.npmrc for the job user' 'tauri_cli taurine-desktop build' 'has a ~/.npmrc'
rm "${work}/home/.npmrc"
write_npm_lock 'git+https://example.invalid/cli.git#1'
expect_fail 'a git-resolved Tauri CLI' 'tauri_cli taurine-desktop build' 'not a registry package'
write_npm_lock 'https://registry.npmjs.org/@tauri-apps/cli/-/cli-2.12.0.tgz' ''
expect_fail 'a Tauri CLI without integrity' 'tauri_cli taurine-desktop build' 'not a registry package'
write_npm_lock
rm "${tdir}/node_modules/.bin/tauri"; printf 'console.log(1)\n' >"${work}/other.js"; ln -s "${work}/other.js" "${tdir}/node_modules/.bin/tauri"
expect_fail '.bin/tauri pointing elsewhere' 'tauri_cli taurine-desktop build' 'is not @tauri-apps/cli/tauri.js'
rm "${tdir}/node_modules/.bin/tauri"; ln -s ../@tauri-apps/cli/tauri.js "${tdir}/node_modules/.bin/tauri"
printf '{"name":"d","scripts":{"tauri":"node evil.js"}}\n' >"${tdir}/package.json"
expect_fail 'a tauri script that is not the CLI' 'tauri_cli taurine-desktop build' 'not exactly `tauri`'
printf '{"name":"d","scripts":{"tauri":"tauri","pretauri":"node evil.js"}}\n' >"${tdir}/package.json"
expect_fail 'a pretauri script' 'tauri_cli taurine-desktop build' 'pre/post script'
printf '{"name":"d","scripts":{"tauri":"tauri"}}\n' >"${tdir}/package.json"
printf 'script-shell=/bin/evil\n' >"${src}/.npmrc"
expect_fail 'an .npmrc in the checkout' 'tauri_cli taurine-desktop build' 'carries an .npmrc'
rm "${src}/.npmrc"
printf 'Tauri.linux.toml overlay\n[build]\nfeatures = ["x"]\n' >"${src}/taurine-desktop/src-tauri/Tauri.linux.toml"
expect_fail 'a Tauri.linux.toml overlay (G1)' 'refuse_build_feature_overrides' 'json5/toml'
rm "${src}/taurine-desktop/src-tauri/Tauri.linux.toml"
printf '{build: {features: ["x"]}}\n' >"${src}/taurine-mobile/src-tauri/tauri.android.conf.json5"
expect_fail 'a json5 platform overlay (G1)' 'refuse_build_feature_overrides' 'json5/toml'
rm "${src}/taurine-mobile/src-tauri/tauri.android.conf.json5"
for key in '{"linux":{"deb":{"files":{"/usr/lib/x":"x"}}}}' '{"macOS":{"files":{"x":"y"}}}' '{"macOS":{"frameworks":["./Vendor.framework"]}}' '{"iOS":{"frameworks":["lib/x.xcframework"]}}'; do
  printf '{"bundle":%s}\n' "${key}" >"${src}/taurine-desktop/src-tauri/tauri.conf.dev.json"
  expect_fail "a file-shipping bundle key ${key%%:*}" 'refuse_build_feature_overrides' 'ships files, frameworks'
done
printf '{"bundle":{"iOS":{"frameworks":["SystemConfiguration"]}}}\n' >"${src}/taurine-desktop/src-tauri/tauri.conf.dev.json"
expect_pass 'a system framework name' 'refuse_build_feature_overrides'
for key in '{"macOS":{"frameworks":["SystemConfiguration"]}}' '{"iOS":{"frameworks":["UIKit"]}}' '{"iOS":{"template":"tpl/project.yml"}}' \
  '{"windows":{"wix":{"fragmentPaths":["f.wxs"]}}}' '{"windows":{"wix":{"template":"m.wxs"}}}' '{"windows":{"wix":{"componentGroupRefs":["x"]}}}' \
  '{"windows":{"wix":{"mergeRefs":["x"]}}}' '{"windows":{"nsis":{"installerHooks":"h.nsh"}}}' '{"windows":{"nsis":{"template":"t.nsi"}}}' \
  '{"windows":{"signCommand":"sign.sh"}}' '{"linux":{"rpm":{"files":{"/x":"y"}}}}' '{"linux":{"rpm":{"postInstallScript":"p.sh"}}}' \
  '{"linux":{"deb":{"postInstallScript":"p.sh"}}}' '{"linux":{"deb":{"preRemoveScript":"p.sh"}}}' '{"linux":{"appimage":{"files":{"/x":"y"}}}}'; do
  printf '{"bundle":%s}\n' "${key}" >"${src}/taurine-desktop/src-tauri/tauri.conf.dev.json"
  expect_fail "a refused bundle key ${key}" 'refuse_build_feature_overrides' 'ships files, frameworks'
done
rm "${src}/taurine-desktop/src-tauri/tauri.conf.dev.json"
mkdir -p "${src}/elsewhere"; printf '{"build":{"features":["x"]}}\n' >"${src}/elsewhere/tauri.conf.json"
expect_fail 'a Tauri config outside src-tauri' 'refuse_build_feature_overrides' 'outside the shells'
rm -r "${src}/elsewhere"
mkdir -p "${src}/taurine-mobile/src-tauri/sub"; printf '{}\n' >"${src}/taurine-mobile/src-tauri/sub/tauri.conf.json"
expect_fail 'a nested Tauri config' 'refuse_build_feature_overrides' 'outside the shells'
rm -r "${src}/taurine-mobile/src-tauri/sub"
printf '{"bundle":{"externalBin":["bin/sidecar"]}}\n' >"${src}/taurine-desktop/src-tauri/tauri.conf.dev.json"
expect_fail 'a sidecar' 'refuse_build_feature_overrides' 'a sidecar'
rm "${src}/taurine-desktop/src-tauri/tauri.conf.dev.json"
# Resources must be data: inside the checkout (symlinks resolved), existing, not ELF/Mach-O/PE.
conf="${src}/taurine-desktop/src-tauri/tauri.conf.dev.json"
printf 'Third-party notices\n' >"${src}/THIRD-PARTY-NOTICES"
printf '{"bundle":{"resources":{"../../THIRD-PARTY-NOTICES":"THIRD-PARTY-NOTICES"}}}\n' >"${conf}"
expect_pass 'notices resource (object form)' 'refuse_build_feature_overrides'
mkdir -p "${src}/res/sub"; printf 'data\n' >"${src}/res/sub/a.txt"
printf '{"bundle":{"resources":["../../res/**/*"]}}\n' >"${conf}"
expect_pass 'data glob (array form)' 'refuse_build_feature_overrides'
printf '\177ELF....' >"${src}/res/sub/tool"
expect_fail 'a glob containing an ELF' 'refuse_build_feature_overrides' 'not text or a known image'
rm "${src}/res/sub/tool"
printf '\177ELF....' >"${src}/res/fake.dat"
printf '{"bundle":{"resources":["../../res/fake.dat"]}}\n' >"${conf}"
expect_fail 'an ELF disguised as a resource' 'refuse_build_feature_overrides' 'not text or a known image'
printf 'MZ\220\000' >"${src}/res/fake.dat"
expect_fail 'a PE disguised as a resource' 'refuse_build_feature_overrides' 'not text or a known image'
printf '\211PNG\r\n\032\n\000\000\000\rIHDR' >"${src}/res/fake.dat"
expect_pass 'a PNG resource' 'refuse_build_feature_overrides'
for blob in 'PK\003\004zip\000' 'PK\003\004META-INF/MANIFEST.MF\000' 'dex\n035\000' '\000asm\001\000\000\000' 'ab\177ELF\002\001\001\000' '\312\376\272\277\000\000\000\002'; do
  printf "${blob}" >"${src}/res/fake.dat"
  expect_fail "a non-text resource ($(printf '%s' "${blob}" | cut -c1-6))" 'refuse_build_feature_overrides' 'not text or a known image'
done
printf '{"bundle":{"resources":["../../res/*"]}}\n' >"${conf}"
rm "${src}/res/fake.dat"; printf 'readme\n' >"${src}/res/readme.txt"; printf '\177ELF\002\001\001\000' >"${src}/res/.libssl.so.3"
expect_fail 'a hidden binary inside a glob (G2)' 'refuse_build_feature_overrides' 'not text or a known image'
rm "${src}/res/.libssl.so.3" "${src}/res/readme.txt"
printf '{"bundle":{"resources":["../../res/fake.dat"]}}\n' >"${conf}"
printf 'outside\n' >"${work}/outside.txt"
printf '{"bundle":{"resources":{"../../../outside.txt":"x"}}}\n' >"${conf}"
expect_fail 'a ../ escape outside the checkout' 'refuse_build_feature_overrides' 'outside the checkout'
ln -s "${work}/outside.txt" "${src}/res/link.txt"
printf '{"bundle":{"resources":["../../res/link.txt"]}}\n' >"${conf}"
expect_fail 'a symlink out of the checkout' 'refuse_build_feature_overrides' 'outside the checkout'
printf '{"bundle":{"resources":["../../res/*.none"]}}\n' >"${conf}"
expect_fail 'a pattern that matches nothing' 'refuse_build_feature_overrides' 'matches nothing'
printf '{"bundle":{"resources":["/etc/hosts"]}}\n' >"${conf}"
expect_fail 'an absolute resource' 'refuse_build_feature_overrides' 'absolute'
rm -r "${src}/res" "${conf}" "${src}/THIRD-PARTY-NOTICES"
mv "${src}/taurine-mobile/src-tauri" "${src}/taurine-mobile/tauri-moved"
expect_fail 'a moved src-tauri' 'refuse_build_feature_overrides' 'src-tauri is missing'
mv "${src}/taurine-mobile/tauri-moved" "${src}/taurine-mobile/src-tauri"
for file in .github/workflows/android-validation.yml .github/workflows/ios-validation.yml .github/actions/ios-project-init/action.yml \
  .github/actions/linux-concern-rust/action.yml .github/actions/macos-concern-rust/action.yml .github/actions/windows-concern-rust/action.yml; do
  if grep -qE 'npm (--prefix taurine-(desktop|mobile) )?run (tauri|android:|ios:)' "${file}"; then fail "${file} builds a shell through a source npm script"; fi
done

# ---- H1: override keys decoded, case-insensitive, parents walked ---------------------------
mkdir -p "${src}/.cargo"
printf '[env]\n"OPENSSL\\u005FNO_VENDOR" = "1"\n' >"${src}/.cargo/config.toml"
expect_fail 'escaped quoted key' 'refuse_openssl_overrides' 'cargo config file'
printf '[env]\nopenssl_dir = "/x"\n' >"${src}/.cargo/config.toml"
expect_fail 'lower-case key' 'refuse_openssl_overrides' 'cargo config file'
rm "${src}/.cargo/config.toml"
expect_fail 'lower-case environment name' 'export openssl_no_vendor=1; refuse_openssl_overrides' 'job environment'
mkdir -p "${work}/.cargo"; printf '[env]\nOPENSSL_STATIC = "1"\n' >"${work}/.cargo/config.toml"
expect_fail 'a parent directory config' 'refuse_openssl_overrides' 'cargo config file'
rm -r "${work}/.cargo"

# ---- H2: every shipped binary is judged ----------------------------------------------------
mkdir -p "${work}/bundle/Frameworks"
cp "$(artefact m1 3.5.5)" "${work}/bundle/app"; cp "$(artefact e1)" "${work}/bundle/Frameworks/clean"
expect_pass 'bundle with clean extras' "artefact_tree_check b '${work}/bundle' '${work}/bundle/app' release present"
cp "$(artefact e2 1.1.1w)" "${work}/bundle/Frameworks/libbundled"
expect_fail 'an extra with its own OpenSSL' "artefact_tree_check b '${work}/bundle' '${work}/bundle/app' release present" 'the door is not in the graph'
mkdir -p "${work}/abi"; cp "$(artefact e3 3.5.5)" "${work}/abi/libssl.so"
expect_fail 'an ABI with only a prebuilt libssl' "artefact_tree_check b '${work}/abi' - debug present" 'the door is not in the graph'
grep -qF 'artefact_tree_check "android-${abi}"' .github/workflows/android-validation.yml || fail 'android-native does not judge every library of each ABI'
grep -qF 'artefact_tree_check ios-arm64-sim-app' .github/workflows/ios-validation.yml || fail 'ios-native does not judge the whole .app'

# ---- H4: the gate also runs before every shell build ---------------------------------------
pre="$(sed -n '/android-native)/,/mobile_run android-debug-build/p' .github/workflows/android-validation.yml)"
grep -qF 'openssl_door_gate android-arm64-v8a-openssl-door-only-prebuild' <<<"${pre}" || fail 'android-native does not gate before the build'
for file in .github/actions/linux-concern-rust/action.yml .github/actions/macos-concern-rust/action.yml .github/actions/windows-concern-rust/action.yml; do
  pre="$(sed -n '/rust-packaging)/,/run_deferred rust-packaging-smoke/p' "${file}")"
  grep -qF 'run_deferred rust-packaging-door-gate openssl_door_gate' <<<"${pre}" || fail "${file} does not gate before the desktop build"
done

# ---- G5: refusals again after the build; the whole APK and the Windows target directory -------
native="$(sed -n '/android-native)/,/android-rust)/p' .github/workflows/android-validation.yml)"
[[ "$(grep -c 'refuse_openssl_overrides || exit 1' <<<"${native}")" -ge 2 ]] || fail 'android-native does not repeat the refusals after the build'
grep -qF 'unzip -q "${apk}" -d "${apk_root}"' <<<"${native}" && grep -qF 'artefact_tree_check android-apk-other' <<<"${native}" || fail 'android-native does not judge the whole APK'
ios_native="$(sed -n '/ios-native)/,/ios-rust)/p' .github/workflows/ios-validation.yml)"
[[ "$(grep -c 'refuse_openssl_overrides || exit 1' <<<"${ios_native}")" -ge 2 ]] || fail 'ios-native does not repeat the refusals after the build'
for file in .github/actions/linux-concern-rust/action.yml .github/actions/macos-concern-rust/action.yml .github/actions/windows-concern-rust/action.yml; do
  post="$(sed -n '/run_deferred rust-packaging-smoke/,/desktop_artefact_check/p' "${file}")"
  grep -qF 'rust-packaging-openssl-overrides-post refuse_openssl_overrides' <<<"${post}" && grep -qF 'rust-packaging-build-overrides-post refuse_build_feature_overrides' <<<"${post}" || fail "${file} does not repeat the refusals after the build"
done
mkdir -p "${work}/tgt/deps"
cp "$(artefact w1 3.5.5)" "${work}/tgt/app.exe"; cp "$(artefact w2 3.5.5)" "${work}/tgt/shell_lib.dll"; cp "$(artefact w3 1.1.1w)" "${work}/tgt/deps/ignored.dll"
expect_pass 'Windows target: shell library judged by the door rule, deps not walked' "TCI_TREE_MAXDEPTH=1 TCI_TREE_DOOR_NAMES=shell_lib.dll artefact_tree_check w '${work}/tgt' '${work}/tgt/app.exe' debug present"
cp "$(artefact w4 3.0.13)" "${work}/tgt/bundled.dll"
expect_fail 'Windows target: another DLL with OpenSSL' "TCI_TREE_MAXDEPTH=1 TCI_TREE_DOOR_NAMES=shell_lib.dll artefact_tree_check w '${work}/tgt' '${work}/tgt/app.exe' debug present" 'the door is not in the graph'
grep -qF 'TCI_TREE_MAXDEPTH=1 TCI_TREE_DOOR_NAMES=' .github/actions/shell-artefact/action.yml || fail 'the Windows desktop check does not scan the target directory'

# ---- D3/G7: door crates fetched afresh, every cached copy verified, built copy compared --------
reg="${work}/cargo-home/registry"
upstream="${work}/upstream"; mkdir -p "${upstream}"
for crate in openssl-0.10.81 openssl-src-300.5.5+3.5.5 openssl-sys-0.9.117 tokio-openssl-0.6.5; do
  mkdir -p "${work}/pkg/${crate}/src" "${work}/pkg/${crate}/empty"; printf 'fn main() {}\n' >"${work}/pkg/${crate}/src/lib.rs"
  COPYFILE_DISABLE=1 tar -czf "${upstream}/${crate}.crate" -C "${work}/pkg" "${crate}"
done
lock_with_real_sums() {
  ruby -e '
    require "digest"
    lock, cache = ARGV
    text = File.read(lock).gsub(/name = "([^"]+)"\nversion = "([^"]+)"\nsource = "([^"]+)"\nchecksum = "[0-9a-f]+"/) do
      name, version, source = $1, $2, $3
      sum = Digest::SHA256.file(File.join(cache, "#{name}-#{version}.crate")).hexdigest
      %(name = "#{name}"\nversion = "#{version}"\nsource = "#{source}"\nchecksum = "#{sum}")
    end
    File.write(lock, text)' "${src}/Cargo.lock" "${upstream}"
}
lock_with_real_sums
# A planted decoy with a good archive, and a tampered copy where cargo looks: both are deleted.
mkdir -p "${reg}/cache/aaa-decoy" "${reg}/cache/index.crates.io-0000" "${reg}/src/index.crates.io-0000/openssl-src-300.5.5+3.5.5"
cp "${upstream}/openssl-src-300.5.5+3.5.5.crate" "${reg}/cache/aaa-decoy/"
printf 'tampered\n' >"${reg}/cache/index.crates.io-0000/openssl-src-300.5.5+3.5.5.crate"
expect_pass 'decoy and tampered copies replaced by a fresh fetch' 'verify_door_crate_sources'
[[ ! -e "${reg}/cache/aaa-decoy/openssl-src-300.5.5+3.5.5.crate" && ! -e "${reg}/src/index.crates.io-0000/openssl-src-300.5.5+3.5.5" ]] || fail 'the planted copies were not deleted before the fetch'
expect_fail 'a fetch that leaves a tampered second copy' 'FAKE_FETCH=decoy verify_door_crate_sources' 'does not match the Cargo.lock checksum'
expect_fail 'a fetch that leaves no archive' 'FAKE_FETCH=none verify_door_crate_sources' 'archive to verify'
expect_pass 'verified again' 'verify_door_crate_sources'
for crate in openssl-0.10.81 openssl-src-300.5.5+3.5.5 openssl-sys-0.9.117 tokio-openssl-0.6.5; do
  tar -xzf "${reg}/cache/index.crates.io-0000/${crate}.crate" -C "${reg}/src/index.crates.io-0000"; : >"${reg}/src/index.crates.io-0000/${crate}/.cargo-ok"
done
expect_pass 'built copies equal their verified archives' 'verify_door_crate_build_inputs'
expect_pass 'built copies equal their verified archives, read by a native Windows Python' "${windows}; verify_door_crate_build_inputs"
mutant 'the extracted crate paths handed to Python unconverted' config '"$(tci_native_path "$1")" "$(tci_native_path "$2")" "$3"' '"$1" "$2" "$3"' pass "${windows}; verify_door_crate_build_inputs"
printf 'planted\n' >"${reg}/src/index.crates.io-0000/openssl-src-300.5.5+3.5.5/build.rs"
expect_fail 'a file the archive does not hold, in a registry/src copy' 'verify_door_crate_build_inputs' 'differs from its verified archive'
mutant 'extra files in a registry/src copy ignored' config 'sys.exit(0 if seen_files == files and seen_dirs == dirs else 1)' 'sys.exit(0 if all(seen_files.get(k) == v for k, v in files.items()) else 1)' fail 'verify_door_crate_build_inputs'
rm "${reg}/src/index.crates.io-0000/openssl-src-300.5.5+3.5.5/build.rs"
ln -s lib.rs "${reg}/src/index.crates.io-0000/openssl-src-300.5.5+3.5.5/src/link.rs"
expect_fail 'a link in a registry/src copy' 'verify_door_crate_build_inputs' 'differs from its verified archive'
rm "${reg}/src/index.crates.io-0000/openssl-src-300.5.5+3.5.5/src/link.rs"
expect_pass 'the registry/src copies restored' 'verify_door_crate_build_inputs'
# An explicit empty archive directory can hide an extra file when descent fails. Prove that
# the kernel actually denies this unprivileged process enumeration; root cannot prove the case.
fixture_uid="$(id -u)"
[[ "${fixture_uid}" -ne 0 ]] || fail 'the unreadable-directory fixture requires an unprivileged user'
unreadable="${reg}/src/index.crates.io-0000/openssl-src-300.5.5+3.5.5/empty"
printf 'planted\n' >"${unreadable}/hidden.rs"
chmod 000 "${unreadable}"
"${real_python}" -c '
import os, sys
try:
    list(os.scandir(sys.argv[1]))
except PermissionError:
    sys.exit(0)
sys.exit(1)
' "${unreadable}" || fail 'the unreadable-directory fixture did not deny enumeration'
expect_fail 'an unreadable archive directory hiding an extra file' 'verify_door_crate_build_inputs' 'differs from its verified archive'
mutant 'directory traversal errors ignored' config 'os.walk(root, onerror=walk_error)' 'os.walk(root)' fail 'verify_door_crate_build_inputs'
chmod 700 "${unreadable}"
rm "${unreadable}/hidden.rs"
unreadable=''
expect_pass 'the readable empty archive directory restored' 'verify_door_crate_build_inputs'
echo "shell-artefact fixtures: unreadable-directory refusal and no-onerror mutant exercised as uid ${fixture_uid}"
printf '// planted\n' >>"${reg}/src/index.crates.io-0000/openssl-src-300.5.5+3.5.5/src/lib.rs"
expect_fail 'a registry/src copy modified after verification' 'verify_door_crate_build_inputs' 'differs from its verified archive'
rm -rf "${reg}"
write_lock

# ---- D4: the committed Gradle wrapper is Gradle's -----------------------------------------------
wrap="${src}/taurine-mobile/src-tauri/gen/android/gradle/wrapper"; mkdir -p "${wrap}"
printf 'wrapper jar\n' >"${wrap}/gradle-wrapper.jar"
printf '#!/bin/sh\n' >"${wrap}/../../gradlew"; printf '@echo off\n' >"${wrap}/../../gradlew.bat"
jar_sum="$( (sha256sum "${wrap}/gradle-wrapper.jar" 2>/dev/null || shasum -a 256 "${wrap}/gradle-wrapper.jar") | cut -d' ' -f1)"
props() { printf 'distributionBase=GRADLE_USER_HOME\ndistributionUrl=%s\n%s' "$1" "${2:+distributionSha256Sum=$2
}" >"${wrap}/gradle-wrapper.properties"; }
props 'https\://services.gradle.org/distributions/gradle-8.14.3-bin.zip' bd71102213493060956ec229d946beee57158dbd89d0e62b91bca0fa2c5f3531
# The stand-in jar plays Gradle 8.14.3's published wrapper jar; a different jar plays 7.0's.
pin="tci_gradle_wrapper_jar_sha256() { [[ \$1 == 8.14.3 ]] && echo ${jar_sum}; };"
scripts="tci_gradle_scripts_sha256() { [[ \$1 == 8.14.3 ]] && echo \"\$(tci_sha256 '${wrap}/../../gradlew') \$(tci_sha256 '${wrap}/../../gradlew.bat')\"; };"
expect_pass 'the 8.14.3 jar with an 8.14.3 distributionUrl' "${pin} ${scripts} gradle_wrapper_check"
expect_fail 'a jar that is no published wrapper' 'gradle_wrapper_check' "not Gradle 8.14.3's published wrapper jar"
printf 'gradle 7.0 wrapper jar\n' >"${wrap}/gradle-wrapper.jar"
expect_fail 'the 7.0 jar with an 8.14.3 distributionUrl' "${pin} gradle_wrapper_check" "not Gradle 8.14.3's published wrapper jar"
printf 'wrapper jar\n' >"${wrap}/gradle-wrapper.jar"
props 'https\://services.gradle.org/distributions/gradle-8.14.3-bin.zip' ''
expect_fail 'no distributionSha256Sum' "${pin} gradle_wrapper_check" 'distributionSha256Sum is missing'
props 'https\://services.gradle.org/distributions/gradle-8.14.3-bin.zip' 0000000000000000000000000000000000000000000000000000000000000000
expect_fail 'a wrong distributionSha256Sum' "${pin} gradle_wrapper_check" 'distributionSha256Sum is missing'
props 'https\://example.invalid/gradle-8.14.3-bin.zip' bd71102213493060956ec229d946beee57158dbd89d0e62b91bca0fa2c5f3531
expect_fail 'a non-official distributionUrl' "${pin} gradle_wrapper_check" 'not an official Gradle'
props 'https\://services.gradle.org/distributions/gradle-7.6-bin.zip' x
expect_fail 'an unpinned Gradle version' "${pin} gradle_wrapper_check" 'no pinned wrapper jar checksum'
props 'https\://services.gradle.org/distributions/gradle-8.14.3-bin.zip' bd71102213493060956ec229d946beee57158dbd89d0e62b91bca0fa2c5f3531
expect_pass 'the pinned gradlew scripts' "${pin} ${scripts} gradle_wrapper_check"
expect_fail 'gradlew scripts that are not pinned' "${pin} gradle_wrapper_check" 'is not the pinned script'
cp "${wrap}/../../gradlew" "${work}/gradlew.pinned"
printf '#!/bin/sh\nexec ./evil\n' >"${work}/gradlew.changed"
expect_fail 'a gradlew changed after pinning' "${pin} tci_gradle_scripts_sha256() { [[ \$1 == 8.14.3 ]] && echo \"\$(tci_sha256 '${work}/gradlew.pinned') \$(tci_sha256 '${wrap}/../../gradlew.bat')\"; }; cp '${work}/gradlew.changed' '${wrap}/../../gradlew'; gradle_wrapper_check" 'is not the pinned script'
grep -qF 'gradle_wrapper_check || exit 1' .github/workflows/android-validation.yml || fail 'android-native does not check the Gradle wrapper'
rm -rf "${src}/taurine-mobile/src-tauri/gen"

# ---- gen/: CI regenerates the mobile Rust build phases ---------------------------------------
gen="${src}/taurine-mobile/src-tauri/gen"
bsrc="${gen}/android/buildSrc"
pkg=src/main/java/co/tangent/taurine/mobile/kotlin
bt="${bsrc}/${pkg}/BuildTask.kt"
mkdir -p "${gen}/apple"
build_task() { mkdir -p "${bsrc}/${pkg}"; printf '        val executable = """%s""";\n        val args = listOf(%s);\n%s' "$1" "$2" "${3:-}" >"${bt}"; }
# The tracked buildSrc stand-in, and a pinned list standing in for the reviewed one.
bsrc_tracked() {
  rm -rf "${bsrc}"; mkdir -p "${bsrc}/${pkg}"
  printf 'plugins { id("stand-in") }\n' >"${bsrc}/build.gradle.kts"
  printf 'class RustPlugin\n' >"${bsrc}/${pkg}/RustPlugin.kt"
  printf 'old callback\n' >"${bt}"
}
bsrc_pins() {
  mobile_pins="mobile_android_buildsrc_pinned() { printf '%s  build.gradle.kts\n%s  ${pkg}/RustPlugin.kt\n' $(shasum -a 256 "${bsrc}/build.gradle.kts" | cut -d' ' -f1) $(shasum -a 256 "${bsrc}/${pkg}/RustPlugin.kt" | cut -d' ' -f1); };"
}
bsrc_tracked; bsrc_pins
expect_pass 'reset removes only the source callback' "${mobile_pins} mobile_build_phase_reset android && [[ ! -e '${bt}' && -f '${bsrc}/build.gradle.kts' && -f '${bsrc}/${pkg}/RustPlugin.kt' ]]"
expect_fail 'init did not regenerate the phase' "${mobile_pins} mobile_build_phase_check android" 'missing file'
build_task npm '"run", "--", "tauri", "android", "android-studio-script"'
expect_pass 'the regenerated npm run -- tauri callback' "${mobile_pins} mobile_build_phase_check android"
bsrc_tracked
printf 'extra\n' >"${bsrc}/extra.gradle"
expect_fail 'an extra file in buildSrc is refused at reset' "${mobile_pins} mobile_build_phase_reset android" 'unexpected file: extra.gradle'
bsrc_tracked; bsrc_pins; printf 'class RustPlugin { evil }\n' >"${bsrc}/${pkg}/RustPlugin.kt"
expect_fail 'a modified RustPlugin.kt is refused' "${mobile_pins} mobile_build_phase_reset android" 'RustPlugin.kt: hash mismatch'
bsrc_tracked; bsrc_pins; printf 'plugins { id("evil") }\n' >"${bsrc}/build.gradle.kts"
expect_fail 'a modified build.gradle.kts is refused' "${mobile_pins} mobile_build_phase_reset android" 'build.gradle.kts: hash mismatch'
bsrc_tracked; bsrc_pins; rm "${bsrc}/${pkg}/RustPlugin.kt"
expect_fail 'a missing pinned file is refused' "${mobile_pins} mobile_build_phase_reset android" 'missing file: src/main/java'
bsrc_tracked; bsrc_pins; rm -rf "${bsrc}"
expect_fail 'a missing buildSrc is refused' "${mobile_pins} mobile_build_phase_reset android" 'buildSrc is missing'
bsrc_tracked; bsrc_pins; ln -s /etc/hosts "${bsrc}/link"
expect_fail 'a symlink in buildSrc is refused' "${mobile_pins} mobile_build_phase_reset android" 'link or special file'
bsrc_tracked; bsrc_pins; build_task npm '"run", "--", "tauri", "android", "android-studio-script"'
printf 'sneaky\n' >"${bsrc}/src/main/java/Other.kt"
expect_fail 'an extra file after init is refused' "${mobile_pins} mobile_build_phase_check android" 'unexpected file: src/main/java/Other.kt'
rm "${bsrc}/src/main/java/Other.kt"
printf 'class RustPlugin { evil }\n' >"${bsrc}/${pkg}/RustPlugin.kt"
expect_fail 'a RustPlugin.kt changed before the check is refused' "${mobile_pins} mobile_build_phase_check android" 'RustPlugin.kt: hash mismatch'
bsrc_tracked; bsrc_pins; build_task npm '"run", "--", "tauri", "android", "android-studio-script"'
expect_pass 'the pinned set plus the callback passes' "${mobile_pins} mobile_build_phase_check android"
build_task node '"tauri", "android", "android-studio-script"'
expect_fail 'an unrunnable node tauri callback' "${mobile_pins} mobile_build_phase_check android" 'callback'
build_task npm '"run", "--", "tauri", "android", "android-studio-script"' '        val executable = """sh""";\n'
expect_fail 'a second executable in the phase' "${mobile_pins} mobile_build_phase_check android" 'callback'
build_task npm '"run", "evil", "android", "android-studio-script"'
expect_fail 'a callback to another npm script' "${mobile_pins} mobile_build_phase_check android" 'callback'
# The library pins the two tracked private files by hash (hashes only, never content).
grep -qF '11818be939b3aa44d691228f8666fba5efc796cdc1b4fb8072ab7c91bc056eb0  build.gradle.kts' .github/actions/shell-config/action.yml || fail 'the buildSrc build.gradle.kts hash is not pinned'
grep -qF 'd9f87ff5a1aaa6c25b2afe8140f1d02fe4f3065ed451a1fef21875d9f30201d9  src/main/java/co/tangent/taurine/mobile/kotlin/RustPlugin.kt' .github/actions/shell-config/action.yml || fail 'the buildSrc RustPlugin.kt hash is not pinned'
yml="${gen}/apple/project.yml"
lsp='$(inherited) $(PROJECT_DIR)/Externals/arm64/$(CONFIGURATION) $(SDKROOT)/usr/lib/swift $(DEVELOPER_DIR)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/$(PLATFORM_NAME) $(DEVELOPER_DIR)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/$(PLATFORM_NAME)'
project_yml() {
  printf 'name: x\ntargets:\n  app_iOS:\n    settings:\n      base:\n        LIBRARY_SEARCH_PATHS[arch=arm64]: "%s"\n%s    dependencies:\n      - framework: %s\n        embed: false\n      - sdk: SystemConfiguration.framework\n      - sdk: UIKit.framework\n%s    preBuildScripts:\n      - name: Build Rust Code\n        script: %s\n%s' \
    "${1:-${lsp}}" "${2:-}" "${3:-libapp.a}" "${6:-}" "${4:-npm run -- tauri ios xcode-script -v --platform x}" "${5:-}" >"${yml}"
}
project_yml
expect_pass 'the regenerated Xcode project' 'mobile_build_phase_check ios'
project_yml '' '' '' 'node tauri ios xcode-script -v'
expect_fail 'an Xcode phase not calling npm run -- tauri' 'mobile_build_phase_check ios' 'regenerated template'
project_yml '' '' '' '' '    postBuildScripts:\n      - name: Extra\n        script: ./x.sh\n'
expect_fail 'a second script phase' 'mobile_build_phase_check ios' 'regenerated template'
project_yml '' '        OTHER_LDFLAGS: -lcrypto\n'
expect_fail 'OTHER_LDFLAGS in the project' 'mobile_build_phase_check ios' 'regenerated template'
project_yml '' '        FRAMEWORK_SEARCH_PATHS: /tmp/f\n'
expect_fail 'FRAMEWORK_SEARCH_PATHS in the project' 'mobile_build_phase_check ios' 'regenerated template'
project_yml '$(inherited) /tmp/libs'
expect_fail 'a changed LIBRARY_SEARCH_PATHS' 'mobile_build_phase_check ios' 'regenerated template'
project_yml '' '' 'Vendor/libssl.a'
expect_fail 'another linked framework file' 'mobile_build_phase_check ios' 'regenerated template'
project_yml '' '' '' '' '' '      - sdk: Vendor.framework\n'
expect_fail 'an SDK framework outside the allow-list' 'mobile_build_phase_check ios' 'regenerated template'
project_yml '' '' '' '' '' '      - carthage: Alamofire\n'
expect_fail 'a carthage dependency' 'mobile_build_phase_check ios' 'regenerated template'
project_yml '' '' '' '' '' '      - package: Vendored\n'
expect_fail 'a package dependency' 'mobile_build_phase_check ios' 'regenerated template'
project_yml '' '' '' '' '' '      - target: Helper\n'
expect_fail 'a target dependency' 'mobile_build_phase_check ios' 'regenerated template'
project_yml
( cd "${src}" && git init -q && git add taurine-mobile/src-tauri/gen/apple/project.yml )
expect_fail 'a committed gen/apple' 'mobile_build_phase_reset ios' 'is committed'
rm -rf "${src}/.git" "${gen}"
grep -qF 'mobile_build_phase_reset android' .github/workflows/android-validation.yml && grep -qF 'mobile_build_phase_check android' .github/workflows/android-validation.yml || fail 'the Android init does not regenerate and check the build phase'
grep -qF 'mobile_build_phase_reset ios' .github/actions/ios-project-init/action.yml && grep -qF 'mobile_build_phase_check ios' .github/actions/ios-project-init/action.yml || fail 'the iOS init does not regenerate and check the build phase'

# ---- Built graph, with REAL cargo: a toy workspace built offline ------------------------------
# Path crates only (no registry), so cargo builds offline in seconds. `openssl`, `openssl-sys`
# and `openssl-src` are stand-ins with the real names; the door path is
# taurine-mobile -> taurine-db-dbx -> openssl -> openssl-sys (build: openssl-src).
toy="${work}/toy"; rm -rf "${toy}"
crate() { # crate <dir> <name> <deps toml> [lib extra]
  mkdir -p "${toy}/$1/src"
  printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n%s\n[dependencies]\n%s\n' "$2" "${4:-}" "$3" >"${toy}/$1/Cargo.toml"
  printf 'pub fn f() {}\n' >"${toy}/$1/src/lib.rs"
}
crate openssl-src openssl-src ''
crate openssl-sys openssl-sys '' '[build-dependencies]
openssl-src = { path = "../openssl-src" }'
printf 'fn main() {}\n' >"${toy}/openssl-sys/build.rs"
crate openssl openssl 'openssl-sys = { path = "../openssl-sys" }'
crate tls taurine-tls-openssl 'openssl = { path = "../openssl" }
openssl-sys = { path = "../openssl-sys" }'
crate dbx taurine-db-dbx 'openssl = { path = "../openssl" }
taurine-tls-openssl = { path = "../tls" }'
crate consumer consumer 'openssl = { path = "../openssl" }'
crate tokio tokio-openssl 'openssl = { path = "../openssl" }'
# The vendored MySQL fork: a tokio-openssl consumer only; `direct` adds the forbidden openssl edge.
# Its description carries U+0401, whose UTF-8 bytes (d0 81) a cp1252 or ASCII reader cannot decode.
crate mysql taurine-mysql-async 'tokio-openssl = { path = "../tokio", optional = true }' 'description = "MySQL fork \u0401"
[features]
legacy-tls = ["dep:tokio-openssl"]'
crate evil2 evil2 'tokio-openssl = { path = "../tokio" }'
crate evil evil '' '[build-dependencies]
openssl-src = { path = "../openssl-src" }'
printf 'fn main() {}\n' >"${toy}/evil/build.rs"
crate shell taurine-mobile 'taurine-db-dbx = { path = "../dbx" }
consumer = { path = "../consumer", optional = true }
evil2 = { path = "../evil2", optional = true }
taurine-mysql-async = { path = "../mysql", optional = true }
evil = { path = "../evil", optional = true }' '[features]
extra = ["dep:consumer"]
mysqlok = ["dep:taurine-mysql-async", "taurine-mysql-async/legacy-tls"]
tokiobad = ["dep:evil2"]
evilsrc = ["dep:evil"]'
printf '[workspace]\nmembers = ["shell", "dbx", "tls", "openssl", "openssl-sys", "openssl-src", "consumer", "evil", "evil2", "tokio", "mysql"]\nresolver = "2"\n' >"${toy}/Cargo.toml"
toy_build() { # toy_build <target-dir> [cargo args]
  local dir="$1"; shift
  ( cd "${toy}" && CARGO_TARGET_DIR="${dir}" "${real_cargo}" build --offline -q -p taurine-mobile "$@" ) >/dev/null 2>&1 ||
    fail "the toy workspace did not build with: $*"
}
toy_check() { echo "cd '${toy}' && TCI_REAL_CARGO='${real_cargo}' built_graph_check toy '$1/debug/libtaurine_mobile.d' taurine-mobile ${2:-present}"; }
toy_build "${work}/t-door"
run_lib "$(toy_check "${work}/t-door")" || { cat "${work}/out" >&2; fail 'the door-only toy graph: should pass'; }
grep -qF 'OpenSSL consumers: openssl, openssl-sys, taurine-db-dbx, taurine-tls-openssl (door only)' "${work}/out" || { cat "${work}/out" >&2; fail 'the door-only toy graph did not list its door consumers'; }
# E3: every unit entry must map, and the door state sets a floor on the built set.
cp -R "${work}/t-door" "${work}/t-renamed"
mv "$(find "${work}/t-renamed/debug/.fingerprint" -maxdepth 1 -name 'openssl-sys-*' | head -n 1)" "${work}/t-renamed/debug/.fingerprint/renamed-unit"
expect_fail 'a renamed fingerprint directory (real cargo)' "$(toy_check "${work}/t-renamed")" 'not a unit of a known package'
cp -R "${work}/t-door" "${work}/t-nosrc"
rm -rf "${work}/t-nosrc/debug/.fingerprint/openssl-src-"* "${work}/t-nosrc/debug/deps/openssl_src-"*.d
# In the toy, openssl-src is a path crate the artefact dep-info also lists; the real one is a
# registry crate it does not, so drop those lines to reproduce a unit that left no trace.
ruby -e 'f = ARGV[0]; File.write(f, File.read(f).split(/(?<!\\) /).reject { |p| p.include?("/openssl-src/") }.join(" ").gsub(/^[^\n]*\/openssl-src\/[^\n]*:\n/, ""))' "${work}/t-nosrc/debug/libtaurine_mobile.d"
expect_fail 'a door-present build missing openssl-src (real cargo)' "$(toy_check "${work}/t-nosrc")" 'lacks openssl-src'
expect_fail 'a door-absent build that contains openssl (real cargo)' "$(toy_check "${work}/t-door" absent)" 'the built set contains'
toy_build "${work}/t-extra" --features extra
expect_fail 'an extra feature that builds a non-door OpenSSL consumer (real cargo)' "$(toy_check "${work}/t-extra")" 'consumer depends on openssl outside the door'
# The vendored MySQL fork: allowed on tokio-openssl only. Built under a non-UTF-8 locale, with a
# U+0401 package description in the metadata, so a text open() without encoding= dies as on Windows.
toy_build "${work}/t-mysql" --features mysqlok
run_lib "PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 LC_ALL=C LANG=C; export PYTHONUTF8 PYTHONCOERCECLOCALE LC_ALL LANG; $(toy_check "${work}/t-mysql")" || { cat "${work}/out" >&2; fail 'the MySQL fork wrapping tokio-openssl, non-UTF-8 locale (real cargo): should pass'; }
grep -qF 'taurine-mysql-async' "${work}/out" || { cat "${work}/out" >&2; fail 'the MySQL fork did not appear among the door consumers'; }
mutant 'the cargo-metadata open() without encoding=' artefact 'json.load(open(meta_path, encoding="utf-8"))' 'json.load(open(meta_path))' pass "PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 LC_ALL=C LANG=C; export PYTHONUTF8 PYTHONCOERCECLOCALE LC_ALL LANG; $(toy_check "${work}/t-mysql")"
# The built graph reads the all-features resolve, so the forbidden edge is added to the fork's own
# manifest for this one build (the fork has no direct openssl edge) and restored after it.
printf 'openssl = { path = "../openssl" }\n' >>"${toy}/mysql/Cargo.toml"
toy_build "${work}/t-mysqldirect" --features mysqlok
expect_fail 'the MySQL fork depending on openssl directly (real cargo)' "$(toy_check "${work}/t-mysqldirect")" 'taurine-mysql-async depends on openssl outside the door'
crate mysql taurine-mysql-async 'tokio-openssl = { path = "../tokio", optional = true }' 'description = "MySQL fork \u0401"
[features]
legacy-tls = ["dep:tokio-openssl"]'
toy_build "${work}/t-tokiobad" --features tokiobad
expect_fail 'another crate depending on tokio-openssl (real cargo)' "$(toy_check "${work}/t-tokiobad")" 'evil2 depends on tokio-openssl outside the door'
mutant 'the built-graph allowlist re-widened: the MySQL fork allowed on openssl' artefact '"openssl": {"tokio-openssl", "taurine-tls-openssl", "taurine-db-dbx"},' '"openssl": {"tokio-openssl", "taurine-tls-openssl", "taurine-db-dbx", "taurine-mysql-async"},' fail "$(toy_check "${work}/t-mysqldirect")"
mutant 'the built-graph allowlist re-widened: any crate allowed on tokio-openssl' artefact '"tokio-openssl": {"taurine-db-dbx", "taurine-mysql-async"},' '"tokio-openssl": {"taurine-db-dbx", "taurine-mysql-async", "evil2"},' fail "$(toy_check "${work}/t-tokiobad")"
toy_build "${work}/t-evil" --features evilsrc
expect_fail 'a non-door crate building openssl-src (real cargo)' "$(toy_check "${work}/t-evil")" 'evil depends on openssl-src outside the door'
# The basedir is the real path cargo writes (macOS resolves /var to /private/var).
mkdir -p "${toy}/.cargo"; printf '[build]\ndep-info-basedir = "%s"\n' "$(cd "${toy}/consumer" && pwd -P)" >"${toy}/.cargo/config.toml"
toy_build "${work}/t-basedir" --features extra
expect_fail 'a consumer hidden by dep-info-basedir (real cargo)' "$(toy_check "${work}/t-basedir")" 'consumer depends on openssl outside the door'
expect_fail 'dep-info-basedir in a cargo config' "cd '${toy}' && refuse_openssl_overrides" 'or dep-info-basedir'
rm -r "${toy}/.cargo"
expect_fail 'CARGO_BUILD_DEP_INFO_BASEDIR in the job' 'export CARGO_BUILD_DEP_INFO_BASEDIR=/x; refuse_openssl_overrides' 'job environment'
printf 'pub fn consumer_impl() {}\n' >"${toy}/shell/src/consumer_impl.rs"
printf '[lib]\npath = "../shell/src/consumer_impl.rs"\n' >>"${toy}/consumer/Cargo.toml"
toy_build "${work}/t-libpath" --features extra
expect_fail 'a [lib] path pointing into the shell crate (real cargo)' "$(toy_check "${work}/t-libpath")" 'consumer has a target whose sources lie outside its own directory'
git -C "${work}" init -q 2>/dev/null || true
crate consumer consumer 'openssl = { path = "../openssl" }'
expect_fail 'missing dep-info (real cargo)' "$(toy_check "${work}/t-none")" 'dep-info is missing'
printf 'not a dep-info file\n' >"${work}/t-door/debug/libtaurine_mobile.d"
expect_fail 'unparseable dep-info (real cargo)' "$(toy_check "${work}/t-door")" 'does not parse'
grep -qF 'built_graph_check "android-${abi}-built-graph"' .github/workflows/android-validation.yml || fail 'android-native does not judge the built graph'
grep -qF 'built_graph_check ios-arm64-sim-built-graph' .github/workflows/ios-validation.yml || fail 'ios-native does not judge the built graph'
grep -qF 'built_graph_check "${os}-desktop-built-graph"' .github/actions/shell-artefact/action.yml || fail 'the desktop check does not judge the built graph'
expect_fail 'a non-door crate building openssl-src (S1 gate)' 'FAKE_SRC_BAD=1 openssl_door_gate g taurine-mobile -' 'evil-sys depends on openssl-src outside the OpenSSL door'

# ---- G2: a cross build reads the host profile for build-dependencies (real cargo) ------------
# openssl-src is a registry crate here (a vendored directory source standing in for crates.io),
# so the artefact dep-info never lists it, and with --target it compiles for the host, into
# target/debug/ rather than target/<triple>/debug/. The host triple is passed explicitly, which
# splits the two profiles without needing a second target installed.
x="${work}/cross"; rm -rf "${x}"; mkdir -p "${x}/vendor/openssl-src/src" "${x}/.cargo"
printf '[package]\nname = "openssl-src"\nversion = "300.5.5+3.5.5"\nedition = "2021"\n' >"${x}/vendor/openssl-src/Cargo.toml"
printf 'pub fn f() {}\n' >"${x}/vendor/openssl-src/src/lib.rs"
printf '{"files":{},"package":null}\n' >"${x}/vendor/openssl-src/.cargo-checksum.json"
printf '[source.crates-io]\nreplace-with = "vendored"\n[source.vendored]\ndirectory = "%s"\n' "${x}/vendor" >"${x}/.cargo/config.toml"
xcrate() { mkdir -p "${x}/$1/src"; printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n%s\n[dependencies]\n%s\n' "$2" "${4:-}" "$3" >"${x}/$1/Cargo.toml"; printf 'pub fn f() {}\n' >"${x}/$1/src/lib.rs"; }
xcrate openssl-sys openssl-sys '' '[build-dependencies]
openssl-src = "300.5"'
printf 'fn main() {}\n' >"${x}/openssl-sys/build.rs"
xcrate openssl openssl 'openssl-sys = { path = "../openssl-sys" }'
xcrate tls taurine-tls-openssl 'openssl = { path = "../openssl" }
openssl-sys = { path = "../openssl-sys" }'
xcrate dbx taurine-db-dbx 'openssl = { path = "../openssl" }
taurine-tls-openssl = { path = "../tls" }'
xcrate shell taurine-mobile 'taurine-db-dbx = { path = "../dbx" }'
printf '[workspace]\nmembers = ["shell", "dbx", "tls", "openssl", "openssl-sys"]\nresolver = "2"\n' >"${x}/Cargo.toml"
host="$("${real_cargo}" -vV 2>/dev/null | sed -n 's/^host: //p')"
[[ -n "${host}" ]] || host="$(rustc -vV | sed -n 's/^host: //p')"
( cd "${x}" && CARGO_TARGET_DIR="${x}/target" "${real_cargo}" build --offline -q -p taurine-mobile --target "${host}" ) >"${work}/cross.log" 2>&1 ||
  { cat "${work}/cross.log" >&2; fail 'the cross toy workspace did not build'; }
[[ -z "$(find "${x}/target/${host}/debug/.fingerprint" -maxdepth 1 -name 'openssl-src-*')" ]] ||
  fail 'the cross fixture does not reproduce a host-only openssl-src'
expect_pass 'a cross build with a host-only registry openssl-src (real cargo)' \
  "cd '${x}' && TCI_REAL_CARGO='${real_cargo}' built_graph_check cross '${x}/target/${host}/debug/libtaurine_mobile.d' taurine-mobile present"
grep -qF 'OpenSSL consumers: openssl, openssl-sys, taurine-db-dbx, taurine-tls-openssl (door only)' "${work}/out" || { cat "${work}/out" >&2; fail 'the cross build did not judge the door consumers'; }
rm -rf "${x}/target/debug/.fingerprint/openssl-src-"* "${x}/target/debug/deps/openssl_src-"*.d
expect_fail 'a cross build whose host profile lost openssl-src (real cargo)' \
  "cd '${x}' && TCI_REAL_CARGO='${real_cargo}' built_graph_check cross '${x}/target/${host}/debug/libtaurine_mobile.d' taurine-mobile present" 'lacks openssl-src'

# ---- B3: the shipped artefact is the judged build ---------------------------------------------
crate bin taurine-desktop ''
printf 'fn main() {}\n' >"${toy}/bin/src/main.rs"
printf '[workspace]\nmembers = ["shell", "dbx", "tls", "openssl", "openssl-sys", "openssl-src", "consumer", "evil", "evil2", "tokio", "mysql", "bin"]\nresolver = "2"\n' >"${toy}/Cargo.toml"
( cd "${toy}" && CARGO_TARGET_DIR="${work}/t-bin" "${real_cargo}" build --offline -q -p taurine-desktop ) >/dev/null 2>&1 || fail 'the toy binary did not build'
cp "${work}/t-bin/debug/taurine-desktop" "${work}/shipped-bin"
expect_pass 'a bundled copy of the judged binary (real cargo)' "bind_same_binary b '${work}/shipped-bin' '${work}/t-bin/debug/taurine-desktop'"
printf 'fn main() { println!("swapped"); }\n' >"${toy}/bin/src/main.rs"
( cd "${toy}" && CARGO_TARGET_DIR="${work}/t-bin2" "${real_cargo}" build --offline -q -p taurine-desktop ) >/dev/null 2>&1 || fail 'the swapped toy binary did not build'
cp "${work}/t-bin2/debug/taurine-desktop" "${work}/shipped-bin"
expect_fail 'a binary swapped in after the build (real cargo)' "bind_same_binary b '${work}/shipped-bin' '${work}/t-bin/debug/taurine-desktop'" 'not the build that was judged'
# The Tauri bundle-type marker: the bundler overwrites the UNK of `__TAURI_BUNDLE_TYPE_VAR_UNK` in
# the copy it puts in a .deb with DEB (tci_bundle_marker_only). `mark <in> <out> <value> [<byte>]`
# does what the bundler does, and with <byte> also flips one byte elsewhere (-1: the middle).
printf 'fn main() { println!("{}", std::hint::black_box("__TAURI_BUNDLE_TYPE_VAR_UNK")); }\n' >"${toy}/bin/src/main.rs"
( cd "${toy}" && CARGO_TARGET_DIR="${work}/t-bin3" "${real_cargo}" build --offline -q -p taurine-desktop ) >/dev/null 2>&1 || fail 'the marked toy binary did not build'
marked="${work}/t-bin3/debug/taurine-desktop"
[[ "$(LC_ALL=C grep -a -o '__TAURI_BUNDLE_TYPE_VAR_UNK' "${marked}" | wc -l | tr -d ' ')" == 1 ]] || fail 'the marked toy binary does not carry exactly one bundle-type marker'
mark() {
  ruby -e '
    input, output, value, flip = ARGV
    bytes = File.binread(input)
    at = bytes.index("__TAURI_BUNDLE_TYPE_VAR_UNK") or abort("no marker")
    bytes[at + 24, 3] = value
    if flip
      byte = Integer(flip)
      byte = bytes.bytesize / 2 if byte.negative?
      byte += 64 if byte.between?(at - 1, at + 27)
      bytes.setbyte(byte, bytes.getbyte(byte) ^ 1)
    end
    File.binwrite(output, bytes)' "$@"
}
bind_marked="bind_same_binary b '${work}/shipped-marked' '${marked}'"
mark "${marked}" "${work}/shipped-marked" DEB
expect_pass 'a .deb copy differing only in its DEB marker (real cargo)' "TCI_BUNDLE_TYPE=DEB ${bind_marked}"
grep -qF 'apart from the DEB bundle-type marker' "${work}/out" || { cat "${work}/out" >&2; fail 'the marker-only binding was not reported as such'; }
expect_fail 'a marked copy where no bundle marker is expected (real cargo)' "${bind_marked}" 'not the build that was judged'
expect_fail 'a marked copy under a marker the bundler never writes' "TCI_BUNDLE_TYPE=XYZ ${bind_marked}" 'not one the Tauri bundler writes'
mark "${marked}" "${work}/shipped-marked" RPM
expect_fail 'an RPM marker where the .deb copy carries DEB (real cargo)' "TCI_BUNDLE_TYPE=DEB ${bind_marked}" 'not the build that was judged'
# ELF64 e_entry is retained by strip. A midpoint byte may live in discarded debug data,
# which is deliberately permitted by the existing stripped-binary binding fallback.
mark "${marked}" "${work}/shipped-marked" DEB 24
expect_fail 'a DEB marker plus one other changed byte (real cargo)' "TCI_BUNDLE_TYPE=DEB ${bind_marked}" 'not the build that was judged'
mutant 'the marker comparison that ignores every other byte' artefact 'if shipped[:start] != built[:start] or shipped[end:] != built[end:]:' 'if False:' fail "TCI_BUNDLE_TYPE=DEB ${bind_marked}"
mark "${work}/t-bin/debug/taurine-desktop" "${work}/shipped-marked" DEB 2>/dev/null && fail 'the unmarked toy binary carries a marker'
cp "${work}/t-bin/debug/taurine-desktop" "${work}/shipped-unmarked"; ruby -e 'b = File.binread(ARGV[0]); b.setbyte(24, b.getbyte(24) ^ 1); File.binwrite(ARGV[0], b)' "${work}/shipped-unmarked"
expect_fail 'a changed copy of a build that carries no marker (real cargo)' "TCI_BUNDLE_TYPE=DEB bind_same_binary b '${work}/shipped-unmarked' '${work}/t-bin/debug/taurine-desktop'" 'not the build that was judged'
expect_fail 'no marker in the built binary' "tci_bundle_marker_only '${work}/shipped-unmarked' '${work}/t-bin/debug/taurine-desktop' DEB" 'carries no bundle-type marker'
printf 'head __TAURI_BUNDLE_TYPE_VAR_UNK mid __TAURI_BUNDLE_TYPE_VAR_UNK tail\n' >"${work}/built-two"
printf 'head __TAURI_BUNDLE_TYPE_VAR_DEB mid __TAURI_BUNDLE_TYPE_VAR_UNK tail\n' >"${work}/shipped-two"
expect_fail 'two markers in the built binary' "tci_bundle_marker_only '${work}/shipped-two' '${work}/built-two' DEB" 'more than one bundle-type marker'
expect_fail 'two markers, through the binding' "TCI_BUNDLE_TYPE=DEB bind_same_binary b '${work}/shipped-two' '${work}/built-two'" 'not the build that was judged'
mutant 'a second marker accepted' artefact 'if built.find(marker, at + 1) >= 0:' 'if False:' fail "tci_bundle_marker_only '${work}/shipped-two' '${work}/built-two' DEB"
# Stripped as well as marked: the stripped copies differ only in the marker.
run_lib "cp \"\$(tci_stripped_copy '${marked}' '')\" '${work}/stripped-marked'" || { cat "${work}/out" >&2; fail 'the marked toy binary did not strip'; }
mark "${work}/stripped-marked" "${work}/shipped-marked" DEB
expect_pass 'a stripped .deb copy differing only in its DEB marker (real cargo)' "TCI_BUNDLE_TYPE=DEB ${bind_marked}"
grep -qF 'equal once stripped, apart from the DEB bundle-type marker' "${work}/out" || { cat "${work}/out" >&2; fail 'the stripped marker-only binding was not reported as such'; }
mark "${work}/stripped-marked" "${work}/shipped-marked" DEB 24
expect_fail 'a stripped DEB copy plus one other changed byte (real cargo)' "TCI_BUNDLE_TYPE=DEB ${bind_marked}" 'not the build that was judged'
# Without the marker normalisation the .deb binding refuses the bundler's own copy: the defect.
mark "${marked}" "${work}/shipped-marked" DEB
mutant 'the bundle-type marker normalisation removed' artefact 'tci_bundle_marker_only() {
  local python' 'tci_bundle_marker_only() {
  return 1
  local python' pass "TCI_BUNDLE_TYPE=DEB ${bind_marked}"
expect_pass 'the marker-only binding read by a native Windows Python (real cargo)' "${windows}; TCI_BUNDLE_TYPE=DEB ${bind_marked}"
grep -qF 'TCI_BUNDLE_TYPE="${marker}" bind_same_binary "${os}-desktop-binding"' .github/actions/shell-artefact/action.yml || fail 'the desktop binding does not name the bundle marker'
[[ "$(ruby -e 'puts File.read(ARGV[0])[/Linux\)\n(.*?);;/m, 1].to_s.scan(/^\s*marker=(\S+)$/).flatten.join(",")' .github/actions/shell-artefact/action.yml)" == DEB ]] ||
  fail 'the Linux desktop binding does not expect exactly the DEB marker of the .deb it unpacks'
# Android: the NDK's llvm-readelf/llvm-strip are not in the policy environment, so stand-ins
# report a build-id read from the file (the comparison logic is what is under test).
printf '#!/usr/bin/env bash\nprintf "  Build ID: %%s\\n" "$(head -n 1 "$2")"\n' >"${work}/bin/fake-readelf"; chmod +x "${work}/bin/fake-readelf"
# The stand-in strip drops line 2 (the "debug" line); line 1 is the build-id, line 3 the code.
printf '#!/usr/bin/env bash\nsed -i.bak 2d "$2" && rm -f "$2.bak"\n' >"${work}/bin/fake-strip"; chmod +x "${work}/bin/fake-strip"
android_bind="TCI_READELF='${work}/bin/fake-readelf' TCI_STRIP='${work}/bin/fake-strip' bind_android_library a '${work}/shipped.so' '${work}/built.so'"
printf 'abc123\ndebug\ncode-a\n' >"${work}/built.so"; printf 'abc123\npackaged\ncode-a\n' >"${work}/shipped.so"
expect_pass 'an APK library equal to the judged build once stripped' "${android_bind}"
printf 'def456\ndebug\ncode-b\n' >"${work}/shipped.so"
expect_fail 'a .so swapped into the APK after the build' "${android_bind}" "build-id is not the judged build"
printf 'abc123\ndebug\ncode-b\n' >"${work}/shipped.so"
expect_fail 'a forged equal build-id with different code (E2)' "${android_bind}" 'stripped contents differ'
grep -qF 'bind_android_library "android-${abi}-binding"' .github/workflows/android-validation.yml || fail 'android-native does not bind the APK library to the judged build'
grep -qF 'bind_same_binary ios-arm64-sim-binding' .github/workflows/ios-validation.yml || fail 'ios-native does not bind libapp.a to the judged build'
grep -qF 'bind_same_binary "${os}-desktop-binding"' .github/actions/shell-artefact/action.yml || fail 'the desktop check does not bind the bundled binary'

# ---- G1: the base-policy toolchain copy cannot be steered by a rust-toolchain file ----------
# The reviewed step runs with stand-ins: a HOME holding rustup's stable toolchain, a rustup that
# honours an explicit toolchain, a `rustc` proxy on PATH that (like rustup's) obeys a
# rust-toolchain.toml in the working directory or its parents, and a sudo that runs as the user.
tc="${work}/tc"; rm -rf "${tc}"; mkdir -p "${tc}/home/.rustup/toolchains/stable-host/bin" "${tc}/home/.rustup/toolchains/stable-host/lib" \
  "${tc}/home/.rustup/toolchains/stable-host/share/doc" "${tc}/home/.cargo/bin" "${tc}/bin" "${tc}/ws/evil/bin" "${tc}/tmp"
for tool in cargo rustc; do printf '#!/bin/sh\necho "stable %s 1.0.0"\n' "${tool}" >"${tc}/home/.rustup/toolchains/stable-host/bin/${tool}"; done
printf 'std\n' >"${tc}/home/.rustup/toolchains/stable-host/lib/libstd.rlib"
chmod +x "${tc}/home/.rustup/toolchains/stable-host/bin/"*
cat >"${tc}/home/.cargo/bin/rustup" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == run && "$2" == stable && "$3" == rustc && "$4" == --print && "$5" == sysroot ]] || exit 2
echo "${FAKE_SYSROOT:-${HOME}/.rustup/toolchains/stable-host}"
STUB
cat >"${tc}/bin/rustc" <<'STUB'
#!/usr/bin/env bash
# rustup's proxy: a rust-toolchain.toml with `path` in the working directory or a parent wins.
dir="${PWD}"
while [[ "${dir}" != / ]]; do
  if [[ -f "${dir}/rust-toolchain.toml" ]]; then
    exec "$(sed -nE 's/^path = "(.*)"$/\1/p' "${dir}/rust-toolchain.toml")/bin/rustc" "$@"
  fi
  dir="$(dirname "${dir}")"
done
exec "${HOME}/.rustup/toolchains/stable-host/bin/rustc" "$@"
STUB
printf '#!/usr/bin/env bash\n[[ "$1" == chown ]] && exit 0\nexec "$@"\n' >"${tc}/bin/sudo"
printf '[toolchain]\npath = "%s"\n' "${tc}/ws/evil" >"${tc}/ws/rust-toolchain.toml"
printf '#!/bin/sh\n: > "%s/evil-ran"\necho "%s/evil"\n' "${tc}" "${tc}/ws" >"${tc}/ws/evil/bin/rustc"; cp "${tc}/ws/evil/bin/rustc" "${tc}/ws/evil/bin/cargo"
chmod +x "${tc}/home/.cargo/bin/rustup" "${tc}/bin/"* "${tc}/ws/evil/bin/"*
toolchain_step() { # toolchain_step <workflow> <dest>: the reviewed step, its destination redirected
  ruby .github/policy/extract-step.rb "$1" 'Install a Rust toolchain where only root can change it' run |
    sed "s#^dest=/opt/taurine-ci-rust\$#dest=$2#"
}
run_toolchain_step() { # run_toolchain_step <workflow> <dest> [env...]
  local wf="$1" dest="$2"; shift 2
  toolchain_step "${wf}" "${dest}" >"${tc}/step.sh"
  ( cd "${tc}/ws" && env -i PATH="${tc}/bin:/usr/bin:/bin" HOME="${tc}/home" RUNNER_TEMP="${tc}/tmp" "$@" /bin/bash "${tc}/step.sh" ) >"${work}/out" 2>&1
}
rm -f "${tc}/evil-ran"
run_toolchain_step .github/workflows/base-policy.yml "${tc}/dest" || { cat "${work}/out" >&2; fail 'the toolchain copy: should pass'; }
[[ ! -e "${tc}/evil-ran" ]] || fail 'a planted rust-toolchain.toml made the toolchain step run its rustc'
[[ "$("${tc}/dest/bin/rustc")" == 'stable rustc 1.0.0' && -f "${tc}/dest/lib/libstd.rlib" && ! -e "${tc}/dest/share" ]] ||
  fail 'the toolchain copy is not the stable toolchain bin/ and lib/ only'
rm -rf "${tc}/dest"
if run_toolchain_step .github/workflows/base-policy.yml "${tc}/dest" FAKE_SYSROOT="${tc}/ws/evil"; then
  fail 'a sysroot outside rustup toolchains was copied'
fi
grep -qF 'not an installed rustup toolchain' "${work}/out" || { cat "${work}/out" >&2; fail 'a sysroot outside rustup toolchains failed for the wrong reason'; }
[[ ! -e "${tc}/dest/bin" ]] || fail 'a refused sysroot left a copy behind'

# The copy and its TCI_REAL_CARGO hand-over live in base-policy.yml's base pass, before drop-root.
ruby -ryaml -e '
  doc = YAML.safe_load(File.read(".github/workflows/base-policy.yml"), aliases: false)
  steps = doc.fetch("jobs").fetch("base-policy").fetch("steps").map { |st| st["name"] }
  copy = steps.index("Install a Rust toolchain where only root can change it")
  drop = steps.index("Remove root before the base policy runs")
  abort "the toolchain copy is not before drop-root in the base-policy job" unless copy && drop && copy < drop
  run = doc["jobs"]["base-policy"]["steps"].find { |st| st["name"] == "Run the base commit\x27s policy against this pull request" }.to_h["run"].to_s
  abort "the base step does not hand TCI_REAL_CARGO to the base scripts" unless run.include?("scrub+=(TCI_REAL_CARGO=/opt/taurine-ci-rust/bin/cargo)")
' || fail 'the base-policy job does not copy the toolchain before drop-root and pass TCI_REAL_CARGO'
! grep -qF 'Install a Rust toolchain where only root can change it' .github/workflows/validate-public-changes.yml || fail 'the toolchain copy is still in validate-public-changes.yml'

# The toolchain copy refuses any symlink (it could point back at a path the job user can write).
ln -s /tmp "${tc}/home/.rustup/toolchains/stable-host/lib/escape"
if run_toolchain_step .github/workflows/base-policy.yml "${tc}/dest"; then fail 'a toolchain copy with a symlink was accepted'; fi
grep -qF 'the toolchain copy contains a symlink' "${work}/out" || { cat "${work}/out" >&2; fail 'a toolchain symlink failed for the wrong reason'; }
[[ ! -e "${tc}/dest" ]] || fail 'a refused toolchain copy was left behind'
rm "${tc}/home/.rustup/toolchains/stable-host/lib/escape"

# ---- Windows: the vendored OpenSSL build tools, recorded and held to their major versions ------
wt="${work}/wintools"; rm -rf "${wt}"; mkdir -p "${wt}"
tools_step() { # tools_step <perl -e output> <nasm -v output | absent>
  printf '#!/bin/sh\nprintf "%%s" "%s"\n' "$1" >"${wt}/perl.exe"; chmod +x "${wt}/perl.exe"
  rm -f "${wt}/nasm.exe"
  if [[ "$2" != absent ]]; then printf '#!/bin/sh\necho "%s"\n' "$2" >"${wt}/nasm.exe"; chmod +x "${wt}/nasm.exe"; fi
  ruby .github/policy/extract-step.rb .github/workflows/windows-validation-concern.yml 'Put the vendored OpenSSL build tools in reach' run |
    sed -e "s#^perl_exe=.*#perl_exe='${wt}/perl.exe'#" -e "s#^nasm_exe=.*#nasm_exe='${wt}/nasm.exe'#" >"${wt}/step.sh"
  : >"${wt}/env"; : >"${wt}/path"; : >"${wt}/summary"
  GITHUB_ENV="${wt}/env" GITHUB_PATH="${wt}/path" GITHUB_STEP_SUMMARY="${wt}/summary" bash "${wt}/step.sh" >"${work}/out" 2>&1
}
tools_step v5.38.2 'NASM version 2.16.03 compiled on Apr 17 2024' || { cat "${work}/out" >&2; fail 'Perl 5 and NASM 2: should pass'; }
grep -qxF -- '- OpenSSL build tools: Strawberry Perl v5.38.2; NASM 2.16.03' "${wt}/summary" || fail 'the Windows summary does not record the Perl and NASM versions'
grep -qF 'OPENSSL_SRC_PERL=' "${wt}/env" && grep -qF 'NASM' "${wt}/path" || fail 'the build tools were not put in reach'
tools_step v5.40.0 absent || { cat "${work}/out" >&2; fail 'Perl 5 without NASM: should pass (no-asm)'; }
grep -qF 'NASM absent' "${wt}/summary" && [[ ! -s "${wt}/path" ]] || fail 'a missing NASM was not recorded as no-asm'
if tools_step v7.0.0 'NASM version 2.16.03'; then fail 'a Perl that is not Perl 5 was accepted'; fi
grep -qF 'is not Perl 5' "${work}/out" || fail 'a non-5 Perl failed for the wrong reason'
if tools_step v5.38.2 'NASM version 3.01 compiled'; then fail 'a NASM that is not version 2 was accepted'; fi
grep -qF 'NASM is not version 2' "${work}/out" || fail 'a non-2 NASM failed for the wrong reason'
if tools_step 'not a version' 'NASM version 2.16.03'; then fail 'an unreadable Perl version was accepted'; fi

[[ "${failures}" -eq 0 ]] || { echo "shell-artefact fixtures: ${failures} case(s) failed" >&2; exit 1; }
echo 'shell-artefact fixtures: lock-bound artefact proof, build-feature and OpenSSL-override refusals, per-ABI gating, fixed door lines, the built graph, the shipped-artefact binding and the base-policy toolchain copy hold'
