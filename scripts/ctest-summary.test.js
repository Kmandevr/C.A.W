// Tests for ctest-summary.js: failing engine tests are named from a CTest log.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { summarize, markdown } = require('./ctest-summary.js');

const log = `
 1/3 Test  #2: caw_tests_shard_1 ................***Failed  12.00 sec
ok   a_case
FAIL mixer_sums_two_tracks (engine/tests/mixer_test.cpp:42): expected 1, got 2
engine/src/mix.cpp:10:5: runtime error: signed integer overflow
==123==ERROR: AddressSanitizer: heap-use-after-free on address 0x1
1 tests, 1 failures (shard 2/8)

67% tests passed, 1 tests failed out of 3

The following tests FAILED:
\t  2 - caw_tests_shard_1 (Failed)
Errors while running CTest
`;

test('names the CTest entry, the case and the sanitizer reports', () => {
  const r = summarize(log);
  assert.deepStrictEqual(r.ctest, ['caw_tests_shard_1 (Failed)']);
  assert.deepStrictEqual(r.cases, [{ name: 'mixer_sums_two_tracks', where: 'engine/tests/mixer_test.cpp:42', message: 'expected 1, got 2' }]);
  assert.strictEqual(r.sanitizer.length, 2);
  const md = markdown('Tests (Linux sanitizers, shard 2/8)', r);
  assert.match(md, /\| mixer_sums_two_tracks \| engine\/tests\/mixer_test.cpp:42 \| expected 1, got 2 \|/);
});

test('reads a log with GitHub timestamps', () => {
  const r = summarize('2026-11-27T03:21:36.1234567Z FAIL x (f.cpp:1): m\n');
  assert.strictEqual(r.cases[0].name, 'x');
});

test('a log with no failures says the job failed elsewhere', () => {
  assert.match(markdown('t', summarize('100% tests passed\n')), /failed outside the tests/);
});
