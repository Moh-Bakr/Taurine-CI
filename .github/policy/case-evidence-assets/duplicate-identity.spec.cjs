'use strict';

const { test, expect } = require('@playwright/test');

test.describe('duplicate group', () => {
  test('part > leaf', () => expect(true).toBe(true));
});

test.describe('duplicate group > part', () => {
  test('leaf', () => expect(true).toBe(true));
});
