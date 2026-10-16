#!/usr/bin/env bash
# The root steps of the base-policy jobs, run with stand-ins for everything that needs root. They
# deny the job user cron and at, stop its user manager, and mask sshd; they must FAIL if ssh is still
# active after the mask, because a base script could then ssh to localhost and start work outside
# the job. Both jobs carry the step, so both copies are run. Run from the repository root.
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
# systemctl keeps one state file per unit. `mask --now` stops the units unless STUB_MASK_LEAVES names
# one that stays active (service, socket, or both); is-active exits 0 when any named unit is active.
cat > "${stubs}/systemctl" <<'SH'
#!/bin/bash
state="${STUB_STATE}"
quiet=no
args=()
for a in "$@"; do
  if [[ "${a}" == --quiet ]]; then quiet=yes; else args+=("${a}"); fi
done
set -- "${args[@]}"
verb="$1"; shift
case "${verb}" in
  is-active)
    any=1
    for unit in "$@"; do
      status=inactive
      [[ -f "${state}/${unit}" ]] && status="$(cat "${state}/${unit}")"
      [[ "${quiet}" == yes ]] || echo "${status}"
      [[ "${status}" != active ]] || any=0
    done
    exit "${any}" ;;
  mask)
    echo "mask $*" >> "${state}/calls"
    for unit in "$@"; do
      [[ "${unit}" == --now ]] && continue
      case "${STUB_MASK_LEAVES:-}" in
        *"${unit#ssh.}"*) ;;
        *) echo inactive > "${state}/${unit}" ;;
      esac
    done ;;
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

# run_step JOB LEAVES: the step with ssh running at the start; LEAVES names what the mask fails to stop.
run_step() {
  local job="$1" leaves="$2" dir="${tmp}/state-${1}-${2:-none}"
  rm -rf "${dir}"; mkdir -p "${dir}"
  echo active > "${dir}/ssh.service"; echo active > "${dir}/ssh.socket"
  step_run "${job}" > "${tmp}/step.sh"
  rc=0
  env -i PATH="${stubs}:/usr/bin:/bin" HOME="${tmp}" STUB_STATE="${dir}" STUB_MASK_LEAVES="${leaves}" \
    bash --noprofile --norc -e -o pipefail "${tmp}/step.sh" > "${tmp}/out" 2>&1 || rc=$?
  state_dir="${dir}"
}

for job in base-policy-fixtures base-policy; do
  run_step "${job}" ''
  [[ "${rc}" -eq 0 ]] || { cat "${tmp}/out" >&2; echo "base-policy root step: ${job}: a successful mask was refused" >&2; exit 1; }
  grep -qF 'mask --now ssh.service ssh.socket' "${state_dir}/calls" \
    || { echo "base-policy root step: ${job}: the step did not mask ssh.service and ssh.socket" >&2; exit 1; }
  if ! grep -qF 'sshd before: active active' "${tmp}/out" || ! grep -qF 'sshd after: inactive inactive' "${tmp}/out"; then
    cat "${tmp}/out" >&2; echo "base-policy root step: ${job}: the step did not log the state before and after" >&2; exit 1
  fi
  # Ssh still active after the mask -- the service, the socket, or both -- fails the step by name.
  for leaves in service socket service,socket; do
    run_step "${job}" "${leaves}"
    [[ "${rc}" -ne 0 ]] || { echo "base-policy root step: ${job}: the step passed with ssh ${leaves} still active after the mask" >&2; exit 1; }
    grep -qF 'ssh is still active after it was masked' "${tmp}/out" \
      || { cat "${tmp}/out" >&2; echo "base-policy root step: ${job}: ${leaves} still active: refused for the wrong reason" >&2; exit 1; }
  done
done

echo 'base-policy root step: both jobs mask ssh and fail if the service or the socket is still active afterwards'
