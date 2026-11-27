// Names each failing Dart test from a `flutter test --file-reporter json:<file>` report, for a CI job's summary.
'use strict';

const fs = require('fs');

// Reads the JSON reporter's events (one per line) and returns the counts and the failures, in the order they ran.
function summarize(text) {
  const suites = new Map();
  const tests = new Map();
  const failures = [];
  let passed = 0;
  let skipped = 0;
  let done = null;
  for (const line of text.split('\n')) {
    if (!line.trim().startsWith('{')) continue;
    let e;
    try {
      e = JSON.parse(line);
    } catch {
      continue;
    }
    if (e.type === 'suite' && e.suite) suites.set(e.suite.id, e.suite.path || '');
    else if (e.type === 'testStart' && e.test) tests.set(e.test.id, { ...e.test, errors: [] });
    else if (e.type === 'error') {
      const t = tests.get(e.testID);
      if (t) t.errors.push(String(e.error || '').trim());
    } else if (e.type === 'testDone') {
      const t = tests.get(e.testID);
      if (!t) continue;
      if (e.result === 'success') {
        // A file's loading step is a hidden test: count only the tests people wrote.
        if (e.hidden) continue;
        if (e.skipped) skipped++;
        else passed++;
      } else {
        failures.push({
          file: suites.get(t.suiteID) || '',
          name: t.name,
          line: t.root_line || t.line || null,
          error: t.errors.find((m) => m) || e.result,
        });
      }
    } else if (e.type === 'done') done = e.success;
  }
  return { passed, skipped, failures, done };
}

function oneLine(s, max = 300) {
  const first = String(s).split('\n').find((l) => l.trim()) || '';
  return first.length > max ? first.slice(0, max - 1) + '…' : first;
}

// The step summary's Markdown: a count line, then a table naming each failing test.
function markdown(title, r) {
  const out = [`### ${title}`, ''];
  if (r.done === null && r.failures.length === 0) {
    out.push('The run ended before the test report finished (a build, load or timeout failure): see the Test step log.');
    return out.join('\n') + '\n';
  }
  out.push(`${r.passed} passed, ${r.failures.length} failed, ${r.skipped} skipped.`);
  if (r.failures.length) {
    out.push('', '| File | Test | First error line |', '| --- | --- | --- |');
    const cell = (s) => String(s).replace(/\|/g, '\\|').replace(/\n/g, ' ');
    for (const f of r.failures) {
      const where = f.line ? `${f.file}:${f.line}` : f.file;
      out.push(`| ${cell(where)} | ${cell(f.name)} | ${cell(oneLine(f.error))} |`);
    }
  }
  return out.join('\n') + '\n';
}

function main(argv) {
  const [file, title = 'Dart tests'] = argv;
  if (!file) {
    console.log('FAIL dart-test-summary - usage: node scripts/dart-test-summary.js <report.json> [title]');
    return 1;
  }
  let text = '';
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    text = '';
  }
  const r = summarize(text);
  const md = markdown(title, r);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, md);
  for (const f of r.failures) {
    // An annotation per failing test: the run's page names it without opening the log.
    const where = f.line ? `${f.file}:${f.line}` : f.file;
    console.log(`::error title=Dart test failed::${where}: ${f.name}`);
    console.log(`FAIL dart-test - ${f.name}: ${oneLine(f.error)} (${f.file})`);
  }
  if (r.done === null && r.failures.length === 0) {
    console.log(`FAIL dart-test-summary - no finished test report (${file})`);
    return 1;
  }
  if (r.failures.length === 0) console.log(`PASS dart-test - ${r.passed} passed, ${r.skipped} skipped (${file})`);
  return r.failures.length ? 1 : 0;
}

module.exports = { summarize, markdown };

if (require.main === module) process.exitCode = main(process.argv.slice(2));
