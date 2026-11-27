// Names each failing engine test from a CTest log (`ctest --output-on-failure | tee <log>`), for a CI job's summary.
'use strict';

const fs = require('fs');

// The failing CTest entries, each caw_tests case's FAIL line and each sanitizer report, in log order.
function summarize(text) {
  const ctest = [];
  const cases = [];
  const sanitizer = [];
  let listing = false;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/^\d{4}-\d\d-\d\dT[\d:.]+Z /, '');  // GitHub's log timestamps, when present
    if (/^The following tests FAILED:/.test(line)) {
      listing = true;
      continue;
    }
    if (listing) {
      const m = line.match(/^\s+\d+\s+-\s+(\S+)\s+\((.+)\)/);
      if (m) {
        ctest.push(`${m[1]} (${m[2]})`);
        continue;
      }
      listing = false;
    }
    const f = line.match(/^FAIL (\S+) \(([^)]*)\): (.*)$/);
    if (f) cases.push({ name: f[1], where: f[2], message: f[3] });
    else if (/ERROR: (Address|Leak|Thread|Memory)Sanitizer|: runtime error: /.test(line)) sanitizer.push(line.trim());
  }
  return { ctest, cases, sanitizer };
}

function cut(s, max = 300) {
  return s.length > max ? s.slice(0, max - 1) + '…' : s;
}

function markdown(title, r) {
  const out = [`### ${title}`, ''];
  if (!r.ctest.length && !r.cases.length && !r.sanitizer.length) {
    out.push('No failing test in the log: the job failed outside the tests (build, configure or setup): see its log.');
    return out.join('\n') + '\n';
  }
  if (r.ctest.length) out.push(`CTest failed: ${r.ctest.map((t) => '`' + t + '`').join(', ')}`, '');
  if (r.cases.length) {
    out.push('| Test | Where | Message |', '| --- | --- | --- |');
    const cell = (s) => cut(String(s)).replace(/\|/g, '\\|');
    for (const c of r.cases) out.push(`| ${cell(c.name)} | ${cell(c.where)} | ${cell(c.message)} |`);
    out.push('');
  }
  if (r.sanitizer.length) {
    out.push('Sanitizer reports:', '');
    for (const s of r.sanitizer.slice(0, 20)) out.push('- `' + cut(s).replace(/`/g, "'") + '`');
  }
  return out.join('\n') + '\n';
}

function main(argv) {
  const [file, title = 'Engine tests'] = argv;
  if (!file) {
    console.log('FAIL ctest-summary - usage: node scripts/ctest-summary.js <ctest.log> [title]');
    return 1;
  }
  let text = '';
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    text = '';
  }
  const r = summarize(text);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, markdown(title, r));
  // One annotation per failing case (the run's page shows them without the log), then the CTest entries.
  for (const c of r.cases) console.log(`::error title=Engine test failed::${c.name} (${c.where}): ${cut(c.message, 200)}`);
  for (const s of r.sanitizer.slice(0, 5)) console.log(`::error title=Sanitizer report::${cut(s, 200)}`);
  for (const t of r.ctest) console.log(`FAIL ctest - ${t} (${file})`);
  if (!r.ctest.length && !r.cases.length && !r.sanitizer.length) console.log(`PASS ctest-summary - no failing test in ${file}`);
  return 0;  // the Test step's own exit code fails the job
}

module.exports = { summarize, markdown };

if (require.main === module) process.exitCode = main(process.argv.slice(2));
