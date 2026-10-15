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

# The step contains each base script with a Linux child subreaper and reads /proc, so it only runs
# on Linux -- as the policy jobs do. Anywhere else, say so rather than fail every fixture for that.
if [[ "$(uname -s)" != Linux ]]; then
  echo "${0##*/}: NOT EXERCISED HERE -- the base-policy step runs only on Linux; the policy jobs run this"
  [[ "${GITHUB_ACTIONS:-}" != true ]] || exit 1
  exit 0
fi

# The step refuses to run while passwordless sudo is available, so these fixtures can only run where
# it is not: a developer machine, or after drop-root in the policy workflow. Say so rather than
# report every fixture as failing for a reason that has nothing to do with it.
if /usr/bin/sudo -n true 2>/dev/null; then
  echo "${0##*/}: passwordless sudo is available, and the step refuses to run with it; run this after drop-root" >&2
  exit 1
fi

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

# The step's log must show the judge as the very next script after the planter.
next_after() {
  local label="$1" first="$2" second="$3"
  ruby -e '
    groups = File.readlines(ARGV[0]).filter_map { |l| l[/::group::base policy: (\S+)/, 1] }
    i = groups.index(ARGV[1])
    abort "#{ARGV[1]} did not run" unless i
    abort "#{ARGV[2]} was not the next script after #{ARGV[1]}: #{groups.inspect}" unless groups[i + 1] == ARGV[2]
  ' "${work}/${label}.out" "${first}" "${second}" || { echo "base-policy isolation: ${label}: wrong order" >&2; exit 1; }
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
expect_reject survivor "${survivor}" 'check-pass.sh left 1 process(es) running when it returned; they were killed'
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
expect_reject steerer "${steerer}" 'check-pass.sh left 1 process(es) running when it returned; they were killed'
[[ -s "${steered_pid}" ]] || { echo 'base-policy isolation: the steerer fixture started no child' >&2; exit 1; }
sleep 1
if kill -0 "$(cat "${steered_pid}")" 2>/dev/null; then
  kill -KILL "$(cat "${steered_pid}")" 2>/dev/null || true
  echo 'base-policy isolation: a base script steered the teardown and kept its child alive' >&2
  exit 1
fi

# A process that leaves the session altogether: Process.daemon double-forks and calls setsid, so
# it is re-parented away from the script. The wrapper is the subreaper it is re-parented to, so it
# is still found, fails the step by name, and is killed.
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
expect_reject daemon "${daemon}" 'check-pass.rb left 1 process(es) running when it returned; they were killed'
[[ -s "${daemon_pid}" ]] || { echo 'base-policy isolation: the daemon fixture started no process' >&2; exit 1; }
if kill -0 "$(cat "${daemon_pid}")" 2>/dev/null; then
  kill -KILL "$(cat "${daemon_pid}")" 2>/dev/null || true
  echo 'base-policy isolation: a daemonised process outlived the step' >&2
  exit 1
fi

# The escape a marker in the environment could not see: script N leaves its session AND clears its
# environment (setsid, then env -i), and keeps writing into HOME. Script N+1 must find its HOME
# still empty, and the process must be gone. Script N is the reviewer's command, verbatim.
envclear="$(fixture "${work}/envclear")"
passing_scripts "${envclear}"
cat > "${envclear}/base-policy/.github/policy/check-a-daemon.sh" <<'SH'
( /usr/bin/setsid /usr/bin/env -i /bin/sh -c 'while :; do printf planted > "$1/planted"; sleep 0.02; done' daemon "$HOME" </dev/null >/dev/null 2>&1 & )
sleep 0.3; exit 0
SH
cat > "${envclear}/base-policy/.github/policy/check-b-judge.sh" <<'SH'
sleep 0.3
[[ ! -e "${HOME}/planted" ]] || { echo 'a process from the previous script wrote into this HOME' >&2; exit 1; }
SH
commit_base "${envclear}"
expect_reject envclear "${envclear}" 'base policy: check-a-daemon.sh left '
next_after envclear check-a-daemon.sh check-b-judge.sh
if grep -qF "The base commit's check-b-judge.sh rejects" "${work}/envclear.out"; then
  echo 'base-policy isolation: envclear: script N+1 found its HOME re-planted' >&2; exit 1
fi
sleep 0.3
if pgrep -f "${work}/envclear/runner/base-policy-home" > /dev/null; then
  pkill -KILL -f "${work}/envclear/runner/base-policy-home" || true
  echo 'base-policy isolation: envclear: the environment-cleared process outlived its script' >&2; exit 1
fi

# A child that has exited but was never reaped is a zombie, not a process left running: the script
# below execs into sleep, which never waits for it, so it is handed to the wrapper unreaped. Base
# tests leave these routinely, so the step must reap them quietly and pass.
zombie="$(fixture "${work}/zombie")"
passing_scripts "${zombie}"
cat > "${zombie}/base-policy/.github/policy/check-pass.sh" <<'SH'
/bin/true &
exec /bin/sleep 0.3
SH
commit_base "${zombie}"
expect_pass zombie "${zombie}"

# A script that tries to read the memory of the wrapper containing it, to find or rewrite what the
# wrapper will do when it returns. The wrapper is not dumpable, so this is refused whatever
# ptrace_scope says. Where Yama already confines ptrace to descendants (the hosted runner) it is
# refused twice over, so this falsifies only on a kernel without Yama.
memory="$(fixture "${work}/memory")"
passing_scripts "${memory}"
cat > "${memory}/base-policy/.github/policy/check-pass.rb" <<'RB'
# Opening is the access check (ptrace attach mode); any read would fail on an unmapped address
# anyway, so only the open is judged.
begin
  File.open("/proc/#{Process.ppid}/mem", "rb").close
rescue Errno::EACCES, Errno::EPERM
  exit 0
end
warn "a base script could open the memory of the wrapper containing it"
exit 1
RB
commit_base "${memory}"
expect_pass memory "${memory}"

# A script that kills the wrapper containing it. Its descendants are then re-parented beyond the
# wrapper's reach, but the wrapper's status says it was killed, so the step fails anyway.
killer="$(fixture "${work}/killer")"
passing_scripts "${killer}"
killer_pid="${work}/killer-child.pid"
cat > "${killer}/base-policy/.github/policy/check-pass.sh" <<SH
( sleep 120 & printf '%s\n' "\$!" > "${killer_pid}" )
kill -KILL "\${PPID}"
SH
commit_base "${killer}"
rm -f "${killer_pid}"
expect_reject killer "${killer}" "The base commit's check-pass.sh rejects this pull request"
[[ ! -s "${killer_pid}" ]] || kill -KILL "$(cat "${killer_pid}")" 2>/dev/null || true

# The pull request's tree, rewritten by an earlier base script. Each is caught before the next
# script runs: a tracked file changed, a file added, .git/config edited to steer later git, and
# git's own state -- HEAD, a ref, the index -- rewritten to change what later git reads.
for case in changed added gitconfig head ref index; do
  tree="$(fixture "${work}/tree-${case}")"
  passing_scripts "${tree}"
  mkdir -p "${tree}/.git" "${tree}/.github/workflows"
  printf 'on: push\n' > "${tree}/.github/workflows/live-proofs.yml"
  printf '[core]\n\tbare = false\n' > "${tree}/.git/config"
  mkdir -p "${tree}/.git/refs/heads"
  printf 'ref: refs/heads/main\n' > "${tree}/.git/HEAD"
  printf 'DIRC fixture index\n' > "${tree}/.git/index"
  case "${case}" in
    changed) edit='File.write(".github/workflows/live-proofs.yml", "on: pull_request\n")'; want='.github/workflows/live-proofs.yml' ;;
    added) edit='File.write("planted.yml", "x\n")'; want='planted.yml' ;;
    gitconfig) edit='File.write(".git/config", "[core]\n\tfsmonitor = /tmp/planted\n")'; want='.git/config' ;;
    head) edit='File.write(".git/HEAD", "ref: refs/heads/planted\n")'; want='.git/HEAD' ;;
    ref) edit='File.write(".git/refs/heads/planted", "0" * 40 + "\n")'; want='.git/refs/heads/planted' ;;
    index) edit='File.write(".git/index", "DIRC planted\n")'; want='.git/index' ;;
  esac
  printf '%s\n' "${edit}" > "${tree}/base-policy/.github/policy/check-a-tree.rb"
  commit_base "${tree}"
  expect_reject "tree-${case}" "${tree}" "the pull request tree changed while the base policy ran: \"${want}\""
