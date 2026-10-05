#!/usr/bin/env bash
# The reviewed cargo and NuGet source cache policy (sourced).

check_cache_policy() {
  local workflow="$1" cache_paths_ok cache_line save_if flat

  # Cache policy (a deliberate, narrow exception). Source-bearing
  # jobs may use ONLY actions/cache/restore and actions/cache/save
  # (never the combined actions/cache, whose implicit post-step save
  # cannot be conditioned or audited), and ONLY for:
  # - cargo's downloaded third-party sources: the registry index, the
  #   registry `.crate` archives and the git dependency databases under
  #   Cargo home, re-verified against the private Cargo.lock checksums
  #   after every restore;
  # - compiled third-party crates (2026-10-05, approved): the deps/,
  #   build/ and .fingerprint/ directories of the debug profile under the
  #   located target directory, which is always outside the private
  #   checkout. The rust-target-cache composite strips every workspace,
  #   path and vendored crate after restore and before save, and a proof
  #   step fails the job if a workspace crate name, a private path or an
  #   executable would be saved. One exact key, no restore-keys.
  # Compiled private code, extracted sources and anything under the
  # checked-out private source must never be cached: a cache entry is
  # readable by later runs. Every save is limited to main, to a miss,
  # and to a source SHA on a protected private branch (the
  # source-checkout ancestry answer, fixed before project code runs).
  if grep -nE 'actions/cache([^/]|$)|actions/cache/(restore|save)@' "$workflow" | grep -vE 'actions/cache/(restore|save)@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6\.1\.0$'; then
    echo "Only the reviewed pinned actions/cache/restore and actions/cache/save are allowed in source-bearing workflows: $workflow" >&2
    exit 1
  fi
  if grep -nE 'actions/cache/' "$workflow" | grep -vE 'actions/cache/(restore|save)@'; then
    echo "Unreviewed actions/cache sub-action in $workflow" >&2
    exit 1
  fi
  if grep -qE 'actions/cache/' "$workflow"; then
    cache_paths_ok=1
    # Every line of every cache step that names a path must be one of
    # the three allowed Cargo-home locations; the `with:` of each cache
    # step is inspected line by line from its `uses:` to the next step.
    while IFS= read -r cache_line; do
      case "$cache_line" in
        *'steps.cargo-home.outputs.dir }}/registry/index'|*'steps.cargo-home.outputs.dir }}/registry/cache'|*'steps.cargo-home.outputs.dir }}/git/db') ;;
        '${{ steps.cargo-target.outputs.dir }}/debug/deps'|'${{ steps.cargo-target.outputs.dir }}/debug/build'|'${{ steps.cargo-target.outputs.dir }}/debug/.fingerprint') ;;
        # The KeelDock concern caches only NuGet's downloaded third-party
        # package folder (restored packages, their .nupkg archives and
        # metadata): never bin/, obj/, publish output or anything under the
        # checked-out private source. Each restored package is re-verified
        # against the private packages.lock.json hashes before use. No other
        # workflow may name this path.
        [~]/.nuget/packages)
          if [[ "$workflow" != ".github/workflows/keeldock-validation-concern.yml" && "$workflow" != "./.github/workflows/keeldock-validation-concern.yml" ]]; then
            cache_paths_ok=0; echo "NuGet cache path outside the KeelDock concern: $cache_line" >&2
          fi
          ;;
        *) cache_paths_ok=0; echo "Disallowed cache path line: $cache_line" >&2 ;;
      esac
    done < <(awk '
      /^      - name:/ { in_cache = 0; in_path = 0 }
      /uses:[[:space:]]*actions\/cache\// { in_cache = 1; next }
      in_cache && /^[[:space:]]+path:/ { in_path = 1; next }
      in_cache && in_path && /^[[:space:]]+(key|restore-keys|enableCrossOsArchive|fail-on-cache-miss|lookup-only):/ { in_path = 0 }
      in_cache && in_path && NF { sub(/^[[:space:]]+/, ""); print "            " $0 }
    ' "$workflow" | sed -E 's/^ +//')
    if (( ! cache_paths_ok )); then
      echo "Cache steps may only name registry/index, registry/cache and git/db under the located Cargo home, or debug/deps, debug/build and debug/.fingerprint under the located target directory: $workflow" >&2
      exit 1
    fi
    if grep -nE 'enableCrossOsArchive|fail-on-cache-miss|lookup-only' "$workflow"; then
      echo "Unexpected cache option in $workflow" >&2
      exit 1
    fi
    # Every save must be conditioned on the protected main branch, and
    # every restore must be followed by the Cargo.lock verification.
    if ! grep -qE "github\.ref == 'refs/heads/main' &&.*cache-hit != 'true'" "$workflow"; then
      echo "actions/cache/save must be guarded by the main branch and a cache miss: $workflow" >&2
      exit 1
    fi
    # The save condition is a conjunction: main must be a top-level term. An
    # `||` outside parentheses would let one alternative skip the main guard
    # (the bug `A && B && C || D && E` had), so it is rejected outright.
    while IFS= read -r save_if; do
      flat="$save_if"
      while [[ "$flat" =~ \([^()]*\) ]]; do
        flat="${flat//${BASH_REMATCH[0]}/}"
      done
      if [[ "$save_if" != *"github.ref == 'refs/heads/main'"* || "$flat" == *'||'* ]]; then
        echo "The cache save condition must require the main branch as a top-level term, with no unparenthesised ||: $save_if" >&2
        exit 1
      fi
    done < <(awk '/^      - name:/ { cond = "" } /^[[:space:]]+if:/ { cond = $0 } /uses:[[:space:]]*actions\/cache\/save@/ { print cond }' "$workflow")
    # Every cargo cache save also requires the protected-ancestry answer of the
    # source checkout (KeelDock's NuGet cache has its own inline checkout).
    if [[ "$workflow" != *keeldock-validation-concern.yml ]]; then
      while IFS= read -r save_if; do
        if [[ "$save_if" != *"steps.verified-source.outputs.protected-ancestor == 'true'"* ]]; then
          echo "A cargo cache save must require the protected-ancestry answer: $save_if" >&2
          exit 1
        fi
      done < <(awk '/^      - name:/ { cond = "" } /^[[:space:]]+if:/ { cond = $0 } /uses:[[:space:]]*actions\/cache\/save@/ { print cond }' "$workflow")
    fi
    # The compiled-dependency cache: one exact key from the locate step and no
    # restore-keys; every save follows a successful strip-and-prove step; the
    # restore is followed by the restore-time strip.
    if grep -qF 'steps.cargo-target.outputs.dir' "$workflow"; then
      while IFS='|' read -r kind restore_keys key cond; do
        if [[ "$restore_keys" != 0 ]]; then
          echo "The compiled-dependency cache must not have restore-keys: $workflow" >&2
          exit 1
        fi
        if [[ "$key" != *'key: ${{ steps.cargo-target.outputs.key }}' ]]; then
          echo "The compiled-dependency cache key must be the locate step's exact key: $key" >&2
          exit 1
        fi
        if [[ "$kind" == save && "$cond" != *"steps.cargo-target-strip.outcome == 'success'"* ]]; then
          echo "A compiled-dependency save must require the strip-and-prove step: $cond" >&2
          exit 1
        fi
      done < <(awk '
        function flush() { if (cache && target) print kind "|" rk "|" key "|" cond; cache = 0; target = 0; rk = 0; key = ""; cond = ""; kind = "" }
        /^      - name:/ { flush() }
        /^[[:space:]]+if:/ { cond = $0 }
        /uses:[[:space:]]*actions\/cache\/save@/ { cache = 1; kind = "save" }
        /uses:[[:space:]]*actions\/cache\/restore@/ { cache = 1; kind = "restore" }
        /steps\.cargo-target\.outputs\.dir/ { target = 1 }
        /^[[:space:]]+restore-keys:/ { rk = 1 }
        /^[[:space:]]+key:/ { key = $0 }
        END { flush() }
      ' "$workflow")
      for required in 'Strip workspace crates from the restored dependency cache' 'Strip and prove the compiled dependency cache'; do
        if ! grep -qF "name: ${required}" "$workflow"; then
          echo "A compiled-dependency cache needs the step '${required}': $workflow" >&2
          exit 1
        fi
      done
    fi
    if [[ "$workflow" == ".github/workflows/keeldock-validation-concern.yml" || "$workflow" == "./.github/workflows/keeldock-validation-concern.yml" ]]; then
      if ! grep -q 'Verify restored NuGet packages against the lock files' "$workflow"; then
        echo "A restored NuGet cache must be verified against packages.lock.json before use: $workflow" >&2
        exit 1
      fi
      if grep -nE '^[[:space:]]+path:.*(bin|obj|publish|artifacts)([/[:space:]]|$)' "$workflow"; then
        echo "The KeelDock cache must never name build or publish output: $workflow" >&2
        exit 1
      fi
    elif ! grep -q 'Verify restored crate archives against Cargo.lock' "$workflow"; then
      echo "A restored cache must be verified against Cargo.lock before use: $workflow" >&2
      exit 1
    fi
  fi
}
