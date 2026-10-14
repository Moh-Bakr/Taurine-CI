#!/usr/bin/env ruby
# Control-owned assets for case-level evidence: the Playwright case-list
# reporter the producers hand to the pinned runner, and the synthetic parity
# fixtures the pinned-parity harness stages.
#
# They live here, inside one flat Ruby file, rather than as tracked .cjs/.json
# files, because .github/policy/check-repository.sh deliberately allows only
# flat .sh and .rb under .github/policy/. Keeping the assets in a module means
# the public repository tracks no JavaScript or JSON, and the path policy needs
# no exception: the narrow rule stays exactly as narrow as it is.
#
# The trust property the producers rely on is unchanged. They used to compare
# each fixture file against `git show <control_sha>:<fixture path>`; they now
# compare this file against `git show <control_sha>:<this path>`, so the bytes
# they stage are still pinned to the control commit they verified.
#
# As a script: ruby case-evidence-assets.rb <directory> <asset name>...
module CaseEvidenceAssets
  RELATIVE_PATH = '.github/policy/case-evidence-assets.rb'.freeze

  PLAYWRIGHT_CASE_LIST_REPORTER_CJS = <<'PLAYWRIGHT_CASE_LIST_REPORTER_CJS_SOURCE'.freeze
'use strict';

// Control-owned reporter used only by the fixed producer wrapper. Playwright
// swallows reporter callback errors, so every callback records a fixed failure
// marker and the parent process requires a successful completion marker.
const fs = require('node:fs');
const path = require('node:path');

const reportPath = process.env.TAURINE_CASE_EVIDENCE_REPORT_PATH;
const completionPath = process.env.TAURINE_CASE_EVIDENCE_COMPLETION_PATH;
const maxBytes = 64 * 1024 * 1024;
const maxCases = 250000;

