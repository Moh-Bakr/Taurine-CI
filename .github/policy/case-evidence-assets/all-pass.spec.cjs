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
