// Docs guard, no dependencies: keeps docs/ (and the README, CLAUDE.md and .claude/ notes) true to the repository.
// FAIL (broken facts): note frontmatter, [[wikilinks]], relative links, repo paths named in `code`, npm scripts,
// `covers:` entries and the vault index.
// WARN (maybe stale): files changed on this branch that a note covers while the note itself didn't change, and code
// areas no note covers. Each note's `covers:` frontmatter lists the code it describes (.claude/rules/docs.md).
// Usage: node scripts/docs-test.js [--base <ref>] [--stale] [--strict]   (exit 1 on any FAIL; --stale prints only the
// stale notes, one "note<TAB>changed files" line each, for the Stop hook; --strict, used by CI on pull requests, makes a
// stale note a FAIL: update it, or at least re-check it and bump its `updated:`, in the same change). Base: --base, else origin/$GITHUB_BASE_REF, else origin/main,
// else origin/HEAD (the remote's default branch).
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const args = process.argv.slice(2);
const STALE_ONLY = args.includes("--stale");
const STRICT = args.includes("--strict");
const baseArg = args.includes("--base") ? args[args.indexOf("--base") + 1] : null;

const out = [];
const add = (level, check, detail, file) => out.push(`${level} ${check} - ${detail}${file ? ` (${file})` : ""}`);
const read = (f) => fs.readFileSync(path.join(ROOT, f), "utf8");
const git = (...a) => { try { return execFileSync("git", a, { cwd: ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }); } catch { return null; } };
const lines = (s) => (s || "").split("\n").filter(Boolean);

// Tracked files plus new untracked ones: what "exists in the repo" means here.
const FILES = [...new Set([...lines(git("ls-files")), ...lines(git("ls-files", "--others", "--exclude-standard"))])]
  .filter((f) => fs.existsSync(path.join(ROOT, f)));
const PKG = FILES.includes("package.json") ? JSON.parse(read("package.json")).scripts || {} : {};
const exists = (p) => { const q = p.replace(/^\/+/, "").replace(/\/$/, ""); return FILES.some((f) => f === q || f.startsWith(q + "/")); };

// ---------- notes and frontmatter ----------
const NOTES = FILES.filter((f) => /^docs\/[^/]+\.md$/.test(f)).sort();
const HISTORY = new Set(["docs/log.md", "docs/decisions.md"]); // dated history: may name files that are gone
const frontmatter = (text) => {
  const m = text.match(/^---\n([\s\S]*?)\n---\n/);
  if (!m) return null;
  return Object.fromEntries(lines(m[1]).map((l) => l.match(/^([\w-]+):\s*(.*)$/)).filter(Boolean).map((x) => [x[1], x[2].trim()]));
};
const covers = {}; // note -> [pattern]
for (const note of NOTES) {
  const fm = frontmatter(read(note));
  if (!fm) { add("FAIL", "frontmatter", "no frontmatter block", note); continue; }
  for (const k of ["title", "summary"]) if (!fm[k]) add("FAIL", "frontmatter", `missing ${k}:`, note);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(fm.updated || "")) add("FAIL", "frontmatter", "updated: must be YYYY-MM-DD", note);
  if (fm.covers === undefined) continue;
  const list = fm.covers.match(/^\[(.*)\]$/);
  if (!list) { add("FAIL", "covers", "covers: must be a one-line list, e.g. [engine/vm/, scripts/docs-test.js]", note); continue; }
  covers[note] = list[1].split(",").map((s) => s.trim().replace(/^["']|["']$/g, "")).filter(Boolean);
}
const toRegex = (pat) => new RegExp("^" + pat.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*\*/g, "\0").replace(/\*/g, "[^/]*").replace(/\0/g, ".*") + (pat.endsWith("/") ? "" : "$"));
const matches = (pat, file) => toRegex(pat).test(file);
for (const [note, pats] of Object.entries(covers)) {
  for (const p of pats) if (!FILES.some((f) => matches(p, f))) add("FAIL", "covers", `"${p}" matches no file`, note);
}

// ---------- links and named paths ----------
const DOCS = [...NOTES, ...FILES.filter((f) => /^(README\.md|CLAUDE\.md|\.claude\/.*\.md)$/.test(f) && !f.startsWith(".claude/worktrees/") && f !== ".claude/handoff.md")];
const OPTIONAL = new Set([".claude/handoff.md"]); // written by the handoff skill only while a task is unfinished
const TOP = new Set(FILES.map((f) => f.split("/")[0]));
const stripCode = (s) => s.replace(/^---\n[\s\S]*?\n---\n/, "").replace(/```[\s\S]*?```/g, "").replace(/`[^`\n]*`/g, "");
for (const doc of DOCS) {
  const text = read(doc);
  if (/\[\[[^\]]+\]\]/.test(stripCode(text))) add("FAIL", "wikilink", "use [text](note.md), not [[wikilinks]]", doc);
  for (const [, target] of stripCode(text).matchAll(/\]\(([^)\s]+)\)/g)) {
    if (/^[a-z]+:|^#|^\//i.test(target)) continue; // external, anchor or site address
    const rel = path.posix.normalize(path.posix.join(path.posix.dirname(doc), decodeURI(target.split("#")[0])));
    if (!exists(rel)) add("FAIL", "link", `${target} doesn't exist`, doc);
  }
  if (HISTORY.has(doc)) continue;
  // Repo paths in `code`: only plain ones under a real top-level entry (no <placeholders>, globs or site URLs).
  for (const [, span] of text.matchAll(/`([^`\n]+)`/g)) {
    for (const tok of span.split(/\s+/)) {
      const p = tok.replace(/^\.\//, "").replace(/[,;:.)\]]+$/, "");
      if (!/^[\w.-]+\/[\w./[\]-]*$/.test(p) || p.startsWith("/") || /\.\.\.|\/\//.test(p)) continue;
      if (!TOP.has(p.split("/")[0]) || exists(p)) continue;
      if (OPTIONAL.has(p) || git("check-ignore", "-q", "--no-index", p) !== null) continue; // generated or local-only (dist/)
      add("FAIL", "path", `\`${p}\` doesn't exist`, doc);
    }
    const npm = span.match(/^npm run(?: -s)? ([\w:-]+)/);
    if (npm && !(npm[1] in PKG)) add("FAIL", "npm-script", `npm run ${npm[1]} isn't in package.json`, doc);
  }
}

