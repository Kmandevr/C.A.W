// Tests the changelog join: a change file's format and its errors, groups in the order New, Changed, Fixed, both copies written and the files deleted, nothing written on a failure, and that the repository's own changes/ files parse.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { parseChange, entry, insertEntry, join, check, maxFileChars } = require('./changelog-join');
const { extract } = require('./changelog-notes');

const changelog = [
  '# Changelog',
  '',
  'Intro.',
  '',
  '## 1.0.1-alpha.1 (2026-11-13)',
  '',
  '### Fixed',
  '- One.',
  '',
].join('\n');

/** A scratch repository root with both changelog copies and [changes] as { name: text }. */
function scratch(changes, text = changelog) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'caw-join-'));
  fs.mkdirSync(path.join(root, 'app', 'assets'), { recursive: true });
  fs.mkdirSync(path.join(root, 'changes'));
  fs.writeFileSync(path.join(root, 'CHANGELOG.md'), text);
  fs.writeFileSync(path.join(root, 'app', 'assets', 'CHANGELOG.md'), text);
  fs.writeFileSync(path.join(root, 'changes', 'README.md'), '# How to write one\n- not a change\n- at all\n');
  for (const [name, body] of Object.entries(changes)) fs.writeFileSync(path.join(root, 'changes', name), body);
  return root;
}

test('a change file is a group and one bullet, with nested and continued lines', () => {
  assert.deepEqual(parseChange('### New\n- **Piccolo:** sings.\n'), { group: 'New', lines: ['- **Piccolo:** sings.'] });
  assert.deepEqual(parseChange('\r\n### fixed  \r\n- A.\r\n  - Nested.\r\n    - Deeper.\r\n  and continued.\r\n\r\n'), {
    group: 'Fixed',
    lines: ['- A.', '  - Nested.', '    - Deeper.', '  and continued.'],
  });
});

test('a change file that does not read is an error saying why', () => {
  assert.match(parseChange('').error, /empty/);
  assert.match(parseChange('- No group.').error, /first line must be the group/);
  assert.match(parseChange('### Improved\n- x').error, /unknown group "Improved"/);
  assert.match(parseChange('### New').error, /must be its bullet/);
  assert.match(parseChange('### New\nText.').error, /must be its bullet/);
  assert.match(parseChange('### New\n- A.\n- B.').error, /one change per file/);
  assert.match(parseChange('### New\n- A.\nB.').error, /one change per file/);
  assert.match(parseChange('### New\n- A.\n\n  - B.').error, /blank line/);
  assert.match(parseChange('### New\n- A.\n\t- B.').error, /tab/);
  assert.match(parseChange('### New\n- A.\n   - B.').error, /2, 4 or 6 spaces/);
  assert.match(parseChange('### New\n- A.\n        - B.').error, /2, 4 or 6 spaces/);
  assert.match(parseChange('### New\n- A.\n  ### Fixed').error, /heading/);
  assert.match(parseChange(`### New\n- ${'x'.repeat(maxFileChars)}`).error, /over 4000 characters/);
  assert.match(parseChange(`### New\n- A.\n${'  - b\n'.repeat(50)}`).error, /over 40 lines/);
});

test('an entry lists the groups New, Changed, Fixed, and goes above the newest one', () => {
  const changes = [
    { group: 'Fixed', lines: ['- F.'] },
    { group: 'New', lines: ['- N1.', '  - nested'] },
    { group: 'New', lines: ['- N2.'] },
  ];
  const block = entry('1.0.2-alpha.1', '2026-11-27', changes, 'The summary.');
  assert.equal(block, '## 1.0.2-alpha.1 (2026-11-27)\n\nThe summary.\n\n### New\n- N1.\n  - nested\n- N2.\n### Fixed\n- F.');
  assert.equal(entry('2.0.0', '2026-01-01', [{ group: 'Changed', lines: ['- C.'] }]), '## 2.0.0 (2026-01-01)\n\n### Changed\n- C.');
  assert.equal(insertEntry(changelog, block).indexOf(block), changelog.indexOf('## 1.0.1'));
  assert.equal(insertEntry('# Changelog\n\nIntro.\n\n', '## 1.0.0 (d)\n- x'), '# Changelog\n\nIntro.\n\n## 1.0.0 (d)\n- x\n');
});

