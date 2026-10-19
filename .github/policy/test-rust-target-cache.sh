#!/usr/bin/env bash
# Exercise the cache strip on synthetic third-party output, including binary,
# build-script and fingerprint files that name the private checkout.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
awk '
  /cat > .*target-cache\.sh.*HELPERS/ { inside = 1; next }
  inside && /^        HELPERS$/ { exit }
  inside { sub(/^        /, ""); print }
' "${root}/.github/actions/rust-target-cache/action.yml" > "${fixture}/helpers.sh"
grep -q '^strip_profile() {' "${fixture}/helpers.sh"
# shellcheck source=/dev/null
source "${fixture}/helpers.sh"

export GITHUB_WORKSPACE="${fixture}/taurine"
mkdir -p "${GITHUB_WORKSPACE}/src" "${fixture}/target/debug" "${fixture}/sets"
cat > "${GITHUB_WORKSPACE}/src/Cargo.lock" <<'LOCK'
[[package]]
name = "private-crate"
version = "0.1.0"

[[package]]
name = "alpha"
version = "1.0.0"
source = "registry+https://example.invalid"

[[package]]
name = "beta"
version = "1.0.0"
source = "registry+https://example.invalid"

[[package]]
name = "gamma"
version = "1.0.0"
source = "registry+https://example.invalid"

[[package]]
name = "delta"
version = "1.0.0"
source = "registry+https://example.invalid"

[[package]]
name = "epsilon"
version = "1.0.0"
source = "registry+https://example.invalid"
LOCK
cd "${GITHUB_WORKSPACE}/src"
printf 'synthetic private source' > "${GITHUB_WORKSPACE}/src/secret.rs"
classify_lock "${fixture}/sets"
profile="${fixture}/target/debug"
mkdir -p "${profile}/deps" "${profile}/build/alpha-aaaa/out" \
  "${profile}/build/beta-bbbb/out" "${profile}/build/gamma-cccc/out" \
  "${profile}/build/delta-dddd/out/taurine/src" "${profile}/build/epsilon-eeee/out" \
  "${profile}/.fingerprint/alpha-aaaa" "${profile}/.fingerprint/beta-bbbb" \
  "${profile}/.fingerprint/gamma-cccc" "${profile}/.fingerprint/delta-dddd" \
  "${profile}/.fingerprint/epsilon-eeee"
printf 'binary\000%s/src/secret.rs\000' "${GITHUB_WORKSPACE}" > "${profile}/deps/libalpha-aaaa.rlib"
printf 'safe' > "${profile}/deps/libalpha-aaaa.rmeta"
printf 'safe' > "${profile}/build/alpha-aaaa/out/generated"
printf 'safe' > "${profile}/.fingerprint/alpha-aaaa/metadata"
printf 'safe' > "${profile}/deps/libbeta-bbbb.rlib"
printf 'private: %s\\src\\secret.rs\n' "${GITHUB_WORKSPACE}" > "${profile}/build/beta-bbbb/out/generated"
printf 'safe' > "${profile}/.fingerprint/beta-bbbb/metadata"
printf 'safe' > "${profile}/deps/libgamma-cccc.rlib"
printf 'safe' > "${profile}/build/gamma-cccc/out/generated"
printf 'safe' > "${profile}/.fingerprint/gamma-cccc/metadata"
printf 'safe' > "${profile}/deps/libdelta-dddd.rlib"
printf 'safe' > "${profile}/build/delta-dddd/out/taurine/src/secret.rs"
printf 'safe' > "${profile}/.fingerprint/delta-dddd/metadata"
printf 'safe' > "${profile}/deps/libepsilon-eeee.rlib"
ln -s "${GITHUB_WORKSPACE}/src/secret.rs" "${profile}/build/epsilon-eeee/out/source-link"
printf 'safe' > "${profile}/.fingerprint/epsilon-eeee/metadata"
printf 'safe' > "${profile}/deps/libprivate_crate-dddd.rlib"
printf 'safe' > "${profile}/deps/tool-eeee"
chmod u+x "${profile}/deps/tool-eeee"

