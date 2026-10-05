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
  # The policy's own scripts: shell and Ruby, nothing else, flat in one directory.
  if [[ "$path" =~ ^\.github/policy/[a-z0-9-]+\.(sh|rb)$ ]]; then
    continue
  fi
  if [[ "$path" == .github/ci-matrix.json || "$path" == .github/dependabot.yml || "$path" == .github/tool-pins.json ]]; then
    continue
  fi
  if [[ "$path" == .gitignore ]]; then
    continue
  fi
  echo "Unexpected tracked path in the public CI repository: $path" >&2
  exit 1
done < <(git ls-files -z)

if git ls-files | grep -vxF -e '.github/ci-matrix.json' -e '.github/dependabot.yml' -e '.github/tool-pins.json' | grep -E "$forbidden_path_re|$forbidden_name_re"; then
  echo "The public repository contains a forbidden source, credential, or starter-document path." >&2
  exit 1
fi

if git grep -nI -E 'GH_APP_PRIVATE_KEY|TAURINE_(PAT|TOKEN|PRIVATE_KEY)|GITHUB_TOKEN[[:space:]]*[:=]|TAURI_SIGNING_PRIVATE_KEY|DEPLOY_KEY|BEGIN (RSA|OPENSSH|EC|PRIVATE) KEY|secrets\.(TAURINE|GH_APP|PAT|DEPLOY|SIGNING)' -- . ':!*.lock' ':!.github/workflows/validate-public-changes.yml' ':!.github/policy/*'; then
  echo "A reusable source, signing, or deployment credential pattern was found." >&2
  exit 1
fi
