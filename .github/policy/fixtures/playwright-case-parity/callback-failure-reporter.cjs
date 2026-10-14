'use strict';

const fs = require('node:fs');

module.exports = class SyntheticCallbackFailureReporter {
  onBegin() {
    const sentinelPath = process.env.TAURINE_PARITY_CALLBACK_SENTINEL;
    if (typeof sentinelPath !== 'string' || sentinelPath.length === 0) {
      throw new Error('SYNTHETIC_REPORTER_SENTINEL_MISSING');
    }
    fs.writeFileSync(sentinelPath, 'synthetic-onBegin-failure-v1', { mode: 0o600 });
    throw new Error('SYNTHETIC_REPORTER_CALLBACK_FAILURE');
  }
};
