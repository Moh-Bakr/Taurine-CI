'use strict';

module.exports = class SyntheticCallbackFailureReporter {
  onBegin() {
    throw new Error('SYNTHETIC_REPORTER_CALLBACK_FAILURE');
  }
};
