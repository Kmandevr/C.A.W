// Tests for worktree-tidy.js: which worktrees are backed up or removed, and when a build folder is stale.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { decide, backupBranch, staleBuild } = require('./worktree-tidy.js');

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
