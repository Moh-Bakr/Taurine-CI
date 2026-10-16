#!/usr/bin/env bash
# The root steps of the base-policy jobs, run with stand-ins for everything that needs root. They
# deny the job user cron and at, stop its user manager, and mask sshd; they must FAIL if ssh is still
# active after the mask, because a base script could then ssh to localhost and start work outside
# the job. That covers every ssh or sshd socket unit (systemd 256 and later generate
# sshd-unix-local.socket and sshd-vsock.socket), and any state that is not inactive, failed or
# masked, `activating` and `reloading` included. Both jobs carry the step, so both copies are run.
# Run from the repository root.
#
# The stand-in sudo runs only what is stateful for this test (systemctl, which keeps a state file and
# can be told that masking fails) and does nothing else; nothing here touches the real machine.
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
  echo "${0##*/}: NOT EXERCISED HERE -- the step runs on Linux; the policy jobs run this"
  [[ "${GITHUB_ACTIONS:-}" != true ]] || exit 1
  exit 0
fi

workflow="${1:-.github/workflows/base-policy.yml}"
step='Deny the job user cron, at and a user systemd manager'
tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/base-policy-root-step-test.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT
stubs="${tmp}/stubs"
mkdir -p "${stubs}"

cat > "${stubs}/sudo" <<'SH'
#!/bin/sh
case "$1" in
  systemctl | ss) exec "$@" ;;
  tee) cat > /dev/null ;;
  *) : ;;
esac
SH
# systemctl keeps one state file per unit; the socket units are the *.socket files.
#   is-active [--quiet] UNIT...     prints each state; exits 0 when any unit is active
#   list-unit-files / list-units    the *.socket units matching the glob arguments (--state=active:
#                                   only the active ones; with --type=socket,service the *.service
#                                   units too). A unit with an `.only-files` marker is listed by the
#                                   first only, one with `.only-units` by the second only.
#       STUB_FAIL          unit-files, units or final: that listing prints an error and exits 1.
#   mask [--now] UNIT...            records the call and stops each unit, except
#       STUB_MASK_LEAVES   names a unit that stays active (service, socket, or a whole unit name),
#       STUB_AFTER_MASK    unit=state pairs: the state a unit is left in instead of inactive,
#       STUB_APPEAR        a unit that comes into being, active, once the mask has run.
cat > "${stubs}/systemctl" <<'SH'
#!/bin/bash
state="${STUB_STATE}"
quiet=no; only_active=no; types=socket
args=()
for a in "$@"; do
  case "${a}" in
    --quiet) quiet=yes ;;
    --state=active) only_active=yes ;;
    --type=*) types="${a#--type=}" ;;
    --all | --no-legend | --plain) ;;
    *) args+=("${a}") ;;
  esac
done
set -- "${args[@]}"
verb="$1"; shift
unit_state() { if [[ -f "${state}/$1" ]]; then cat "${state}/$1"; else echo inactive; fi; }
case "${verb}" in
  is-active)
    any=1
    for unit in "$@"; do
      status="$(unit_state "${unit}")"
      [[ "${quiet}" == yes ]] || echo "${status}"
      [[ "${status}" != active ]] || any=0
    done
    exit "${any}" ;;
  list-unit-files | list-units)
    kind=unit-files
    if [[ "${verb}" == list-units ]]; then if [[ "${only_active}" == yes ]]; then kind=final; else kind=units; fi; fi
    if [[ "${STUB_FAIL:-}" == "${kind}" ]]; then echo "stub systemctl: ${verb} failed" >&2; exit 1; fi
    files=("${state}"/*.socket)
    [[ "${types}" != *service* ]] || files+=("${state}"/*.service)
    for file in "${files[@]}"; do
      [[ -f "${file}" ]] || continue
      unit="${file##*/}"
      [[ "${only_active}" == no || "$(cat "${file}")" == active ]] || continue
      [[ "${verb}" != list-unit-files || ! -e "${file}.only-units" ]] || continue
      [[ "${verb}" != list-units || ! -e "${file}.only-files" ]] || continue
      for pattern in "$@"; do
        # shellcheck disable=SC2053
        if [[ "${unit}" == ${pattern} ]]; then echo "${unit} enabled"; break; fi
      done
    done ;;
  mask)
    echo "mask $*" >> "${state}/calls"
    for unit in "$@"; do
      [[ "${unit}" == --now ]] && continue
      new=inactive
      case "${STUB_MASK_LEAVES:-}" in *"${unit#ssh.}"*) new=active ;; esac
      for pair in ${STUB_AFTER_MASK:-}; do [[ "${pair%%=*}" == "${unit}" ]] && new="${pair#*=}"; done
      echo "${new}" > "${state}/${unit}"
    done
    [[ -z "${STUB_APPEAR:-}" ]] || echo active > "${state}/${STUB_APPEAR}" ;;
  stop) echo inactive > "${state}/$1" ;;
