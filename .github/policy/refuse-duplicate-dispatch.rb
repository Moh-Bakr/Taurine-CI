#!/usr/bin/env ruby
# Refuse a duplicate dispatch: a queued or in-progress run of the same
# workflow whose run title carries the same dispatch key (which binds the
# exact source SHA, control-plane revision and normalized inputs) already
# exists. The new run stops in the pre-source job, before any token is minted;
# the existing run is never cancelled or evicted - nothing shared with it
# changes state, so this guard cannot break a source-bearing run that is
# already waiting or executing.
#
# Runs are never deduplicated after they start (two completed runs of the same
# identity are allowed and re-checked by the coordinator's ledger); this guard
# closes the accidental double-dispatch window only. It fails closed: if the
# run list cannot be read, the dispatch is refused rather than started blind.
require 'json'

EXPECTED_TITLE = /\ATaurine validation ([0-9a-fA-F]{40}) ([0-9a-f]{64})\z/.freeze
WORKFLOW = /\A\.github\/workflows\/[a-z0-9-]+\.yml\z/.freeze

def fail_closed(reason)
  warn "dispatch dedup: #{reason}"
  exit 1
end

workflow_path = ENV.fetch('CI_WORKFLOW_PATH')
source_sha = ENV.fetch('CI_SOURCE_SHA').downcase
dispatch_key = ENV.fetch('CI_DISPATCH_KEY')
run_id = ENV.fetch('CI_RUN_ID').to_i
# The dispatching workflows set GH_TOKEN but not GH_REPO; GITHUB_REPOSITORY is
# standard in every Actions run and names the same control repository.
repository = ENV.fetch('GH_REPO') { ENV.fetch('GITHUB_REPOSITORY') }

fail_closed('the guard inputs are malformed') unless workflow_path.match?(WORKFLOW) &&
                                                    source_sha.match?(/\A[0-9a-f]{40}\z/) &&
                                                    dispatch_key.match?(/\A[0-9a-f]{64}\z/) &&
                                                    run_id.positive? &&
                                                    repository.match?(/\A[A-Za-z0-9-]+\/[A-Za-z0-9._-]+\z/)

duplicates = []
%w[queued in_progress].each do |status|
  output = `gh run list --repo "#{repository}" --workflow "#{File.basename(workflow_path)}" --status "#{status}" --json databaseId,displayTitle,url --limit 1000 2>#{File::NULL}`
  fail_closed("the #{status} run list was unreadable; refusing to dispatch blind") unless $?.success?
  begin
    runs = JSON.parse(output)
  rescue JSON::ParserError
    fail_closed("the #{status} run list was unreadable; refusing to dispatch blind")
  end
  fail_closed("the #{status} run list was unreadable; refusing to dispatch blind") unless runs.is_a?(Array)
  runs.each do |run|
    next unless run.is_a?(Hash)
    next if run['databaseId'].to_i == run_id
    match = EXPECTED_TITLE.match(run['displayTitle'].to_s)
    next unless match && match[1].downcase == source_sha && match[2] == dispatch_key
    duplicates << "#{run['url']} (run #{run['databaseId']}, #{status})"
  end
end

fail_closed("a duplicate queued or in-progress dispatch already exists: #{duplicates.first}") unless duplicates.empty?
puts 'dispatch dedup: no queued or in-progress run carries this dispatch identity'
