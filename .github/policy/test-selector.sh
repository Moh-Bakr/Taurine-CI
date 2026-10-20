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
  python3 "${work}/concern_selector.py" "${matrix_file:-.github/ci-matrix.json}" "${repo}" "$2" "$1" linux "${work}/out.txt" "${3:-[]}" > /dev/null
  echo "$(grep '^selection=' "${work}/out.txt" | cut -d= -f2) $(grep '^matrix=' "${work}/out.txt" | cut -d= -f2- | jq -r '.concern | join(",")')"
}
parent_of() { git -C "${repo}" rev-parse "$1~1"; }
# Concern lists are compared sorted, never as ordered strings, so the matrix's own order may change.
# A partial selection always carries every concern the matrix declares `always`, so the wanted list is
# the case's own concerns plus those, de-duplicated (it is a union of two lists). The got list keeps
# every occurrence, so a concern selected twice fails, as does an undeclared or missing one; a concern
# added to the matrix (declared `always` or not selected here) is judged by the matrix.
always_set="$(jq -r '[.concerns.linux | to_entries[] | select(.value.opt_in == null and .value.always == true) | .key] | join(",")' .github/ci-matrix.json)"
canonical() {
  local value="$1" kind="${1%% *}" list="${1#* }" extra="${2:-}" dedupe="${3:-}"
  [[ -n "${extra}" ]] && list="${list},${extra}"
  local lines
  lines="$(tr ',' '\n' <<<"${list}" | sed '/^$/d')"
  [[ -n "${dedupe}" ]] && lines="$(awk '!seen[$0]++' <<<"${lines}")"
  printf '%s %s' "${kind}" "$(LC_ALL=C sort <<<"${lines}" | paste -sd, -)"
}
expect() {
  local label="$1" got="$2" want="$3" extra=''
  [[ "${want}" == partial* ]] && extra="${always_set}"
  got="$(canonical "${got}")"
  want="$(canonical "${want}" "${extra}" dedupe)"
  if [[ "${got}" != "${want}" ]]; then
    echo "selector case '${label}' failed: wanted '${want}' got '${got}'" >&2
    exit 1
  fi
}
# The selection is also published split by the table's long_pole flag (the dispatcher runs the long
# poles in their own jobs): the two halves are disjoint, together exactly `matrix` (which the Result
# job requires), and the long half is exactly the flagged concerns of the selection, in order.
check_split() {
  ruby -rjson -e 'out = File.readlines(ARGV.fetch(0)).to_h { |l| k, v = l.chomp.split("=", 2); [k, v] }
    whole = JSON.parse(out.fetch("matrix")).fetch("concern"); long = JSON.parse(out.fetch("long_matrix")).fetch("concern"); short = JSON.parse(out.fetch("short_matrix")).fetch("concern")
    flagged = JSON.parse(File.read(ARGV.fetch(1))).fetch("concerns").fetch("linux").select { |_, s| s["long_pole"] }.keys
    abort "#{ARGV.fetch(2)}: long and short halves are not the selection" unless (long + short).sort == whole.sort && (long & short).empty? && long.length + short.length == whole.length
    abort "#{ARGV.fetch(2)}: the long half is not exactly the flagged concerns" unless long == whole.select { |c| flagged.include?(c) } && short.none? { |c| flagged.include?(c) }' "${work}/out.txt" .github/ci-matrix.json "$1"
}
all="$(jq -r '[.concerns.linux | to_entries[] | select(.value.opt_in == null) | .key] | join(",")' .github/ci-matrix.json)"
sha="$(change docs/a.md)"
expect docs "$(selected "$(parent_of "${sha}")" "${sha}")" 'partial contracts,scan-security'
check_split docs
sha="$(change taurine-backend/taurine-model/src/lib.rs)"
# The app shards the selection must name are the shard rows of this tree's own table, exactly: a table with
# three shards must select three, never a list written for another table.
table_shards="$(jq -r '[.concerns.linux | keys[] | select(test("^rust-app-[0-9]+$"))] | join(",")' .github/ci-matrix.json)"
[[ "${table_shards}" == 'rust-app-1,rust-app-2,rust-app-3' ]] || { echo "selector case 'crate': the table's app shards are '${table_shards}', not rust-app-1 to rust-app-3" >&2; exit 1; }
expect crate "$(selected "$(parent_of "${sha}")" "${sha}")" "partial contracts,rust-domain,${table_shards},scan-security"
check_split crate
sha="$(change taurine-backend/taurine-db-model/src/lib.rs)"
expect db "$(selected "$(parent_of "${sha}")" "${sha}")" 'partial contracts,rust-db,scan-security'
sha="$(change taurine-desktop/src/a.ts)"
expect ui "$(selected "$(parent_of "${sha}")" "${sha}")" 'partial contracts,frontend-build-budget,desktop-quality,desktop-shard-1,desktop-shard-2,e2e-critical,e2e-a11y,e2e-regression-1,e2e-regression-2,e2e-regression-3,e2e-regression-4,rust-packaging,scan-security'
sha="$(change Cargo.lock)"
expect lockfile "$(selected "$(parent_of "${sha}")" "${sha}")" "full ${all}"
check_split lockfile
sha="$(change mystery/a.txt)"
expect unknown "$(selected "$(parent_of "${sha}")" "${sha}")" "full ${all}"
expect no-base "$(selected "" "${sha}")" "full ${all}"
# An explicitly requested opt-in concern joins a partial selection (docs only here).
docs_sha="$(change docs/b.md)"
expect opt-in "$(selected "$(parent_of "${docs_sha}")" "${docs_sha}" '["e2e-visual"]')" 'partial contracts,scan-security,e2e-visual'
# The selector's `always` path, proven on a synthetic matrix instead of by trusting the real one:
# a concern declared `always` is selected exactly once on a docs-only and on a UI change, and a
# concern that is not `always` and matches no changed path is not. This holds for any future
# always-concern without naming one; whether the real matrix should mark a concern `always` is a
# reviewed matrix change that no fixture can judge without pinning a list.
matrix_file="${work}/synthetic-matrix.json"
jq '.concerns.linux += {"zz-always": {"always": true, "timeout": 30, "paths": []}, "zz-optional": {"timeout": 30, "paths": ["never/**"]}}' .github/ci-matrix.json > "${matrix_file}"
for synthetic_change in docs/c.md taurine-desktop/src/a.ts; do
  sha_syn="$(change "${synthetic_change}")"
  got_syn="$(selected "$(parent_of "${sha_syn}")" "${sha_syn}")"
  count_always="$(tr ',' '\n' <<<"${got_syn#* }" | grep -cx 'zz-always' || true)"
  if [[ "${got_syn%% *}" != partial || "${count_always}" != 1 ]] || tr ',' '\n' <<<"${got_syn#* }" | grep -qx 'zz-optional'; then
    echo "selector case 'synthetic always' failed for ${synthetic_change}: got '${got_syn}'" >&2
    exit 1
  fi
done
unset matrix_file
tree_ref='HEAD^{tree}'
orphan="$(git -C "${repo}" commit-tree "$(git -C "${repo}" rev-parse "${tree_ref}")" -m orphan)"
expect not-ancestor "$(selected "${orphan}" "${sha}")" "full ${all}"
echo 'concern selector: all synthetic cases behave as specified'
