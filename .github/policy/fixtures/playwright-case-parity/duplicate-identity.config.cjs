'use strict';

module.exports = {
  testDir: __dirname,
  testMatch: ['duplicate-identity.spec.cjs'],
  retries: 0,
  reporter: 'json',
  projects: [{ name: 'smoke' }]
};
