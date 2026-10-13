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

  test('flaky retry', async ({}, testInfo) => {
    if (testInfo.retry === 0) throw new Error('SYNTHETIC_RETRY_FAILURE');
    expect(testInfo.retry).toBe(1);
  });

  test.skip('intentional skip', async () => {
    throw new Error('SYNTHETIC_SKIP_SHOULD_NOT_RUN');
  });
});
