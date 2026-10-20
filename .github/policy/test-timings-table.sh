#!/usr/bin/env bash
# Fixtures for the Timings table (the `table` mode of .github/actions/timings).
#
# The table lists each concern's queue time (job start minus job creation), duration and baseline.
# Runs from main and from the untrusted ref have separate baselines, because an untrusted run restores
# no cache and compiles cold: comparing it with the warm main baseline raised false drift warnings
# (survey 8.6). These fixtures run the reviewed step against a stub `gh` that returns a synthetic job
# listing, and prove:
#   - the queue column is start minus creation, `-` when a job has no creation time, and never negative;
#   - a main run is compared with the main baseline;
#   - an untrusted run is compared with the untrusted baseline alone, and a concern missing from it
#     is listed with no comparison, never against the main baseline;
#   - an untrusted run with no untrusted baseline at all keeps the main baseline (other platforms);
#   - the long-pole job names (`validate-long-*`, `validate-rust-long-*`) are matched by the dispatchers' patterns;
#   - the slow-job warning keeps its 25% and two-minute thresholds, and the table never fails the step.
# Run from the repository root (the policy workflow does).
set -euo pipefail
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
ruby -ryaml -e '
  action = YAML.safe_load(File.read(".github/actions/timings/action.yml"), aliases: false)
  step = action.fetch("runs").fetch("steps").find { |s| s["name"] == "Tabulate timings against the baseline" } or abort "no table step"
  File.write(ARGV.fetch(0), step.fetch("run"))
' "${work}/table.sh"

mkdir -p "${work}/bin"
cat > "${work}/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub: the jobs listing of the fixture run, whatever the arguments.
cat "${FIXTURE_JOBS}"
STUB
chmod +x "${work}/bin/gh"

# Jobs: name, created, started, completed. Seconds after 12:00:00.
mkjobs() {
  ruby -rjson -e '
    base = Time.utc(2026, 10, 19, 12, 0, 0)
    t = ->(s) { s.nil? ? nil : (base + s).strftime("%Y-%m-%dT%H:%M:%SZ") }
    rows = [
      ["validate-long-main (rust-app-1) / Linux rust-app-1", 0, 3, 2003],
      ["validate-long-untrusted (rust-db) / Linux rust-db", 0, 130, 1530],
      ["validate-untrusted (contracts) / Linux contracts", 0, 10, 160],
      ["validate-untrusted (rust-net) / Linux rust-net", nil, 20, 150],
      ["validate-untrusted (e2e-critical) / Linux e2e-critical", 50, 40, 1100],
      ["validate-rust-long-main (rust-app-2) / Linux rust-app-2", 0, 0, 100]
    ]
    jobs = rows.map { |name, created, started, completed| { "name" => name, "conclusion" => "success", "created_at" => t.(created), "started_at" => t.(started), "completed_at" => t.(completed) } }
    jobs << { "name" => "Result", "conclusion" => "success", "created_at" => t.(0), "started_at" => t.(1), "completed_at" => t.(2) }
    puts JSON.generate({ "jobs" => jobs })
  ' > "${work}/jobs.json"
}
mkjobs

MAIN_BASELINE='{"rust-app-1":1981,"rust-app-2":100,"rust-db":839,"contracts":95,"rust-net":124,"e2e-critical":744}'
UNTRUSTED_BASELINE='{"rust-db":1300,"contracts":150,"e2e-critical":1050}'
PATTERN='^validate(-rust)?(-long)?-(main|untrusted) \(.+\) / Linux (?<concern>.+)$'

