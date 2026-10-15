# frozen_string_literal: true

# The reviewed Action references (required by check-action-uses.rb, not run). One entry per line,
# so a pull request that adds a reviewed local action adds exactly one line here and does not touch
# the check's logic. A remote action is an exact owner/repo[/path]@<40-hex SHA>; a local action or
# reusable workflow is an exact ./.github/... path. Nothing else is accepted: no tag, no branch,
# no wildcard, no docker:// reference.
ACTION_ALLOWLIST = [
  'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1',
  # The one reviewed cache exception (actions/cache v6.1.0), split
  # into restore and save so each use is explicit. See the cache
  # policy (check-cache-policy.sh) for the only paths either may touch.
  'actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9',
  'actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9',
  'actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1',
  'actions/setup-node@820762786026740c76f36085b0efc47a31fe5020',
  './.github/workflows/windows-validation-concern.yml',
  # Local composite actions are reviewed in this repository; each one is added
  # here deliberately and held to the composite rules below.
  './.github/actions/source-checkout',
  './.github/actions/environment-preflight',
  './.github/actions/sanitize',
  './.github/actions/concern-report',
  './.github/actions/timings',
  './.github/actions/rust-toolchain',
  './.github/actions/node-setup',
  './.github/actions/run-result',
  './.github/workflows/linux-validation-concern.yml',
  './.github/workflows/select-concerns.yml',
  './.github/actions/select-concerns',
  './.github/actions/scan-concern',
  './.github/actions/rust-lint-enforce',
  './.github/actions/linux-concern-js',
  './.github/actions/linux-concern-e2e',
  './.github/actions/linux-concern-rust',
  './.github/actions/windows-concern-rust',
  './.github/actions/macos-concern-rust',
  './.github/actions/macos-concern-js',
  './.github/actions/vendor-fetch',
  './.github/actions/verify-cargo-cache',
  './.github/actions/linux-test-identities',
  './.github/actions/rust-target-cache',
  './.github/workflows/live-proof-arm.yml',
  './.github/workflows/pg8-measurement-arm.yml',
  './.github/actions/mobile-report',
  './.github/actions/android-sdk-setup',
  './.github/actions/ios-project-init',
  './.github/actions/android-emulator-tests',
  './.github/actions/ios-simulator-tests',
  './.github/actions/live-build',
  './.github/actions/live-run',
  './.github/actions/live-summary',
  './.github/actions/live-start-ibm',
  './.github/actions/live-start-iris',
  './.github/actions/live-start-mpp',
  './.github/actions/live-start-pg',
  './.github/actions/pg8-measurement',
  './.github/actions/live-start-rocketmq',
  './.github/actions/live-start-sql',
  './.github/actions/egress-audit',
  # Linux egress block mode, called only from the egress-audit composite's enforce phase.
  './.github/actions/egress-block',
  # Finding H2: root-needing setup, then the removal of root, before project code.
  './.github/actions/root-setup',
  './.github/actions/drop-root',
].freeze

# The reviewed container EXPRESSIONS, as exact text (the parsed YAML value). Any other expression for
# a container image must be exactly `${{ fromJSON('<one JSON literal>') }}` with every image in the
# literal pinned by digest; everything else is refused, because an expression can fall back to an
# unpinned image through vars, env, inputs, matrix or needs.
CONTAINER_EXPRESSION_ALLOWLIST = [
  # The Playwright visual tier: the digest-pinned image only for the e2e-visual concern, none
  # otherwise (`|| null`). The condition and the null fallback are why it is not the plain shape.
  %q(${{ inputs.concern == 'e2e-visual' && fromJSON('{"image":"mcr.microsoft.com/playwright@sha256:02bbb2155cd7109e3e9c741941097ed1608cf8b6fa44ee2595896da2bdc1f471","options":"--ipc=host"}') || null }}),
].freeze

# The reviewed container `options`, as exact text. The runner puts options before the image in
# `docker create`, so a positional token (or an unreviewed flag such as --privileged or -v) in
# free text would change what runs; only text listed here is accepted, in a container, a service or
# a fromJSON literal.
CONTAINER_OPTIONS_ALLOWLIST = [
  # The Playwright visual tier needs a shared IPC namespace for the browser.
  '--ipc=host',
].freeze
