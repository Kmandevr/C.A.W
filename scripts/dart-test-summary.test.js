// Tests for dart-test-summary.js: failing Dart tests are named from the JSON reporter's events.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { summarize, markdown } = require('./dart-test-summary.js');

const events = [
  { type: 'start' },
  { type: 'suite', suite: { id: 0, path: 'test/a_test.dart' } },
  { type: 'testStart', test: { id: 1, name: 'loading test/a_test.dart', suiteID: 0, line: null } },
  { type: 'testDone', testID: 1, result: 'success', hidden: true, skipped: false },
  { type: 'testStart', test: { id: 2, name: 'adds | numbers', suiteID: 0, line: 4 } },
  { type: 'testDone', testID: 2, result: 'success', hidden: false, skipped: false },
  { type: 'testStart', test: { id: 3, name: 'later', suiteID: 0, line: 9 } },
  { type: 'testDone', testID: 3, result: 'success', hidden: false, skipped: true },
  { type: 'testStart', test: { id: 4, name: 'breaks', suiteID: 0, line: 12, root_line: 30 } },
  { type: 'error', testID: 4, error: 'Expected: 1\n  Actual: 2', isFailure: true },
  { type: 'testDone', testID: 4, result: 'failure', hidden: false, skipped: false },
  { type: 'done', success: false },
];
const text = events.map((e) => JSON.stringify(e)).join('\n') + '\nnot json\n';

test('counts passes and skips, not the hidden loading step', () => {
  const r = summarize(text);
  assert.strictEqual(r.passed, 1);
  assert.strictEqual(r.skipped, 1);
  assert.strictEqual(r.done, false);
});

test('names each failure with its file, line and first error line', () => {
  const r = summarize(text);
  assert.deepStrictEqual(r.failures, [{ file: 'test/a_test.dart', name: 'breaks', line: 30, error: 'Expected: 1\n  Actual: 2' }]);
  const md = markdown('Dart tests (1/4)', r);
  assert.match(md, /1 passed, 1 failed, 1 skipped/);
  assert.match(md, /\| test\/a_test.dart:30 \| breaks \| Expected: 1 \|/);
});

test('a load failure counts as a failure', () => {
  const r = summarize([
    JSON.stringify({ type: 'suite', suite: { id: 0, path: 'test/b_test.dart' } }),
    JSON.stringify({ type: 'testStart', test: { id: 1, name: 'loading test/b_test.dart', suiteID: 0 } }),
    JSON.stringify({ type: 'error', testID: 1, error: 'Compilation failed' }),
    JSON.stringify({ type: 'testDone', testID: 1, result: 'error', hidden: true }),
    JSON.stringify({ type: 'done', success: false }),
  ].join('\n'));
  assert.strictEqual(r.failures.length, 1);
  assert.strictEqual(r.failures[0].error, 'Compilation failed');
});

test('an unfinished report says so', () => {
  assert.match(markdown('Dart tests', summarize('')), /ended before the test report finished/);
});
