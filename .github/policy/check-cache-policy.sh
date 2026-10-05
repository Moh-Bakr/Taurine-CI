#!/usr/bin/env bash
# The reviewed cargo and NuGet source cache policy (sourced).

# Finding H1 (2026-10-05), with ref isolation: unprotected SHAs run from the untrusted ref,
# whose cache scope main never reads, and main runs only protected-ancestry SHAs. So the cargo
# source, compiled-dependency and NuGet caches run only on main for a protected source SHA: every
# restore, save and helper step of them has both exact top-level terms below, and no `||` at the
# top level (which would re-open the gate). Defined after cond_top_terms, which it calls.
cache_gated_to_protected_main() {
  local cond="$1"
  cond_requires "$cond" "github.ref == 'refs/heads/main'" \
    && cond_requires "$cond" "steps.verified-source.outputs.protected-ancestor == 'true'"
}
GATE_RULE="runs only on main for a protected source SHA (ref isolation, finding H1): the step must have the top-level terms github.ref == 'refs/heads/main' and steps.verified-source.outputs.protected-ancestor == 'true', with no unparenthesised ||"

# Built-in action caches (finding H1 extended, 2026-10-05). `setup-node` (v5 and later) and the
# other `setup-*` actions restore the package manager's downloads from the same cache scope an
# unprotected run can write, and their restore extracts with absolute paths exactly as
# actions/cache does. So every setup-node step must say `package-manager-cache: false`, and no
# step may turn a setup-* cache on with `cache:`, `cache-dependency-path:` or `cache-read-only:`.
# Prints the offending step and returns 1.
check_builtin_cache_off() {
  local file="$1"
  if grep -nE '^[[:space:]]+(cache|cache-dependency-path|cache-read-only|cache-write-only):' "$file"; then
    echo "A setup action's built-in cache is disabled until ref isolation exists (finding H1): $file" >&2
    return 1
  fi
  if ! awk '
    function flush() { if (need && !off) { print "setup-node step without package-manager-cache: false at line " need; bad = 1 } need = 0; off = 0 }
    /^[[:space:]]*- / { flush() }
    /uses:[[:space:]]*actions\/setup-node@/ { need = NR }
    /^[[:space:]]+package-manager-cache:[[:space:]]*false[[:space:]]*$/ { off = 1 }
    END { flush(); exit bad }
  ' "$file"; then
    echo "Every setup-node step must set package-manager-cache: false (finding H1): $file" >&2
    return 1
  fi
}