test('the join writes both copies, deletes the change files and reads back through changelog-notes', () => {
  const root = scratch({
    'b-fix.md': '### Fixed\n- **Tuba:** ends cleanly.\n',
    'a-piccolo.md': '### New\n- **Piccolo:** sings up to A7.\n  - With a drawing.\n',
    'c-hall.md': '### Changed\n- **Hall:** keeps the bass clean.\n',
  });
  const r = join(root, '1.0.2-alpha.1', '2026-11-27', { summary: 'Winds.' });
  assert.equal(r.ok, true, r.lines.join('\n'));
  assert.match(r.lines[0], /^PASS changelog-join - 3 change file\(s\) joined into 1\.0\.2-alpha\.1: New 1, Changed 1, Fixed 1/);
  const a = fs.readFileSync(path.join(root, 'CHANGELOG.md'), 'utf8');
  assert.equal(a, fs.readFileSync(path.join(root, 'app', 'assets', 'CHANGELOG.md'), 'utf8'), 'the copies stay identical');
  assert.equal(extract(a, '1.0.2-alpha.1').body,
    'Winds.\n\n### New\n- **Piccolo:** sings up to A7.\n  - With a drawing.\n### Changed\n- **Hall:** keeps the bass clean.\n### Fixed\n- **Tuba:** ends cleanly.');
  assert.equal(extract(a, '1.0.1-alpha.1').body, '### Fixed\n- One.', 'the older entry is untouched');
  assert.deepEqual(fs.readdirSync(path.join(root, 'changes')), ['README.md']);
  fs.rmSync(root, { recursive: true, force: true });
});

test('the join writes nothing when it fails', () => {
  const cases = [
    [{ 'bad.md': '### New\n- A.\n- B.\n', 'ok.md': '### New\n- C.\n' }, ['1.0.2', '2026-11-27'], /^FAIL changes - .*one change per file.*\(changes\/bad\.md\)$/],
    [{}, ['1.0.2', '2026-11-27'], /no change files/],
    [{ 'ok.md': '### New\n- C.\n' }, ['1.0.1-alpha.1', '2026-11-27'], /already has a "## 1.0.1-alpha.1" entry/],
    [{ 'ok.md': '### New\n- C.\n' }, ['next', '2026-11-27'], /not a version/],
    [{ 'ok.md': '### New\n- C.\n' }, ['1.0.2', '27/11/2026'], /not a date/],
    [{ 'ok.md': '### New\n- A.\n  Version: 1.0.2\n' }, ['1.0.2', '2026-11-27'], /would fail the release notes: .*update check reads/],
  ];
  for (const [changes, [v, d], want] of cases) {
    const root = scratch(changes);
    const before = fs.readdirSync(path.join(root, 'changes')).sort();
    const r = join(root, v, d);
    assert.equal(r.ok, false, v);
    assert.match(r.lines.join('\n'), want);
    assert.equal(fs.readFileSync(path.join(root, 'CHANGELOG.md'), 'utf8'), changelog);
    assert.deepEqual(fs.readdirSync(path.join(root, 'changes')).sort(), before);
    fs.rmSync(root, { recursive: true, force: true });
  }
  const root = scratch({ 'ok.md': '### New\n- C.\n' });
  fs.writeFileSync(path.join(root, 'app', 'assets', 'CHANGELOG.md'), `${changelog}\nextra\n`);
  assert.match(join(root, '1.0.2', '2026-11-27').lines.join('\n'), /differs from CHANGELOG\.md/);
  assert.equal(fs.readFileSync(path.join(root, 'CHANGELOG.md'), 'utf8'), changelog);
  fs.rmSync(root, { recursive: true, force: true });
});

test('the command prints PASS and the entry, or FAIL lines with exit code 1; --check only parses', () => {
  const script = path.join(__dirname, 'changelog-join.js');
  const root = scratch({ 'x.md': '### Fixed\n- X.\n' });
  const checked = spawnSync('node', [script, '--root', root, '--check'], { encoding: 'utf8' });
  assert.equal(checked.status, 0);
  assert.match(checked.stdout, /^PASS changes - 1 change file\(s\) parse/);
  assert.equal(fs.readdirSync(path.join(root, 'changes')).length, 2, '--check deletes nothing');
  const ok = spawnSync('node', [script, '--root', root, '1.0.2', '2026-11-27'], { encoding: 'utf8' });
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.stdout, /^PASS changelog-join .*\n\n## 1\.0\.2 \(2026-11-27\)\n\n### Fixed\n- X\.\n$/);
  assert.match(ok.stderr, /^WARN changelog-join - no --summary/);
  const again = spawnSync('node', [script, '--root', root, '1.0.3', '2026-11-27'], { encoding: 'utf8' });
  assert.equal(again.status, 1);
  assert.match(again.stderr, /^FAIL changelog-join - no change files/);
  fs.writeFileSync(path.join(root, 'changes', 'y.md'), 'nope\n');
  const bad = spawnSync('node', [script, '--root', root, '--check'], { encoding: 'utf8' });
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /^FAIL changes - the first line must be the group: .*\(changes\/y\.md\)$/m);
  fs.rmSync(root, { recursive: true, force: true });
});

test("every file in the repository's changes/ parses", () => {
  const r = check(path.join(__dirname, '..'));
  assert.equal(r.ok, true, r.lines.join('\n'));
});
