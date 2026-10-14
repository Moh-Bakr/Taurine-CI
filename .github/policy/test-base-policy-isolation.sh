#!/usr/bin/env bash
# The base-policy step must pin the base policy to the base commit's own objects, must not let a
# base script outlive its own check, and must not hand a base script the loader variables.
#
# Like test-base-policy-env.sh, this extracts the reviewed step itself and runs it over fixture
# trees, so the fixtures exercise the step rather than a copy of it. The runner's own process setup
# is not reproduced; only the command it executes is.
#
# Run from the repository root. Usage: test-base-policy-isolation.sh [workflow-file]
set -euo pipefail

workflow="${1:-.github/workflows/validate-public-changes.yml}"
step="Run the base commit's policy against this pull request"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/base-policy-isolation-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
root="${PWD}"

ruby "${root}/.github/policy/extract-step.rb" "${workflow}" "${step}" run > "${work}/step.sh"
step_shell="$(ruby -ryaml -e '
  doc = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  found = doc.fetch("jobs").values.flat_map { |job| job.fetch("steps").select { |s| s["name"] == ARGV[1] } }
  abort "expected one step" unless found.length == 1
  print found.first.fetch("shell")
' "${workflow}" "${step}")"
[[ -n "${step_shell}" ]] || { echo "base-policy isolation: the step declares no shell" >&2; exit 1; }
[[ "${step_shell}" != bash ]] || step_shell='bash --noprofile --norc -eo pipefail {0}'

# The base policy, as a real checkout: that is what actions/checkout leaves beside the tree, and
# what the step reads its pinning manifest out of.
fixture() {
  local dir="$1"
  rm -rf "${dir}"
  mkdir -p "${dir}/tree/base-policy/.github/policy" "${dir}/tree/.github/policy" "${dir}/runner"
  printf '%s\n' "${dir}/tree"
}

commit_base() {
  local base="$1/base-policy"
  git -C "${base}" init -q
  git -C "${base}" config user.name 'Base Policy Fixture'
  git -C "${base}" config user.email 'base-policy-fixture@example.invalid'
  git -C "${base}" add -A
  git -C "${base}" -c commit.gpgsign=false commit -qm 'base policy fixture'
}

# A base policy that passes, so a fixture fails for the reason it is about and not because some
# base script rejected the tree.
passing_scripts() {
  local policy="$1/base-policy/.github/policy"
  printf 'exit 0\n' > "${policy}/check-pass.rb"
  printf 'exit 0\n' > "${policy}/check-pass.sh"
  printf 'exit 0\n' > "${policy}/lint.sh"
  printf 'exit 0\n' > "${policy}/test-pass.sh"
  printf 'exit 0\n' > "${policy}/test-pass.rb"
}

run_step() {
  local tree="$1" runner="$1/../runner" base_sha
  shift
  # The base commit the pull request names: the fixture checkout's own HEAD, unless a fixture
  # overrides it to show a mismatch is refused.
  base_sha="$(git -C "${tree}/base-policy" rev-parse HEAD)"
  local -a environment=(
    "RUNNER_TEMP=${runner}" GH_TOKEN=fixture-token "GITHUB_WORKSPACE=${tree}"
    GITHUB_REPOSITORY=Moh-Bakr/Taurine-CI GITHUB_EVENT_NAME=pull_request "BASE_SHA=${base_sha}" "$@"
  )
  local -a shell_argv=()
  read -r -a shell_argv <<< "${step_shell}"
  local i
  for i in "${!shell_argv[@]}"; do
    [[ "${shell_argv[i]}" != '{0}' ]] || shell_argv[i]="${work}/step.sh"
  done
  (cd "${tree}" && env "${environment[@]}" "${shell_argv[@]}")
}

expect_pass() {
  local label="$1" tree="$2" rc=0
  shift 2
  run_step "${tree}" "$@" > "${work}/${label}.out" 2>&1 || rc=$?
  [[ "${rc}" -eq 0 ]] || {
    echo "base-policy isolation: ${label}: the step failed when it should have passed" >&2
    sed 's/^/  /' "${work}/${label}.out" >&2
    exit 1
  }
}

