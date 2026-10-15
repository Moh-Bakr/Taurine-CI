#!/usr/bin/env bash
# Fixtures for the shell-artefact library (the OpenSSL door gate and the artefact proof), the
# fixed-schema door lines in mobile-report, the per-ABI Android wiring and the weekly
# openssl-src cadence. Every case is a weakening that must be refused (or a control that must
# pass). Offline: `cargo`, `readelf` and the binaries are stand-ins. Run from the repository root.
# shellcheck disable=SC1091,SC2016,SC2015,SC2059 # literal snippets and byte fixtures are evaluated later; libraries are extracted at run time
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
    puts body
  ' "$1"
}
extract_library .github/actions/sanitize/action.yml >"${work}/sanitize.sh"
extract_library .github/actions/mobile-report/action.yml >"${work}/mobile-report.sh"
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
cat >"${work}/bin/cargo" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == metadata ]]; then
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
expect_fail 'absent while linked (build.features)' 'FAKE_TREE=absent openssl_door_gate g taurine-desktop -' 'build.features, build.runner'
expect_fail 'door_in_graph under build.features' 'FAKE_TREE=absent door_in_graph taurine-desktop -'
printf '{"build":{"runner":"other-cargo"}}\n' >"${src}/taurine-desktop/src-tauri/tauri.conf.uat.json"
expect_fail 'build.runner' 'openssl_door_gate g taurine-desktop -' 'build.features, build.runner'
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
cat >"${tdir}/node_modules/@tauri-apps/cli/tauri.js" <<'STUB'
const env = process.env;
console.log(`tauri-argv: ${process.argv.slice(2).join(" ")} | cwd=${require("path").basename(process.cwd())} | config=${env.TAURI_CONFIG || "unset"} | other=${env.TAURI_EXTRA || "unset"}`);
STUB
ln -s ../@tauri-apps/cli/tauri.js "${tdir}/node_modules/.bin/tauri"
write_npm_lock() {
  jq -n --arg r1 "${1-https://registry.npmjs.org/@tauri-apps/cli/-/cli-2.12.0.tgz}" --arg i1 "${2-sha512-AAAA}" \
    '{lockfileVersion: 3, packages: {"node_modules/@tauri-apps/cli": {resolved: $r1, integrity: $i1},
      "node_modules/@tauri-apps/cli-linux-x64-gnu": {resolved: "https://registry.npmjs.org/@tauri-apps/cli-linux-x64-gnu/-/x.tgz", integrity: "sha512-BBBB"}}}' >"${tdir}/package-lock.json"
}
write_npm_lock
expect_pass 'tauri_cli' 'TAURI_CONFIG={} TAURI_EXTRA=1 tauri_cli taurine-desktop build --debug'
grep -qxF 'tauri-argv: build --debug | cwd=taurine-desktop | config=unset | other=unset' "${work}/out" || fail 'tauri_cli did not run the CLI with only CI arguments and no TAURI_* environment'
write_npm_lock 'git+https://example.invalid/cli.git#1'
expect_fail 'a git-resolved Tauri CLI' 'tauri_cli taurine-desktop build' 'not a registry package'
write_npm_lock 'https://registry.npmjs.org/@tauri-apps/cli/-/cli-2.12.0.tgz' ''
expect_fail 'a Tauri CLI without integrity' 'tauri_cli taurine-desktop build' 'not a registry package'
write_npm_lock
rm "${tdir}/node_modules/.bin/tauri"; printf 'console.log(1)\n' >"${work}/other.js"; ln -s "${work}/other.js" "${tdir}/node_modules/.bin/tauri"
expect_fail '.bin/tauri pointing elsewhere' 'tauri_cli taurine-desktop build' 'is not @tauri-apps/cli/tauri.js'
rm "${tdir}/node_modules/.bin/tauri"; ln -s ../@tauri-apps/cli/tauri.js "${tdir}/node_modules/.bin/tauri"
printf 'Tauri.linux.toml overlay\n[build]\nfeatures = ["x"]\n' >"${src}/taurine-desktop/src-tauri/Tauri.linux.toml"
expect_fail 'a Tauri.linux.toml overlay (G1)' 'refuse_build_feature_overrides' 'json5/toml'
rm "${src}/taurine-desktop/src-tauri/Tauri.linux.toml"
printf '{build: {features: ["x"]}}\n' >"${src}/taurine-mobile/src-tauri/tauri.android.conf.json5"
expect_fail 'a json5 platform overlay (G1)' 'refuse_build_feature_overrides' 'json5/toml'
rm "${src}/taurine-mobile/src-tauri/tauri.android.conf.json5"
for key in '{"linux":{"deb":{"files":{"/usr/lib/x":"x"}}}}' '{"macOS":{"files":{"x":"y"}}}' '{"macOS":{"frameworks":["./Vendor.framework"]}}' '{"iOS":{"frameworks":["lib/x.xcframework"]}}'; do
  printf '{"bundle":%s}\n' "${key}" >"${src}/taurine-desktop/src-tauri/tauri.conf.dev.json"
  expect_fail "a file-shipping bundle key ${key%%:*}" 'refuse_build_feature_overrides' 'deb/macOS files or a framework path'
