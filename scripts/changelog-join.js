// Joins the changes/ files (one per change: a "### New|Changed|Fixed" group and one bullet) into a version's CHANGELOG.md entry, in both copies, and deletes them; --check only parses them.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { extract } = require('./changelog-notes');

/** The groups a change file may name, in the order an entry lists them. */
const groups = ['New', 'Changed', 'Fixed'];

// Limits for what is read: a change is one bullet with a few nested ones, and a release joins a few dozen.
const maxFileChars = 4000;
const maxFileLines = 40;
const maxFiles = 500;
const maxDepth = 3; // the app's parser nests bullets at most this deep (lib/model/changelog.dart)

/** The two copies the join writes, relative to the repository root; the app's must stay identical to the root's. */
const copies = ['CHANGELOG.md', path.join('app', 'assets', 'CHANGELOG.md')];

/**
 * Parses one change file's [text]: { group, lines } with its bullet lines as written (CRLF and trailing spaces
 * dropped), or { error } saying what is wrong.
 */
function parseChange(text) {
  if (text.length > maxFileChars) return { error: `over ${maxFileChars} characters` };
  const all = text.replace(/\r\n?/g, '\n').split('\n').map((l) => l.replace(/\s+$/, ''));
  while (all.length && !all[0]) all.shift();
  while (all.length && !all[all.length - 1]) all.pop();
  if (!all.length) return { error: 'empty' };
  if (all.length > maxFileLines) return { error: `over ${maxFileLines} lines` };
  const g = /^###\s+(.*)$/.exec(all[0]);
  if (!g) return { error: `the first line must be the group: "### ${groups.join('", "### ')}"` };
  const group = groups.find((n) => n.toLowerCase() === g[1].trim().toLowerCase());
  if (!group) return { error: `unknown group "${g[1].trim()}": use ${groups.join(', ')}` };
  const lines = all.slice(1);
  if (!lines.length || !/^- \S/.test(lines[0])) return { error: 'the line after the group must be its bullet: "- **Name:** what changed"' };
  for (let i = 1; i < lines.length; i++) {
    const l = lines[i];
    if (!l) return { error: `blank line inside the bullet (line ${i + 2})` };
    if (/\t/.test(l)) return { error: `tab on line ${i + 2}: indent nested bullets by two spaces` };
    if (/^- /.test(l) || /^\S/.test(l)) return { error: `a second top-level line (line ${i + 2}): one change per file, nested bullets indent by two spaces` };
    const nested = /^( +)- \S/.exec(l);
    if (nested && (nested[1].length % 2 || nested[1].length / 2 > maxDepth)) {
      return { error: `nested bullet on line ${i + 2} must indent by 2, 4 or 6 spaces` };
    }
    // Any other indented line continues the bullet above it, as the app's parser reads it.
  }
  if (lines.some((l) => /^\s*#/.test(l))) return { error: 'a heading inside the bullet' };
  return { group, lines };
}

/** The change files in [dir]: every *.md but README.md, sorted by name so a join is repeatable. */
function changeFiles(dir) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch (e) {
    if (e.code === 'ENOENT') return [];
    throw e;
  }
  return names.filter((n) => n.endsWith('.md') && n !== 'README.md').sort();
}

/**
 * Reads and parses every change file in [dir]: { changes: [{ file, group, lines }], errors: [{ file, error }] }.
 */
function readChanges(dir) {
  const changes = [];
  const errors = [];
  const files = changeFiles(dir);
  if (files.length > maxFiles) return { changes, errors: [{ file: dir, error: `over ${maxFiles} change files` }] };
  for (const file of files) {
    const full = path.join(dir, file);
    let text;
    try {
      if (fs.statSync(full).size > maxFileChars * 4) {
        errors.push({ file: full, error: `over ${maxFileChars} characters` });
        continue;
      }
      text = fs.readFileSync(full, 'utf8');
    } catch (e) {
      errors.push({ file: full, error: `cannot read it: ${e.message}` });
      continue;
    }
    const r = parseChange(text);
    if (r.error) errors.push({ file: full, error: r.error });
    else changes.push({ file: full, group: r.group, lines: r.lines });
  }
  return { changes, errors };
}

/** The entry for [version] on [date]: its heading, an optional [summary] paragraph, then each group in order. */
function entry(version, date, changes, summary = '') {
  const out = [`## ${version} (${date})`, ''];
  if (summary.trim()) out.push(summary.trim(), '');
  for (const g of groups) {
    const mine = changes.filter((c) => c.group === g);
    if (!mine.length) continue;
    out.push(`### ${g}`);
    for (const c of mine) out.push(...c.lines);
  }
  return out.join('\n');
}

/** [text] with [block] inserted before its first "## " entry (or at its end), a blank line after it. */
function insertEntry(text, block) {
  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  const at = lines.findIndex((l) => /^##\s/.test(l) && !l.startsWith('###'));
  if (at < 0) {
    while (lines.length && !lines[lines.length - 1]) lines.pop();
    return [...lines, '', ...block.split('\n'), ''].join('\n');
  }
  return [...lines.slice(0, at), ...block.split('\n'), '', ...lines.slice(at)].join('\n');
}

/**
 * Joins the change files under [root]/changes into [version]'s entry dated [date] in both changelog copies, then
 * deletes them. Returns { ok, lines } with the PASS/WARN/FAIL lines to print; nothing is written on a FAIL.
 */
function join(root, version, date, { summary = '' } = {}) {
  const lines = [];
  const fail = (msg, file) => ({ ok: false, lines: [...lines, `FAIL changelog-join - ${msg} (${file})`] });
  const v = String(version || '').trim().replace(/^v/, '');
  if (!/^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$/.test(v)) return fail(`"${version || ''}" is not a version like 1.1.3-alpha.7`, 'arguments');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(date || ''))) return fail(`"${date || ''}" is not a date like 2026-11-27`, 'arguments');
  const dir = path.join(root, 'changes');
  const { changes, errors } = readChanges(dir);
  if (errors.length) return { ok: false, lines: errors.map((e) => `FAIL changes - ${e.error} (${path.relative(root, e.file)})`) };
  if (!changes.length) return fail('no change files to join: each change adds one first', 'changes/');
  const texts = [];
  for (const c of copies) {
    try {
      texts.push(fs.readFileSync(path.join(root, c), 'utf8'));
    } catch (e) {
      return fail(`cannot read it: ${e.message}`, c);
    }
  }
  if (texts[0] !== texts[1]) return fail(`${copies[1]} differs from ${copies[0]}: make it a copy first`, copies[1]);
  if (!/^no "## /.test(extract(texts[0], v).error || '')) {
    return fail(`it already has a "## ${v}" entry`, copies[0]);
  }
  const block = entry(v, date, changes, summary);
  const joined = insertEntry(texts[0], block);
  // The release job reads the entry back with changelog-notes.js: check it would pass there before writing.
  const back = extract(joined, v);
  if (back.error) return fail(`the joined entry would fail the release notes: ${back.error}`, copies[0]);
  for (const c of copies) fs.writeFileSync(path.join(root, c), joined);
  for (const c of changes) fs.rmSync(c.file);
  const counts = groups.map((g) => [g, changes.filter((c) => c.group === g).length]).filter(([, n]) => n);
  lines.push(`PASS changelog-join - ${changes.length} change file(s) joined into ${v}: ${counts.map(([g, n]) => `${g} ${n}`).join(', ')} (${copies.join(', ')})`);
  if (!summary.trim()) lines.push(`WARN changelog-join - no --summary: add the entry's one-line summary under its heading by hand, in both copies (${copies[0]})`);
  return { ok: true, lines, entry: block };
}

/** Parses every change file under [root]/changes without writing: the check CI runs. */
function check(root) {
  const dir = path.join(root, 'changes');
  const { changes, errors } = readChanges(dir);
  const lines = errors.map((e) => `FAIL changes - ${e.error} (${path.relative(root, e.file)})`);
  if (!errors.length) lines.push(`PASS changes - ${changes.length} change file(s) parse (changes/)`);
  return { ok: !errors.length, lines };
}

function main(argv) {
  let root = path.join(__dirname, '..');
  let summary = '';
  let checkOnly = false;
  const pos = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--root') root = argv[++i] || '';
    else if (argv[i] === '--summary') summary = argv[++i] || '';
    else if (argv[i] === '--check') checkOnly = true;
    else pos.push(argv[i]);
  }
  const r = checkOnly ? check(root) : join(root, pos[0], pos[1], { summary });
  for (const l of r.lines) (l.startsWith('PASS') ? console.log : console.error)(l);
  if (r.ok && r.entry) console.log(`\n${r.entry}`);
  return r.ok ? 0 : 1;
}

module.exports = { parseChange, readChanges, entry, insertEntry, join, check, groups, maxFileChars };

if (require.main === module) process.exitCode = main(process.argv.slice(2));
