// Builds START.md: the one file a chat agent fetches first, bundling the agent route, project rules and every area rule.
// Usage: node scripts/agent-context.js <out.md> [--commit SHA]
// Generated from the files below on every push to the default branch; never edit START.md by hand.
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ENTRY = ['AGENTS.md', 'CLAUDE.md', 'docs/vision.md'];
const RULES_DIR = '.claude/rules';
const REPO = 'Kmandevr/C.A.W';

function read(rel) {
  return fs.readFileSync(path.join(ROOT, rel), 'utf8').replace(/\r\n/g, '\n').trim();
}

// Area rules start with a `paths:` frontmatter list; it is what tells an agent when the rule applies.
function rulePaths(text) {
  const m = text.match(/^---\npaths:\n([\s\S]*?)\n---/);
  return m ? m[1].split('\n').map((l) => l.replace(/^\s*-\s*"?|"?\s*$/g, '')).filter(Boolean) : [];
}

const args = process.argv.slice(2);
const out = args[0];
if (!out) { console.log('FAIL agent-context - usage: agent-context.js <out.md> [--commit SHA]'); process.exit(1); }
const commitAt = args.indexOf('--commit');
const commit = commitAt > 0 ? args[commitAt + 1] : 'unknown';

const rules = fs.readdirSync(path.join(ROOT, RULES_DIR)).filter((f) => f.endsWith('.md')).sort()
  .map((f) => { const rel = `${RULES_DIR}/${f}`; const text = read(rel); return { rel, text, paths: rulePaths(text) }; });

const md = [];
md.push('# C.A.W start file for chat agents', '');
md.push(`Generated from \`${commit}\` on the default branch at ${new Date().toISOString().replace(/\.\d+Z$/, 'Z')} by \`scripts/agent-context.js\`. Don't edit it; edit the files it bundles.`, '');
md.push('Read this whole file before doing anything else. It replaces separately reading `AGENTS.md`, `CLAUDE.md`, `docs/vision.md` and `.claude/rules/*.md`.', '');
md.push('## Before you start: confirm in your first reply', '');
md.push(`1. The commit this file was generated from (\`${commit.slice(0, 7)}\`).`);
md.push('2. The task issue number and your branch (`gpt/<issue>-<short-name>`).');
md.push('3. The progress comment\'s next action, or "new task" if there is none yet.');
md.push('4. Which area rules below apply to the files you will touch.');
md.push(`5. The latest Quick check report for your branch, if one exists: \`quick-check/<branch with / as -->.md\` on the \`agent-results\` branch (or https://raw.githubusercontent.com/${REPO}/agent-results/quick-check/<name>.md).`, '');
md.push('Then follow "The loop" in the AGENTS.md section.', '');
md.push('## Area rules: when each applies', '', '| Rule | Applies to |', '| --- | --- |');
for (const r of rules) md.push(`| \`${r.rel}\` | ${r.paths.map((p) => `\`${p}\``).join(', ') || 'see the file'} |`);
for (const rel of ENTRY) md.push('', '---', '', `## File: \`${rel}\``, '', read(rel));
for (const r of rules) md.push('', '---', '', `## File: \`${r.rel}\``, '', r.text);
md.push('');

fs.writeFileSync(out, md.join('\n'));
const words = md.join(' ').split(/\s+/).length;
console.log(`PASS agent-context - ${ENTRY.length + rules.length} files bundled, about ${words} words (${out})`);
