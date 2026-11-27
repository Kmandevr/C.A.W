// Tests for dart-test-shard.js: Dart test files are split into balanced, deterministic, complete shards.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');
const { assign, listTests, median } = require('./dart-test-shard.js');

const SCRIPT = path.join(__dirname, 'dart-test-shard.js');

test('greedy: heaviest first, each to the lightest shard, listed heaviest first', () => {
  const times = { 'test/a_test.dart': 10, 'test/b_test.dart': 6, 'test/c_test.dart': 5, 'test/d_test.dart': 4 };
  const s = assign(Object.keys(times), times, 2);
  assert.deepStrictEqual(s, [
    { files: ['test/a_test.dart', 'test/d_test.dart'], seconds: 14 },
    { files: ['test/b_test.dart', 'test/c_test.dart'], seconds: 11 },
  ]);
});

test('ties are broken by path and the result does not depend on input order', () => {
  const files = ['test/d_test.dart', 'test/b_test.dart', 'test/a_test.dart', 'test/c_test.dart'];
  const a = assign(files, {}, 2);
  const b = assign([...files].reverse(), {}, 2);
  assert.deepStrictEqual(a, b);
  assert.deepStrictEqual(a[0].files, ['test/a_test.dart', 'test/c_test.dart']);
  assert.deepStrictEqual(a[1].files, ['test/b_test.dart', 'test/d_test.dart']);
});

test('a new file weighs the median; a gone file is ignored', () => {
  const times = { 'test/a_test.dart': 1, 'test/b_test.dart': 3, 'test/c_test.dart': 9, 'test/gone_test.dart': 100 };
  assert.strictEqual(median(Object.values(times)), 6);
  const s = assign(['test/a_test.dart', 'test/b_test.dart', 'test/c_test.dart', 'test/new_test.dart'], times, 2);
  const all = s.flatMap((x) => x.files).sort();
  assert.deepStrictEqual(all, ['test/a_test.dart', 'test/b_test.dart', 'test/c_test.dart', 'test/new_test.dart']);
  assert.deepStrictEqual(s.map((x) => x.seconds), [10, 9]);
  assert.deepStrictEqual(s[0].files, ['test/c_test.dart', 'test/a_test.dart'], 'heaviest first');
});

test('a bad shard count throws', () => {
  assert.throws(() => assign(['test/a_test.dart'], {}, 0));
  assert.throws(() => assign(['test/a_test.dart'], {}, 1.5));
});

test('the CLI lists every file in exactly one shard and errors on an empty shard', () => {
  const app = fs.mkdtempSync(path.join(os.tmpdir(), 'dart-shard-'));
  fs.mkdirSync(path.join(app, 'test', 'sub'), { recursive: true });
  for (const f of ['x_test.dart', 'y_test.dart', 'sub/z_test.dart', 'helper.dart']) fs.writeFileSync(path.join(app, 'test', f), '');
  fs.writeFileSync(path.join(app, 'test', 'test_times.json'), JSON.stringify({ 'test/x_test.dart': 5 }));
  assert.deepStrictEqual(listTests(app), ['test/sub/z_test.dart', 'test/x_test.dart', 'test/y_test.dart']);
  const run = (...a) => execFileSync('node', [SCRIPT, ...a, '--app', app], { encoding: 'utf8' });
  const lists = [1, 2].map((i) => run(String(i), '2').trim().split('\n'));
  assert.deepStrictEqual(lists, [['test/sub/z_test.dart', 'test/y_test.dart'], ['test/x_test.dart']]);
  assert.match(run('--check', '3'), /all 3 test files in exactly one of 3 shards/);
  const empty = spawnSync('node', [SCRIPT, '4', '4', '--app', app], { encoding: 'utf8' });
  assert.strictEqual(empty.status, 1);
  assert.match(empty.stderr, /shard 4\/4 has no test files/);
  assert.strictEqual(spawnSync('node', [SCRIPT, '--check', '4', '--app', app]).status, 1);
  assert.strictEqual(spawnSync('node', [SCRIPT, '5', '4', '--app', app]).status, 1);
  fs.rmSync(app, { recursive: true, force: true });
});