// ---------- the README names everything someone new needs to find ----------
// Every top-level folder, workflow and npm script must appear in README.md (as `name`), so a new one can't be added
// without the README saying what it is.
if (FILES.includes("README.md")) {
  const readme = read("README.md");
  const named = (n) => readme.includes("`" + n);
  const want = [
    ...[...TOP].filter((t) => !t.startsWith(".") && FILES.some((f) => f.startsWith(t + "/"))),
    ...FILES.filter((f) => /^\.github\/workflows\/[^/]+\.ya?ml$/.test(f)),
    ...Object.keys(PKG).map((s) => (s === "test" ? "npm test" : `npm run ${s}`)),
  ];
  // npm scripts may sit in a shell block: `npm test`, or a script's name anywhere (e.g. "npm run test:api / test:browser").
  const npmNamed = (s) => (s === "npm test" ? /\bnpm test\b/ : new RegExp(`(^|[\\s/(])${s.slice(8).replace(/[^\w]/g, "\\$&")}\\b`, "m")).test(readme);
  const missing = want.filter((n) => !(n.startsWith("npm ") ? npmNamed(n) : named(n)));
  if (missing.length) add("FAIL", "readme", `README.md doesn't name ${missing.join(", ")}; say what each is`, "README.md");
}
// The README's own covers: list sits in an HTML comment on its first line (it has no frontmatter).
{
  const m = FILES.includes("README.md") && read("README.md").match(/^<!-- covers: \[(.*)\] -->/);
  if (m) covers["README.md"] = m[1].split(",").map((s) => s.trim()).filter(Boolean);
}

// ---------- the vault index lists every note ----------
if (NOTES.includes("docs/index.md")) {
  const index = read("docs/index.md");
  for (const note of NOTES) if (note !== "docs/index.md" && !index.includes(`](${path.basename(note)})`)) add("FAIL", "index", `${note} isn't linked from the vault index`, "docs/index.md");
}

// ---------- code areas no note covers ----------
const allCovers = Object.values(covers).flat();
const covered = (f) => allCovers.some((p) => matches(p, f));
const AREAS = [...new Set(FILES.flatMap((f) => {
  const m = f.match(/^(engine|android|library)\/([^/]+)\//);
  if (m) return [`${m[1]}/${m[2]}/`];
  if (path.basename(f).startsWith(".")) return [];
  return /^scripts\/[^/]+$|^\.github\/workflows\//.test(f) ? [f] : [];
}))].sort();
const uncovered = AREAS.filter((a) => !FILES.some((f) => f.startsWith(a) && covered(f)));
if (uncovered.length) add("WARN", "uncovered", `no note's covers: names ${uncovered.join(", ")}`);
else if (Object.keys(covers).length) add("PASS", "uncovered", "every code area is covered by a note");

// ---------- stale notes: covered code changed on this branch, the note didn't ----------
const baseRef = baseArg || (process.env.GITHUB_BASE_REF ? `origin/${process.env.GITHUB_BASE_REF}` : git("rev-parse", "-q", "--verify", "origin/main") ? "origin/main" : "origin/HEAD");
const mergeBase = (git("merge-base", baseRef, "HEAD") || "").trim();
let stale = [];
if (!mergeBase) add("WARN", "stale", `can't find ${baseRef}; skipped the changed-code check (fetch it, or pass --base <ref>)`);
else {
  const changed = new Set([...lines(git("diff", "--name-only", mergeBase)), ...lines(git("ls-files", "--others", "--exclude-standard"))]);
  for (const [note, pats] of Object.entries(covers)) {
    if (changed.has(note)) continue;
    const hit = [...changed].filter((f) => f !== note && pats.some((p) => matches(p, f)));
    if (hit.length) stale.push([note, hit]);
  }
  for (const [note, hit] of stale) add(STRICT ? "FAIL" : "WARN", "stale", `covers changed files (${hit.slice(0, 5).join(", ")}${hit.length > 5 ? ` +${hit.length - 5} more` : ""}); check it still holds and update it if not`, note);
  if (!stale.length) add("PASS", "stale", `every note covering code changed since ${baseRef} was updated too`);
}

if (STALE_ONLY) {
  for (const [note, hit] of stale) console.log(`${note}\t${hit.join(" ")}`);
  process.exit(0);
}
const fails = out.filter((l) => l.startsWith("FAIL")).length;
if (!fails) out.unshift(`PASS docs - ${NOTES.length} notes and ${DOCS.length - NOTES.length} other docs: frontmatter, links, paths and index hold`);
console.log(out.join("\n"));
process.exit(fails ? 1 : 0);
