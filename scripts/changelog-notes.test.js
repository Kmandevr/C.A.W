// Tests the release-notes extraction: the version's CHANGELOG.md section with its "(…)" suffix ignored, a clear failure when it is missing, and the repository's own changelog.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');
const { extract, headingVersion, maxChars } = require('./changelog-notes');

const sample = [
  '# Changelog',
  '',
  'Intro.',
  '',
  '## 1.0.2-alpha.1 (not yet released)',
  '',
  '### New',
  '- **Changelog:** this list.',
  '',
  '## 1.0.1-alpha.1 (2026-11-13)',
  '',
  'The polish release.',
  '',
  '### Fixed',
  '- One.',
  '  - Nested.',
  '',
  '## 1.0.0-alpha.1',
  '- First.',
  '',
].join('\n');

test('a heading names its version without the suffix', () => {
  assert.equal(headingVersion('## 1.0.2-alpha.1 (not yet released)'), '1.0.2-alpha.1');
  assert.equal(headingVersion('## 1.0.0-alpha.1'), '1.0.0-alpha.1');
  assert.equal(headingVersion('### New'), null);
  assert.equal(headingVersion('- ## no'), null);
});

test('the section between its heading and the next, blank ends dropped', () => {
  assert.deepEqual(extract(sample, '1.0.1-alpha.1'), {
    body: 'The polish release.\n\n### Fixed\n- One.\n  - Nested.',
    note: '2026-11-13',
  });
  assert.equal(extract(sample, '1.0.2-alpha.1').body, '### New\n- **Changelog:** this list.');
  assert.equal(extract(sample, 'v1.0.0-alpha.1').body, '- First.', 'the last entry, and a v prefix');
  assert.equal(extract(sample.replace(/\n/g, '\r\n'), '1.0.0-alpha.1').body, '- First.', 'CRLF');
});

test('a missing, partial or empty entry is an error', () => {
  assert.match(extract(sample, '1.0.3-alpha.1').error, /no "## 1.0.3-alpha.1" entry/);
  assert.match(extract(sample, '1.0.2').error, /no "## 1.0.2" entry/, 'no prefix match');
  assert.match(extract('## 2.0.0\n\n## 1.0.0\n- x', '2.0.0').error, /empty/);
  assert.match(extract(sample, '').error, /no version/);
  assert.match(extract(`## 2.0.0\n${'- x\n'.repeat(maxChars)}`, '2.0.0').error, /over 8000 characters/,
    'the app reads 20000 characters of notes, checksums last');
});

test('an entry may not carry a line the update check reads', () => {
  const sha = 'a'.repeat(64);
  assert.match(extract(`## 2.0.0\n- ok\nSHA256 x.apk: ${sha}\n`, '2.0.0').error, /update check reads/);
  assert.match(extract('## 2.0.0\nBuild: abcdef123456\n', '2.0.0').error, /update check reads/);
  assert.match(extract('## 2.0.0\nVersion: 2.0.0\n', '2.0.0').error, /update check reads/);
});

test('the command prints the entry, and fails with a FAIL line when there is none', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'caw-changelog-'));
  const file = path.join(dir, 'CHANGELOG.md');
  fs.writeFileSync(file, sample);
  const script = path.join(__dirname, 'changelog-notes.js');
  assert.equal(execFileSync('node', [script, '--file', file, '--version', '1.0.0-alpha.1'], { encoding: 'utf8' }), '- First.\n');
  const missing = spawnSync('node', [script, '--file', file, '--version', '9.9.9'], { encoding: 'utf8' });
  assert.equal(missing.status, 1);
  assert.equal(missing.stdout, '');
  assert.match(missing.stderr, /^FAIL changelog - no "## 9.9.9" entry/);
  const draft = spawnSync('node', [script, '--file', file, '--version', '1.0.2-alpha.1'], { encoding: 'utf8' });
  assert.equal(draft.status, 0);
  assert.match(draft.stderr, /^WARN changelog - .*not yet released/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("the repository's CHANGELOG.md has an entry for every version from 1.0.0-alpha.1", () => {
  const text = fs.readFileSync(path.join(__dirname, '..', 'CHANGELOG.md'), 'utf8');
  for (const v of ['1.0.0-alpha.1', '1.0.1-alpha.1']) assert.ok(extract(text, v).body, v);
});