expect_reject() {
  local label="$1" tree="$2" reason="$3" rc=0
  shift 3
  run_step "${tree}" "$@" > "${work}/${label}.out" 2>&1 || rc=$?
  [[ "${rc}" -ne 0 ]] || {
    echo "base-policy isolation: ${label}: the step passed" >&2
    sed 's/^/  /' "${work}/${label}.out" >&2
    exit 1
  }
  grep -qF "${reason}" "${work}/${label}.out" || {
    echo "base-policy isolation: ${label}: rejected for the wrong reason" >&2
    echo "  wanted: ${reason}" >&2
    sed 's/^/  got:    /' "${work}/${label}.out" >&2
    exit 1
  }
}

# A base policy that passes, passes. Everything below is a departure from this one case, so if this
# breaks the other fixtures are meaningless.
baseline="$(fixture "${work}/baseline")"
passing_scripts "${baseline}"
commit_base "${baseline}"
expect_pass baseline "${baseline}"
grep -q 'scripts run against' "${work}/baseline.out" || {
  echo 'base-policy isolation: the baseline did not report what it ran' >&2; exit 1;
}

# The pin reads the commit the checkout holds, so that commit must be the one the pull request
# names. A checkout of any other commit is refused before anything is pinned or run.
mismatch="$(fixture "${work}/mismatch")"
passing_scripts "${mismatch}"
commit_base "${mismatch}"
expect_reject mismatch "${mismatch}" 'not the base commit' "BASE_SHA=$(printf 'a%.0s' {1..40})"

# A base script that rewrites a later base script, after the manifest was built. The pin is what
# notices: the file on disk no longer matches the object the base commit holds.
rewrite="$(fixture "${work}/rewrite")"
passing_scripts "${rewrite}"
printf '%s\n' 'printf "exit 0\n# rewritten by an earlier base script\n" > .github/policy/test-pass.sh' \
  > "${rewrite}/base-policy/.github/policy/check-pass.sh"
commit_base "${rewrite}"
expect_reject rewrite "${rewrite}" 'no longer matches the base commit it was pinned to'

# A base file that appears after the manifest was built, and one that disappears.
added="$(fixture "${work}/added")"
passing_scripts "${added}"
printf '%s\n' 'printf "exit 0\n" > .github/policy/check-smuggled.sh' \
  > "${added}/base-policy/.github/policy/check-pass.sh"
commit_base "${added}"
expect_reject added "${added}" 'does not match the files the base commit pinned'

removed="$(fixture "${work}/removed")"
passing_scripts "${removed}"
printf '%s\n' 'rm -f .github/policy/test-pass.rb' \
  > "${removed}/base-policy/.github/policy/check-pass.sh"
commit_base "${removed}"
expect_reject removed "${removed}" 'does not match the files the base commit pinned'

# The same rewrite, with ruby poisoned the way an earlier step could poison it. The step builds
# and verifies the pin with ruby, so if that ruby were not scrubbed too, `at_exit { exit! 0 }`
# would make the pin agree with anything.
poison="${work}/poison"
mkdir -p "${poison}"
printf 'at_exit { exit!(0) }\n' > "${poison}/poison.rb"
poisoned_rewrite="$(fixture "${work}/poisoned-rewrite")"
passing_scripts "${poisoned_rewrite}"
printf '%s\n' 'printf "exit 0\n# rewritten by an earlier base script\n" > .github/policy/test-pass.sh' \
  > "${poisoned_rewrite}/base-policy/.github/policy/check-pass.sh"
commit_base "${poisoned_rewrite}"
expect_reject poisoned-rewrite "${poisoned_rewrite}" 'no longer matches the base commit it was pinned to' \
  RUBYOPT=-rpoison "RUBYLIB=${poison}"

# A poison aimed at the pin itself rather than at the exit status: every SHA-256 the poisoned ruby
# computes comes out the same. If the ruby that BUILDS the manifest were not scrubbed, it would pin
# forged digests, and the clean verification would then disagree with every file of a perfectly
# good base policy. So this must pass -- and stops passing the moment the build loses its scrub.
forge="${work}/forge"
mkdir -p "${forge}"
cat > "${forge}/forge.rb" <<'RB'
require 'digest'
class << Digest::SHA256
  def hexdigest(*)
    '0' * 64
  end
