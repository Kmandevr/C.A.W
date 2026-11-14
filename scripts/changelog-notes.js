// Prints CHANGELOG.md's entry for one version (the "## <version>" section, its "(…)" suffix ignored) for the top of a GitHub Release's notes; fails when the version has no entry.
'use strict';
const fs = require('node:fs');
const path = require('node:path');

// Lines the app's update check reads from release notes (app/lib/model/updates/releases.dart): an entry must not
// contain one, or it would be read as the release's own.
const reserved = [
  /^\s*Build:\s*[0-9a-f]{7,40}\s*$/i,
  /^\s*SHA256\s+\S{1,200}:\s*[0-9a-fA-F]{64}\s*$/,
  /^\s*Version:\s*v?\S{1,64}\s*$/i,
];

// The app reads at most 20000 characters of a release's notes (releases.dart), and the SHA256 lines come after the
// entry: an entry is kept well under that.
const maxChars = 8000;

/** The version a "## " heading names: its text without a trailing "(…)". */
function headingVersion(line) {
  const m = /^##\s+(.*?)\s*$/.exec(line);
  if (!m || line.startsWith('###')) return null;
  return m[1].replace(/\s*\([^()]*\)\s*$/, '').trim();
}

/**
 * The entry for [version] in [text]: { body, note } with the lines between its heading and the next "## " heading
 * (blank lines at either end dropped), or { error } saying why there is none.
 */
function extract(text, version) {
  const want = String(version || '').trim().replace(/^v/, '');
  if (!want) return { error: 'no version given' };
  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  let start = -1;
  let note = '';
  for (let i = 0; i < lines.length; i++) {
    if (headingVersion(lines[i]) === want) {
      start = i;
      note = (/\(([^()]*)\)\s*$/.exec(lines[i]) || [])[1] || '';
      break;
    }
  }
  if (start < 0) return { error: `no "## ${want}" entry` };
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (headingVersion(lines[i]) !== null) {
      end = i;
      break;
    }
  }
  const body = lines.slice(start + 1, end);
  while (body.length && !body[0].trim()) body.shift();
  while (body.length && !body[body.length - 1].trim()) body.pop();
  if (!body.length) return { error: `the "## ${want}" entry is empty` };
  const joined = body.join('\n');
  if (joined.length > maxChars) return { error: `the "## ${want}" entry is over ${maxChars} characters (the checksum lines after it must stay readable)` };
  const bad = body.find((l) => reserved.some((r) => r.test(l)));
  if (bad) return { error: `the "## ${want}" entry has a line the update check reads: "${bad.trim()}"` };
  return { body: joined, note: note.trim() };
}

function main(argv) {
  let version = '';
  let file = path.join(__dirname, '..', 'CHANGELOG.md');
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--version') version = argv[++i] || '';
    else if (argv[i] === '--file') file = argv[++i] || '';
  }
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (e) {
    console.error(`FAIL changelog - cannot read it: ${e.message} (${file})`);
    return 1;
  }
  const r = extract(text, version);
  if (r.error) {
    console.error(`FAIL changelog - ${r.error}: each release adds its entry first (${path.basename(file)})`);
    return 1;
  }
  if (/not yet released/i.test(r.note)) {
    console.error(`WARN changelog - the ${version} heading still says "(${r.note})" (${path.basename(file)})`);
  }
  process.stdout.write(`${r.body}\n`);
  return 0;
}

module.exports = { extract, headingVersion, maxChars };

if (require.main === module) process.exitCode = main(process.argv.slice(2));
