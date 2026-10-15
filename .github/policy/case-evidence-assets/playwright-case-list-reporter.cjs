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
