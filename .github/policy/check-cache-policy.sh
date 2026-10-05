#!/usr/bin/env bash
# The reviewed cargo and NuGet source cache policy (sourced).

check_cache_policy() {
  local workflow="$1" cache_paths_ok cache_line save_if flat

  # Cache policy (a deliberate, narrow exception). Source-bearing
  # jobs may use ONLY actions/cache/restore and actions/cache/save
  # (never the combined actions/cache, whose implicit post-step save
  # cannot be conditioned or audited), and ONLY for cargo's
  # downloaded third-party sources: the registry index, the registry
  # `.crate` archives and the git dependency databases under Cargo
  # home. Compiled output (target/), extracted sources and anything
  # under the checked-out private source must never be cached: a
  # cache entry is readable by later runs, and compiled private code
  # must not leave the runner. Third-party archives are re-verified
  # against the private Cargo.lock checksums after every restore
  # (the verify step below), and the save step is limited to main.
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
      echo "Cache steps may only name registry/index, registry/cache and git/db under the located Cargo home: $workflow" >&2
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
