#!/usr/bin/env bash
# Discovery proof for the three-way `rust-app` split (survey 8.5-4 and 7.7).
#
# `rust-app` runs the same package set in three jobs per platform, each a nextest `hash:K/3` partition.
# The hash partition assigns every test to exactly one of the three from a stable hash of its binary and
# name, so the three together run every test once and none twice, provided the three jobs are the three
# partitions of ONE command: same packages, same profile, same filters, partition numbers 1 to 3 of 3,
# every job present, doctests once. A shard that is dropped, renamed, counted out of three, given
# different packages or run with the doctests twice would silently drop or repeat tests, and nothing at
# run time would notice. This check pins that shape statically, on the real tree and on mutated copies:
#   - each platform composite runs one case arm for rust-app-1, -2 and -3 with partition
#     hash:${CONCERN##*-}/3 (the shard number from the concern name), no count: partition left behind;
#   - both branches (the doctest shard and the others) run the same package list under
#     NEXTEST_REQUIRE_TESTS, so an empty partition fails; the doctests run on shard 1 only;
#   - Linux's openvpn check runs once, on shard 3, and nowhere else;
#   - ci-matrix.json holds exactly rust-app-1 to rust-app-3, each a long pole with the same crates;
#   - the Windows and macOS planners and their Result lists name exactly the three shards, once each;
#   - the privileged package setup knows all three.
# Run from the repository root (the policy workflow does).
set -euo pipefail
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

checker="${work}/check.rb"
cat > "${checker}" <<'RUBY'
require 'json'
root = ARGV.fetch(0)
problems = []
read = ->(path) { File.read(File.join(root, path), encoding: 'UTF-8') }

SHARDS = %w[rust-app-1 rust-app-2 rust-app-3].freeze
ARM_HEADER = "          rust-app-1|rust-app-2|rust-app-3)\n"
PARTITION = %q(export NEXTEST_PARTITION="hash:${CONCERN##*-}/3")
PACKAGES = '"${rust_app_packages[@]/#/--package=}"'
FIRST = %(if [[ "${CONCERN}" == rust-app-1 ]]; then\n              NEXTEST_REQUIRE_TESTS=true rust_tests rust-app-tests #{PACKAGES}\n            else\n              NEXTEST_REQUIRE_TESTS=true NEXTEST_DOCTESTS=skip rust_tests rust-app-tests #{PACKAGES}\n            fi)

%w[linux macos windows].each do |os|
  path = ".github/actions/#{os}-concern-rust/action.yml"
  text = read.call(path)
  start = text.index(ARM_HEADER)
  if start.nil?
    problems << "#{path}: no case arm for exactly #{SHARDS.join(', ')}"
    next
  end
  arm = text[start..][/\A.*?\n            ;;\n/m].to_s
  problems << "#{path}: the arm does not end where expected" if arm.empty?
  problems << "#{path}: the partition is not exactly hash:${CONCERN##*-}/3" unless arm.scan(/NEXTEST_PARTITION=/).length == 1 && arm.include?(PARTITION)
  problems << "#{path}: a count: partition is left behind" if text.include?('count:${CONCERN##*-}')
  problems << "#{path}: the shard branches must run one package list, require tests, and keep the doctests on shard 1 only" unless arm.include?(FIRST)
  problems << "#{path}: rust-app-tests must run in exactly the two branches" unless arm.scan('rust_tests rust-app-tests').length == 2
  openvpn = arm.scan('rust-app-openvpn-check').length
  if os == 'linux'
    problems << "#{path}: the openvpn check must run once, on rust-app-3" unless openvpn == 1 && arm.include?(%(if [[ "${CONCERN}" == rust-app-3 ]]; then\n              run_deferred rust-app-openvpn-check))
  else
    problems << "#{path}: the openvpn check belongs to Linux only" unless openvpn.zero?
  end
  problems << "#{path}: another arm still names a rust-app shard" if text.sub(arm, '').match?(/rust-app-[0-9]\)/)
end

table = JSON.parse(read.call('.github/ci-matrix.json')).fetch('concerns').fetch('linux')
shards = table.keys.grep(/\Arust-app-\d+\z/)
problems << "ci-matrix.json: the rust-app shards are #{shards.inspect}, not #{SHARDS.inspect}" unless shards.sort == SHARDS
SHARDS.each do |name|
  row = table[name] or next
  problems << "ci-matrix.json: #{name} is not a long pole" unless row['long_pole'] == true
  problems << "ci-matrix.json: #{name} is not full_only" unless row['full_only'] == true
  problems << "ci-matrix.json: #{name} crates differ from rust-app-1" unless row['rust_packages'] == table.fetch('rust-app-1')['rust_packages']
  problems << "ci-matrix.json: #{name} timeout is #{row['timeout'].inspect}, below the 60-minute cold budget" unless row['timeout'].is_a?(Integer) && row['timeout'] >= 60
end

