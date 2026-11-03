// Writes the Quick check report: one short Markdown file per branch that a chat agent can read in a single fetch.
// Usage: node scripts/quick-report.js <out.md> --branch B --commit SHA --run URL "<Check name>=<outcome>=<log file>" ...
// Outcomes are GitHub step outcomes (success, failure, cancelled, skipped, or empty when the step never ran).
'use strict';
const fs = require('fs');

const MAX_EXCERPT_LINES = 30;
const MAX_LINE_CHARS = 240;
// Lines that usually name the actual problem in compiler, ctest, Dart and docs-guard output.
const PROBLEM = /\b(error|FAIL(ED)?|failed|failure|Exception|assert(ion)?|undefined reference|No such file)\b|^\s*(✗|x) /i;

function parseArgs(argv) {
  const out = argv[0];
  const meta = {};
  const checks = [];
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) { meta[a.slice(2)] = argv[++i] || ''; continue; }
    const [name, outcome, log] = a.split('=');
    checks.push({ name, outcome: outcome || 'skipped', log });
  }
  if (!out) { console.log('FAIL quick-report - usage: quick-report.js <out.md> [--branch B --commit SHA --run URL] "Name=outcome=log" ...'); process.exit(1); }
  return { out, meta, checks };
}

function excerpt(logFile) {
  let text = '';
  try { text = fs.readFileSync(logFile, 'utf8'); } catch { return ['(no log was written)']; }
  const lines = text.split(/\r?\n/).filter((l) => l.trim() !== '');
  const problems = lines.filter((l) => PROBLEM.test(l) && !/^\s*PASS\b/.test(l));
  const picked = (problems.length ? problems : lines.slice(-MAX_EXCERPT_LINES)).slice(0, MAX_EXCERPT_LINES);
  return picked.map((l) => (l.length > MAX_LINE_CHARS ? l.slice(0, MAX_LINE_CHARS) + ' …' : l));
}

function label(outcome) {
  if (outcome === 'success') return 'PASS';
  if (outcome === 'failure') return 'FAIL';
  if (outcome === 'cancelled') return 'CANCELLED';
  return 'SKIPPED';
}

const { out, meta, checks } = parseArgs(process.argv.slice(2));
const results = checks.map((c) => ({ ...c, result: label(c.outcome) }));
const failed = results.filter((r) => r.result === 'FAIL' || r.result === 'CANCELLED');
const ran = results.filter((r) => r.result !== 'SKIPPED');
const verdict = failed.length === 0 && ran.length > 0 ? 'PASS' : 'FAIL';

const md = [];
md.push(`# Quick check: ${meta.branch || '(unknown branch)'}`, '');
md.push(`- Commit: \`${meta.commit || 'unknown'}\` (trust this report only if it is your latest commit)`);
md.push(`- Finished: ${new Date().toISOString().replace(/\.\d+Z$/, 'Z')}`);
md.push(`- Verdict: **${verdict}**`);
if (meta.run) md.push(`- Full logs: ${meta.run}`);
md.push('', '| Check | Result |', '| --- | --- |');
for (const r of results) md.push(`| ${r.name} | ${r.result} |`);
for (const r of failed) {
  md.push('', `## ${r.name}: ${r.result}`, '', '```text', ...excerpt(r.log), '```');
}
md.push('');
md.push(verdict === 'PASS'
  ? 'Next: if the task is finished, open the pull request (full CI and app builds run there). Otherwise do the next step.'
  : 'Next: fix only what the failing sections above name, push once, then read this file again for the new commit.');
md.push('');

fs.writeFileSync(out, md.join('\n'));
if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, `verdict=${verdict}\n`);
// This script's own check is writing the report; the workflow's last step turns a FAIL verdict into a red run.
console.log(`PASS quick-report - verdict ${verdict}: ${results.map((r) => `${r.name} ${r.result}`).join(', ')} (${out})`);
process.exit(0);
