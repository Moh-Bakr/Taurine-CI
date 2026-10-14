#!/usr/bin/env bash
# The absolute-path guard over committed case-evidence assets, against the
# spellings a literal-string scan would miss.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/.github/policy/check-case-evidence-assets.rb"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/case-evidence-assets-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

expect_pass() {
  local dir="$1" label="$2"
  if ! ruby "${check}" "${dir}" >/dev/null 2>&1; then
    echo "case-evidence asset fixture failed: ${label} should pass" >&2
    exit 1
  fi
}

expect_reject() {
  local dir="$1" label="$2" output
  if output="$(ruby "${check}" "${dir}" 2>&1)"; then
    echo "case-evidence asset fixture failed: ${label} unexpectedly passed" >&2
    exit 1
  fi
  if [[ "${output}" != *'is an absolute path'* && "${output}" != *'not valid JSON'* ]]; then
    echo "case-evidence asset fixture failed: ${label} hit an unexpected rejection: ${output}" >&2
    exit 1
  fi
}

# The shapes a recorded report is allowed to carry: placeholders, and paths
# relative to them. The base64 integrity values matter here -- they contain
# slashes, and an over-eager rule would reject every real manifest.
clean="$tmp/clean"
mkdir -p "${clean}"
cat > "${clean}/report.json" <<'JSON'
{
  "config": {
    "argv": ["node", "__APP_ROOT__/node_modules/playwright/cli.js", "test"],
    "rootDir": "__APP_ROOT__/tests/e2e",
    "configFile": "__SCRATCH__/app/playwright.config.ts"
  },
  "suites": [{"file": "deep/inner.spec.ts", "title": "deep/inner.spec.ts"}],
  "integrity": "sha512-Z14dG305dgaLu6foB1TXQagFiW8JfSUIUaUuPaKQ6Nt/BPKF1P/qXcqfh6c6K/icPqd+y37Jmj==",
  "packages": {"node_modules/@playwright/test": "1.62.0"}
}
JSON
printf "'use strict';\nmodule.exports = { testMatch: ['all-pass.spec.cjs'], testDir: __dirname };\n" > "${clean}/fixture.cjs"
expect_pass "${clean}" 'placeholders, relative paths and a base64 integrity value'

# One case per spelling. A literal-string scan catches the first and none of
# the rest.
i=0
while IFS= read -r payload; do
  i=$((i + 1))
  case_dir="$tmp/case-${i}"
  mkdir -p "${case_dir}"
  printf '{"config":{"argv":["%s"]}}\n' "${payload}" > "${case_dir}/report.json"
  expect_reject "${case_dir}" "an absolute path spelled as ${payload}"
# A single-segment root is included deliberately: the embedded rule needs two
# segments, so without this the whole leading-anchor rule could be deleted and
# the suite would still pass.
done <<'CASES'
/opt/homebrew/bin/node
\/Users\/someone\/project
\u002froot\u002fsecret
/root/.ssh/id_rsa
/Volumes/External/build
/__w/repo/repo/node_modules
/nix/store/abc-node/bin/node
/home/runner/work/source
/srv
/w
CASES

# Windows and UNC shapes, which no POSIX-rooted rule would reach.
i=0
while IFS= read -r payload; do
  i=$((i + 1))
  win_dir="$tmp/win-${i}"
  mkdir -p "${win_dir}"
  printf '{"config":{"configFile":"%s"}}\n' "${payload}" > "${win_dir}/report.json"
  expect_reject "${win_dir}" "a Windows or UNC path spelled as ${payload}"
done <<'CASES'
D:/build/app
C:\\Users\\someone\\app
\\\\server\\share\\app
CASES

# An absolute path quoted inside a longer message, and the same in a key.
embedded="$tmp/embedded"
mkdir -p "${embedded}"
cat > "${embedded}/report.json" <<'JSON'
{"errors": [{"message": "Error: cannot open /opt/homebrew/lib/node_modules/thing"}]}
JSON
expect_reject "${embedded}" 'an absolute path quoted inside a message'

keyed="$tmp/keyed"
mkdir -p "${keyed}"
cat > "${keyed}/report.json" <<'JSON'
{"/private/var/folders/x/y": {"cases": 1}}
JSON
expect_reject "${keyed}" 'an absolute path used as an object key'

# JavaScript assets get the same shapes as a text scan.
script="$tmp/script"
mkdir -p "${script}"
printf "'use strict';\nconst p = '/Users/someone/app/reporter.cjs';\n" > "${script}/fixture.cjs"
expect_reject "${script}" 'an absolute path in a JavaScript asset'

malformed="$tmp/malformed"
mkdir -p "${malformed}"
printf '{"config":\n' > "${malformed}/report.json"
expect_reject "${malformed}" 'a JSON asset that does not parse'

# Finally, the real committed assets.
expect_pass "${root}/.github/policy/case-evidence-assets" 'the committed case-evidence assets'

echo 'case evidence asset fixtures: placeholders and relative paths pass; POSIX, escaped, unicode-escaped, Windows, UNC, embedded and keyed absolute paths rejected'