%w[.github/workflows/windows-validation.yml .github/workflows/macos-validation.yml].each do |path|
  text = read.call(path)
  rust = text[/^\s+rust='(\[[^\n]*\])'$/, 1]
  long = text[/^\s+(?:rust_)?long='(\[[^\n]*\])'$/, 1]
  problems << "#{path}: no rust list in the planner" unless rust
  problems << "#{path}: no long-pole list in the planner" unless long
  rust_names = JSON.parse(rust || '[]')
  long_names = JSON.parse(long || '[]')
  problems << "#{path}: the planner lists #{rust_names.grep(/rust-app/).inspect}" unless rust_names.grep(/rust-app/) == SHARDS
  problems << "#{path}: the long-pole list lists #{long_names.grep(/rust-app/).inspect}" unless long_names.grep(/rust-app/) == SHARDS
  expected = text[/expected-concerns: '(\[[^\n]*\])'/, 1]
  problems << "#{path}: the Result list names #{JSON.parse(expected).grep(/rust-app/).inspect}" unless expected && JSON.parse(expected).grep(/rust-app/) == SHARDS
end
windows = read.call('.github/workflows/windows-validation.yml')
required = windows[/required-concerns: \$\{\{ inputs\.rust && '(\[[^\n]*?\])' \|\|/, 1]
problems << '.github/workflows/windows-validation.yml: the required list does not name exactly the three shards' unless required && JSON.parse(required).grep(/rust-app/) == SHARDS

setup = read.call('.github/actions/root-setup/action.yml')
problems << 'root-setup does not install the native packages for rust-app-3' unless setup.include?('rust-app|rust-app-1|rust-app-2|rust-app-3|rust-packaging)')

if problems.empty?
  puts 'rust-app shards: three hash partitions of one command on every platform, every shard present once'
else
  problems.each { |p| warn p }
  exit 1
end
RUBY

tree() { # tree NAME: a copy of the files the check reads
  rm -rf "${work}/$1"; mkdir -p "${work}/$1"
  cp -R .github "${work}/$1/"
}
mutate() { # mutate NAME FILE OLD NEW: replace the first OLD in the copy; fail the fixture if OLD is absent
  OLD="$3" NEW="$4" ruby -e 't = File.read(ARGV[0]); i = t.index(ENV["OLD"]) or abort("fixture text not found in #{ARGV[0]}: #{ENV["OLD"][0, 60]}"); t[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], t)' "${work}/$1/$2"
}
expect_fail() { # expect_fail LABEL NAME
  if ruby "${checker}" "${work}/$2" >/dev/null 2>"${work}/err"; then echo "rust-app shards: '$1' was not refused" >&2; exit 1; fi
  [[ -s "${work}/err" ]] || { echo "rust-app shards: '$1' was refused without a reason" >&2; exit 1; }
}

ruby "${checker}" .
linux=.github/actions/linux-concern-rust/action.yml
windows_action=.github/actions/windows-concern-rust/action.yml
macos_action=.github/actions/macos-concern-rust/action.yml

tree m; mutate m "${linux}" 'hash:${CONCERN##*-}/3' 'hash:${CONCERN##*-}/2'; expect_fail 'a partition counted out of two' m
tree m; mutate m "${windows_action}" 'hash:${CONCERN##*-}/3' 'count:${CONCERN##*-}/3'; expect_fail 'a count partition on Windows' m
tree m; mutate m "${macos_action}" 'NEXTEST_DOCTESTS=skip ' ''; expect_fail 'doctests run on every macOS shard' m
tree m; mutate m "${linux}" 'NEXTEST_REQUIRE_TESTS=true NEXTEST_DOCTESTS=skip' 'NEXTEST_DOCTESTS=skip'; expect_fail 'an empty Linux partition could pass' m
tree m; mutate m "${linux}" '"${CONCERN}" == rust-app-3 ]]; then' '"${CONCERN}" == rust-app-2 ]]; then'; expect_fail 'the openvpn check moved to the cache-saving shard' m
tree m; mutate m "${linux}" 'cargo check --locked --lib --package taurine-app --features openvpn' 'cargo check --locked --lib --package taurine-app --features openvpn
              run_deferred rust-app-openvpn-check true'; expect_fail 'a second openvpn check' m
tree m; mutate m "${windows_action}" 'rust-app-1|rust-app-2|rust-app-3)' 'rust-app-1|rust-app-2)'; expect_fail 'a Windows shard without an arm' m
tree m; mutate m .github/ci-matrix.json '"rust-app-3": {' '"rust-app-4": {'; expect_fail 'a renamed shard in the table' m
tree m; mutate m .github/workflows/windows-validation.yml '"rust-app-1","rust-app-2","rust-app-3","rust-packaging"]' '"rust-app-1","rust-app-2","rust-packaging"]'; expect_fail 'a shard dropped from a Windows list' m
tree m; mutate m .github/workflows/macos-validation.yml 'long='"'"'["rust-db","rust-app-1","rust-app-2","rust-app-3","rust-packaging"]' 'long='"'"'["rust-db","rust-app-1","rust-app-2","rust-packaging"]'; expect_fail 'a shard dropped from the macOS long-pole list' m
tree m; mutate m .github/actions/root-setup/action.yml 'rust-app-2|rust-app-3|rust-packaging)' 'rust-app-2|rust-packaging)'; expect_fail 'the native packages missing for shard 3' m
tree m; ruby -rjson -e 'p = ARGV[0]; d = JSON.parse(File.read(p)); d["concerns"]["linux"]["rust-app-3"]["rust_packages"] = ["taurine-app"]; File.write(p, JSON.pretty_generate(d))' "${work}/m/.github/ci-matrix.json"; expect_fail 'shard 3 testing different crates' m

echo 'rust-app shards: the real tree passes; a miscounted, dropped, renamed, repeated or re-packaged shard is refused'
