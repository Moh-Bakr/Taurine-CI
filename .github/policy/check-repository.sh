#!/usr/bin/env bash
# Reject private-source and credential material
# Run from the repository root (the policy workflow does).
set -euo pipefail

forbidden_path_re='(^|/)(src|target|node_modules|vendor|taurine-desktop|taurine-mobile)(/|$)|\.(rs|ts|tsx|js|jsx|json|toml|lock|pem|p12|pfx|jks|keystore)$'
forbidden_name_re='(^|/)(README|SECURITY|CODEOWNERS|LICENSE)(\.|$)'

# The tracked-file list is read once into a temporary file and its exit status checked: a failing
# `git ls-files` (not a repository, an unreadable index) must stop the check, never read as an empty tree.
tracked_list="$(mktemp)"
git ls-files -z > "${tracked_list}" || { echo "The tracked file list could not be read (git ls-files failed)" >&2; exit 1; }
# Every later listing of the index goes through the same rule: written to a temporary file, its status
# checked, then read, so a failing `git ls-files` is fatal wherever it is used.
index_list() { # dest git-ls-files-args...
  local dest="$1"; shift
  git ls-files "$@" > "${dest}" || { echo "The tracked file list could not be read (git ls-files failed)" >&2; exit 1; }
}
exact_list="$(mktemp)"; assets_list="$(mktemp)"; names_list="$(mktemp)"; entries_list="$(mktemp)"
trap 'rm -f "${tracked_list}" "${exact_list}" "${assets_list}" "${names_list}" "${entries_list}"' EXIT

# Compiled or binary build output is never tracked, wherever it sits: Python bytecode, Java classes and
# archives, object files, static and shared libraries, Windows binaries, WebAssembly and any __pycache__
# directory, whatever the case of the extension. Checked first, with its own message, so no allowlist branch
# below can admit one by accident.
shopt -s nocasematch
while IFS= read -r -d '' path; do
  if [[ "$path" =~ \.(pyc|pyo|class|o|so|dylib|a|dll|exe|jar|wasm)$ || "$path" =~ (^|/)__pycache__(/|$) ]]; then
    echo "Compiled or binary build output is tracked in the public CI repository: $path" >&2
    exit 1
  fi
done < "${tracked_list}"
shopt -u nocasematch

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
  # .github/CODEOWNERS is the one reviewed ownership file (exact path, matched in the sweep below too);
  # CODEOWNERS anywhere else still trips the forbidden-name sweep.
  if [[ "$path" == .github/ci-matrix.json || "$path" == .github/dependabot.yml || "$path" == .github/tool-pins.json || "$path" == .github/egress-allowlist.txt || "$path" == .github/CODEOWNERS ]]; then
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
done < "${tracked_list}"

# The files admitted by exact path above are plain data too: a tracked symlink or an executable file at
# one of those paths would pass the name rules while pointing elsewhere or being runnable. Read the git
# mode from the index and accept only a regular, non-executable file (100644).
index_list "${exact_list}" -s -z -- .github/ci-matrix.json .github/dependabot.yml .github/tool-pins.json .github/egress-allowlist.txt .github/CODEOWNERS
while IFS= read -r -d '' record; do
  mode="${record%% *}"
  exact="${record#*$'\t'}"
  if [[ "$mode" != '100644' ]]; then
    echo "Exact-path files must be plain non-executable regular files: $exact has git mode $mode" >&2
    exit 1
  fi
done < "${exact_list}"

# The assets in that directory are not inert data: the reporter is JavaScript
# the pinned runner loads on the hosted runner. A tracked symlink would pass
# every name rule above while pointing anywhere -- including into the private
# source checkout -- so accept only plain regular files, read from the index
# rather than from the filesystem.
index_list "${assets_list}" -s -z -- .github/policy/case-evidence-assets
while IFS= read -r -d '' record; do
  mode="${record%% *}"
  oid="${record#* }"
  oid="${oid%% *}"
  asset="${record#*$'\t'}"
  if [[ "$mode" != '100644' ]]; then
    echo "Case-evidence assets must be plain regular files: $asset has git mode $mode" >&2
    exit 1
  fi
  # Valid JSON and JavaScript never contain a raw NUL, and a NUL is what makes
  # git call a file binary. Refusing it here keeps these files inside the text
  # world every other check assumes, rather than leaving the credential scan to
  # decide how to treat them.
  #
  # The bytes come from the index, by object id, not from the working tree. In
  # the base-policy pass .github/policy on disk is the base commit's copy while
  # the index still lists the pull request's assets, so a path read from disk
  # is a different file or no file at all.
  #
  # A read that fails is reported as that, not as a NUL byte: the two need
  # different fixes, and a missing object is not something the author put in
  # the file.
  if ! size="$(git cat-file -s "$oid" 2>/dev/null)" ||
     ! stripped="$(git cat-file blob "$oid" 2>/dev/null | LC_ALL=C tr -d '\000' | wc -c | tr -d ' ')"; then
    echo "Case-evidence asset could not be read from the index: $asset" >&2
    exit 1
  fi
  if [[ "$stripped" != "$size" ]]; then
    echo "Case-evidence assets must not contain NUL bytes: $asset" >&2
    exit 1
  fi
done < "${assets_list}"

index_list "${names_list}"
if grep -vxF -e '.github/ci-matrix.json' -e '.github/dependabot.yml' -e '.github/tool-pins.json' -e '.github/CODEOWNERS' "${names_list}" \
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
# Every object the index names must be readable before the scan runs. git grep
# --cached reports an object it cannot read as an error but exits 1 -- the same
# status as "no match" -- so the scan below would pass a tree whose blobs it
# never saw. Fail closed instead, and name the paths.
index_list "${entries_list}" -s -z
unreadable="$(while IFS= read -r -d '' entry; do
  entry_oid="${entry#* }"
  entry_oid="${entry_oid%% *}"
  printf '%s %s\n' "${entry_oid}" "${entry#*$'\t'}"
done < "${entries_list}" | while read -r entry_oid entry_path; do
  # A missing object prints "<oid> missing" whatever --batch-check format is
  # asked for, so test the last word rather than compare the whole line.
  object_state="$(git cat-file --batch-check <<<"${entry_oid}")"
  if [[ "${object_state##* }" == missing ]]; then
    printf '%s\n' "${entry_path}"
  fi
done)"
if [[ -n "${unreadable}" ]]; then
  echo "The index names objects that cannot be read, so the credential scan could not see them:" >&2
  printf '  %s\n' ${unreadable} >&2
  exit 1
fi

# --cached: the scan reads what the index holds, which is what this tree
# commits. Reading the working tree instead missed every pull-request file the
# base-policy pass had replaced on disk -- the case-evidence assets among them.
if git grep --cached -na -E 'GH_APP_PRIVATE_KEY|TAURINE_(PAT|TOKEN|PRIVATE_KEY)|GITHUB_TOKEN[[:space:]]*[:=]|TAURI_SIGNING_PRIVATE_KEY|DEPLOY_KEY|BEGIN ([A-Z0-9]+ )*PRIVATE KEY|secrets\.(TAURINE|GH_APP|PAT|DEPLOY|SIGNING)' -- . ':!*.lock' ':!.github/workflows/validate-public-changes.yml' ':!.github/policy/*.sh' ':!.github/policy/*.rb' ':!.github/policy/*.py'; then
  echo "A reusable source, signing, or deployment credential pattern was found." >&2
  exit 1
fi
