#!/usr/bin/env bash
# Test the concern selector on a synthetic repository
#
# The selector (embedded in the select-concerns action) is exercised on a synthetic
# repository so its rules are proven here, before any hosted run relies on them:
# documentation only, a crate and its dependents, a UI path, a build-wide input, an
# unknown path, a base that is not an ancestor, and no base at all.
# Run from the repository root (the policy workflow does).
set -euo pipefail
work="${RUNNER_TEMP}/selector-test"
rm -rf "${work}"
mkdir -p "${work}"
ruby -ryaml -e 'run = YAML.safe_load(File.read(".github/actions/select-concerns/action.yml"), aliases: false)["runs"]["steps"][0]["run"]; m = run.match(/<<'"'"'TCI_CONCERN_SELECTOR'"'"'\n(.*?)\n\s*TCI_CONCERN_SELECTOR/m); File.write(ARGV[0], m[1])' "${work}/concern_selector.py"
repo="${work}/src"
mkdir -p "${repo}"
git -C "${repo}" init -q
git -C "${repo}" config user.email ci@example.invalid
git -C "${repo}" config user.name ci
mk_crate() {
  local dir="$1" name="$2" dep="${3:-}"
  mkdir -p "${repo}/${dir}/src"
  { echo "[package]"; echo "name = \"${name}\""; echo 'version = "0.1.0"'; echo "[dependencies]"; if [[ -n "${dep}" ]]; then echo "${dep%%=*} = { path = \"${dep#*=}\" }"; fi; } > "${repo}/${dir}/Cargo.toml"
  echo "// ${name}" > "${repo}/${dir}/src/lib.rs"
}
mk_crate taurine-backend/taurine-model taurine-model
mk_crate taurine-backend/taurine-core taurine-core 'taurine-model=../taurine-model'
mk_crate taurine-backend/taurine-app taurine-app 'taurine-core=../taurine-core'
mk_crate taurine-backend/taurine-db-model taurine-db-model
mkdir -p "${repo}/taurine-desktop/src" "${repo}/docs" "${repo}/mystery"
echo a > "${repo}/taurine-desktop/src/a.ts"
echo a > "${repo}/docs/a.md"
echo a > "${repo}/mystery/a.txt"
echo a > "${repo}/Cargo.lock"
git -C "${repo}" add -A
git -C "${repo}" commit -q -m base
change() {
  local file="$1"
  mkdir -p "$(dirname "${repo}/${file}")"
  echo "$RANDOM" >> "${repo}/${file}"
  git -C "${repo}" add -A
  git -C "${repo}" commit -q -m "change ${file}"
  git -C "${repo}" rev-parse HEAD
}
selected() {
  : > "${work}/out.txt"
  python3 "${work}/concern_selector.py" .github/ci-matrix.json "${repo}" "$2" "$1" linux "${work}/out.txt" "${3:-[]}" > /dev/null
  echo "$(grep '^selection=' "${work}/out.txt" | cut -d= -f2) $(grep '^matrix=' "${work}/out.txt" | cut -d= -f2- | jq -r '.concern | join(",")')"
}
parent_of() { git -C "${repo}" rev-parse "$1~1"; }
expect() {
  local label="$1" got="$2" want="$3"
  if [[ "${got}" != "${want}" ]]; then
    echo "selector case '${label}' failed: wanted '${want}' got '${got}'" >&2
    exit 1
  fi
}
all="$(jq -r '[.concerns.linux | to_entries[] | select(.value.opt_in == null) | .key] | join(",")' .github/ci-matrix.json)"
sha="$(change docs/a.md)"
expect docs "$(selected "$(parent_of "${sha}")" "${sha}")" 'partial contracts,scan-security'
sha="$(change taurine-backend/taurine-model/src/lib.rs)"
expect crate "$(selected "$(parent_of "${sha}")" "${sha}")" 'partial contracts,rust-domain,rust-app-1,rust-app-2,scan-security'
sha="$(change taurine-backend/taurine-db-model/src/lib.rs)"
expect db "$(selected "$(parent_of "${sha}")" "${sha}")" 'partial contracts,rust-db,scan-security'
sha="$(change taurine-desktop/src/a.ts)"
expect ui "$(selected "$(parent_of "${sha}")" "${sha}")" 'partial contracts,frontend-build-budget,desktop-quality,desktop-shard-1,desktop-shard-2,e2e-critical,e2e-a11y,e2e-regression-1,e2e-regression-2,e2e-regression-3,e2e-regression-4,rust-packaging,scan-security'
sha="$(change Cargo.lock)"
expect lockfile "$(selected "$(parent_of "${sha}")" "${sha}")" "full ${all}"
sha="$(change mystery/a.txt)"
expect unknown "$(selected "$(parent_of "${sha}")" "${sha}")" "full ${all}"
expect no-base "$(selected "" "${sha}")" "full ${all}"
# An explicitly requested opt-in concern joins a partial selection (docs only here).
docs_sha="$(change docs/b.md)"
expect opt-in "$(selected "$(parent_of "${docs_sha}")" "${docs_sha}" '["e2e-visual"]')" 'partial contracts,scan-security,e2e-visual'
tree_ref='HEAD^{tree}'
orphan="$(git -C "${repo}" commit-tree "$(git -C "${repo}" rev-parse "${tree_ref}")" -m orphan)"
expect not-ancestor "$(selected "${orphan}" "${sha}")" "full ${all}"
echo 'concern selector: all synthetic cases behave as specified'
