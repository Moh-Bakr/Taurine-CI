#!/usr/bin/env bash
# Action references: every `uses:` is a full commit SHA and an exact reviewed reference (sourced).

check_action_references() {
  local workflow="$1" reference

  if grep -nE '^\s*uses:\s*[^#[:space:]]+@(v[0-9]|main|master|stable|latest|[[:alnum:]_.-]+)$' "$workflow"; then
    echo "Every Action reference must use a full 40-character commit SHA: $workflow" >&2
    exit 1
  fi

  while IFS= read -r reference; do
    case "$reference" in
      actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1) ;;
      # The one reviewed cache exception (actions/cache v6.1.0), split
      # into restore and save so each use is explicit. See the cache
      # policy block below for the only paths either may touch.
      actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9) ;;
      actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9) ;;
      actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1) ;;
      actions/setup-node@820762786026740c76f36085b0efc47a31fe5020) ;;
      actions/setup-dotnet@a98b56852c35b8e3190ac28c8c2271da59106c68) ;;
      ./.github/workflows/windows-validation-concern.yml) ;;
      # Local composite actions are reviewed in this repository; each one is added
      # here deliberately and held to the composite rules below.
      ./.github/actions/source-checkout) ;;
      ./.github/actions/sanitize) ;;
      ./.github/actions/concern-report) ;;
      ./.github/actions/timings) ;;
      ./.github/actions/rust-toolchain) ;;
      ./.github/actions/node-setup) ;;
      ./.github/actions/run-result) ;;
      ./.github/workflows/linux-validation-concern.yml) ;;
      ./.github/workflows/select-concerns.yml) ;;
      ./.github/actions/select-concerns) ;;
      ./.github/actions/scan-concern) ;;
      ./.github/actions/linux-concern-js) ;;
      ./.github/actions/linux-concern-e2e) ;;
      ./.github/actions/linux-concern-rust) ;;
      ./.github/actions/windows-concern-rust) ;;
      ./.github/actions/macos-concern-rust) ;;
      ./.github/actions/macos-concern-js) ;;
      ./.github/actions/vendor-fetch) ;;
      ./.github/actions/verify-cargo-cache) ;;
      ./.github/actions/linux-test-identities) ;;
      ./.github/workflows/keeldock-validation-concern.yml) ;;
      ./.github/workflows/live-proof-arm.yml) ;;
      ./.github/actions/mobile-report) ;;
      ./.github/actions/android-sdk-setup) ;;
      ./.github/actions/ios-project-init) ;;
      ./.github/actions/live-build) ;;
      ./.github/actions/live-run) ;;
      ./.github/actions/live-summary) ;;
      ./.github/actions/live-start-ibm) ;;
      ./.github/actions/live-start-iris) ;;
      ./.github/actions/live-start-mpp) ;;
      ./.github/actions/live-start-pg) ;;
      ./.github/actions/live-start-rocketmq) ;;
      ./.github/actions/live-start-sql) ;;
      ./.github/actions/keeldock-restore) ;;
      ./.github/actions/keeldock-build-format) ;;
      ./.github/actions/keeldock-test-suites) ;;
      ./.github/actions/keeldock-supply-chain) ;;
      ./.github/actions/keeldock-apphost) ;;
      ./.github/actions/keeldock-contracts-publish) ;;
      ./.github/actions/keeldock-summary) ;;
      ./.github/actions/keeldock-proof) ;;
      ./.github/actions/keeldock-nuget-verify) ;;
      ./.github/actions/egress-audit) ;;
      '') ;;
      *)
        echo "Unreviewed or mutable Action reference in $workflow: $reference" >&2
        exit 1
        ;;
    esac
  done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^#[:space:]]+).*/\1/p' "$workflow")

}
