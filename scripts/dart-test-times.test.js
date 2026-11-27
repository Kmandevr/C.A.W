// Tests for dart-test-times.js: each Dart test file's time is the span from its suite event to its last test's end.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { measure, format, relative } = require('./dart-test-times.js');

const events = [
  { type: 'start', time: 0 },
  { type: 'suite', suite: { id: 0, path: '/w/app/test/b_test.dart' }, time: 100 },
  { type: 'suite', suite: { id: 1, path: 'test/a/a_test.dart' }, time: 200 },
  { type: 'testStart', test: { id: 1, suiteID: 0, name: 'loading' }, time: 100 },
  { type: 'testDone', testID: 1, hidden: true, time: 2100 },
  { type: 'testStart', test: { id: 2, suiteID: 0, name: 'x' }, time: 2200 },
  { type: 'testDone', testID: 2, time: 3150 },
  { type: 'testStart', test: { id: 3, suiteID: 1, name: 'loading' }, time: 200 },
  { type: 'testDone', testID: 3, hidden: true, time: 700 },
  { type: 'done', time: 3200 },
];
const text = events.map((e) => JSON.stringify(e)).join('\n') + '\nnot json\n';

test('a file spans its suite event to its last test end, including loading', () => {
  assert.deepStrictEqual(measure(text), { 'test/b_test.dart': 3.05, 'test/a/a_test.dart': 0.5 });
});

test('the table is sorted by path and rounded to tenths', () => {
  const out = format(measure(text));
  assert.strictEqual(out, '{\n  "test/a/a_test.dart": 0.5,\n  "test/b_test.dart": 3.1\n}\n');
});

test('paths are keyed relative to app/', () => {
  assert.strictEqual(relative('C:\\w\\app\\test\\x_test.dart'), 'test/x_test.dart');
  assert.strictEqual(relative('test/y/z_test.dart'), 'test/y/z_test.dart');
});

test('an empty or broken report measures nothing', () => {
  assert.deepStrictEqual(measure(''), {});
  assert.deepStrictEqual(measure('{oops'), {});
});