esac
exit 0
SH
printf '#!/bin/sh\nexit 0\n' > "${stubs}/loginctl"
printf '#!/bin/sh\nexit 0\n' > "${stubs}/ss"
# The step reads ptrace_scope, which a container without Yama does not have.
cat > "${stubs}/cat" <<'SH'
#!/bin/sh
if [ "$1" = /proc/sys/kernel/yama/ptrace_scope ]; then echo 1; exit 0; fi
exec /bin/cat "$@"
SH
chmod +x "${stubs}"/*

# step_run JOB: the run script of the step in that job.
step_run() {
  ruby -ryaml -e '
    doc = YAML.safe_load(File.read(ARGV[0]), aliases: false)
    found = doc.fetch("jobs").fetch(ARGV[1]).fetch("steps").select { |s| s["name"] == ARGV[2] }
    abort "#{ARGV[0]}: expected one step #{ARGV[2].inspect} in #{ARGV[1]}, found #{found.length}" unless found.length == 1
    print found.first.fetch("run")
  ' "${workflow}" "$1" "${step}"
}

# run_step JOB: the step with ssh running at the start, in the scenario the caller set up:
#   LEAVES  what the mask fails to stop (service, socket, or a whole unit name)
#   EXTRA   further socket units that are active at the start (generated by newer systemd)
#   AFTER   unit=state pairs: the state a unit is left in after the mask
#   APPEAR  a unit that comes into being, active, once the mask has run
#   FILES_ONLY / UNITS_ONLY  active socket units that only the unit files, or only the loaded units, list
#   FAIL    unit-files, units or final: that systemctl listing fails
LEAVES=''; EXTRA=''; AFTER=''; APPEAR=''; FILES_ONLY=''; UNITS_ONLY=''; FAIL=''
reset() { LEAVES=''; EXTRA=''; AFTER=''; APPEAR=''; FILES_ONLY=''; UNITS_ONLY=''; FAIL=''; }
run_step() {
  local job="$1" dir
  dir="${tmp}/state-${job}-$((++runs))"
  rm -rf "${dir}"; mkdir -p "${dir}"
  echo active > "${dir}/ssh.service"; echo active > "${dir}/ssh.socket"
  for unit in ${EXTRA}; do echo active > "${dir}/${unit}"; done
  for unit in ${FILES_ONLY}; do echo active > "${dir}/${unit}"; : > "${dir}/${unit}.only-files"; done
  for unit in ${UNITS_ONLY}; do echo active > "${dir}/${unit}"; : > "${dir}/${unit}.only-units"; done
  step_run "${job}" > "${tmp}/step.sh"
  rc=0
  env -i PATH="${stubs}:/usr/bin:/bin" HOME="${tmp}" STUB_STATE="${dir}" STUB_MASK_LEAVES="${LEAVES}" \
    STUB_AFTER_MASK="${AFTER}" STUB_APPEAR="${APPEAR}" STUB_FAIL="${FAIL}" \
    bash --noprofile --norc -e -o pipefail "${tmp}/step.sh" > "${tmp}/out" 2>&1 || rc=$?
  state_dir="${dir}"
}
runs=0
expect_pass() {
  run_step "$1"
  [[ "${rc}" -eq 0 ]] || { cat "${tmp}/out" >&2; echo "base-policy root step: $1: $2: the step was refused" >&2; exit 1; }
}
# expect_refused JOB LABEL [TEXT]: the step fails, naming ssh as still active (and TEXT if given).
expect_refused() {
  run_step "$1"
  [[ "${rc}" -ne 0 ]] || { echo "base-policy root step: $1: $2: the step passed" >&2; exit 1; }
  grep -qF 'ssh is still active after it was masked' "${tmp}/out" \
    || { cat "${tmp}/out" >&2; echo "base-policy root step: $1: $2: refused for the wrong reason" >&2; exit 1; }
  if [[ -n "${3:-}" ]] && ! grep -qF "$3" "${tmp}/out"; then
    cat "${tmp}/out" >&2; echo "base-policy root step: $1: $2: the refusal does not name ${3}" >&2; exit 1
  fi
}

# expect_list_failure JOB LABEL TEXT: the step fails with TEXT, and never reaches a verdict that ssh is
# stopped. A listing that errors must not read as "nothing to find".
expect_list_failure() {
  run_step "$1"
  [[ "${rc}" -ne 0 ]] || { echo "base-policy root step: $1: $2: the step passed" >&2; exit 1; }
  grep -qF "$3" "${tmp}/out" || { cat "${tmp}/out" >&2; echo "base-policy root step: $1: $2: not refused for '$3'" >&2; exit 1; }
}

for job in base-policy-fixtures base-policy; do
  reset
  expect_pass "${job}" 'a successful mask'
  grep -qF 'mask --now ssh.service ssh.socket' "${state_dir}/calls" \
    || { echo "base-policy root step: ${job}: the step did not mask ssh.service and ssh.socket" >&2; exit 1; }
  if ! grep -qF 'sshd before: active active' "${tmp}/out" || ! grep -qF 'sshd after: inactive inactive' "${tmp}/out"; then
    cat "${tmp}/out" >&2; echo "base-policy root step: ${job}: the step did not log the state before and after" >&2; exit 1
  fi
  # Ssh still active after the mask -- the service, the socket, or both -- fails the step by name.
  for LEAVES in service socket service,socket; do expect_refused "${job}" "ssh ${LEAVES} left active"; done

  # Newer systemd generates further ssh socket units. They are found, masked by name, and a mask
  # that leaves one running fails the step naming it.
  reset; EXTRA='sshd-unix-local.socket sshd-vsock.socket'
  expect_pass "${job}" 'generated sshd sockets, masked'
  grep -qF 'mask --now ssh.service ssh.socket sshd-unix-local.socket sshd-vsock.socket' "${state_dir}/calls" \
    || { cat "${state_dir}/calls" >&2; echo "base-policy root step: ${job}: the generated sshd sockets were not masked by name" >&2; exit 1; }
  LEAVES='sshd-vsock.socket'; expect_refused "${job}" 'a generated socket left active' sshd-vsock.socket
  # The names come from both the unit files and the loaded units, so a unit only one of them lists is
  # still masked.
  reset; FILES_ONLY='sshd-file.socket'
  expect_pass "${job}" 'a socket only the unit files list'
  grep -qF 'sshd-file.socket' "${state_dir}/calls" || { echo "base-policy root step: ${job}: a socket only the unit files list was not masked" >&2; exit 1; }
  reset; UNITS_ONLY='sshd-loaded.socket'
  expect_pass "${job}" 'a socket only the loaded units list'
  grep -qF 'sshd-loaded.socket' "${state_dir}/calls" || { echo "base-policy root step: ${job}: a socket only the loaded units list was not masked" >&2; exit 1; }
  # One that appears only after the mask is found by the final list of active sockets, not the states.
  reset; APPEAR='sshd-late.socket'; expect_refused "${job}" 'a socket that appears after the mask' sshd-late.socket

  # A listing that fails is a failure, not an empty list. Each of the three is checked on its own.
  reset; FAIL='unit-files'; expect_list_failure "${job}" 'list-unit-files fails' 'could not list the ssh unit files'
  reset; FAIL=units; expect_list_failure "${job}" 'list-units fails' 'could not list the loaded ssh units'
  reset; FAIL=final; expect_list_failure "${job}" 'the final list-units fails' 'could not list the active ssh units'

  # The final list covers services as well as sockets: an ssh@N.service or sshd-*@N.service instance
  # that is already running outlives the mask of its socket. A service that is not ssh is left alone.
  reset; EXTRA='ssh@9.service'; expect_refused "${job}" 'an active ssh@ instance' ssh@9.service
  reset; EXTRA='sshd-session@3.service'; expect_refused "${job}" 'an active sshd-session@ instance' sshd-session@3.service
  reset; EXTRA='cron.service'; expect_pass "${job}" 'an unrelated active service'

  # Only inactive, failed and masked are states that serve no connection. activating and reloading
  # are not, and `is-active --quiet` let both through.
  reset; AFTER='ssh.service=activating'; expect_refused "${job}" 'activating' ssh.service
  reset; AFTER='ssh.socket=reloading'; expect_refused "${job}" 'reloading' ssh.socket
  reset; AFTER='ssh.service=failed'; expect_pass "${job}" 'failed'
  reset; AFTER='ssh.service=masked ssh.socket=masked'; expect_pass "${job}" 'masked'
done

echo 'base-policy root step: both jobs mask every ssh socket and fail unless each is inactive, failed or masked afterwards'
