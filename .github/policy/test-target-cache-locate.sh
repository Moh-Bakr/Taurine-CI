#!/usr/bin/env bash
# Run the hashed `locate` step of the rust-target-cache composite as the runner would, with a stub
# rustup and rustc, and prove it computes a key from an installed toolchain and refuses everything the
# checkout or the environment could use to substitute a tool: a `path` toolchain override that names a
# binary inside the checkout, a compiler outside rustup's toolchains, a planted rustup or rustc, a
# relative PATH entry and an unreviewed target directory. The stubs stand in for the real tools, so this
# needs neither rustup nor a network.
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/target-cache-locate.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
action=.github/actions/rust-target-cache/action.yml

ruby -ryaml -e '
  steps = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false).dig("runs", "steps")
  locate = steps.select { |s| s["id"] == "locate" }
  abort "target-cache locate fixture: expected one locate step" unless locate.length == 1
  puts locate.first.fetch("run")
' "${action}" > "${work}/locate.sh"

workspace="${work}/workspace"
home="${work}/home"
rustup_home="${home}/.rustup"
stubs="${work}/stubs"
mkdir -p "${workspace}/src" "${home}" "${work}/runner-temp" "${stubs}" "${rustup_home}/toolchains/stable/bin"
(
  cd "${workspace}/src"
  git init -q .
  printf '[[package]]\nname = "x"\nversion = "1.0.0"\n' > Cargo.lock
  git add -A
  git -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m fixture
)
# The installed toolchain's compiler, and a rustup that reports it (or whatever the case asks for).
printf '#!/bin/sh\nif [ "$1" = -V ]; then echo "rustc 1.85.0 (fixture)"; else printf "rustc 1.85.0\\nhost: fixture\\n"; fi\n' > "${rustup_home}/toolchains/stable/bin/rustc"
chmod +x "${rustup_home}/toolchains/stable/bin/rustc"
printf '#!/bin/sh\n[ "$1" = which ] || exit 2\nprintf "%%s\\n" "${FIXTURE_RUSTC:-%s}"\n' "${rustup_home}/toolchains/stable/bin/rustc" > "${stubs}/rustup"
chmod +x "${stubs}/rustup"
cp "${rustup_home}/toolchains/stable/bin/rustc" "${stubs}/rustc"

base_path="/usr/bin:/bin:/usr/sbin:/sbin"
for dir in /opt/homebrew/bin /usr/local/bin; do [[ ! -d "${dir}" ]] || base_path="${dir}:${base_path}"; done

run_locate() { # label path-prefix extra-env...
  local label="$1" prefix="$2"
  shift 2
  rm -f "${work}/out"
  : > "${work}/env"
  # The step runs in the checkout's src directory (its working-directory).
  (cd "${workspace}/src" && env -i PATH="${prefix}${base_path}" HOME="${home}" GITHUB_WORKSPACE="${workspace}" RUNNER_TEMP="${work}/runner-temp" \
    GROUP=rust-app FEATURES=test-default GITHUB_OUTPUT="${work}/out" GITHUB_ENV="${work}/env" \
    RUNNER_OS=Linux RUNNER_ARCH=X64 "$@" bash "${work}/locate.sh" > "${work}/log" 2>&1)
}
expect_ok() { # label path-prefix extra-env...
  local label="$1"
  run_locate "$@" || { echo "target-cache locate fixture '${label}' should pass but failed:" >&2; cat "${work}/log" >&2; exit 1; }
  grep -q '^key=cargo-target-v1-' "${work}/out" || { echo "target-cache locate fixture '${label}' wrote no key" >&2; exit 1; }
}
expect_refused() { # label needle path-prefix extra-env...
  local label="$1" needle="$2"
  shift 2
  if run_locate "${label}" "$@"; then echo "target-cache locate fixture '${label}' should fail but passed" >&2; exit 1; fi
  grep -qF -- "${needle}" "${work}/log" || { echo "target-cache locate fixture '${label}' failed with the wrong message (wanted '${needle}'):" >&2; cat "${work}/log" >&2; exit 1; }
}

expect_ok 'an installed toolchain selected by rustup' "${stubs}:"

# A `path` override in src/rust-toolchain.toml: rustup run in the checkout names a binary inside it.
mkdir -p "${workspace}/src/evil/bin"
cp "${rustup_home}/toolchains/stable/bin/rustc" "${workspace}/src/evil/bin/rustc"
expect_refused 'a path toolchain naming a compiler inside the checkout' 'selected compiler is inside the checkout' "${stubs}:" FIXTURE_RUSTC="${workspace}/src/evil/bin/rustc"
# A compiler that is neither in the checkout nor an installed toolchain.
mkdir -p "${work}/elsewhere/bin"
cp "${rustup_home}/toolchains/stable/bin/rustc" "${work}/elsewhere/bin/rustc"
expect_refused 'a compiler outside rustup toolchains' 'not an installed rustup toolchain' "${stubs}:" FIXTURE_RUSTC="${work}/elsewhere/bin/rustc"
# A compiler under the runner temp directory.
mkdir -p "${work}/runner-temp/bin"
cp "${rustup_home}/toolchains/stable/bin/rustc" "${work}/runner-temp/bin/rustc"
expect_refused 'a compiler in the runner temp directory' 'selected compiler is inside the checkout or the temp directory' "${stubs}:" FIXTURE_RUSTC="${work}/runner-temp/bin/rustc"
# A rustup, or a rustc, planted in the checkout ahead of the real ones on PATH.
mkdir -p "${workspace}/shim"
cp "${stubs}/rustup" "${workspace}/shim/rustup"
expect_refused 'a rustup planted in the checkout' 'rustup resolves inside the checkout' "${workspace}/shim:${stubs}:"
rm "${workspace}/shim/rustup"
cp "${rustup_home}/toolchains/stable/bin/rustc" "${workspace}/shim/rustc"
expect_refused 'a rustc planted in the checkout' 'rustc resolves inside the checkout' "${workspace}/shim:${stubs}:"
# PATH hygiene and the target directory.
expect_refused 'a relative PATH entry' 'relative or empty entry' ".:${stubs}:"
expect_refused 'an unreviewed target directory' 'not one of the reviewed locations' "${stubs}:" CARGO_TARGET_DIR=/tmp/evil

echo 'target-cache locate fixtures: an installed toolchain passes; a checkout-supplied or foreign compiler, a planted rustup or rustc, a relative PATH entry and an unreviewed target directory are refused'
