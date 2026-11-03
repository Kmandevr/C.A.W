// Writes the Quick check report: one short Markdown file per branch that a chat agent can read in a single fetch.
// Usage: node scripts/quick-report.js <out.md> --branch B --commit SHA --run URL "<Check name>=<outcome>=<log file>" ...
// Outcomes are GitHub step outcomes (success, failure, cancelled, skipped, or empty when the step never ran).
'use strict';
const fs = require('fs');
const path = require('path');

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

// Names the .claude/rules files whose `paths:` globs match a changed file, so the agent rereads only those.
function globToRegex(glob) {
  const s = glob.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*\//g, '\u0000').replace(/\*\*/g, '\u0001')
    .replace(/\*/g, '[^/]*').replace(/\u0000/g, '(.*/)?').replace(/\u0001/g, '.*');
  return new RegExp(`^${s}$`);
}
function rulesFor(changedFile) {
  if (!changedFile) return [];
  let changed = [];
  try { changed = fs.readFileSync(changedFile, 'utf8').split('\n').filter(Boolean); } catch { return []; }
  const dir = path.join(__dirname, '..', '.claude', 'rules');
  let files = [];
  try { files = fs.readdirSync(dir).filter((f) => f.endsWith('.md')).sort(); } catch { return []; }
  return files.filter((f) => {
    const m = fs.readFileSync(path.join(dir, f), 'utf8').replace(/\r\n/g, '\n').match(/^---\npaths:\n([\s\S]*?)\n---/);
    const globs = m ? m[1].split('\n').map((l) => l.replace(/^\s*-\s*"?|"?\s*$/g, '')).filter(Boolean) : [];
    return globs.some((g) => changed.some((c) => globToRegex(g).test(c)));
  }).map((f) => `.claude/rules/${f}`);
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
const rules = rulesFor(meta.changed);
if (rules.length) md.push(`- Rules for the files you changed: ${rules.map((r) => `\`${r}\``).join(', ')} (all bundled in \`START.md\` on \`agent-results\`)`);
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
