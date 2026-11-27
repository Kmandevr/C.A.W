// Makes a per-build compat hash table (engine/tests/drums_compat_hashes*.inc) from an old build's printed hashes, for compat-tables.yml.
'use strict';

// Usage: node scripts/compat-table.js --printed <caw_tests output> --names <a committed table: which presets, in order>
//          --array <C++ array name> --comment <the new file's first line> [--compare <the committed table for this build>]
// The printed output is `CAW_PRINT_DRUM_HASHES=1 caw_tests drums_presets_from_before_1_1_render_bit_identically`
// from the old commit: one `    {"<preset>", 0x<16 hex>ull},` line per preset. The new table takes the presets the
// names table lists, in its order, with the printed hashes, and goes to stdout. A preset the old build did not print
// fails. Status goes to stderr as PASS|WARN|FAIL lines; with --compare, a WARN line names the entries that differ from
// the committed table (not a FAIL: a record is a record, and differing bits are what the job is for finding out).

const fs = require('fs');

const ENTRY = /^\s*\{"((?:[^"\\]|\\.)*)", (0x[0-9a-f]{16})ull\},\s*$/;

// The `{"name", 0x...ull},` entries of a table or of printed output, as [name, hash] in order.
function entries(text) {
  const out = [];
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(ENTRY);
    if (m) out.push([m[1], m[2]]);
  }
  return out;
}

// The new table's text, or throws naming the presets the printed output lacks.
function makeTable(printedText, namesText, array, comment) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(array)) throw new Error(`bad array name: ${array}`);
  const oneLine = comment.replace(/[\r\n]+/g, ' ').trim();
  const printed = new Map(entries(printedText));
  const names = entries(namesText).map(([n]) => n);
  if (!names.length) throw new Error('the names table lists no presets');
  if (!printed.size) throw new Error('the printed output holds no hashes (did the old build print its table?)');
  const missing = names.filter((n) => !printed.has(n));
  if (missing.length) throw new Error(`the old build printed no hash for ${missing.join(', ')}`);
  const lines = names.map((n) => `    {"${n}", ${printed.get(n)}ull},`);
  return `// ${oneLine}\nconst Known ${array}[] = {\n${lines.join('\n')}\n};\n`;
}

// How a new table compares with a committed one, entry by entry.
function compare(newText, committedText) {
  const committed = new Map(entries(committedText));
  const rows = entries(newText);
  const differ = rows.filter(([n, h]) => committed.has(n) && committed.get(n) !== h).map(([n]) => n);
  const absent = rows.filter(([n]) => !committed.has(n)).map(([n]) => n);
  return { total: rows.length, same: rows.length - differ.length - absent.length, differ, absent };
}

function args(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    if (!argv[i].startsWith('--') || i + 1 >= argv.length) throw new Error(`bad argument: ${argv[i]}`);
    out[argv[i].slice(2)] = argv[i + 1];
  }
  for (const k of ['printed', 'names', 'array', 'comment']) if (!(k in out)) throw new Error(`--${k} is required`);
  return out;
}

if (require.main === module) {
  try {
    const a = args(process.argv.slice(2));
    const table = makeTable(fs.readFileSync(a.printed, 'utf8'), fs.readFileSync(a.names, 'utf8'), a.array, a.comment);
    process.stdout.write(table);
    console.error(`PASS table - ${entries(table).length} presets recorded`);
    if (a.compare) {
      if (!fs.existsSync(a.compare)) {
        console.error(`PASS compare - no committed table for this build yet (${a.compare})`);
      } else {
        const c = compare(table, fs.readFileSync(a.compare, 'utf8'));
        const status = c.same === c.total ? 'PASS' : 'WARN';
        console.error(`${status} compare - ${c.same} of ${c.total} entries the same as the committed table` +
          (c.differ.length ? `; different: ${c.differ.join(', ')}` : '') +
          (c.absent.length ? `; not in it: ${c.absent.join(', ')}` : '') + ` (${a.compare})`);
      }
    }
  } catch (e) {
    console.error(`FAIL table - ${e.message}`);
    process.exit(1);
  }
}

module.exports = { entries, makeTable, compare };