done

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

# Files a base script leaves in HOME. Pull-request code that one base test runs could plant a gem
# or a node module there, and a later base check that requires json, or a module node finds
# through ~/.node_modules, would load it and could exit 0 from inside. HOME must be empty again
# for every script. The planter is script N (check-a-*.rb sorts first) and the judge is script
# N+1 (check-b-*.rb), which next_after checks in the step's own log; the judge always rejects,
# unless planted code it loads makes it pass.
planter() {
  cat > "$1/base-policy/.github/policy/check-a-plant.rb" <<'RB'
require "fileutils"
home = ENV.fetch("HOME")
gems = Gem.user_dir
FileUtils.mkdir_p(File.join(gems, "specifications"))
FileUtils.mkdir_p(File.join(gems, "gems/json-99.0.0/lib"))
File.write(File.join(gems, "specifications/json-99.0.0.gemspec"), <<~SPEC)
  Gem::Specification.new do |s|
    s.name = "json"; s.version = "99.0.0"; s.summary = "planted"; s.authors = ["fixture"]
    s.files = ["lib/json.rb"]; s.require_paths = ["lib"]
  end
SPEC
File.write(File.join(gems, "gems/json-99.0.0/lib/json.rb"), "exit!(0)\n")
FileUtils.mkdir_p(File.join(home, ".node_modules/taurine-planted"))
File.write(File.join(home, ".node_modules/taurine-planted/index.js"), "process.exit(0);\n")
RB
}


