# PostgreSQL DBX PG8 measurement

The protected `pg8-measurement.yml` dispatcher accepts one exact private source SHA and a coordinator dispatch key. Its reusable source-read arm starts the fixed PostgreSQL 17 fixture, revokes the read token before project commands, and publishes only fixed numeric measurements.

The arm compiles one selected integration-test target with fixed Cargo arguments. It accepts one compiler artifact only when its package, target name, test kind, executable type, and resolved path under that run's owned target directory match the contract. The binary is invoked directly for paired, legacy, and DBX modes. Legacy and DBX peak RSS is measured around the test binary itself, not Cargo. Each process must report exactly one passed test, no skipped or ignored test, one marker with the fixed mode and 5 warmups/30 samples, and valid finite nonnegative measurements. The paired ratios must meet the 1.10 budget.

The workflow then builds the actual `taurine-desktop` release executable twice with the same source, Linux target, locked dependencies, and UAT configuration, using separate target directories. The second build adds only `taurine-app/dbx-pg`. It publishes executable byte sizes and their signed delta; it does not upload binaries or raw test output.

The public parser fixtures exercise malformed counts and markers, skipped tests, nonfinite values, duplicate output, failed runs, ambiguous artifacts, and path escapes. These fixtures validate the control-plane parser; they do not claim hosted performance measurements. A hosted run is the evidence for the private source SHA named in that run.
