#!/usr/bin/env bash
# KeelDock Cloud, the second private source: its own, stricter checks (sourced).

check_keeldock_concern() {
  local workflow="$1"

  # KeelDock Cloud, the second private source: its own, stricter checks.
  # The generic checks above prove the shape of a source-read workflow; these
  # pin the facts that make THIS one safe to run project code in.
  if [[ "$workflow" == ".github/workflows/keeldock-validation-concern.yml" || "$workflow" == "./.github/workflows/keeldock-validation-concern.yml" ]]; then
    # The source identity is the numeric repository id, owner and name, checked
    # against the API after checkout. A changed constant would point the whole
    # lane, and its token, at a different repository.
    for constant in \
      "SOURCE_REPOSITORY_ID: '1377321992'" \
      "SOURCE_REPOSITORY_OWNER: Moh-Bakr" \
      "SOURCE_REPOSITORY_NAME: keeldock-cloud"; do
      if ! grep -qxF "  ${constant}" "$workflow"; then
        echo "The KeelDock concern must pin the reviewed source identity constant (${constant}): $workflow" >&2
        exit 1
      fi
    done
    if ! grep -qE '^    environment:[[:space:]]+\$\{\{ inputs\.environment \}\}[[:space:]]*$' "$workflow"; then
      echo "The KeelDock concern must take its environment from the environment input: $workflow" >&2
      exit 1
    fi
    if grep -nE 'upload-artifact|download-artifact|actions/cache@' "$workflow"; then
      echo "The KeelDock concern must not upload, download or cache source-bearing artifacts: $workflow" >&2
      exit 1
    fi
    # Step order. Every step must be named so the order can be read. The steps
    # before the verify-and-revoke step may only be the reviewed pre-source ones:
    # anything else (a setup action, a project command, a script) would run before
    # the token is verified and destroyed.
    verify_name='Verify identity, exact checkout, and revoke source token'
    if (( $(grep -cE '^      - ' "$workflow") != $(grep -cE '^      - name:' "$workflow") )); then
      echo "Every KeelDock concern step must be named so its order can be verified: $workflow" >&2
      exit 1
    fi
    if (( $(grep -cE "^      - name: ${verify_name}\$" "$workflow") != 1 )); then
      echo "The KeelDock concern must have exactly one verify-and-revoke step: $workflow" >&2
      exit 1
    fi
    if ! awk -v verify="${verify_name}" '
      /^      - / { in_verify = ($0 == "      - name: " verify) }
      in_verify && /^        if:[[:space:]]+always\(\)[[:space:]]*$/ { ok = 1 }
      END { exit !ok }
    ' "$workflow"; then
      echo "The KeelDock verify-and-revoke step must run with if: always(): $workflow" >&2
      exit 1
    fi
    while IFS= read -r step_name; do
      case "$step_name" in
        'Start the concern timer'|'Check out public control plane'|'Validate protected call input'|'Mint read-only private-source token'|'Check out exact private source SHA') ;;
        "${verify_name}") break ;;
        *)
          echo "Step '${step_name}' precedes the KeelDock token revoke; project code and setup actions must run only after it: $workflow" >&2
          exit 1
          ;;
      esac
    done < <(sed -nE 's/^      - name:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$workflow")
    # Nothing project-shaped may sit in the reviewed pre-source steps, and the
    # source checkout must be the only step that names the private repository.
    if awk -v verify="${verify_name}" '
      /^      - name:/ { name = substr($0, 15) }
      name == verify { exit }
      /^        run:/ && name != "Validate protected call input" && name != "Start the concern timer" { bad = 1 }
      /^          (npm|dotnet|bash scripts|cargo) / { bad = 1 }
      END { exit !bad }
    ' "$workflow"; then
      echo "A KeelDock step before the token revoke runs project-shaped commands: $workflow" >&2
      exit 1
    fi
  fi
}
