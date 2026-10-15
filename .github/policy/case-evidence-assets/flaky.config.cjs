'use strict';

module.exports = {
  testDir: __dirname,
  testMatch: ['flaky.spec.cjs'],
  retries: 1,
  reporter: 'json',
  projects: [{ name: 'smoke' }]
};