run_table() { # run_table REF UNTRUSTED_BASELINE
  : > "${work}/summary.md"
  rc=0
  PATH="${work}/bin:${PATH}" FIXTURE_JOBS="${work}/jobs.json" GITHUB_STEP_SUMMARY="${work}/summary.md" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1 \
    GITHUB_REF="$1" GH_TOKEN=x LABEL=Linux BASELINE_SECONDS="${MAIN_BASELINE}" BASELINE_SECONDS_UNTRUSTED="$2" NAME_PATTERN="${PATTERN}" \
    bash "${work}/table.sh" >"${work}/stdout.txt" 2>"${work}/stderr.txt" || rc=$?
  summary="$(cat "${work}/summary.md")"; stdout="$(cat "${work}/stdout.txt")"
  [[ "${rc}" -eq 0 ]] || { echo "timings table failed (exit ${rc}): $(cat "${work}/stderr.txt")" >&2; exit 1; }
}
row() { grep -F "| $1 |" <<<"${summary}" || { echo "timings table has no row for $1: ${summary}" >&2; exit 1; }; }
expect_row() { # expect_row CONCERN TEXT...
  local concern="$1" line; shift
  line="$(row "${concern}")"
  for text in "$@"; do grep -qF -- "${text}" <<<"${line}" || { echo "timings row ${concern} lacks '${text}': ${line}" >&2; exit 1; }; done
}

# A main run: the main baseline, the queue column, and the long-pole job names matched.
run_table refs/heads/main '{}'
grep -qF '| Concern | Queue | Duration | Baseline | Conclusion |' <<<"${summary}" || { echo 'the table has no Queue column' >&2; exit 1; }
grep -qF 'Baseline: main' <<<"${summary}"
expect_row rust-app-1 '0m03s' '33m20s' '33m01s'
expect_row rust-db '2m10s' '23m20s' '13m59s (SLOWER)'
expect_row contracts '0m10s' '2m30s' '1m35s'
# contracts: 150 s against 95 s is over 25% but only 55 s over, under the two-minute floor: no flag.
if grep -qF 'SLOWER' <<<"$(row contracts)"; then echo 'contracts is under the two-minute floor and must not be flagged' >&2; exit 1; fi
if grep -qF 'Slow job::Linux contracts' <<<"${stdout}"; then echo 'contracts raised a warning under the two-minute floor' >&2; exit 1; fi
expect_row rust-net '-' '2m10s' '2m04s'
expect_row e2e-critical '0m00s' '17m40s' '12m24s (SLOWER)'
expect_row rust-app-2 '0m00s' '1m40s'
if grep -qF '| Result |' <<<"${summary}"; then echo 'a job outside the pattern was tabulated' >&2; exit 1; fi
grep -qF 'Longest queue: 2m10s.' <<<"${summary}" || { echo 'the longest queue line is wrong' >&2; exit 1; }
grep -qF '::warning title=Slow job::Linux rust-db' <<<"${stdout}"

# An untrusted run with an untrusted baseline: that baseline alone, no comparison for a missing concern.
run_table refs/heads/untrusted "${UNTRUSTED_BASELINE}"
grep -qF 'Baseline: untrusted' <<<"${summary}"
expect_row rust-db '2m10s' '23m20s' '21m40s'
if grep -qF 'SLOWER' <<<"$(row rust-db)"; then echo 'rust-db is within its untrusted baseline and must not be flagged' >&2; exit 1; fi
expect_row contracts '0m10s' '2m30s' '2m30s'
if grep -qF 'SLOWER' <<<"$(row contracts)"; then echo 'contracts is on its untrusted baseline and must not be flagged' >&2; exit 1; fi
expect_row rust-app-1 '0m03s' '33m20s' 'none'
if grep -qF '33m01s' <<<"$(row rust-app-1)"; then echo 'an untrusted run used the warm main baseline for a concern missing from the untrusted one' >&2; exit 1; fi
expect_row rust-net '-' 'none'
if grep -qF 'Slow job::Linux rust-app-1' <<<"${stdout}"; then echo 'rust-app-1 has no untrusted baseline and must raise no warning' >&2; exit 1; fi

# An untrusted run for a platform with no untrusted baseline keeps the main baseline.
run_table refs/heads/untrusted '{}'
grep -qF 'Baseline: main' <<<"${summary}"
expect_row rust-app-1 '33m01s'

# A negative queue (clock skew between creation and start) is clamped to zero, not printed negative.
expect_row e2e-critical '0m00s'

echo 'timings table: queue column, separate main and untrusted baselines, long-pole name patterns and warning thresholds behave as specified'
