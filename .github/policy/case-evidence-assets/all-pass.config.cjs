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
