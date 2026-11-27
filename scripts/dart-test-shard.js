// Picks the Dart test files for CI shard i of n, balanced by the measured times in app/test/test_times.json.
'use strict';

const fs = require('fs');
const path = require('path');

const APP = path.join(__dirname, '..', 'app');

// Every *_test.dart under <app>/test, relative to app/ (test/…), sorted.
function listTests(app = APP) {
  const out = [];
  const walk = (dir) => {
    for (const d of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, d.name);
      if (d.isDirectory()) walk(p);
      else if (d.isFile() && d.name.endsWith('_test.dart')) out.push(path.relative(app, p).split(path.sep).join('/'));
    }
  };
  walk(path.join(app, 'test'));
  return out.sort();
}

function median(values) {
  if (values.length === 0) return 1;
  const v = [...values].sort((a, b) => a - b);
  const m = Math.floor(v.length / 2);
  return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2;
}

// Greedy: heaviest file first (ties by path), each to the lightest shard (ties by the lower number). A file
// missing from the table weighs the table's median; table entries for files that are gone are ignored.
// Returns n shards of { files, seconds }, each shard's files heaviest first: `flutter test` starts files in the
// order given, so the longest ones don't start last and run on alone.
function assign(files, times, n) {
  if (!Number.isInteger(n) || n < 1) throw new Error(`the shard count must be a whole number of at least 1, not ${n}`);
  const fallback = median(Object.values(times));
  const weight = (f) => (Object.prototype.hasOwnProperty.call(times, f) ? times[f] : fallback);
  const order = [...new Set(files)].sort((a, b) => weight(b) - weight(a) || (a < b ? -1 : a > b ? 1 : 0));
  // Totals in tenths of a second as integers, so the comparison never depends on float rounding.
  const shards = Array.from({ length: n }, () => ({ files: [], tenths: 0 }));
  for (const f of order) {
    let best = 0;
    for (let i = 1; i < n; i++) if (shards[i].tenths < shards[best].tenths) best = i;
    shards[best].files.push(f);
    shards[best].tenths += Math.round(weight(f) * 10);
  }
  return shards.map((s) => ({ files: s.files, seconds: s.tenths / 10 }));
}

function readTimes(file) {
  try {
    const t = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (t && typeof t === 'object' && !Array.isArray(t)) {
      const out = {};
      for (const [k, v] of Object.entries(t)) if (typeof v === 'number' && v >= 0) out[k] = v;
      return out;
    }
  } catch {
    // No table (or a broken one): every file weighs the same.
  }
  return {};
}

function main(argv) {
  const usage = 'usage: node scripts/dart-test-shard.js <i> <n> | --check <n> [--times <file>] [--app <dir>]';
  const args = [...argv];
  const opt = (name, def) => {
    const k = args.indexOf(name);
    if (k < 0) return def;
    const v = args[k + 1];
    args.splice(k, 2);
    return v;
  };
  const app = opt('--app', APP);
  const times = readTimes(opt('--times', path.join(app, 'test', 'test_times.json')));
  const check = args[0] === '--check';
  if (check) args.shift();
  const files = listTests(app);
  if (files.length === 0) {
    console.error(`FAIL dart-test-shard - no test files (${path.join(app, 'test')})`);
    return 1;
  }
  if (check) {
    // Every file in exactly one shard, and none empty.
    const n = Number(args[0]);
    let shards;
    try {
      shards = assign(files, times, n);
    } catch (err) {
      console.log(`FAIL dart-test-shard - ${err.message}; ${usage}`);
      return 1;
    }
    const seen = new Map();
    for (const s of shards) for (const f of s.files) seen.set(f, (seen.get(f) || 0) + 1);
    const wrong = files.filter((f) => seen.get(f) !== 1);
    const empty = shards.findIndex((s) => s.files.length === 0);
    shards.forEach((s, i) => console.log(`PASS dart-test-shard - shard ${i + 1}/${n}: ${s.files.length} files, ${s.seconds} s measured`));
    if (wrong.length || seen.size !== files.length || empty >= 0) {
      console.log(`FAIL dart-test-shard - ${wrong.length} files not in exactly one shard${empty >= 0 ? `, shard ${empty + 1} empty` : ''}`);
      return 1;
    }
    console.log(`PASS dart-test-shard - all ${files.length} test files in exactly one of ${n} shards`);
    return 0;
  }
  const i = Number(args[0]);
  const n = Number(args[1]);
  if (!Number.isInteger(i) || !Number.isInteger(n) || n < 1 || i < 1 || i > n) {
    console.error(`FAIL dart-test-shard - ${usage}`);
    return 1;
  }
  const shard = assign(files, times, n)[i - 1];
  if (shard.files.length === 0) {
    console.error(`FAIL dart-test-shard - shard ${i}/${n} has no test files (more shards than files)`);
    return 1;
  }
  process.stdout.write(shard.files.join('\n') + '\n');
  return 0;
}

module.exports = { assign, listTests, median, readTimes };

if (require.main === module) process.exitCode = main(process.argv.slice(2));
