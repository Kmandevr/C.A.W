// Measures each Dart test file's run time from a `flutter test --file-reporter json:<file>` report, for app/test/test_times.json.
'use strict';

const fs = require('fs');
const path = require('path');

// A file's time is its wall-clock span: from its suite event (loading starts, which includes compiling the file)
// to the end of its last test. A shard pays for compiling and for setUpAll/tearDown gaps too, which a sum of the
// tests' own times would leave out (the hidden loading test covers compiling, not the gaps between tests).
function measure(text) {
  const suites = new Map(); // suite id -> { path, start, end }
  const tests = new Map(); // test id -> suite id
  for (const line of text.split('\n')) {
    if (!line.trim().startsWith('{')) continue;
    let e;
    try {
      e = JSON.parse(line);
    } catch {
      continue;
    }
    if (e.type === 'suite' && e.suite && e.suite.path) {
      suites.set(e.suite.id, { path: e.suite.path, start: e.time, end: e.time });
    } else if (e.type === 'testStart' && e.test) {
      tests.set(e.test.id, e.test.suiteID);
    } else if (e.type === 'testDone') {
      const s = suites.get(tests.get(e.testID));
      if (s && typeof e.time === 'number' && e.time > s.end) s.end = e.time;
    }
  }
  const times = {};
  for (const s of suites.values()) {
    const key = relative(s.path);
    // A file reported twice (a re-run) keeps its longer time.
    const seconds = Math.max(0, s.end - s.start) / 1000;
    times[key] = Math.max(times[key] || 0, seconds);
  }
  return times;
}

// Paths in the report are absolute or relative to app/; the table keys them relative to app/ (test/…).
function relative(p) {
  const s = String(p).replace(/\\/g, '/');
  if (s.startsWith('test/')) return s;
  const app = s.lastIndexOf('/app/test/');
  if (app >= 0) return s.slice(app + 5);
  const i = s.indexOf('/test/');
  return i >= 0 ? s.slice(i + 1) : s;
}

// Sorted by path, rounded to a tenth of a second, so a re-measure's diff is readable.
function format(times) {
  const out = {};
  for (const k of Object.keys(times).sort()) out[k] = Math.round(times[k] * 10) / 10;
  return JSON.stringify(out, null, 2) + '\n';
}

function main(argv) {
  const [report, out = path.join(__dirname, '..', 'app', 'test', 'test_times.json')] = argv;
  if (!report) {
    console.log('FAIL dart-test-times - usage: node scripts/dart-test-times.js <report.json> [out.json]');
    return 1;
  }
  let text;
  try {
    text = fs.readFileSync(report, 'utf8');
  } catch (err) {
    console.log(`FAIL dart-test-times - cannot read the report: ${err.message} (${report})`);
    return 1;
  }
  const times = measure(text);
  const n = Object.keys(times).length;
  if (n === 0) {
    console.log(`FAIL dart-test-times - no test files in the report (${report})`);
    return 1;
  }
  fs.writeFileSync(out, format(times));
  const total = Object.values(times).reduce((a, b) => a + b, 0);
  console.log(`PASS dart-test-times - ${n} files, ${Math.round(total)} s in all (${out})`);
  return 0;
}

module.exports = { measure, format, relative };

if (require.main === module) process.exitCode = main(process.argv.slice(2));
