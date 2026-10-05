#!/usr/bin/env bash
# Lint workflows with pinned actionlint and zizmor
#
# actionlint and zizmor, as pinned release binaries downloaded from their
# projects' GitHub releases and verified against a committed SHA-256 (the
# same shape as the other pinned tool downloads here; no third-party Action,
# nothing cached). Both run over this repository's own workflows only.
# zizmor's online audits (impostor commits, known-vulnerable Actions) use
# this run's read-only token.
#
# Every finding is fixed or explicitly justified:
# - actionlint's shellcheck integration is run with SC2016 and SC2129
#   ignored. SC2016 (info) fires on single-quoted text that is meant to be
#   literal (awk and jq programs, `$'...'` patterns, echoed `${VAR}` text);
#   SC2129 (style) asks for grouped redirects in scripts that append to
#   GITHUB_ENV and GITHUB_PATH a line at a time. Neither is a defect, and
#   rewriting dozens of long, passing scripts to satisfy them would risk
#   more than it protects. Every other shellcheck code (including the
#   warning-level ones) fails the check.
# - zizmor findings are suppressed inline, one reason above each, only
#   for: `github-app` (skip-token-revoke is deliberate; an explicit step
#   revokes the token before project code and fails closed),
#   `secrets-inherit` (the callee is this repository's own protected
#   reusable workflow, and the policy below requires that form) and
#   `self-repository` (the policy matches the `./` form). The keeldock-*
#   workflows are linted like every other workflow.
# Run from the repository root (the policy workflow does).
set -euo pipefail
tools="${RUNNER_TEMP}/lint-tools"
mkdir -p "${tools}"
fetch() {
  local url="$1" want="$2" out="$3"
  curl --fail --silent --show-error --location --retry 3 -o "${out}" "${url}"
  got="$(sha256sum "${out}" | cut -d' ' -f1)"
  if [[ "${got}" != "${want}" ]]; then
    echo "Checksum mismatch for ${url}" >&2
    exit 1
  fi
}
fetch https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz \
  8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 "${tools}/actionlint.tar.gz"
fetch https://github.com/zizmorcore/zizmor/releases/download/v1.30.1/zizmor-x86_64-unknown-linux-gnu.tar.gz \
  e65324f4430c2717591937edcec90ccbefaf14c174f8ec9415e03ca875b46e1a "${tools}/zizmor.tar.gz"
tar xzf "${tools}/actionlint.tar.gz" -C "${tools}" actionlint
tar xzf "${tools}/zizmor.tar.gz" -C "${tools}" zizmor
"${tools}/actionlint" -version | head -n 1
"${tools}/actionlint" -ignore 'SC2016:' -ignore 'SC2129:'
workflows=()
while IFS= read -r -d '' file; do
  workflows+=("${file}")
done < <(find .github/workflows .github/actions -type f -name '*.yml' -print0 2>/dev/null | sort -z)
"${tools}/zizmor" --format plain "${workflows[@]}"
