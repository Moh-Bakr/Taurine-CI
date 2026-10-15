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