home_gem="$(fixture "${work}/home-gem")"
passing_scripts "${home_gem}"
planter "${home_gem}"
printf '%s\n' 'require "json"' 'warn "the judge loaded the system json and rejects"' 'exit 1' \
  > "${home_gem}/base-policy/.github/policy/check-b-judge.rb"
commit_base "${home_gem}"
expect_reject home-gem "${home_gem}" "The base commit's check-b-judge.rb rejects this pull request"
next_after home-gem check-a-plant.rb check-b-judge.rb

# A planted digest gem aimed at the verifier rather than at a base check. The verifier runs while
# the planting script's HOME is still there, so if it loaded gems, a digest that matched every file
# would hide the rewrite the same script made to a later base script. This only falsifies where
# RubyGems resolves a default gem's require to a newer installed copy, as Ruby 4.0 does for digest;
# Ruby 3.2 (the runner's /usr/bin/ruby) and 2.6 keep the default copy, so there it passes with or
# without --disable-gems.
home_digest="$(fixture "${work}/home-digest")"
passing_scripts "${home_digest}"
cat > "${home_digest}/base-policy/.github/policy/check-a-plant.rb" <<'RB'
require "fileutils"
gems = Gem.user_dir
FileUtils.mkdir_p(File.join(gems, "specifications"))
FileUtils.mkdir_p(File.join(gems, "gems/digest-99.0.0/lib"))
File.write(File.join(gems, "specifications/digest-99.0.0.gemspec"), <<~SPEC)
  Gem::Specification.new do |s|
    s.name = "digest"; s.version = "99.0.0"; s.summary = "planted"; s.authors = ["fixture"]
    s.files = ["lib/digest.rb"]; s.require_paths = ["lib"]
  end
SPEC
File.write(File.join(gems, "gems/digest-99.0.0/lib/digest.rb"), "exit!(0)\n")
File.write(".github/policy/check-pass.sh", "exit 0\n# rewritten by an earlier base script\n")
RB
commit_base "${home_digest}"
expect_reject home-digest "${home_digest}" 'no longer matches the base commit it was pinned to'

# Script N replaces HOME with a symbolic link to a directory of its choosing. Emptying HOME must
# remove the link, not what it points at, and script N+1 must get a real, empty directory.
home_link="$(fixture "${work}/home-link")"
passing_scripts "${home_link}"
victim="$(cd "${work}" && pwd -P)/victim"
mkdir -p "${victim}"
printf 'keep\n' > "${victim}/sentinel"
{
  echo 'require "fileutils"'
  echo 'home = ENV.fetch("HOME")'
  echo 'FileUtils.rm_rf(home)'
  echo "File.symlink($(ruby -e 'print ARGV[0].dump' "${victim}"), home)"
} > "${home_link}/base-policy/.github/policy/check-a-plant.rb"
cat > "${home_link}/base-policy/.github/policy/check-b-judge.rb" <<'RB'
home = ENV.fetch("HOME")
abort "HOME is still a link" if File.symlink?(home)
abort "HOME is not an empty directory" unless File.directory?(home) && Dir.empty?(home)
RB
commit_base "${home_link}"
expect_pass home-link "${home_link}"
next_after home-link check-a-plant.rb check-b-judge.rb
[[ -f "${victim}/sentinel" ]] || { echo 'base-policy isolation: home-link: emptying HOME followed the link and removed what it pointed at' >&2; exit 1; }