removed="$(strip_profile "${profile}" "${fixture}/sets")"
[[ "${removed}" -ge 12 ]]
for path in deps/libalpha-aaaa.rlib deps/libalpha-aaaa.rmeta build/alpha-aaaa \
  .fingerprint/alpha-aaaa deps/libbeta-bbbb.rlib build/beta-bbbb \
  .fingerprint/beta-bbbb deps/libdelta-dddd.rlib build/delta-dddd \
  .fingerprint/delta-dddd deps/libepsilon-eeee.rlib build/epsilon-eeee \
  .fingerprint/epsilon-eeee deps/libprivate_crate-dddd.rlib deps/tool-eeee; do
  [[ ! -e "${profile}/${path}" ]] || { echo "cache strip retained ${path}" >&2; exit 1; }
done
for path in deps/libgamma-cccc.rlib build/gamma-cccc/out/generated .fingerprint/gamma-cccc/metadata; do
  [[ -e "${profile}/${path}" ]] || { echo "cache strip removed clean ${path}" >&2; exit 1; }
done
if LC_ALL=C grep -rlaqE -- "$(private_path_pattern)" "${profile}/deps" "${profile}/build" "${profile}/.fingerprint"; then
  echo 'cache strip retained a private checkout reference' >&2
  exit 1
fi
[[ -z "$(find "${profile}" -type l -print)" ]] || { echo 'cache strip retained a symlink' >&2; exit 1; }
# A crafted deps suffix must never be echoed by the inventory report.
touch "${profile}/deps/libgamma-cccc.taurine\\src\\secret.rs"
inventory="$(cd "${profile}" && deps_file_inventory)"
[[ "${inventory}" =~ ^[[:space:]]+deps[[:space:]]+files:[[:space:]]+[0-9]+$ ]] || {
  echo 'cache inventory did not emit a count-only summary' >&2
  exit 1
}
[[ "${inventory}" != *secret* ]]
[[ -n "$(cd "${profile}" && unsafe_cache_entries "$(private_path_pattern)")" ]]

# A linked cache root must be unlinked without reading or deleting its target.
mkdir -p "${fixture}/root-link-profile" "${fixture}/root-link-sets"
classify_lock "${fixture}/root-link-sets"
ln -s "${GITHUB_WORKSPACE}/src" "${fixture}/root-link-profile/deps"
strip_profile "${fixture}/root-link-profile" "${fixture}/root-link-sets" >/dev/null
[[ ! -L "${fixture}/root-link-profile/deps" && -f "${GITHUB_WORKSPACE}/src/secret.rs" ]]

# A linked profile is never traversed by the destructive strip.
ln -s "${profile}" "${fixture}/linked-profile"
if strip_profile "${fixture}/linked-profile" "${fixture}/root-link-sets" >/dev/null 2>&1; then
  echo 'cache strip accepted a linked profile' >&2
  exit 1
fi

# Traversal failures must block saving and never print an inaccessible private
# path into the public job log.
blocked="${profile}/build/gamma-cccc/out/taurine/src/private"
mkdir -p "${blocked}"
chmod 000 "${blocked}"
if (cd "${profile}" && unsafe_cache_entries "$(private_path_pattern)") >"${fixture}/scan-out" 2>"${fixture}/scan-err"; then
  echo 'cache scan accepted an unreadable directory' >&2
  exit 1
fi
if (cd "${profile}" && cache_du build) >"${fixture}/du-out" 2>"${fixture}/du-err"; then
  echo 'cache size check accepted an unreadable directory' >&2
  exit 1