done
printf '{"bundle":{"iOS":{"frameworks":["SystemConfiguration"]}}}\n' >"${src}/taurine-desktop/src-tauri/tauri.conf.dev.json"
expect_pass 'a system framework name' 'refuse_build_feature_overrides'
rm "${src}/taurine-desktop/src-tauri/tauri.conf.dev.json"
mkdir -p "${src}/elsewhere"; printf '{"build":{"features":["x"]}}\n' >"${src}/elsewhere/tauri.conf.json"
expect_fail 'a Tauri config outside src-tauri' 'refuse_build_feature_overrides' 'outside the shells'
rm -r "${src}/elsewhere"
mkdir -p "${src}/taurine-mobile/src-tauri/sub"; printf '{}\n' >"${src}/taurine-mobile/src-tauri/sub/tauri.conf.json"
expect_fail 'a nested Tauri config' 'refuse_build_feature_overrides' 'outside the shells'
rm -r "${src}/taurine-mobile/src-tauri/sub"
printf '{"bundle":{"externalBin":["bin/sidecar"]}}\n' >"${src}/taurine-desktop/src-tauri/tauri.conf.dev.json"
expect_fail 'a sidecar' 'refuse_build_feature_overrides' 'bundle.externalBin'
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

# ---- G7: the door crates are re-extracted from verified archives ------------------------------
reg="${work}/cargo-home/registry"
mkdir -p "${reg}/cache/index.crates.io-0000" "${reg}/src/index.crates.io-0000/openssl-src-300.5.5+3.5.5"
for crate in openssl-0.10.81 openssl-src-300.5.5+3.5.5 openssl-sys-0.9.117 tokio-openssl-0.6.5; do printf 'archive %s\n' "${crate}" >"${reg}/cache/index.crates.io-0000/${crate}.crate"; done
lock_with_real_sums() {
  ruby -e '
    require "digest"
    lock, cache = ARGV
    text = File.read(lock).gsub(/name = "([^"]+)"\nversion = "([^"]+)"\nsource = "([^"]+)"\nchecksum = "[0-9a-f]+"/) do
      name, version, source = $1, $2, $3
      sum = Digest::SHA256.file(File.join(cache, "#{name}-#{version}.crate")).hexdigest
      %(name = "#{name}"\nversion = "#{version}"\nsource = "#{source}"\nchecksum = "#{sum}")
    end
    File.write(lock, text)' "${src}/Cargo.lock" "${reg}/cache/index.crates.io-0000"
}
lock_with_real_sums
expect_pass 'verified door crate archives' 'verify_door_crate_sources'
[[ ! -e "${reg}/src/index.crates.io-0000/openssl-src-300.5.5+3.5.5" ]] || fail 'the extracted openssl-src was not removed for re-extraction'
printf 'tampered\n' >"${reg}/cache/index.crates.io-0000/openssl-src-300.5.5+3.5.5.crate"
expect_fail 'a tampered openssl-src archive' 'verify_door_crate_sources' 'does not match the Cargo.lock checksum'
rm "${reg}/cache/index.crates.io-0000/openssl-src-300.5.5+3.5.5.crate"
expect_fail 'a missing openssl-src archive' 'verify_door_crate_sources' 'archive to verify'
write_lock

# ---- gen/: CI regenerates the mobile Rust build phases ---------------------------------------
gen="${src}/taurine-mobile/src-tauri/gen"
mkdir -p "${gen}/android/buildSrc/k" "${gen}/apple"
printf 'val executable = """npm""";\nval args = listOf("run", "--", "tauri", "android", "android-studio-script");\n' >"${gen}/android/buildSrc/k/BuildTask.kt"
expect_pass 'reset removes the source build phase' 'mobile_build_phase_reset android && [[ ! -e taurine-mobile/src-tauri/gen/android/buildSrc ]]'
expect_fail 'init did not regenerate the phase' 'mobile_build_phase_check android' 'did not regenerate'
mkdir -p "${gen}/android/buildSrc/k"
printf 'val executable = """npm""";\nval args = listOf("run", "--", "tauri", "android", "android-studio-script");\n' >"${gen}/android/buildSrc/k/BuildTask.kt"
expect_fail 'a phase calling a package-manager script' 'mobile_build_phase_check android' 'does not call the CLI'
printf 'val executable = """/opt/node/bin/node""";\nval args = listOf("/w/taurine-mobile/node_modules/@tauri-apps/cli/tauri.js", "android", "android-studio-script");\n' >"${gen}/android/buildSrc/k/BuildTask.kt"
expect_pass 'a phase calling the CLI tauri.js with node' 'mobile_build_phase_check android'
printf 'targets:\n  app:\n    preBuildScripts:\n      - script: /opt/node/bin/node /w/taurine-mobile/node_modules/@tauri-apps/cli/tauri.js ios xcode-script -v\n' >"${gen}/apple/project.yml"
expect_pass 'an Xcode phase calling the CLI tauri.js' 'mobile_build_phase_check ios'
printf 'targets:\n  app:\n    preBuildScripts:\n      - script: npm run -- tauri ios xcode-script -v\n' >"${gen}/apple/project.yml"
expect_fail 'an Xcode phase calling npm run' 'mobile_build_phase_check ios' 'does not call the CLI'
( cd "${src}" && git init -q && git add taurine-mobile/src-tauri/gen/apple/project.yml )
expect_fail 'a committed gen/apple' 'mobile_build_phase_reset ios' 'is committed'
rm -rf "${src}/.git" "${gen}"
grep -qF 'mobile_build_phase_reset android' .github/workflows/android-validation.yml && grep -qF 'mobile_build_phase_check android' .github/workflows/android-validation.yml || fail 'the Android init does not regenerate and check the build phase'
grep -qF 'mobile_build_phase_reset ios' .github/actions/ios-project-init/action.yml && grep -qF 'mobile_build_phase_check ios' .github/actions/ios-project-init/action.yml || fail 'the iOS init does not regenerate and check the build phase'

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