end
RB
forged="$(fixture "${work}/forged-pin")"
passing_scripts "${forged}"
commit_base "${forged}"
expect_pass forged-pin "${forged}" RUBYOPT=-rforge "RUBYLIB=${forge}"

# The attack the in-memory pin exists for: a base script that rewrites a later base script AND
# writes a matching manifest wherever a manifest file might be kept. The script runs as the same
# user with RUNNER_TEMP in view, so a pin on disk would be one more file for it to forge. Held in
# the step's memory, it cannot be reached.
forger="$(fixture "${work}/forger")"
passing_scripts "${forger}"
cat > "${forger}/base-policy/.github/policy/check-pass.sh" <<'SH'
printf 'exit 0\n# rewritten\n' > .github/policy/test-pass.sh
forged=''
for f in $(find .github/policy -type f | sort); do
  forged+="$(shasum -a 256 "$f" 2>/dev/null || sha256sum "$f")"$'\n'
done
for target in "${RUNNER_TEMP}/base-policy.sha256" "${RUNNER_TEMP}/manifest" "${RUNNER_TEMP}/pins"; do
  printf '%s' "${forged}" > "${target}"
done
exit 0
SH
commit_base "${forger}"
expect_reject forger "${forger}" 'no longer matches the base commit it was pinned to'

# A base script that leaves a process behind. The child writes its pid, then sleeps long enough
# that it would still be running if nothing tore the session down.
survivor="$(fixture "${work}/survivor")"
passing_scripts "${survivor}"
child_pid="${work}/survivor-child.pid"
cat > "${survivor}/base-policy/.github/policy/check-pass.sh" <<SH
sleep 120 &
printf '%s\n' "\$!" > "${child_pid}"
exit 0
SH
commit_base "${survivor}"
rm -f "${child_pid}"
# Leaving a process behind fails the step, by name, and the process is gone.
expect_reject survivor "${survivor}" 'left a process running in its session when it returned'
[[ -s "${child_pid}" ]] || { echo 'base-policy isolation: the survivor fixture started no child' >&2; exit 1; }
# Give the teardown a moment to land, then the child must be gone.
sleep 1
if kill -0 "$(cat "${child_pid}")" 2>/dev/null; then
  kill -KILL "$(cat "${child_pid}")" 2>/dev/null || true
  echo 'base-policy isolation: a base script left a process running after its check returned' >&2
  exit 1
fi

# The same, with the script also writing a bogus process-group id wherever the teardown might
# read one, to steer it at a group that does not exist and keep its own child alive. The leader
# is taken from the step's own `$!`, so there is nothing to steer.
steerer="$(fixture "${work}/steerer")"
passing_scripts "${steerer}"
steered_pid="${work}/steerer-child.pid"
cat > "${steerer}/base-policy/.github/policy/check-pass.sh" <<SH
sleep 120 &
printf '%s\n' "\$!" > "${steered_pid}"
for target in "\${RUNNER_TEMP}/base-policy-pgid" "\${RUNNER_TEMP}/pgid" "\${RUNNER_TEMP}/leader"; do
  printf '999999\n' > "\${target}"
done
exit 0
SH
commit_base "${steerer}"
rm -f "${steered_pid}"
expect_reject steerer "${steerer}" 'left a process running in its session when it returned'
[[ -s "${steered_pid}" ]] || { echo 'base-policy isolation: the steerer fixture started no child' >&2; exit 1; }
sleep 1
if kill -0 "$(cat "${steered_pid}")" 2>/dev/null; then
  kill -KILL "$(cat "${steered_pid}")" 2>/dev/null || true
  echo 'base-policy isolation: a base script steered the teardown and kept its child alive' >&2
  exit 1
fi