# The top-level conjuncts of an `if:` condition, one per line. The `${{ }}` wrapper is
# dropped, every parenthesised group (a call's arguments, an `(a || b)` alternative, a
# negated `!(...)`) is removed whole, and what remains is split on `&&`. A required term
# therefore counts only when it stands alone at the top level: `(x == 'true' || true)`,
# `!(x == 'true')` and `x == 'true' || true` do not yield the exact term `x == 'true'`.
# Returns 1 (no output) when an `||` remains at the top level.
cond_top_terms() {
  local flat="$1" term
  flat="${flat#*if:}"
  flat="${flat#"${flat%%[![:space:]]*}"}"
  flat="${flat%"${flat##*[![:space:]]}"}"
  if [[ "$flat" == '${{'*'}}' ]]; then
    flat="${flat#'${{'}"; flat="${flat%'}}'}"
  fi
  while [[ "$flat" =~ \([^()]*\) ]]; do
    flat="${flat//"${BASH_REMATCH[0]}"/}"
  done
  [[ "$flat" != *'||'* ]] || return 1
  while IFS= read -r term; do
    term="${term#"${term%%[![:space:]]*}"}"
    term="${term%"${term##*[![:space:]]}"}"
    printf '%s\n' "$term"
  done <<<"${flat//&&/$'\n'}"
}

# True when the condition has the exact top-level conjunct $2.
cond_requires() {
  local terms
  terms="$(cond_top_terms "$1")" || return 1
  grep -qxF -- "$2" <<<"$terms"
}

check_cache_policy() {
  local workflow="$1" cache_paths_ok cache_line save_if flat

  # A setup action's built-in cache is off as well (check_builtin_cache_off).
  check_builtin_cache_off "$workflow" || exit 1

  # Cache policy (a deliberate, narrow exception). Source-bearing
  # jobs may use ONLY actions/cache/restore and actions/cache/save
  # (never the combined actions/cache, whose implicit post-step save
  # cannot be conditioned or audited), and ONLY for:
  # - cargo's downloaded third-party `.crate` archives (registry/cache under
  #   Cargo home), re-hashed against the private Cargo.lock checksums after
  #   every restore and saved before any project code runs;
  # - compiled third-party crates (2026-10-05, approved; main and protected
  #   SHAs only, finding H1, see cache_gated_to_protected_main): the deps/,
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
        # Only the `.crate` archives: each is re-hashed against Cargo.lock on restore. The
        # registry index and git databases cannot be verified that way (finding L1).
        '${{ steps.cargo-home.outputs.dir }}/registry/cache') ;;
        '${{ steps.cargo-target.outputs.dir }}/debug/deps'|'${{ steps.cargo-target.outputs.dir }}/debug/build'|'${{ steps.cargo-target.outputs.dir }}/debug/.fingerprint') ;;
        # The KeelDock concern caches only NuGet's downloaded third-party
        # package folder (restored packages, their .nupkg archives and
        # metadata): never bin/, obj/, publish output or anything under the
        # checked-out private source. Each restored .nupkg is re-hashed against
        # the private packages.lock.json contentHash and the extracted folders
        # are discarded before use. No other workflow may name this path.
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
      echo "Cache steps may only name registry/cache under the located Cargo home, debug/deps, debug/build and debug/.fingerprint under the located target directory, or the KeelDock NuGet folder: $workflow" >&2
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
      if ! cond_requires "$save_if" "github.ref == 'refs/heads/main'"; then
        echo "The cache save condition must require the main branch as a top-level term, with no unparenthesised ||: $save_if" >&2
        exit 1
      fi
    done < <(awk '/^      - name:/ { cond = "" } /^[[:space:]]+if:/ { cond = $0 } /uses:[[:space:]]*actions\/cache\/save@/ { print cond }' "$workflow")
    # Every cache save, cargo and NuGet alike, requires the protected-ancestry
    # answer of the source checkout (KeelDock's inline checkout gives the same
    # answer under the same step id), fixed before any project code ran.
    while IFS= read -r save_if; do
      if ! cond_requires "$save_if" "steps.verified-source.outputs.protected-ancestor == 'true'"; then
        echo "A cache save must require the protected-ancestry answer as an exact top-level term: $save_if" >&2
        exit 1
      fi
    done < <(awk '/^      - name:/ { cond = "" } /^[[:space:]]+if:/ { cond = $0 } /uses:[[:space:]]*actions\/cache\/save@/ { print cond }' "$workflow")
    # The cargo source cache saves under the key its restore step computed before any
    # project code ran (finding L2), never a hashFiles evaluated at save time.
    while IFS= read -r key; do
      if [[ "$key" != *'key: ${{ steps.cargo-sources.outputs.cache-primary-key }}' ]]; then
        echo "The cargo source cache save key must be the restore step's cache-primary-key: $key" >&2
        exit 1
      fi
    done < <(awk '
      function flush() { if (save && home) print key; save = 0; home = 0; key = "" }
      /^      - name:/ { flush() }
      /uses:[[:space:]]*actions\/cache\/save@/ { save = 1 }
      /steps\.cargo-home\.outputs\.dir/ { home = 1 }
      /^[[:space:]]+key:/ { key = $0 }
      END { flush() }
    ' "$workflow")
    # Finding H1, extended: actions/cache extracts with absolute paths and a cache write needs
    # only the runner's runtime token, so an entry is only as trustworthy as whoever can write
    # main's scope. The restore, the completion step that only exists to feed the save, and the
    # save each run only on main for a protected source SHA (cache_gated_to_protected_main).
    while IFS= read -r cond; do
      if ! cache_gated_to_protected_main "$cond"; then
        echo "The cargo source cache ${GATE_RULE}: $cond" >&2
        exit 1
      fi
    done < <(awk '
      function flush() { if (home || completion) print (cond == "" ? "<no if>" : cond); home = 0; completion = 0; cond = "" }
      /^      - name:/ { flush() }
      /^      - name: Complete the third-party source set before saving/ { completion = 1 }
      /^[[:space:]]+if:/ { cond = $0 }
      /uses:[[:space:]]*actions\/cache\/(restore|save)@/ { cache = 1 }
      /steps\.cargo-home\.outputs\.dir/ { if (cache) home = 1 }
      /^      - name:/ { cache = 0 }
      END { flush() }
    ' "$workflow")
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
        if ! cache_gated_to_protected_main "$cond"; then
          echo "The compiled-dependency cache ${GATE_RULE}: $cond" >&2
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
      # The restore-time and save-time strips of the composite are gated off with them.
      while IFS= read -r cond; do
        if ! cache_gated_to_protected_main "$cond"; then
          echo "The compiled-dependency strip step ${GATE_RULE}: $cond" >&2
          exit 1
        fi
      done < <(awk '
        function flush() { if (composite && mode != "locate") print cond; composite = 0; mode = ""; cond = "" }
        /^      - name:/ { flush() }
        /^[[:space:]]+if:/ { cond = $0 }
        /uses:[[:space:]]*\.\/\.github\/actions\/rust-target-cache/ { composite = 1 }
        /^[[:space:]]+mode:/ { mode = $2 }
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
      # Findings H1/M1 (2026-10-05): the NuGet restore and save stay off until
      # unprotected SHAs run from a ref whose cache scope main never reads. The
      # save key is the restore step's primary key (computed before project
      # code), never a hashFiles evaluated after it.
      while IFS='|' read -r cond key; do
        if ! cache_gated_to_protected_main "$cond"; then
          echo "The NuGet cache ${GATE_RULE}: $cond" >&2
          exit 1
        fi
        if [[ -n "$key" && "$key" != *'key: ${{ steps.nuget-packages.outputs.cache-primary-key }}' ]]; then
          echo "The NuGet cache save key must be the restore step's cache-primary-key: $key" >&2
          exit 1
        fi
      done < <(awk '
        function flush() { if (cache) print cond "|" (kind == "save" ? key : ""); cache = 0; key = ""; cond = ""; kind = "" }
        /^      - name:/ { flush() }
        /^[[:space:]]+if:/ { cond = $0 }
        /uses:[[:space:]]*actions\/cache\/save@/ { cache = 1; kind = "save" }
        /uses:[[:space:]]*actions\/cache\/restore@/ { cache = 1; kind = "restore" }
        /^[[:space:]]+key:/ { key = $0 }
        END { flush() }
      ' "$workflow")
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