function writePrivateJson(file, value) {
  if (typeof file !== 'string' || !path.isAbsolute(file)) throw new Error('path');
  const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_TRUNC |
    (fs.constants.O_NOFOLLOW || 0);
  const contents = JSON.stringify(value);
  if (Buffer.byteLength(contents, 'utf8') > maxBytes) throw new Error('size');
  const fd = fs.openSync(file, flags, 0o600);
  try {
    if (!fs.fstatSync(fd).isFile()) throw new Error('file');
    fs.writeFileSync(fd, contents);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

module.exports = class CaseListReporter {
  constructor() {
    this.failure = null;
    this.reportWritten = false;
    this.count = 0;
  }

  fail() {
    this.failure = 'reporter_callback_failed';
  }

  guarded(callback) {
    try {
      callback();
    } catch (_) {
      this.fail();
    }
  }

  onBegin(_config, rootSuite) {
    this.guarded(() => {
      if (!rootSuite || typeof rootSuite.allTests !== 'function') throw new Error('suite');
      const tests = rootSuite.allTests();
      if (!Array.isArray(tests) || tests.length === 0 || tests.length > maxCases) throw new Error('empty_or_large');
      const suitesByFile = new Map();
      for (const test of tests) {
        if (!test || typeof test.title !== 'string' || !test.location ||
            typeof test.location.file !== 'string' || !test.parent ||
            typeof test.titlePath !== 'function') throw new Error('test');
        if (Buffer.byteLength(test.title, 'utf8') > 8192 ||
            Buffer.byteLength(test.location.file, 'utf8') > 4096) throw new Error('field_size');
        const ancestors = [];
        let current = test.parent;
        let projectName = null;
        while (current) {
          if (typeof current.project === 'function') {
            const project = current.project();
            if (project && typeof project.name === 'string') projectName = project.name;
          }
          if (current.type === 'describe' && typeof current.title === 'string' && current.title.length > 0) {
            ancestors.unshift(current.title);
          }
          current = current.parent;
        }
        if (!projectName) throw new Error('project');
        if (Buffer.byteLength(projectName, 'utf8') > 256) throw new Error('project_size');
        const file = path.resolve(test.location.file);
        const suite = suitesByFile.get(file) || { file, specs: [] };
        suite.specs.push({
          title: [...ancestors, test.title].join(' > '),
          file,
          tests: [{ projectName, status: 'discovered', results: [] }]
        });
        suitesByFile.set(file, suite);
      }
      const report = { suites: [...suitesByFile.values()], errors: [] };
      if (report.suites.reduce((sum, suite) => sum + suite.specs.length, 0) !== tests.length) {
        throw new Error('count');
      }
      writePrivateJson(reportPath, report);
      this.count = tests.length;
      this.reportWritten = true;
    });
  }

  onError(_error) {
    this.fail();
  }

  onEnd(result) {
    this.guarded(() => {
      if (!result || result.status !== 'passed' || !this.reportWritten) throw new Error('end');
    });
  }

  onExit() {
    this.guarded(() => {
      writePrivateJson(completionPath, {
        schema_version: 1,
        status: this.failure ? 'failed' : (this.reportWritten ? 'complete' : 'failed'),
        error_class: this.failure,
        count: this.count
      });
    });
  }

  printsToStdio() {
    return false;
  }
};
PLAYWRIGHT_CASE_LIST_REPORTER_CJS_SOURCE

  ALL_PASS_CONFIG_CJS = <<'ALL_PASS_CONFIG_CJS_SOURCE'.freeze
'use strict';

// Copy this config and its matching spec into a private synthetic directory
// under the selected app root before a future hosted parity run.
module.exports = {
  testDir: __dirname,
  testMatch: ['all-pass.spec.cjs'],
  retries: 0,
  reporter: 'json',
  projects: [{ name: 'smoke' }, { name: 'critical' }]
};
ALL_PASS_CONFIG_CJS_SOURCE

  ALL_PASS_SPEC_CJS = <<'ALL_PASS_SPEC_CJS_SOURCE'.freeze
'use strict';

const { test, expect } = require('@playwright/test');

test.describe('outer group', () => {
  test.describe('inner group', () => {
    for (const value of ['alpha', 'beta']) {
      test(`parameterized value ${value}`, () => {
        expect(value).not.toBe('');
      });
    }

    test('shared title across projects', () => {
      expect(2 + 2).toBe(4);
    });
  });
});
ALL_PASS_SPEC_CJS_SOURCE

  CALLBACK_FAILURE_REPORTER_CJS = <<'CALLBACK_FAILURE_REPORTER_CJS_SOURCE'.freeze
'use strict';

const fs = require('node:fs');

module.exports = class SyntheticCallbackFailureReporter {
  onBegin() {
    const sentinelPath = process.env.TAURINE_PARITY_CALLBACK_SENTINEL;
    if (typeof sentinelPath !== 'string' || sentinelPath.length === 0) {
      throw new Error('SYNTHETIC_REPORTER_SENTINEL_MISSING');
    }
    fs.writeFileSync(sentinelPath, 'synthetic-onBegin-failure-v1', { mode: 0o600 });
    throw new Error('SYNTHETIC_REPORTER_CALLBACK_FAILURE');
  }
};
CALLBACK_FAILURE_REPORTER_CJS_SOURCE

  DUPLICATE_IDENTITY_CONFIG_CJS = <<'DUPLICATE_IDENTITY_CONFIG_CJS_SOURCE'.freeze
'use strict';

module.exports = {
  testDir: __dirname,
  testMatch: ['duplicate-identity.spec.cjs'],
  retries: 0,
  reporter: 'json',
  projects: [{ name: 'smoke' }]
};
DUPLICATE_IDENTITY_CONFIG_CJS_SOURCE

  DUPLICATE_IDENTITY_SPEC_CJS = <<'DUPLICATE_IDENTITY_SPEC_CJS_SOURCE'.freeze
'use strict';

const { test, expect } = require('@playwright/test');

test.describe('duplicate group', () => {
  test('part > leaf', () => expect(true).toBe(true));
});

test.describe('duplicate group > part', () => {
  test('leaf', () => expect(true).toBe(true));
});
DUPLICATE_IDENTITY_SPEC_CJS_SOURCE

  EXPECTED_CASES_JSON = <<'EXPECTED_CASES_JSON_SOURCE'.freeze
{
  "schema_version": 1,
  "runner_bindings": [
    {
      "runner_id": "playwright-desktop",
      "config_id": "desktop-playwright-projects",
      "version": "1.62.0",
      "packages": {
        "node_modules/@playwright/test": "sha512-9zOJ6ZQRAena31MpOH9VSzIz8Ou3YJ/wtY/eQm5T2uhfhG7/U3COrMS8xOtUrZrp9OgdmzEnIYODye3nY1VqzA==",
        "node_modules/playwright": "sha512-Z14dG305dgaLu6foB1TXQagFiW8JfSUIUaUuPaKQ6NtBPKF1P/qXcqfh6c6K/icPqdy37JmjbiBXf6JNg6Sylw==",
        "node_modules/playwright-core": "sha512-nsNRyq0r2zsG8AcRHWknc9QRA5XCueC7gWMrs+Gx2tlZn9hcl8zudfh00lhJPY1DE7NmZ6bDsT9g2yey8mXljA=="
      }
    },
    {
      "runner_id": "playwright-mobile",
      "config_id": "mobile-playwright-projects",
      "version": "1.62.1",
      "packages": {
        "node_modules/@playwright/test": "sha512-DTcUc8qii+cpHvtOwggMtBRMjKZHXYWdw8syRYu2vtzuq4Wxphqq4NfCs5Zt44L6mA8rfDfj+PHnxFc/FeK6mQ==",
        "node_modules/playwright": "sha512-0M+L3LAD8/nm554LOla9Ayx0j0tmFZ0FBcoQ7F1VuVHpM/XpiC8RcDzBQB8W5+hA8L22THxELzeF+2WcUzvcLg==",
        "node_modules/playwright-core": "sha512-wPYSwEBJY9GHraISXqyqtx0na0LpO3XEX7jNDhntbex7tzUS7kLnZsOlFruFJB4Hi/rhDMjXGqHewDZ68nYZVw=="
      }
    }
  ],
  "all_pass": {
    "config": "all-pass.config.cjs",
    "file": "all-pass.spec.cjs",
    "platform": "linux",
    "scopes": [
      {"runner_id": "playwright-desktop", "config_id": "desktop-playwright-projects", "project": "smoke", "tier": "feedback", "app_file": "taurine-desktop/.case-evidence-fixtures/all-pass.spec.cjs", "file_suite_title": "all-pass.spec.cjs"},
      {"runner_id": "playwright-desktop", "config_id": "desktop-playwright-projects", "project": "critical", "tier": "feedback", "app_file": "taurine-desktop/.case-evidence-fixtures/all-pass.spec.cjs", "file_suite_title": "all-pass.spec.cjs"},
      {"runner_id": "playwright-mobile", "config_id": "mobile-playwright-projects", "project": "smoke", "tier": "smoke", "app_file": "taurine-mobile/.case-evidence-fixtures/all-pass.spec.cjs", "file_suite_title": "all-pass.spec.cjs"},
      {"runner_id": "playwright-mobile", "config_id": "mobile-playwright-projects", "project": "critical", "tier": "critical", "app_file": "taurine-mobile/.case-evidence-fixtures/all-pass.spec.cjs", "file_suite_title": "all-pass.spec.cjs"}
    ],
    "cases": [
      {"describe": ["outer group", "inner group"], "title": "parameterized value alpha"},
      {"describe": ["outer group", "inner group"], "title": "parameterized value beta"},
      {"describe": ["outer group", "inner group"], "title": "shared title across projects"}
    ],
    "expected_outcome": "passed"
  },
  "duplicate_identity": {
    "config": "duplicate-identity.config.cjs",
    "file": "duplicate-identity.spec.cjs",
    "project": "smoke",
    "paths": [
      {"describe": ["duplicate group"], "title": "part > leaf"},
      {"describe": ["duplicate group > part"], "title": "leaf"}
    ],
    "expected_normalized_title": "duplicate group > part > leaf",
    "expected_disposition": "duplicate_case_identity",
    "expected_phase": "control_identity_normalization"
  },
  "outcomes": [
    {
    "config": "outcomes.config.cjs",
    "file": "outcomes.spec.cjs",
    "project": "smoke",
    "retries": 0,
    "cases": [
      {"describe": ["outcome group"], "title": "expected failure", "expected_status": "failed", "attempts": ["failed"], "aggregate": "expected", "disposition": "passed"},
      {"describe": ["outcome group"], "title": "unexpected pass", "expected_status": "failed", "attempts": ["passed"], "aggregate": "unexpected", "disposition": "blocked"},
      {"describe": ["outcome group"], "title": "intentional skip", "expected_status": "skipped", "attempts": [], "aggregate": "skipped", "disposition": "blocked"}
    ]
    },
    {
      "config": "flaky.config.cjs",
      "file": "flaky.spec.cjs",
      "project": "smoke",
      "retries": 1,
      "cases": [
        {"describe": ["flaky group"], "title": "flaky retry", "expected_status": "passed", "attempts": ["failed", "passed"], "aggregate": "flaky", "disposition": "blocked"}
      ]
    }
  ],
  "callback_failure": {
    "reporter": "callback-failure-reporter.cjs",
    "callback": "onBegin",
    "expected_completion_marker": "absent",
    "expected_disposition": "blocked"
  }
}
EXPECTED_CASES_JSON_SOURCE

  FLAKY_CONFIG_CJS = <<'FLAKY_CONFIG_CJS_SOURCE'.freeze
'use strict';

module.exports = {
  testDir: __dirname,
  testMatch: ['flaky.spec.cjs'],
  retries: 1,
  reporter: 'json',
  projects: [{ name: 'smoke' }]
};
FLAKY_CONFIG_CJS_SOURCE

  FLAKY_SPEC_CJS = <<'FLAKY_SPEC_CJS_SOURCE'.freeze
'use strict';

const { test, expect } = require('@playwright/test');

test.describe('flaky group', () => {
  test('flaky retry', async ({}, testInfo) => {
    if (testInfo.retry === 0) throw new Error('SYNTHETIC_RETRY_FAILURE');
    expect(testInfo.retry).toBe(1);
  });
});
FLAKY_SPEC_CJS_SOURCE

  OUTCOMES_CONFIG_CJS = <<'OUTCOMES_CONFIG_CJS_SOURCE'.freeze
'use strict';

// Separate from all-pass so negative runner outcomes can never be reported as
// a successful parity fixture.
module.exports = {
  testDir: __dirname,
  testMatch: ['outcomes.spec.cjs'],
  retries: 0,
  reporter: 'json',
  projects: [{ name: 'smoke' }]
};
OUTCOMES_CONFIG_CJS_SOURCE

  OUTCOMES_SPEC_CJS = <<'OUTCOMES_SPEC_CJS_SOURCE'.freeze
'use strict';

const { test, expect } = require('@playwright/test');

test.describe('outcome group', () => {
  test('expected failure', async () => {
    test.fail();
    expect(1).toBe(2);
  });

  test('unexpected pass', async () => {
    test.fail();
    expect(2 + 2).toBe(4);
  });

  test.skip('intentional skip', async () => {
    throw new Error('SYNTHETIC_SKIP_SHOULD_NOT_RUN');
  });
});
OUTCOMES_SPEC_CJS_SOURCE

  ASSETS = {
    'playwright-case-list-reporter.cjs' => PLAYWRIGHT_CASE_LIST_REPORTER_CJS,
    'all-pass.config.cjs' => ALL_PASS_CONFIG_CJS,
    'all-pass.spec.cjs' => ALL_PASS_SPEC_CJS,
    'callback-failure-reporter.cjs' => CALLBACK_FAILURE_REPORTER_CJS,
    'duplicate-identity.config.cjs' => DUPLICATE_IDENTITY_CONFIG_CJS,
    'duplicate-identity.spec.cjs' => DUPLICATE_IDENTITY_SPEC_CJS,
    'expected-cases.json' => EXPECTED_CASES_JSON,
    'flaky.config.cjs' => FLAKY_CONFIG_CJS,
    'flaky.spec.cjs' => FLAKY_SPEC_CJS,
    'outcomes.config.cjs' => OUTCOMES_CONFIG_CJS,
    'outcomes.spec.cjs' => OUTCOMES_SPEC_CJS
  }.freeze

  # Materialise named assets into an existing private directory as mode-0600
  # regular files. The caller owns the directory and its 0700 mode; this method
  # refuses to follow a link or overwrite an existing entry.
  def self.materialize(directory, names)
    names.map do |name|
      content = ASSETS.fetch(name)
      path = File.join(directory, name)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      path
    end
  end
end

if $PROGRAM_NAME == __FILE__
  directory, *requested = ARGV
  abort('usage: case-evidence-assets.rb <directory> <asset name>...') if directory.nil? || requested.empty?
  abort('unknown asset') unless requested.all? { |name| CaseEvidenceAssets::ASSETS.key?(name) }
  abort('duplicate asset') unless requested.uniq == requested
  CaseEvidenceAssets.materialize(directory, requested)
end
