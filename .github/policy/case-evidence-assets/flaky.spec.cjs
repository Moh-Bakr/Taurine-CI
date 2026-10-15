'use strict';

const { test, expect } = require('@playwright/test');

test.describe('flaky group', () => {
  test('flaky retry', async ({}, testInfo) => {
    if (testInfo.retry === 0) throw new Error('SYNTHETIC_RETRY_FAILURE');
    expect(testInfo.retry).toBe(1);
  });
});
