// Backs up agent worktrees to caw-backup-<name> branches and removes worktrees and scratch builds that are no longer needed.
//   node scripts/worktree-tidy.js backup [--dry-run]
//   node scripts/worktree-tidy.js clean [--apply] [--days <n>]
// `backup` pushes each worktree under .claude/worktrees whose commits Main lacks and whose backup branch is behind.
// It commits nothing: a worktree with uncommitted changes is reported, and its last commit is what gets pushed.
// `clean` lists by default; with --apply it removes only what is safe: a clean worktree whose tip Main or its backup
// branch already holds, and a CMake build folder (one holding CMakeCache.txt) untouched for --days (default 1).
// Branches are never deleted (settings.json asks first), and nothing outside the repository and scratchpad is touched.
'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const WORKTREES = path.join(ROOT, '.claude', 'worktrees');
const MAIN = 'origin/Main';
const DAY = 24 * 60 * 60 * 1000;

function git(args, cwd = ROOT) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

function tryGit(args, cwd) {
  try {
    return git(args, cwd);
  } catch {
    return null;
  }
}

// A worktree's backup branch name: its folder name, kept to the characters a branch name allows.
function backupBranch(name) {
  return 'caw-backup-' + name.replace(/[^A-Za-z0-9._-]/g, '-');
}

// What to do with one worktree, from its facts: { name, dirty, ahead (commits Main lacks), tip, backupTip }.
function decide(w) {
  const backedUp = w.backupTip !== null && w.backupTip === w.tip;
  return {
    backup: w.ahead > 0 && !backedUp,
    remove: !w.dirty && (w.ahead === 0 || backedUp),
    note: w.dirty ? 'uncommitted changes (commit them to back them up)' : '',
  };
}

// A build folder is stale when its newest top-level entry is older than `days`.
function staleBuild(newestMtimeMs, nowMs, days) {
  return nowMs - newestMtimeMs > days * DAY;
}

function worktrees() {
  if (!fs.existsSync(WORKTREES)) return [];
  const backups = new Map();
  const remote = tryGit(['ls-remote', 'origin', 'refs/heads/caw-backup-*']) || '';
  for (const line of remote.split('\n')) {
    const [sha, ref] = line.split('\t');
    if (ref) backups.set(ref.replace('refs/heads/', ''), sha);
  }
  const out = [];
  for (const name of fs.readdirSync(WORKTREES).sort()) {
    const dir = path.join(WORKTREES, name);
    if (!fs.existsSync(path.join(dir, '.git'))) continue;
    const tip = tryGit(['rev-parse', 'HEAD'], dir);
    if (!tip) continue;
    const ahead = Number(tryGit(['rev-list', '--count', `${MAIN}..${tip}`]) || 0);
    const dirty = (tryGit(['status', '--porcelain'], dir) || '') !== '';
    out.push({ name, dir, tip, ahead, dirty, backupTip: backups.get(backupBranch(name)) || null });
  }
  return out;
}

function newestMtime(dir) {
  let newest = fs.statSync(dir).mtimeMs;
  for (const e of fs.readdirSync(dir)) {
    try {
      newest = Math.max(newest, fs.lstatSync(path.join(dir, e)).mtimeMs);
    } catch {
      // An entry removed while listing doesn't count.
    }
  }
  return newest;
}

// CMake build folders: engine/build* in the repository, and top-level folders in the scratchpad (CLAUDE_SCRATCHPAD).
function buildFolders() {
  const roots = [path.join(ROOT, 'engine')];
  if (process.env.CLAUDE_SCRATCHPAD) roots.push(process.env.CLAUDE_SCRATCHPAD);
  const out = [];
  for (const root of roots) {
    if (!fs.existsSync(root)) continue;
    for (const e of fs.readdirSync(root, { withFileTypes: true })) {
      if (!e.isDirectory()) continue;
      if (root.endsWith('engine') && !e.name.startsWith('build')) continue;
      const dir = path.join(root, e.name);
      if (fs.existsSync(path.join(dir, 'CMakeCache.txt'))) out.push(dir);
    }
  }
  return out;
}

function size(dir) {
  try {
    return execFileSync('du', ['-sh', dir], { encoding: 'utf8' }).split('\t')[0];
  } catch {
    return '?';
  }
}

function backup(dryRun) {
  tryGit(['fetch', '-q', 'origin', 'Main']);
  let failed = 0;
  for (const w of worktrees()) {
    const d = decide(w);
    if (d.note) console.log(`WARN backup - ${w.name} has ${d.note} (${w.dir})`);
    if (!d.backup) continue;
    const branch = backupBranch(w.name);
    if (dryRun) {
      console.log(`PASS backup - would push ${w.name} (${w.ahead} commit(s)) to ${branch}`);
      continue;
    }
    try {
      git(['push', '-q', 'origin', `${w.tip}:refs/heads/${branch}`]);
      console.log(`PASS backup - pushed ${w.name} (${w.ahead} commit(s)) to ${branch}`);
    } catch (e) {
      failed++;
      console.log(`FAIL backup - push of ${w.name} to ${branch} failed: ${String(e.stderr || e.message).trim()}`);
    }
  }
  return failed ? 1 : 0;
}

function clean(apply, days) {
  tryGit(['fetch', '-q', 'origin', 'Main']);
  for (const w of worktrees()) {
    const d = decide(w);
    if (!d.remove) {
      console.log(`PASS clean - keeps ${w.name}: ${d.note || `${w.ahead} commit(s) Main lacks, not backed up (run backup)`}`);
      continue;
    }
    if (!apply) {
      console.log(`PASS clean - would remove worktree ${w.name}`);
      continue;
    }
    git(['worktree', 'remove', w.dir]);
    console.log(`PASS clean - removed worktree ${w.name} (its branch stays)`);
  }
  const now = Date.now();
  const inWorktree = (dir) => dir.startsWith(WORKTREES + path.sep);
  for (const dir of buildFolders()) {
    if (inWorktree(dir) || !staleBuild(newestMtime(dir), now, days)) continue;
    const rel = path.relative(ROOT, dir).startsWith('..') ? dir : path.relative(ROOT, dir);
    if (!apply) {
      console.log(`PASS clean - would remove build ${rel} (${size(dir)}, untouched for over ${days} day(s))`);
      continue;
    }
    fs.rmSync(dir, { recursive: true, force: true });
    console.log(`PASS clean - removed build ${rel}`);
  }
  return 0;
}

function main(argv) {
  const [cmd, ...rest] = argv;
  const flag = (f) => rest.includes(f);
  const daysAt = rest.indexOf('--days');
  const days = daysAt >= 0 ? Number(rest[daysAt + 1]) : 1;
  if (cmd === 'backup') return backup(flag('--dry-run'));
  if (cmd === 'clean' && Number.isFinite(days) && days >= 0) return clean(flag('--apply'), days);
  console.error('usage: worktree-tidy.js backup [--dry-run] | clean [--apply] [--days <n>]');
  return 2;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = { decide, backupBranch, staleBuild };