fi
scan_error="$(cat "${fixture}/scan-err")"
[[ "${scan_error}" == 'target-cache: cache traversal failed' ||
   "${scan_error}" == 'target-cache: cache content scan failed' ]] || {
  echo 'cache scan emitted an unexpected error class' >&2
  exit 1
}
[[ "$(cat "${fixture}/du-err")" == 'target-cache: cache size measurement failed' ]]
if removed="$(strip_profile "${profile}" "${fixture}/sets" 2>"${fixture}/strip-err")"; then
  echo 'cache strip accepted an unreadable directory through command substitution' >&2
  exit 1
fi
strip_error="$(cat "${fixture}/strip-err")"
[[ "${strip_error}" == 'target-cache: cache traversal failed' ||
   "${strip_error}" == 'target-cache: cache content scan failed' ]] || {
  echo 'cache strip emitted an unexpected error class' >&2
  exit 1
}
if before="$(size_mib "${profile}" 2>"${fixture}/size-err")"; then
  echo 'cache size accepted an unreadable directory through command substitution' >&2
  exit 1
fi
[[ "$(cat "${fixture}/size-err")" == 'target-cache: cache size measurement failed' ]]
chmod 700 "${blocked}"
unreadable="${profile}/deps/libgamma-cccc.unreadable"
printf 'synthetic contents' > "${unreadable}"
chmod 000 "${unreadable}"
if (cd "${profile}" && unsafe_cache_entries "$(private_path_pattern)") >"${fixture}/scan-out" 2>"${fixture}/scan-err"; then
  echo 'cache scan accepted an unreadable file' >&2
  exit 1
fi
[[ "$(cat "${fixture}/scan-err")" == 'target-cache: cache content scan failed' ]]
if removed="$(strip_profile "${profile}" "${fixture}/sets" 2>"${fixture}/strip-err")"; then
  echo 'cache strip accepted an unreadable file through command substitution' >&2
  exit 1
fi
[[ "$(cat "${fixture}/strip-err")" == 'target-cache: cache content scan failed' ]]
chmod 600 "${unreadable}"
# The door strip (deny-door, every untrusted restore): the OpenSSL door crates and every crate built on
# one are removed from a restored entry, entries of unrelated third-party crates stay, and a leftover door
# entry is counted. Without the door argument nothing about the classification changes.
door_dir="${fixture}/door"
mkdir -p "${door_dir}/src" "${door_dir}/sets" "${door_dir}/plain-sets" "${door_dir}/target/debug"
cat > "${door_dir}/src/Cargo.lock" <<'LOCK'
[[package]]
name = "openssl-src"
version = "300.5.0"
source = "registry+https://example.invalid"

[[package]]
name = "openssl-sys"
version = "0.9.0"
source = "registry+https://example.invalid"
dependencies = [
 "openssl-src",
]

[[package]]
name = "openssl"
version = "0.10.0"
source = "registry+https://example.invalid"
dependencies = [
 "openssl-sys",
]

[[package]]
name = "tls-wrapper"
version = "1.0.0"
source = "registry+https://example.invalid"
dependencies = [
 "openssl",
]

