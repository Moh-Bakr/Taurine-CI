#!/usr/bin/env bash
# Reject private-source and credential material
# Run from the repository root (the policy workflow does).
set -euo pipefail

forbidden_path_re='(^|/)(src|target|node_modules|vendor|taurine-desktop|taurine-mobile)(/|$)|\.(rs|ts|tsx|js|jsx|json|toml|lock|pem|p12|pfx|jks|keystore)$'
forbidden_name_re='(^|/)(README|SECURITY|CODEOWNERS|LICENSE)(\.|$)'

while IFS= read -r -d '' path; do
  if [[ "$path" == .github/workflows/* ]]; then
    continue
  fi
  # Local composite actions (action.yml only) and the one machine-readable
  # concern table. Both are scanned by the checks below; nothing else may
  # live under .github/actions, and no other JSON is allowed anywhere.
  if [[ "$path" =~ ^\.github/actions/[a-z0-9-]+/action\.yml$ ]]; then
    continue
  fi
  # The policy's own scripts: shell and Ruby, plus the exact reviewed PG8
  # parser/fixture pair. Keep every other extension and filename outside this
  # bootstrap allowlist.
  if [[ "$path" =~ ^\.github/policy/[a-z0-9-]+\.(sh|rb)$ ||
        "$path" == .github/policy/pg8-measurement.py ||
        "$path" == .github/policy/test-pg8-measurement.py ]]; then
    continue
  fi
  # The reviewed case-evidence assets, and nothing else: the control-owned
  # Playwright list reporter the producers hand to the pinned runner, the
  # fixture configs and specs it stages, and the recorded runner reports their
  # tests replay. They are JavaScript and JSON because that is what the pinned
  # runner loads and emits; a Ruby or shell file cannot be either.
  #
  # One flat directory and lower-case names, each starting with a letter or a
  # digit: a leading dash reads as an option to any shell tool that later
  # handles the path unquoted. The only compound names allowed
  # are the `.config.cjs` and `.spec.cjs` pair Playwright itself expects, so a
  # name cannot smuggle another extension past the forbidden-extension sweep
  # below: `x.ts.cjs` and `x.pem.json` stay rejected. No nesting, no other
  # extension, and no other path in the repository gains an exception.
  if [[ "$path" =~ ^\.github/policy/case-evidence-assets/[a-z0-9][a-z0-9-]*(\.(config|spec))?\.(cjs|json)$ ]]; then
    continue
  fi
  if [[ "$path" == .github/ci-matrix.json || "$path" == .github/dependabot.yml || "$path" == .github/tool-pins.json || "$path" == .github/egress-allowlist.txt ]]; then
    continue
  fi
  # Flat documentation guides: markdown directly under docs/, nothing else.
  if [[ "$path" =~ ^docs/[a-z0-9-]+\.md$ ]]; then
    continue
  fi
  if [[ "$path" == .gitignore ]]; then
    continue
  fi
  echo "Unexpected tracked path in the public CI repository: $path" >&2
  exit 1
done < <(git ls-files -z)

# The assets in that directory are not inert data: the reporter is JavaScript
# the pinned runner loads on the hosted runner. A tracked symlink would pass
# every name rule above while pointing anywhere -- including into the private
# source checkout -- so accept only plain regular files, read from the index
# rather than from the filesystem.
while IFS= read -r -d '' record; do
  mode="${record%% *}"
  asset="${record#*$'\t'}"
  if [[ "$mode" != '100644' ]]; then
    echo "Case-evidence assets must be plain regular files: $asset has git mode $mode" >&2
    exit 1
  fi
  # Valid JSON and JavaScript never contain a raw NUL, and a NUL is what makes
  # git call a file binary. Refusing it here keeps these files inside the text
  # world every other check assumes, rather than leaving the credential scan to
  # decide how to treat them.
  if [[ "$(LC_ALL=C tr -d '\000' < "$asset" | wc -c | tr -d ' ')" != "$(wc -c < "$asset" | tr -d ' ')" ]]; then
    echo "Case-evidence assets must not contain NUL bytes: $asset" >&2
    exit 1
  fi
done < <(git ls-files -s -z -- .github/policy/case-evidence-assets)

if git ls-files | grep -vxF -e '.github/ci-matrix.json' -e '.github/dependabot.yml' -e '.github/tool-pins.json' \
  | grep -vE '^\.github/policy/case-evidence-assets/[a-z0-9][a-z0-9-]*(\.(config|spec))?\.json$' \
  | grep -E "$forbidden_path_re|$forbidden_name_re"; then
  echo "The public repository contains a forbidden source, credential, or starter-document path." >&2
  exit 1
fi

# The policy scripts are excluded because they carry these patterns as the
# very rules being matched. That exemption was written as the whole of
# .github/policy, and a git pathspec * crosses /, so it also hid the
# case-evidence assets -- recorded runner reports and a reporter, exactly where
# a pasted key or private path would land. Exclude the scripts by extension
# instead, so the asset directory is scanned like anything else.
#
# -a, not -I: -I skips whatever git judges binary, and a single NUL byte is
# enough to earn that judgement, so one NUL in front of a key header hid it
# from this scan entirely. Every path this repository admits is a text type,
# so there is nothing here that needs skipping.
#
# The PEM alternation was also wrong: it read BEGIN (RSA|OPENSSH|EC|PRIVATE)
# KEY, which matches "BEGIN PRIVATE KEY" but not "BEGIN RSA PRIVATE KEY" --
# the commonest header of all, and every other qualified one. Any sequence of
# qualifiers is now allowed in front of PRIVATE KEY, which also covers
# "BEGIN PGP PRIVATE KEY BLOCK" and anything added later. It only widens what
# is caught, and it matches nothing already in this repository.
if git grep -na -E 'GH_APP_PRIVATE_KEY|TAURINE_(PAT|TOKEN|PRIVATE_KEY)|GITHUB_TOKEN[[:space:]]*[:=]|TAURI_SIGNING_PRIVATE_KEY|DEPLOY_KEY|BEGIN ([A-Z0-9]+ )*PRIVATE KEY|secrets\.(TAURINE|GH_APP|PAT|DEPLOY|SIGNING)' -- . ':!*.lock' ':!.github/workflows/validate-public-changes.yml' ':!.github/policy/*.sh' ':!.github/policy/*.rb' ':!.github/policy/*.py'; then
  echo "A reusable source, signing, or deployment credential pattern was found." >&2
  exit 1
fi
