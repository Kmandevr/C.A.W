// Checks the two numbered lists that branches race for: caw_bench's modes (engine/bench/bench_modes.h) and the C API versions (caw.h's history, CAW_API_VERSION, the app's cawApiVersion, the docs).
// FAIL: a bench mode number, name or ctest listed twice; a `caw_bench S N` in the docs, workflows or CMake naming no
// listed mode; a C API version in caw.h's history twice, out of order or not ending at CAW_API_VERSION; the app's
// cawApiVersion or a note's "`CAW_API_VERSION` N" / "`cawApiVersion` N" not equal to it (or to the version a
// "C API N" line is about).
// Usage: node scripts/number-lists.js   (exit 1 on any FAIL). docs-test.js runs the same checks (CI: docs.yml).
const fs = require("fs");
const path = require("path");

const BENCH = "engine/bench/bench_modes.h";
const CAW_H = "engine/include/caw.h";
const BINDINGS = "app/lib/engine/bindings.dart";
const HISTORY = new Set(["docs/log.md", "docs/decisions.md"]); // dated history: old numbers stay as they were

// The rows of bench::kModes: [{number, name, ctest, line}].
function benchModes(text) {
  const rows = [];
  text.split("\n").forEach((l, i) => {
    const m = l.match(/^\s*\{(-?\d+), "([a-z0-9_]+)", "([^"]*)", "([^"]*)",/);
    if (m) rows.push({ number: Number(m[1]), name: m[2], ctest: m[3], line: i + 1 });
  });
  return rows;
}

// caw.h's version history (the comment just before the #define) and the #define: {entries: [n...], current}.
function apiHistory(text) {
  const def = text.match(/^#define CAW_API_VERSION (\d+)/m);
  if (!def) return { entries: [], current: null };
  const block = text.slice(text.lastIndexOf("/*", def.index), def.index);
  const entries = [...block.matchAll(/^(?:\/\*)?\s*(\d+)(?: \(\d{4}-\d{2}-\d{2}|: not used)/gm)].map((m) => Number(m[1]));
  return { entries, current: Number(def[1]) };
}

// `caw_bench SECONDS N` and the like in a text: [{mode, line}].
function benchCalls(text) {
  const out = [];
  text.split("\n").forEach((l, i) => {
    for (const m of l.matchAll(/caw_bench(?:\.exe)?\s+(?:SECONDS|S|"?\$[\w{}.]+"?|\d+(?:\.\d+)?)\s+(-?\d+)\b/g)) out.push({ mode: Number(m[1]), line: i + 1 });
  });
  return out;
}

// Every check, over the repository at `root`: an array of "PASS|WARN|FAIL check - detail (file)" lines.
function check(root, files) {
  const out = [];
  const add = (level, name, detail, file) => out.push(`${level} ${name} - ${detail}${file ? ` (${file})` : ""}`);
  const has = (f) => fs.existsSync(path.join(root, f));
  const read = (f) => fs.readFileSync(path.join(root, f), "utf8");
  const dupes = (xs) => [...new Set(xs.filter((x, i) => xs.indexOf(x) !== i))];

  if (has(BENCH)) {
    const rows = benchModes(read(BENCH));
    const fails = out.length;
    if (!rows.length) add("FAIL", "bench-modes", "no mode rows found", BENCH);
    for (const n of dupes(rows.map((r) => r.number))) add("FAIL", "bench-modes", `mode ${n} is listed twice (lines ${rows.filter((r) => r.number === n).map((r) => r.line).join(", ")}): give the newer one the next free number`, BENCH);
    for (const n of dupes(rows.map((r) => r.name))) add("FAIL", "bench-modes", `name "${n}" is listed twice`, BENCH);
    for (const n of dupes(rows.map((r) => r.ctest).filter(Boolean))) add("FAIL", "bench-modes", `ctest ${n} is listed twice`, BENCH);
    const known = new Set(rows.map((r) => r.number));
    const where = (files || []).filter((f) => (/^docs\/[^/]+\.md$/.test(f) && !HISTORY.has(f)) || f === "README.md" || f === "engine/CMakeLists.txt" || /^\.github\/workflows\/[^/]+\.ya?ml$/.test(f) || /^\.claude\/.*\.md$/.test(f));
    let calls = 0;
    for (const f of where) {
      if (!has(f)) continue;
      for (const c of benchCalls(read(f))) {
        calls++;
        if (!known.has(c.mode)) add("FAIL", "bench-calls", `line ${c.line} runs caw_bench mode ${c.mode}, which ${BENCH} doesn't list`, f);
      }
    }
    if (out.length === fails) add("PASS", "bench-modes", `${rows.length} modes, each number once; ${calls} caw_bench calls in the docs, workflows and CMake name one`);
  }

  if (has(CAW_H)) {
    const fails = out.length;
    const { entries, current } = apiHistory(read(CAW_H));
    if (current === null) add("FAIL", "api-version", "no #define CAW_API_VERSION", CAW_H);
    else {
      for (const n of dupes(entries)) add("FAIL", "api-version", `version ${n} has two history entries: the later branch takes the next number`, CAW_H);
      entries.forEach((n, i) => { if (i && n !== entries[i - 1] + 1 && n !== entries[i - 1]) add("FAIL", "api-version", `history goes from ${entries[i - 1]} to ${n}`, CAW_H); });
      if (entries[entries.length - 1] !== current) add("FAIL", "api-version", `CAW_API_VERSION is ${current} but the history's last entry is ${entries[entries.length - 1]}`, CAW_H);
      if (has(BINDINGS)) {
        const m = read(BINDINGS).match(/^const int cawApiVersion = (\d+);/m);
        if (!m) add("FAIL", "api-version", "no `const int cawApiVersion = N;`", BINDINGS);
        else if (Number(m[1]) !== current) add("FAIL", "api-version", `cawApiVersion is ${m[1]}, CAW_API_VERSION ${current}: bump them together`, BINDINGS);
      }
      for (const f of (files || []).filter((f) => (/^docs\/[^/]+\.md$/.test(f) && !HISTORY.has(f)) || f === "README.md")) {
        if (!has(f)) continue;
        read(f).split("\n").forEach((l, i) => {
          // A line about one version ("- **C API 42:** ... `cawApiVersion` 42") may name that one; any other, the current.
          const about = (l.match(/^\W*C API (\d+)\b/) || [])[1];
          for (const m of l.matchAll(/`(?:CAW_API_VERSION|cawApiVersion)`,? (\d+)\b/g)) {
            const n = Number(m[1]);
            if (n !== current && String(n) !== about) add("FAIL", "api-version", `line ${i + 1} says ${m[0]}; the current version is ${current}${about ? ` (or the line's own C API ${about})` : ""}`, f);
          }
        });
      }
    }
    if (out.length === fails) add("PASS", "api-version", `C API ${current}: caw.h's history, the app's cawApiVersion and the notes agree`);
  }
  return out;
}

module.exports = { benchModes, apiHistory, benchCalls, check };

if (require.main === module) {
  const { execFileSync } = require("child_process");
  const root = path.resolve(__dirname, "..");
  let files = [];
  try { files = execFileSync("git", ["ls-files"], { cwd: root, encoding: "utf8" }).split("\n").filter(Boolean); } catch { /* not a checkout: the list checks still run */ }
  const out = check(root, files);
  console.log(out.join("\n"));
  process.exit(out.some((l) => l.startsWith("FAIL")) ? 1 : 0);
}