# A process that leaves the session altogether: Process.daemon double-forks and calls setsid, so
# it is in no group the teardown kills and is re-parented away from the step. It must still be
# found, fail the step by name, and be killed.
#
# The step finds it by the marker in its environment, which it reads from /proc. Where there is
# no /proc -- macOS, where ps also hides the environment of Apple's own binaries such as
# /usr/bin/ruby -- the marker cannot be read, so this fixture says plainly that it did not run
# rather than passing. The policy job runs on Linux, where it does.
if [[ ! -d /proc/self ]]; then
  echo 'base-policy isolation: NOT EXERCISED HERE -- the daemon-escape fixture needs /proc; it runs in the Linux policy job' >&2
  daemon_skipped=yes
else
  daemon_skipped=no
fi
if [[ "${daemon_skipped}" == no ]]; then
daemon="$(fixture "${work}/daemon")"
passing_scripts "${daemon}"
daemon_pid="${work}/daemon-child.pid"
cat > "${daemon}/base-policy/.github/policy/check-pass.rb" <<RB
Process.daemon(true, true)
File.write('${daemon_pid}', Process.pid.to_s)
sleep 120
RB
commit_base "${daemon}"
rm -f "${daemon_pid}"
expect_reject daemon "${daemon}" 'left a process that escaped its session'
[[ -s "${daemon_pid}" ]] || { echo 'base-policy isolation: the daemon fixture started no process' >&2; exit 1; }
if kill -0 "$(cat "${daemon_pid}")" 2>/dev/null; then
  kill -KILL "$(cat "${daemon_pid}")" 2>/dev/null || true
  echo 'base-policy isolation: a daemonised process outlived the step' >&2
  exit 1
fi
fi

# The last base script rewrites one that already ran. No script runs after it, so only the
# final verification can notice.
last="$(fixture "${work}/last")"
passing_scripts "${last}"
printf '%s\n' 'File.write(".github/policy/check-pass.sh", "exit 0\n# rewritten after it ran\n")' \
  > "${last}/base-policy/.github/policy/test-pass.rb"
commit_base "${last}"
expect_reject last "${last}" 'no longer matches the base commit it was pinned to'

# A base checkout whose file on disk no longer matches its git object. The pin must come from the
# object, so the disk copy is caught; a pin built from the disk would agree with the tampered file.
tampered="$(fixture "${work}/tampered")"
passing_scripts "${tampered}"
commit_base "${tampered}"
printf 'exit 0\n# changed on disk after the commit\n' > "${tampered}/base-policy/.github/policy/check-pass.sh"
expect_reject tampered "${tampered}" 'no longer matches the base commit it was pinned to'

# A hidden file added after the pin is an unexpected file like any other.
hidden="$(fixture "${work}/hidden")"
passing_scripts "${hidden}"
printf '%s\n' 'printf "exit 0\n" > .github/policy/.hidden' > "${hidden}/base-policy/.github/policy/check-pass.sh"
commit_base "${hidden}"
expect_reject hidden "${hidden}" 'does not match the files the base commit pinned'

# The loader variables must not reach a base script, however they were planted. The witness is a
# base script that fails when it can see one.
loader="$(fixture "${work}/loader")"
passing_scripts "${loader}"
cat > "${loader}/base-policy/.github/policy/check-pass.sh" <<'SH'
for name in LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH; do
  if [[ -n "${!name:-}" ]]; then
    echo "a base script can see ${name}" >&2
    exit 1
  fi
done
exit 0
SH
commit_base "${loader}"
expect_pass loader "${loader}" \
  LD_PRELOAD=/tmp/planted.so LD_LIBRARY_PATH=/tmp/planted LD_AUDIT=/tmp/planted-audit.so \
  DYLD_INSERT_LIBRARIES=/tmp/planted.dylib DYLD_LIBRARY_PATH=/tmp/planted

echo 'base-policy isolation fixtures: a checkout of any commit but the named base is refused; a rewritten, added or removed base file is caught by the commit pin, with ruby poisoned as well as clean, and a forged manifest on disk changes nothing; a process a base script leaves behind, in its session or escaped from it by Process.daemon, fails the step and is killed, even when the script plants a bogus group id; a rewrite by the last script, a tampered base checkout and a hidden file are caught; and planted loader variables never reach a base script'
[[ "${daemon_skipped}" == no ]] || echo 'base-policy isolation: the daemon-escape case above was NOT exercised on this host'
