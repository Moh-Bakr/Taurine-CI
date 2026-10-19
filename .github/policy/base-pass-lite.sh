#!/usr/bin/env bash
# Developer tool, never run by CI: rehearse the base pass before pushing a policy or CI change.
#
# A pull request is judged by main's own policy scripts run against the pull request's tree (the
# "base pass", step "Run the base commit's policy against this pull request" in
# .github/workflows/base-policy.yml). Main's fixtures can pin exact text (a timeout, a job shape, a
# concern order), and finding that out costs a hosted wait. This runs the same scripts locally.
#
# Usage: bash .github/policy/base-pass-lite.sh [base-ref] [--full]
#   base-ref  the ref whose .github/policy judges the tree (default origin/main)
#   --full    also run test-mutations.sh and the slow fixture suites, and lint.sh on Linux x86_64
#             (MUTATION_JOBS is set to the CPU count)
# Run `git fetch origin` first so the base ref is current; the tool warns when it looks stale.
#
# The default is a fast subset: it skips lint.sh (downloads pinned Linux binaries), test-mutations.sh (runs the whole offline policy once per mutation;
# its unmutated-tree precheck is internal to it and cannot be run alone) and a few slow fixture
# suites (the slow_scripts list below).
#
# How it stays safe: the base ref's policy is read with git archive (no checkout), the current
# working tree (tracked plus untracked, not ignored) is copied to a temp directory, the base policy
# replaces the copy's .github/policy as the hosted step does, and each script runs there with a
# scrubbed environment. Your working tree is never written to, no token is used, and the pull
# request's own scripts never act as the judge. Fast mode makes no network calls; --full on Linux
# runs lint.sh, which downloads pinned binaries. Not a substitute for the hosted base pass: it does
# not reproduce drop-root, process containment or the hosted HOME layout, and fixtures that cannot
# run on this host are reported as SKIPPED(self), not as passes.
#
# Its name matches neither check-* nor test-*, so the base pass's script glob never runs it.
set -euo pipefail

base_ref=origin/main
full=0
for arg in "$@"; do
  case "${arg}" in
    --full) full=1 ;;
    -h | --help) sed -n 2,30p "$0"; exit 0 ;;
    -*) echo "base-pass-lite: unknown option ${arg}" >&2; exit 2 ;;
    *) base_ref="${arg}" ;;
  esac
done

repo="$(git rev-parse --show-toplevel)"
cd "${repo}"
git rev-parse --verify --quiet "${base_ref}^{commit}" > /dev/null \
  || { echo "base-pass-lite: ${base_ref} is not a known ref (try: git fetch origin)" >&2; exit 2; }
base_sha="$(git rev-parse "${base_ref}^{commit}")"