[[package]]
name = "rustls-thing"
version = "1.0.0"
source = "registry+https://example.invalid"
LOCK
(
  cd "${door_dir}/src"
  classify_lock "${door_dir}/plain-sets"
  classify_lock "${door_dir}/sets" door
  # Plain classification keeps every third-party crate, door ones included; the door pass strips them and
  # their dependents, and nothing else.
  for crate in openssl_src openssl_sys openssl tls_wrapper rustls_thing; do
    grep -qx "${crate}" "${door_dir}/plain-sets/keep.txt" || { echo "plain classification dropped ${crate}" >&2; exit 1; }
  done
  [[ ! -s "${door_dir}/plain-sets/door.txt" ]] || { echo 'plain classification reported door crates' >&2; exit 1; }
  for crate in openssl_src openssl_sys openssl tls_wrapper; do
    grep -qx "${crate}" "${door_dir}/sets/strip.txt" || { echo "door classification kept ${crate}" >&2; exit 1; }
  done
  grep -qx rustls_thing "${door_dir}/sets/keep.txt" || { echo 'door classification dropped an unrelated crate' >&2; exit 1; }
  grep -qx rustls_thing "${door_dir}/sets/strip.txt" && { echo 'door classification stripped an unrelated crate' >&2; exit 1; }
  dprofile="${door_dir}/target/debug"
  mkdir -p "${dprofile}/deps" "${dprofile}/build/openssl-src-1111/out" "${dprofile}/build/openssl-sys-2222/out" \
    "${dprofile}/.fingerprint/openssl-sys-2222" "${dprofile}/.fingerprint/tls-wrapper-4444" "${dprofile}/.fingerprint/rustls-thing-5555"
  printf 'safe' > "${dprofile}/deps/libopenssl_sys-2222.rlib"
  printf 'safe' > "${dprofile}/deps/libopenssl-3333.rlib"
  printf 'safe' > "${dprofile}/deps/libtls_wrapper-4444.rlib"
  printf 'safe' > "${dprofile}/deps/librustls_thing-5555.rlib"
  printf 'safe' > "${dprofile}/build/openssl-src-1111/out/libssl.a"
  # The realistic layout of the shipped door (taurine-app enables legacy-tls, so rust-app and rust-db caches carry
  # it): libssl.a and libcrypto.a under both build outputs, openssl-src's source tree and fingerprints.
  printf 'safe' > "${dprofile}/build/openssl-src-1111/out/libcrypto.a"
  mkdir -p "${dprofile}/build/openssl-src-1111/out/lib" "${dprofile}/.fingerprint/openssl-src-1111" "${dprofile}/.fingerprint/openssl-1234"
  printf 'safe' > "${dprofile}/build/openssl-src-1111/out/lib/libssl.a"
  printf 'safe' > "${dprofile}/build/openssl-sys-2222/out/libssl.a"
  printf 'safe' > "${dprofile}/build/openssl-sys-2222/out/libcrypto.a"
  # Before the strip the door entries are counted; the plain strip leaves them; the door strip removes them.
  [[ "$(door_entries_remaining "${dprofile}" "${door_dir}/sets")" -ge 5 ]] || { echo 'door entries were not counted' >&2; exit 1; }
  strip_profile "${dprofile}" "${door_dir}/plain-sets" >/dev/null
  [[ -e "${dprofile}/deps/libopenssl_sys-2222.rlib" ]] || { echo 'the plain strip removed a door entry' >&2; exit 1; }
  strip_profile "${dprofile}" "${door_dir}/sets" >/dev/null
  [[ "$(door_entries_remaining "${dprofile}" "${door_dir}/sets")" == 0 ]] || { echo 'the door strip left a door entry' >&2; exit 1; }
  for path in deps/libopenssl_sys-2222.rlib deps/libopenssl-3333.rlib deps/libtls_wrapper-4444.rlib build/openssl-src-1111 \
    build/openssl-sys-2222 build/openssl-sys-2222/out/libssl.a build/openssl-sys-2222/out/libcrypto.a build/openssl-src-1111/out/libcrypto.a \
    .fingerprint/openssl-sys-2222 .fingerprint/openssl-src-1111 .fingerprint/openssl-1234 .fingerprint/tls-wrapper-4444; do
    [[ ! -e "${dprofile}/${path}" ]] || { echo "the door strip retained ${path}" >&2; exit 1; }
  done
  [[ -e "${dprofile}/deps/librustls_thing-5555.rlib" && -d "${dprofile}/.fingerprint/rustls-thing-5555" ]] || { echo 'the door strip removed an unrelated crate' >&2; exit 1; }
  # A door entry that survives (here planted after the strip) is reported, so the restore step fails.
  printf 'planted' > "${dprofile}/deps/libopenssl_sys-9999.rlib"
  [[ "$(door_entries_remaining "${dprofile}" "${door_dir}/sets")" == 1 ]] || { echo 'a surviving door entry was not reported' >&2; exit 1; }
  rm -f "${dprofile}/deps/libopenssl_sys-9999.rlib"
  # The step fails if any one door entry survives: each realistic shape, planted alone after the strip, is reported.
  for planted in deps/libopenssl_sys-9999.rlib deps/libopenssl-3333.rlib build/openssl-sys-9999 build/openssl-src-9999 \
    .fingerprint/openssl-sys-9999 .fingerprint/openssl-src-9999 .fingerprint/openssl-9999; do
    case "${planted}" in deps/*) printf 'planted' > "${dprofile}/${planted}" ;; *) mkdir -p "${dprofile}/${planted}/out"; printf 'x' > "${dprofile}/${planted}/out/libssl.a" ;; esac
    # A planted directory also holds a nested libssl.a, which the recursive content check counts too.
    [[ "$(door_entries_remaining "${dprofile}" "${door_dir}/sets")" -ge 1 ]] || { echo "a surviving ${planted} was not reported" >&2; exit 1; }
    rm -rf "${dprofile:?}/${planted}"
  done
  [[ "$(door_entries_remaining "${dprofile}" "${door_dir}/sets")" == 0 ]] || { echo 'the door fixture was not clean after the survivor cases' >&2; exit 1; }
  # A door library hidden under an unrelated crate name, at any depth and in any case, is reported.
  for hidden in build/renamed-sys-7777/out/lib/libssl.a build/renamed-sys-7777/out/LIBCRYPTO.a build/other-8888/out/deep/er/libeay32.lib deps/SSLEAY32.dll; do
    mkdir -p "${dprofile}/$(dirname "${hidden}")"; printf 'planted' > "${dprofile}/${hidden}"
    [[ "$(door_entries_remaining "${dprofile}" "${door_dir}/sets")" == 1 ]] || { echo "a hidden ${hidden} was not reported" >&2; exit 1; }
    rm -rf "${dprofile:?}/build/renamed-sys-7777" "${dprofile:?}/build/other-8888" "${dprofile:?}/${hidden}"
  done
  # A traversal error fails the helper: an unreadable directory under deps is not read as an empty result.
  mkdir -p "${dprofile}/build/unreadable-1/out"; chmod 000 "${dprofile}/build/unreadable-1/out"
  if [[ "$(id -u)" != 0 ]]; then
    if (door_entries_remaining "${dprofile}" "${door_dir}/sets") >/dev/null 2>&1; then
      chmod 755 "${dprofile}/build/unreadable-1/out"; echo 'a traversal error was swallowed by the door check' >&2; exit 1
    fi
  fi
  chmod 755 "${dprofile}/build/unreadable-1/out"; rm -rf "${dprofile:?}/build/unreadable-1"
  # Content-level defence in depth: whatever crate produced them, libssl*, libcrypto* and openssl-build*
  # entries under debug/deps and debug/build are refused after the door strip, and nothing else is.
  [[ "$(door_entries_remaining "${dprofile}" "${door_dir}/sets")" == 0 ]] || { echo 'the door fixture was not clean before the content cases' >&2; exit 1; }
  for planted in deps/libssl.so.3 deps/libcrypto-0a1b.a build/openssl-build-1234; do
    case "${planted}" in build/*) mkdir -p "${dprofile}/${planted}" ;; *) printf 'planted' > "${dprofile}/${planted}" ;; esac
    [[ "$(door_entries_remaining "${dprofile}" "${door_dir}/sets")" == 1 ]] || { echo "a planted ${planted} was not reported" >&2; exit 1; }
    rm -rf "${dprofile:?}/${planted}"
  done
  mkdir -p "${dprofile}/.fingerprint/libssl-1"
  printf 'x' > "${dprofile}/deps/librustls_thing-6666.rlib"
  [[ "$(door_entries_remaining "${dprofile}" "${door_dir}/sets")" == 0 ]] || { echo 'the content check reported an unrelated or out-of-scope entry' >&2; exit 1; }
)
echo 'rust target cache strip fixtures passed'
