'use strict';

const { test, expect } = require('@playwright/test');

test.describe('duplicate group', () => {
  test('same case identity', () => expect(true).toBe(true));
  test('same case identity', () => expect(true).toBe(true));
});
