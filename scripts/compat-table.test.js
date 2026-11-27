// Tests for compat-table.js: a recorded compat table holds only the expected `{"name", 0x...ull},` lines.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { entries, makeTable, compare } = require('./compat-table.js');

const names = 'const Known kKnown111[] = {\n    {"Kit A", 0x0000000000000001ull},\n    {"Kit \\"B\\"", 0x0000000000000002ull},\n};\n';
const printed = 'ok   x\r\n    {"Kit \\"B\\"", 0x00000000000000bbull},\r\n    {"Kit A", 0x00000000000000aaull},\r\n    {"Extra", 0x00000000000000ccull},\r\n';

test('entries read Windows (CRLF) output and escaped quotes', () => {
  assert.deepStrictEqual(entries(printed), [['Kit \\"B\\"', '0x00000000000000bb'], ['Kit A', '0x00000000000000aa'], ['Extra', '0x00000000000000cc']]);
});

test('a table takes the names table\'s presets, in its order, with the printed hashes', () => {
  const t = makeTable(printed, names, 'kKnown111', 'recorded');
  assert.strictEqual(t, '// recorded\nconst Known kKnown111[] = {\n    {"Kit A", 0x00000000000000aaull},\n    {"Kit \\"B\\"", 0x00000000000000bbull},\n};\n');
});

test('a preset the old build did not print fails', () => {
  assert.throws(() => makeTable('    {"Kit A", 0x00000000000000aaull},\n', names, 'kKnown111', 'c'), /no hash for Kit \\"B\\"/);
});

test('a bad array name fails', () => {
  assert.throws(() => makeTable(printed, names, 'k; system("x")', 'c'), /bad array name/);
});

test('a newline in the comment stays on the comment line', () => {
  const t = makeTable(printed, names, 'kKnown111', 'run 1\nint evil = 1;');
  assert.strictEqual(t.split('\n')[0], '// run 1 int evil = 1;');
  assert.ok(!/^int evil/m.test(t));
});

test('printed lines that are not entries are dropped', () => {
  const t = makeTable(printed + '#include "x.h"\n    {"Kit A", 0xBAD}ull},\n', names, 'kKnown111', 'c');
  assert.ok(!t.includes('#include'));
  assert.ok(!t.includes('BAD'));
});

test('compare counts same, differing and absent entries', () => {
  const t = makeTable(printed, names, 'kKnown111', 'c');
  assert.deepStrictEqual(compare(t, names), { total: 2, same: 0, differ: ['Kit A', 'Kit \\"B\\"'], absent: [] });
  assert.deepStrictEqual(compare(t, t), { total: 2, same: 2, differ: [], absent: [] });
});
