// Tests for worktree-tidy.js: which worktrees are backed up or removed, and when a build folder is stale.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { decide, backupBranch, staleBuild, blocked, safeScratchpad } = require('./worktree-tidy.js');

const w = (o) => ({ name: 'a', dirty: false, ahead: 0, tip: 't1', backupTip: null, ...o });

test('a worktree Main already holds is removed and not backed up', () => {
  assert.deepStrictEqual(decide(w({})), { backup: false, remove: true, note: '' });
});

test('unmerged commits are backed up, and kept until the backup holds the tip', () => {
  assert.deepStrictEqual(decide(w({ ahead: 2 })), { backup: true, remove: false, note: '' });
  assert.deepStrictEqual(decide(w({ ahead: 2, backupTip: 'old' })), { backup: true, remove: false, note: '' });
  assert.deepStrictEqual(decide(w({ ahead: 2, backupTip: 't1' })), { backup: false, remove: true, note: '' });
});

test('uncommitted changes keep a worktree, even when its commits are backed up', () => {
  const d = decide(w({ ahead: 2, backupTip: 't1', dirty: true }));
  assert.strictEqual(d.remove, false);
  assert.strictEqual(d.backup, false);
  assert.match(d.note, /uncommitted/);
  assert.strictEqual(decide(w({ dirty: true })).remove, false);
});

test('backup branch names keep only branch-safe characters', () => {
  assert.strictEqual(backupBranch('agent-a1b2'), 'caw-backup-agent-a1b2');
  assert.strictEqual(backupBranch('x y:z~'), 'caw-backup-x-y-z-');
});

test('a build is stale only when untouched for longer than the given days', () => {
  const day = 24 * 60 * 60 * 1000;
  assert.strictEqual(staleBuild(0, 2 * day, 1), true);
  assert.strictEqual(staleBuild(0, day / 2, 1), false);
  assert.strictEqual(staleBuild(0, 1, 0), true);
});

test('an unknown commit count keeps the worktree and pushes nothing', () => {
  const d = decide(w({ ahead: null }));
  assert.strictEqual(d.backup, false);
  assert.strictEqual(d.remove, false);
});

test('a backup refuses secret-like files and private-plan paths', () => {
  const paths = ['app/lib/a.dart', '.env', 'a/.env.local', 'x/key.properties', 'docs/caw/plan.md', 'k.jks', 'my_token.txt', 'docs/app.md'];
  assert.deepStrictEqual(blocked(paths), ['.env', 'a/.env.local', 'x/key.properties', 'docs/caw/plan.md', 'k.jks', 'my_token.txt']);
});

test('the scratchpad is cleaned only when it is under the temp folder', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tidy-'));
  const inner = path.join(tmp, 'pad');
  fs.mkdirSync(inner);
  assert.strictEqual(safeScratchpad(inner, tmp), fs.realpathSync(inner));
  assert.strictEqual(safeScratchpad(tmp, tmp), null);
  assert.strictEqual(safeScratchpad('/', tmp), null);
  assert.strictEqual(safeScratchpad(os.homedir(), tmp), null);
  assert.strictEqual(safeScratchpad(undefined, tmp), null);
  fs.rmSync(tmp, { recursive: true });
});