# Warn when a remote-tracking base looks stale: the last fetch is older than a day, or unknown.
if [[ "${base_ref}" == origin/* ]]; then
  fetch_head="$(git rev-parse --git-path FETCH_HEAD)"
  if [[ ! -f "${fetch_head}" || -n "$(find "${fetch_head}" -mmin +1440 2>/dev/null)" ]]; then
    echo "base-pass-lite: WARNING ${base_ref} may be older than the remote; run: git fetch origin" >&2
  fi
fi
# A gitlink (submodule) cannot be copied as a file tree.
if [[ -n "$(git ls-files -s | awk '$1 == "160000" { print $4 }')" ]]; then
  echo "base-pass-lite: the tree has a gitlink or submodule entry, which this tool cannot copy" >&2
  exit 2
fi

work="$(mktemp -d)"
cleanup() {
  local pid
  for pid in $(jobs -p); do pkill -P "${pid}" 2>/dev/null || true; kill "${pid}" 2>/dev/null || true; done
  rm -rf "${work:?}"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM
tree="${work}/tree"
mkdir -p "${tree}"

# The current working tree, as the pull request's tree: tracked and untracked files that are not
# ignored. A file deleted in the working tree but still in the index is left out.
while IFS= read -r -d '' path; do
  [[ -e "${path}" || -L "${path}" ]] || continue
  mkdir -p "${tree}/$(dirname "${path}")"
  cp -P "${path}" "${tree}/${path}"
done < <(git ls-files -z --cached --others --exclude-standard)

# The judge: the base ref's policy directory, in place of the copy's own, as the hosted step does.
rm -rf "${tree}/.github/policy"
mkdir -p "${tree}/.github"
git archive "${base_sha}" .github/policy | tar -x -C "${tree}"
[[ -d "${tree}/.github/policy" ]] || { echo "base-pass-lite: ${base_ref} has no .github/policy" >&2; exit 2; }

# Several checks read the git index of the tree they judge.
(
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
  cd "${tree}"
  git init -q .
  git add -A
  git -c user.name=base-pass-lite -c user.email=base-pass-lite@localhost \
    -c commit.gpgsign=false commit -q -m "base-pass-lite working tree"
)

cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
# PATH is pinned to the system directories as on the hosted step. The hosted image carries modern
# ruby, python3 and GNU tools in them; a Mac does not, so there /opt/homebrew/bin (or
# BASE_PASS_LITE_EXTRA_PATH) goes first. The scripts need it (Psych.safe_load_file, tomllib,
# sha256sum); the chosen PATH is printed below.
extra="${BASE_PASS_LITE_EXTRA_PATH:-}"
if [[ -z "${extra}" && "$(uname -s)" == Darwin && -d /opt/homebrew/bin ]]; then extra=/opt/homebrew/bin; fi
tool_path="${extra:+${extra}:}/usr/bin:/bin:/usr/sbin:/sbin"
scrub=(/usr/bin/env -i "PATH=${tool_path}" LANG=C.UTF-8 LC_ALL=C.UTF-8 "MUTATION_JOBS=${cpus}")
# The names the hosted step forwards, when set here.
for name in CI GITHUB_ACTIONS GITHUB_API_URL GITHUB_EVENT_NAME GITHUB_REF GITHUB_REPOSITORY GITHUB_SERVER_URL GITHUB_SHA GITHUB_WORKSPACE RUNNER_ARCH RUNNER_OS; do
  [[ -z "${!name+x}" ]] || scrub+=("${name}=${!name}")
done

echo "base-pass-lite: PATH=${tool_path}; bash $(PATH="${tool_path}" command -v bash) ($(PATH="${tool_path}" bash -c 'echo ${BASH_VERSION}')), ruby $(PATH="${tool_path}" command -v ruby) ($(PATH="${tool_path}" ruby -e 'print RUBY_VERSION'))"
echo "base-pass-lite: not reproduced: drop-root, process containment, the hosted HOME layout"
echo "base-pass-lite: judging the working tree with the policy of ${base_ref} (${base_sha:0:12}), $([[ ${full} -eq 1 ]] && echo full || echo fast)"

# The scripts are independent, so they run in parallel (bounded by the CPU count), each in its own
# copy of the tree and its own HOME and RUNNER_TEMP, and report in the order the hosted step runs
# them. Output is printed per script once every script before it has finished.
policy=.github/policy
names=()
for check in "${policy}"/check-*.rb "${policy}"/check-*.sh "${policy}"/lint.sh "${policy}"/test-*.sh "${policy}"/test-*.rb; do
  [[ -f "${tree}/${check}" ]] || continue
  names+=("${check##*/}")
done
[[ ${#names[@]} -gt 0 ]] || { echo "base-pass-lite: the base policy has no scripts to run" >&2; exit 2; }

# Fast mode skips these: lint.sh and test-mutations.sh by design (see the header), and the fixture
# suites that mutate scripts or re-run the whole policy per case, each measured at minutes of CPU.
# --full runs them. test-shell-artefact.sh fails on an unmodified main under macOS (its mutation
# text assumes the hosted Linux shell), so it is skipped on Darwin in both modes.
slow_scripts=" lint.sh test-mutations.sh test-policy.sh test-action-uses.sh test-rule-n-if-shape.sh test-cache-expressions.rb test-build-failure-category.sh test-case-evidence-admission.sh test-live-roster.sh "
# A name here that the base policy no longer has is a stale entry: say so, so the list is pruned.
for slow in ${slow_scripts}; do
  found=0
  for name in "${names[@]}"; do [[ "${name}" == "${slow}" ]] && found=1; done
  (( found )) || echo "base-pass-lite: WARNING slow_scripts names ${slow}, which the base policy does not have; remove it from the list" >&2
done
skip_reason() {
  if [[ ${full} -eq 0 && "${slow_scripts}" == *" $1 "* ]]; then echo "fast mode"; return; fi
  if [[ "$1" == test-shell-artefact.sh && "$(uname -s)" == Darwin ]]; then echo "does not run under macOS"; return; fi
  if [[ "$1" == lint.sh && ( "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ) ]]; then
    echo "downloads pinned Linux binaries"
  fi
}

for name in "${names[@]}"; do
  reason="$(skip_reason "${name}")"
  [[ -z "${reason}" ]] || echo "base-pass-lite: will skip ${name}: ${reason}"
done

run_one() {
  local i="$1" name="$2" dir="${work}/job-${1}" t0="${SECONDS}" rc=0
  mkdir -p "${dir}/home" "${dir}/runner-temp"
  cp -R "${tree}" "${dir}/tree"
  local cmd=(bash --noprofile --norc "${policy}/${name}")
  [[ "${name}" == *.rb ]] && cmd=(ruby "${policy}/${name}")
  (cd "${dir}/tree" && "${scrub[@]}" "HOME=${dir}/home" "RUNNER_TEMP=${dir}/runner-temp" "${cmd[@]}") > "${dir}/log" 2>&1 || rc=$?
  echo "${rc} $((SECONDS - t0))" > "${dir}/done"
  rm -rf "${dir:?}/tree" "${dir:?}/home" "${dir:?}/runner-temp"
}

# test-mutations.sh runs its own pool sized by MUTATION_JOBS, so it goes alone, last.
passed=0; failed=0; skipped=0; failures=(); started=(); skipped_names=()
start="${SECONDS}"
for i in "${!names[@]}"; do
  [[ -z "$(skip_reason "${names[${i}]}")" ]] || continue
  [[ "${names[${i}]}" != test-mutations.sh ]] || continue
  while (( $(jobs -rp | wc -l) >= cpus )); do sleep 0.2; done
  run_one "${i}" "${names[${i}]}" &
  started+=("${i}")
done
wait
for i in "${!names[@]}"; do
  if [[ "${names[${i}]}" == test-mutations.sh && -z "$(skip_reason test-mutations.sh)" ]]; then
    run_one "${i}" "${names[${i}]}"
  fi
done

for i in "${!names[@]}"; do
  name="${names[${i}]}"
  reason="$(skip_reason "${name}")"
  if [[ -n "${reason}" ]]; then
    echo "SKIP ${name} (${reason})"; skipped=$((skipped + 1)); skipped_names+=("${name}"); continue
  fi
  read -r rc secs < "${work}/job-${i}/done" || { rc=255; secs=0; }
  if [[ "${rc}" -eq 0 ]]; then
    if grep -q "NOT EXERCISED HERE" "${work}/job-${i}/log"; then
      echo "SKIPPED(self) ${name} (${secs}s): it declined to run on this host"
      skipped=$((skipped + 1)); skipped_names+=("${name}")
    else
      echo "PASS ${name} (${secs}s)"; passed=$((passed + 1))
    fi
  else
    echo "FAIL ${name} (${secs}s, exit ${rc})"
    head -n 15 "${work}/job-${i}/log" | sed 's/^/    /'
    failed=$((failed + 1)); failures+=("${name}")
  fi
done

echo "base-pass-lite: ${passed} passed, ${failed} failed, ${skipped} skipped in $((SECONDS - start))s"
if [[ ${failed} -gt 0 ]]; then
  echo "base-pass-lite: FAILED: ${failures[*]}" >&2
  exit 1
fi
if [[ ${skipped} -gt 0 ]]; then
  echo "base-pass-lite: PARTIAL (fast subset: ${skipped} skipped; not equivalent to the hosted base pass)"
  echo "base-pass-lite: skipped: ${skipped_names[*]}"
else
  echo "base-pass-lite: PASS (nothing skipped; still not the hosted sandbox)"
fi
