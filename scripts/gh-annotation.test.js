// Tests for gh-annotation.js: annotation text can't end its line or start another workflow command.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { escapeData, escapeProperty, errorLine, flat } = require('./gh-annotation.js');

test('a message escapes %, CR and LF', () => {
  assert.strictEqual(escapeData('50%\r\nnext'), '50%25%0D%0Anext');
});

test('a property also escapes : and ,', () => {
  assert.strictEqual(escapeProperty('a:b,c%'), 'a%3Ab%2Cc%25');
});

test('a name carrying a command stays on its line', () => {
  const line = errorLine('Dart test failed', 'x\n::stop-commands::tok');
  assert.strictEqual(line, '::error title=Dart test failed::x%0A::stop-commands::tok');
  assert.ok(!line.includes('\n'));
});

test('plain log text is flattened to one line', () => {
  assert.strictEqual(flat('a\r\n::warning::b'), 'a ::warning::b');
});
