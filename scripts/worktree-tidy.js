// Backs up agent worktrees to caw-backup-<name> branches and removes worktrees and scratch builds that are no longer needed.
//   node scripts/worktree-tidy.js backup [--dry-run]
//   node scripts/worktree-tidy.js clean [--apply] [--days <n>]
// `backup` pushes each worktree under .claude/worktrees whose commits Main lacks and whose backup branch is behind.
// It commits nothing: a worktree with uncommitted changes is reported, and its last commit is what gets pushed.
// The remote is public, so it runs only by hand, after reading what it would push (--dry-run), and it refuses a tip
// that adds secret-like files or private-plan paths (`blocked`).
// `clean` lists by default; with --apply it removes only what is safe: a clean worktree whose tip Main or its backup
// branch already holds and that nobody used for --days (default 1), and a CMake build folder (one holding
// CMakeCache.txt) untouched for as long.
// Branches are never deleted (settings.json asks first), and nothing outside the repository and scratchpad is touched.
'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
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

// What to do with one worktree, from its facts: { name, dirty, ahead (commits Main lacks, or null when git couldn't
// tell), tip, backupTip }. An unknown count keeps the worktree and pushes nothing.
function decide(w) {
  const backedUp = w.backupTip !== null && w.backupTip === w.tip;
  if (w.ahead === null) return { backup: false, remove: false, note: 'unknown commits ahead of Main (fetch origin Main)' };
  return {
    backup: w.ahead > 0 && !backedUp,
    remove: !w.dirty && (w.ahead === 0 || backedUp),
    note: w.dirty ? 'uncommitted changes (commit them to back them up)' : '',
  };
}

// Paths a backup must never publish: secret-like files and the private plans' folder.
const BLOCKED = [/(^|\/)\.env(\.|$)/, /\.(pem|key|p12|pfx|jks|keystore)$/i, /(^|\/)(id_rsa|id_ed25519|credentials\.json|key\.properties)$/, /(^|\/)docs\/caw\//, /token/i, /secret/i];
function blocked(paths) {
  return paths.filter((p) => BLOCKED.some((re) => re.test(p)));
}

// The scratchpad's build folders are cleaned only when it is a real folder under the system temp folder.
function safeScratchpad(dir, tmp) {
  if (!dir) return null;
  let real, realTmp;
  try {
    real = fs.realpathSync(dir);
    realTmp = fs.realpathSync(tmp);
  } catch {
    return null;
  }
  return real.startsWith(realTmp + path.sep) ? real : null;
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
    // A real folder only (not a link to a worktree elsewhere), and the top of its own worktree.
    if (!fs.lstatSync(dir).isDirectory() || !fs.existsSync(path.join(dir, '.git'))) continue;
    if (tryGit(['rev-parse', '--show-toplevel'], dir) !== fs.realpathSync(dir)) continue;
    const tip = tryGit(['rev-parse', 'HEAD'], dir);
    if (!tip) continue;
    const count = tryGit(['rev-list', '--count', `${MAIN}..${tip}`]);
    const ahead = count === null ? null : Number(count);
    const dirty = (tryGit(['status', '--porcelain'], dir) || '') !== '';
    // Last used: the newer of its tip's commit time and its index (git status and add touch it).
    const index = tryGit(['rev-parse', '--path-format=absolute', '--git-path', 'index'], dir);
    const committed = Number(tryGit(['log', '-1', '--format=%ct', tip], dir) || 0) * 1000;
    let used = committed;
    try {
      if (index) used = Math.max(used, fs.statSync(index).mtimeMs);
    } catch {
      used = Date.now();
    }
    out.push({ name, dir, tip, ahead, dirty, used, backupTip: backups.get(backupBranch(name)) || null });
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
  const scratch = safeScratchpad(process.env.CLAUDE_SCRATCHPAD, os.tmpdir());
  if (scratch) roots.push(scratch);
  else if (process.env.CLAUDE_SCRATCHPAD) console.log('WARN clean - CLAUDE_SCRATCHPAD is not under the temp folder; skipped');
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
    const added = (tryGit(['diff', '--name-only', '--diff-filter=AR', `${MAIN}...${w.tip}`]) || '').split('\n').filter(Boolean);
    const bad = blocked(added);
    if (bad.length) {
      failed++;
      console.log(`FAIL backup - ${w.name} adds ${bad.join(', ')}; not pushed (the remote is public)`);
      continue;
    }
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
  const now = Date.now();
  for (const w of worktrees()) {
    const d = decide(w);
    if (d.remove && !staleBuild(w.used, now, days)) {
      console.log(`PASS clean - keeps ${w.name}: used within ${days} day(s) (an agent may be working there)`);
      continue;
    }
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

module.exports = { decide, backupBranch, staleBuild, blocked, safeScratchpad };
