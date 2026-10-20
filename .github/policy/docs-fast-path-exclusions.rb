# frozen_string_literal: true

# The reviewed exclusion list of the docs-only fast path (required, not run).
#
# A pull request whose every changed path is a documentation file runs a short policy job instead of
# the full policy (classify-docs-change.rb decides; docs/how-ci-works.md, "Docs-only fast path"). That
# is only sound for a document no check reads: a policy script, test or workflow that opens a document
# turns an edit of it into a change of policy, and the full policy must judge that change.
#
# EXCLUDED_DOCS lists the documents the policy reads. It is read by the classifier from the BASE
# commit, so a pull request cannot shorten it for itself. check-docs-reads.rb greps the tree for
# every document the policy names and fails when one is neither listed here nor pinned as a message
# only, so a new reader of a document cannot land without a decision about this list.
#
# Paths are exact, relative to the repository root, and compared case-insensitively.
module DocsFastPathExclusions
  EXCLUDED_DOCS = %w[
    docs/untrusted-readonly-cache.md
  ].freeze

  # Lines outside the list above that still name a document or the docs/ directory, and are reviewed as not
  # reading any document (a message, a description, a synthetic fixture, or a read of an excluded document
  # only). Exact text of the stripped line, per file. A line that is not here and is not covered by
  # EXCLUDED_DOCS makes check-docs-reads.rb fail, so a new reader cannot land unnoticed.
  NAMED_NOT_READ = {
    # a description and a summary message that name the guide; neither opens it
    ".github/actions/drop-root/action.yml" => [
      "is written to the summary and documented in docs/how-ci-works.md. Every step that needs root",
      "echo '- drop-root: **not possible on Windows**: the hosted job user is an administrator and cannot be demoted within the job. The source token is still revoked before project code; see docs/how-ci-works.md for the residual risk.'",
    ],
    # a description that names the guide
    ".github/actions/egress-audit/action.yml" => [
      "(docs/how-ci-works.md, \"Egress\").",
    ],
    # an error message that names the guide
    ".github/actions/environment-preflight/action.yml" => [
      "echo 'The source-read environment does not exist. Create it (Deployment branches and tags: Selected branches and tags, exactly the branches main and untrusted); see docs/how-ci-works.md, \"Repository settings the owner applies\". Refusing before any job enters it.' >&2",
    ],
    # an error message that names the guide
    ".github/actions/source-checkout/action.yml" => [
      "echo 'Reset untrusted by an admin fast-forward from main (docs/how-ci-works.md, \"Ref isolation\"), then dispatch again.' >&2",
    ],
    # a path class of the private repository selector, a glob over the private docs/ tree
    ".github/ci-matrix.json" => [
      "\"docs/**\",",
    ],
    # the two reads of the excluded spike-record document (the tree own copy and the base checkout copy)
    ".github/policy/check-cache-mode.rb" => [
      "tree_doc = File.join(root, 'docs', 'untrusted-readonly-cache.md')",
      "candidate = File.join(ENV['RUNNER_TEMP'], 'base-policy', 'docs', 'untrusted-readonly-cache.md')",
    ],
    # a tracked-file allow-list that names docs/*.md by path and opens none of them
    ".github/policy/check-workflows.sh" => [
      "if find . -type f -not -path './.git' -not -path './.git/*' -not -path './.github/workflows/*' -not -path './.github/actions/*/action.yml' -not -path './.github/policy/*' -not -path './.github/ci-matrix.json' -not -path './.github/dependabot.yml' -not -path './.github/tool-pins.json' -not -path './.github/egress-allowlist.txt' -not -path './.github/CODEOWNERS' -not \\( -path './docs/*.md' -not -path './docs/*/*' \\) -not -name '.gitignore' -print -quit | grep -q .; then",
    ],
    # copies docs/ into each mutated tree; only the excluded document is mutated or read back
    ".github/policy/test-mutations.sh" => [
      "cp -R \"${src}/.github\" \"${src}/docs\" \"${dir}/tree/\"",
    ],
    # synthetic changed-file names fed to a stub, not files read
    ".github/policy/test-policy.sh" => [
      "[[ -n \"${files}\" ]] || files='[{\"filename\":\"docs/how-ci-works.md\"}]'",
      "FAKE_FILES='[{\"filename\":\"docs/a.md\"},{\"filename\":\"README-not-github.md\"}]' freshness_run refs/heads/untrusted behind 0 2",
      "many=\"$(ruby -rjson -e 'puts JSON.generate((1..300).map { |i| { \"filename\" => \"docs/f\#{i}.md\" } })')\"",
      "for changed in '[{\"filename\":\".github/workflows/validation.yml\"}]' '[{\"filename\":\"docs/a.md\"},{\"filename\":\".github/policy/lib.sh\"}]' \\",
      "'[{\"filename\":\"docs/x.yml\",\"previous_filename\":\".github/actions/drop-root/action.yml\"}]' \"${many}\" '{}' unreadable; do",
    ],
    # synthetic documents written into temporary repositories
    ".github/policy/test-repository.sh" => [
      "for rejected in 'CODEOWNERS' 'docs/CODEOWNERS' '.github/codeowners' '.github/CODEOWNERS.bak' '.github/CODEOWNERS/extra' '.github/policy/CODEOWNERS'; do",
      "mkdir -p \"${credential}/docs\"",
      "printf 'GH_APP_PRIVATE_KEY=TEST_FIXTURE_SENTINEL\\n' > \"${credential}/docs/repository-fixture.md\"",
      "mkdir -p \"${nul_docs}/docs\"",
      "printf -- '\\000-----BEGIN RSA PRIVATE KEY-----\\nTEST_FIXTURE_NOT_A_REAL_KEY\\n' > \"${nul_docs}/docs/nul-fixture.md\"",
      "mkdir -p \"${unreadable}/docs\"",
    ],
    # a synthetic docs/ directory in a temporary repository
    ".github/policy/test-selector.sh" => [
      "mkdir -p \"${repo}/taurine-desktop/src\" \"${repo}/docs\" \"${repo}/mystery\"",
      "echo a > \"${repo}/docs/a.md\"",
    ],
    # copies the excluded document into temporary trees and builds synthetic docs/ directories
    ".github/policy/test-untrusted-restore-shape.sh" => [
      "mkdir -p \"${d}/.github/workflows\" \"${d}/docs\"",
      "cp docs/untrusted-readonly-cache.md \"${d}/docs/\"",
      "rt=\"${work}/rt\"; rm -rf \"${rt}\"; mkdir -p \"${rt}/base-policy/docs\"",
      "rm -rf \"${d}\"; mkdir -p \"${d}/.github/workflows\" \"${d}/docs\"",
      "mkdir -p \"${flipped}/.github\" \"${flipped}/docs\"",
      "cp \"${true_tree}/docs/untrusted-readonly-cache.md\" \"${flipped}/docs/\"",
    ],
  }.freeze
end