# The same through node. The judge names node by the absolute path found here, because the base
# PATH holds only the system directories, where a developer machine and the fixtures job have none.
node_for_fixture="$(command -v node || true)"
home_node_skipped=no
if [[ -n "${node_for_fixture}" ]]; then
  home_node="$(fixture "${work}/home-node")"
  passing_scripts "${home_node}"
  planter "${home_node}"
  printf '%s\n' "exit 0 if system($(ruby -e 'print ARGV[0].dump' "${node_for_fixture}"), '-e', 'require(\"taurine-planted\"); process.exit(3)', err: File::NULL)" \
    'warn "the judge found no planted module and rejects"' 'exit 1' \
    > "${home_node}/base-policy/.github/policy/check-b-judge.rb"
  commit_base "${home_node}"
  expect_reject home-node "${home_node}" "The base commit's check-b-judge.rb rejects this pull request"
  next_after home-node check-a-plant.rb check-b-judge.rb
else
  home_node_skipped=yes
fi

# The node install step keeps an existing node only if it is a real file that it and its directory
# leave to root alone. Run that branch of the step, pointed at stand-ins, with nothing installed.
install_step="Install node where only root can change it"
ruby "${root}/.github/policy/extract-step.rb" "${workflow}" "${install_step}" run > "${work}/install.sh"
node_line='node_dest=/usr/bin/node'
[[ "$(grep -cxF "${node_line}" "${work}/install.sh" || true)" -eq 1 ]] || {
  echo "base-policy isolation: the install step does not set ${node_line} exactly once" >&2; exit 1;
}
run_install() {
  local label="$1" dest="$2" rc=0
  ruby -e 'text, from, to = File.read(ARGV[0]), ARGV[1], ARGV[2]; print text.sub(from) { to }' \
    "${work}/install.sh" "${node_line}" "node_dest=${dest}" > "${work}/install-${label}.sh"
  bash --noprofile --norc -eo pipefail "${work}/install-${label}.sh" > "${work}/install-${label}.out" 2>&1 || rc=$?
  printf '%s' "${rc}"
}
expect_install_refuses() {
  local label="$1" dest="$2"
  if [[ "$(run_install "${label}" "${dest}")" -eq 0 ]] ||
     ! grep -qF 'exists but is a link or can be changed by someone other than root' "${work}/install-${label}.out"; then
    echo "base-policy isolation: install ${label}: an existing ${dest} was not refused" >&2
    sed 's/^/  /' "${work}/install-${label}.out" >&2
    exit 1
  fi
}
mkdir -p "${work}/install"
# A link root owns, so it is refused for being a link and not for its owner: /tmp on macOS, /bin on
# merged-/usr Linux. Where there is none, a link the job user makes still has to be refused.
root_link="$(ruby -e 'ARGV.each { |p| s = File.lstat(p) rescue next; if s.symlink? && s.uid.zero? then print p; exit end }' /tmp /bin /sbin /lib)"
if [[ -z "${root_link}" ]]; then
  root_link="${work}/install/link-node"
  ln -s /usr/bin/env "${root_link}"
fi
expect_install_refuses link "${root_link}"
printf 'stand-in\n' > "${work}/install/owned-node"
chmod 0755 "${work}/install/owned-node"
expect_install_refuses owned "${work}/install/owned-node"
# A real file root owns, 0755, in a root-owned directory nobody else can write: kept.
if [[ "$(run_install kept /usr/bin/env)" -ne 0 ]] ||
   ! grep -qF 'already installed and only root can change it' "${work}/install-kept.out"; then
  echo 'base-policy isolation: install kept: a root-owned node was not kept' >&2
  sed 's/^/  /' "${work}/install-kept.out" >&2
  exit 1
fi

echo 'base-policy isolation fixtures: a checkout of any commit but the named base is refused; a rewritten, added or removed base file is caught by the commit pin, with ruby poisoned as well as clean, and a forged manifest on disk changes nothing; a process a base script leaves behind -- in its session, daemonised, or out of its session with a cleared environment -- fails the step and is killed, even when the script plants a bogus group id, and a script that kills its own wrapper fails the step; the pull request tree changed by an earlier script fails the step; a rewrite by the last script, a tampered base checkout and a hidden file are caught; planted loader variables never reach a base script; a gem or node module planted in HOME by one base script is gone before the next, and a HOME replaced by a link is removed without following it; and an existing node is kept only when root alone can change it'
if [[ "${home_node_skipped}" == yes ]]; then
  echo 'base-policy isolation: the node HOME case above was NOT exercised on this host: no node'
  [[ "${GITHUB_ACTIONS:-}" != true ]] || exit 1
fi
