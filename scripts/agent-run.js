// Runs a chat agent's requested commands in CI (tests, builds, search, Graphify) and writes its Quick check report.
// Usage: node scripts/agent-run.js plan --message-file F [--request TEXT] [--changed F] [--app true] --out plan.json
//        node scripts/agent-run.js run --plan plan.json --out report.md --branch B --commit SHA [--run URL] [--base REF]
// A commit message line `run: <command> [args]` (several lines, or `;` between commands) asks for exactly those
// commands; with none, the default set runs. Commands are a fixed list run without a shell, so arguments can't inject.
'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const MAX_COMMANDS = 20;
const MAX_LINE_CHARS = 240;
const INFO_LINES = 120;     // output shown for search and navigation commands
const PASS_TAIL = 6;        // output shown for a passing build or test
const FAIL_LINES = 40;      // output shown for a failure
const BUILD = { release: 'engine/build', asan: 'engine/build-asan' };
const TARGETS = ['caw_core', 'caw_engine', 'caw_cli', 'caw_tests', 'caw_bench'];
const GRAPH_SUBCOMMANDS = ['query', 'explain', 'affected'];
const PROBLEM = /\b(error|FAIL(ED)?|failed|failure|Exception|assert(ion)?|undefined reference|No such file)\b|^\s*(✗|x) /i;

// name: [needs, minArgs, maxArgs, one-line help]. `needs` decides which toolchains the workflow installs.
const COMMANDS = {
  docs: [[], 0, 0, 'docs guard, strict (stale notes fail)'],
  build: [['engine'], 0, 1, `engine build; optional target: ${TARGETS.join(', ')}`],
  test: [['engine'], 0, 1, 'engine tests; optional name filter (substring), else the full ctest suite'],
  sanitize: [['engine'], 0, 1, 'engine tests under AddressSanitizer/UBSan (Debug); optional name filter'],
  examples: [['engine'], 0, 0, 'caw check of every example and the generated language-docs check'],
  check: [['engine'], 1, 20, 'caw check of the given .caw files'],
  render: [['engine'], 1, 2, 'caw render of one .caw file to WAV (artifact); optional BPM, default 140'],
  bench: [['engine'], 0, 0, 'engine benchmark (callback time, real-time load, memory)'],
  analyze: [['flutter'], 0, 20, 'flutter analyze; optional paths under app/'],
  'dart-test': [['flutter', 'engine'], 0, 2, 'flutter test against the native engine; optional test path under app/, then a name filter'],
  grep: [[], 1, 20, 'ripgrep: regex, then optional paths'],
  refs: [[], 1, 1, 'whole-word uses of an identifier in engine/, app/, examples/ and scripts/'],
  tree: [[], 0, 1, 'repo map with each file\'s purpose; optional directory'],
  graph: [['graph'], 2, 10, `Graphify: ${GRAPH_SUBCOMMANDS.join('|')} then its arguments`],
  symbols: [['ctags'], 1, 1, 'symbols defined in one file, with line numbers'],
  def: [['ctags'], 1, 1, 'where a symbol is defined (engine and app sources)'],
};
const DEFAULT = ['docs', 'build', 'test', 'examples'];
const DEFAULT_APP = ['analyze', 'dart-test'];

function args(argv) {
  const o = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) o[argv[i].slice(2)] = argv[i + 1] === undefined ? '' : argv[++i];
    else o._.push(argv[i]);
  }
  return o;
}
const readOr = (f, d) => { try { return fs.readFileSync(f, 'utf8'); } catch { return d; } };
const clip = (l) => (l.length > MAX_LINE_CHARS ? l.slice(0, MAX_LINE_CHARS) + ' …' : l);

// Shell-like words: spaces separate, "..." or '...' group. No expansion of any kind.
function words(text) {
  const out = []; let cur = ''; let q = null; let has = false;
  for (const ch of text) {
    if (q) { if (ch === q) q = null; else cur += ch; continue; }
    if (ch === '"' || ch === "'") { q = ch; has = true; continue; }
    if (/\s/.test(ch)) { if (has || cur) out.push(cur); cur = ''; has = false; continue; }
    cur += ch;
  }
  if (has || cur) out.push(cur);
  return out;
}

function requested(message, extra) {
  const lines = [];
  for (const l of `${message}\n${extra || ''}`.split(/\r?\n/)) {
    const m = l.match(/^\s*run:\s*(.*)$/i);
    if (m) lines.push(...m[1].split(';').map((s) => s.trim()).filter(Boolean));
  }
  return lines;
}

// Paths must stay inside the repository and can't pose as options.
function safePath(p, { mustExist = true, under = null } = {}) {
  const n = path.posix.normalize(p.replace(/\\/g, '/'));
  if (!p || p.startsWith('-') || path.isAbsolute(p) || n.startsWith('..') || n.split('/').includes('..')) return `path "${p}" must be relative to the repository root`;
  if (under && !(n === under || n.startsWith(`${under}/`))) return `path "${p}" must be under ${under}/`;
  if (mustExist && !fs.existsSync(path.join(ROOT, n))) return `path "${p}" does not exist`;
  return null;
}

function validate(name, a) {
  const spec = COMMANDS[name];
  if (!spec) return `unknown command "${name}"; known: ${Object.keys(COMMANDS).join(', ')}`;
  if (a.length < spec[1] || a.length > spec[2]) return `"${name}" takes ${spec[1]}–${spec[2]} arguments (${spec[3]})`;
  if (name === 'build' && a[0] && !TARGETS.includes(a[0])) return `unknown target "${a[0]}"; known: ${TARGETS.join(', ')}`;
  if ((name === 'test' || name === 'sanitize') && a[0] && a[0].startsWith('-')) return 'a test filter can\'t start with "-"';
  if (name === 'check' || name === 'render') {
    const files = name === 'render' ? a.slice(0, 1) : a;
    for (const f of files) { const e = safePath(f); if (e) return e; if (!f.endsWith('.caw')) return `"${f}" is not a .caw file`; }
    if (name === 'render' && a[1] && !/^\d{2,3}(\.\d+)?$/.test(a[1])) return `BPM "${a[1]}" must be a number`;
  }
  if (name === 'analyze') for (const p of a) { const e = safePath(p, { under: 'app' }); if (e) return e; }
  if (name === 'dart-test' && a[0]) { const e = safePath(a[0], { under: 'app' }); if (e) return e; }
  if (name === 'grep') for (const p of a.slice(1)) { const e = safePath(p); if (e) return e; }
  if (name === 'refs' && !/^[A-Za-z_][A-Za-z0-9_:~]*$/.test(a[0])) return `"${a[0]}" is not an identifier`;
  if (name === 'tree' && a[0]) { const e = safePath(a[0]); if (e) return e; }
  if (name === 'graph') {
    if (!GRAPH_SUBCOMMANDS.includes(a[0])) return `graph subcommand must be one of ${GRAPH_SUBCOMMANDS.join(', ')}`;
    if (a.slice(1).some((x) => x.startsWith('-'))) return 'graph arguments can\'t start with "-"';
  }
  if (name === 'symbols') { const e = safePath(a[0]); if (e) return e; }
  if (name === 'def' && !/^[A-Za-z_][A-Za-z0-9_]*$/.test(a[0])) return `"${a[0]}" is not a symbol name`;
  return null;
}

function plan(o) {
  const lines = requested(readOr(o['message-file'], ''), o.request);
  const changed = readOr(o.changed, '').split('\n').filter(Boolean);
  const app = o.app === 'true' || changed.some((f) => f.startsWith('app/'));
  const source = lines.length ? 'requested' : 'default';
  const text = lines.length ? lines : [...DEFAULT, ...(app ? DEFAULT_APP : [])];
  const steps = text.slice(0, MAX_COMMANDS).map((t) => {
    const [name, ...a] = words(t);
    return { text: t, name, args: a, error: validate(name, a) };
  });
  if (text.length > MAX_COMMANDS) steps.push({ text: `(${text.length - MAX_COMMANDS} more)`, name: '-', args: [], error: `at most ${MAX_COMMANDS} commands per push` });
  const needs = new Set();
  for (const s of steps) if (!s.error) for (const n of COMMANDS[s.name][0]) needs.add(n);
  fs.writeFileSync(o.out, JSON.stringify({ source, changed, steps }, null, 2));
  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, ['engine', 'flutter', 'graph', 'ctags'].map((n) => `${n}=${needs.has(n)}\n`).join(''));
  }
  console.log(`PASS agent-run - ${source} plan: ${steps.map((s) => s.text).join('; ')} (${o.out})`);
}

// Runs one program with stdout and stderr interleaved into a single log, as a terminal would show them.
function exec(log, program, argv, { cwd = ROOT, env = {}, timeoutSec = 1200 } = {}) {
  fs.appendFileSync(log, `$ ${program} ${argv.join(' ')}\n`);
  const fd = fs.openSync(log, 'a');
  const r = spawnSync(program, argv, { cwd, env: { ...process.env, ...env }, stdio: ['ignore', fd, fd], timeout: timeoutSec * 1000 });
  fs.closeSync(fd);
  if (r.error) fs.appendFileSync(log, `${r.error.code === 'ETIMEDOUT' ? `timed out after ${timeoutSec}s` : r.error.message}\n`);
  return r.status === null ? 124 : r.status;
}

const configured = new Set();
const flutterReady = { done: false };
function configure(log, kind) {
  if (configured.has(kind)) return 0;
  const flags = kind === 'asan' ? ['-DCMAKE_BUILD_TYPE=Debug', '-DCAW_SANITIZE=ON'] : ['-DCMAKE_BUILD_TYPE=Release'];
  const s = exec(log, 'cmake', ['-S', 'engine', '-B', BUILD[kind], ...flags, '-DCMAKE_C_COMPILER_LAUNCHER=ccache', '-DCMAKE_CXX_COMPILER_LAUNCHER=ccache']);
  if (s === 0) configured.add(kind);
  return s;
}
function build(log, kind, target) {
  const c = configure(log, kind);
  if (c !== 0) return c;
  return exec(log, 'cmake', ['--build', BUILD[kind], '--parallel', ...(target ? ['--target', target] : [])]);
}
function flutterSetup(log) {
  if (flutterReady.done) return 0;
  const s = exec(log, 'flutter', ['--disable-analytics'], { cwd: path.join(ROOT, 'app') })
    || exec(log, 'flutter', ['pub', 'get'], { cwd: path.join(ROOT, 'app') });
  if (s === 0) flutterReady.done = true;
  return s;
}
const seq = (...fns) => { for (const f of fns) { const s = f(); if (s !== 0) return s; } return 0; };

// Returns [exit status, kind] for one validated step; kind 'info' shows its output, 'check' only a tail or errors.
function runStep(step, log, base) {
  const a = step.args;
  const cli = `${BUILD.release}/caw`;
  switch (step.name) {
    case 'docs': return [exec(log, 'node', ['scripts/docs-test.js', '--strict', '--base', base]), 'check'];
    case 'build': return [build(log, 'release', a[0]), 'check'];
    case 'test': return [a[0]
      ? seq(() => build(log, 'release', 'caw_tests'), () => exec(log, `${BUILD.release}/caw_tests`, [a[0]]))
      : seq(() => build(log, 'release', 'caw_tests'), () => exec(log, 'ctest', ['--test-dir', BUILD.release, '--output-on-failure', '--parallel', '4'])), 'check'];
    case 'sanitize': return [seq(() => build(log, 'asan', 'caw_tests'), () => exec(log, `${BUILD.asan}/caw_tests`, a[0] ? [a[0]] : [])), 'check'];
    case 'examples': {
      const ex = fs.readdirSync(path.join(ROOT, 'examples')).filter((f) => f.endsWith('.caw')).sort().map((f) => `examples/${f}`);
      return [seq(() => build(log, 'release', 'caw_cli'), () => exec(log, cli, ['check', ...ex]), () => exec(log, cli, ['docs', '--check', '--dir', 'docs'])), 'check'];
    }
    case 'check': return [seq(() => build(log, 'release', 'caw_cli'), () => exec(log, cli, ['check', ...a])), 'info'];
    case 'render': {
      fs.mkdirSync(path.join(ROOT, 'renders'), { recursive: true });
      const out = `renders/${path.basename(a[0], '.caw')}.wav`;
      return [seq(() => build(log, 'release', 'caw_cli'), () => exec(log, cli, ['render', a[0], '-o', out, '--bpm', a[1] || '140'])), 'info'];
    }
    case 'bench': return [seq(() => build(log, 'release', 'caw_bench'), () => exec(log, `${BUILD.release}/caw_bench`, [], { timeoutSec: 300 })), 'info'];
    case 'analyze': return [seq(() => flutterSetup(log), () => exec(log, 'flutter', ['analyze', ...a.map((p) => path.posix.relative('app', p) || '.')], { cwd: path.join(ROOT, 'app') })), 'check'];
    case 'dart-test': {
      const t = a[0] ? [path.posix.relative('app', a[0]) || '.'] : [];
      const name = a[1] ? ['--plain-name', a[1]] : [];
      return [seq(() => build(log, 'release', 'caw_engine'), () => flutterSetup(log),
        () => exec(log, 'flutter', ['test', '--concurrency=4', ...t, ...name], { cwd: path.join(ROOT, 'app'), env: { CAW_LIB: path.join(ROOT, BUILD.release, 'libcaw.so') } })), 'check'];
    }
    case 'grep': {
      const s = exec(log, 'rg', ['-n', '--no-heading', '--max-columns', '300', '-e', a[0], ...(a.length > 1 ? a.slice(1) : ['.'])]);
      return [s === 1 ? 0 : s, 'info'];
    }
    case 'refs': {
      const s = exec(log, 'rg', ['-n', '--no-heading', '-w', '-F', '-e', a[0], 'engine', 'app/lib', 'app/test', 'examples', 'scripts']);
      return [s === 1 ? 0 : s, 'info'];
    }
    case 'tree': return [exec(log, '.claude/tools/tree.sh', a), 'info'];
    case 'graph': return [exec(log, '.claude/tools/graph.sh', a, { timeoutSec: 900 }), 'info'];
    case 'symbols': return [exec(log, 'ctags', ['-x', '--sort=no', a[0]]), 'info'];
    case 'def': {
      const tmp = `${log}.tags`;
      const s = exec(tmp, 'ctags', ['-x', '-R', 'engine/src', 'engine/include', 'engine/platform', 'app/lib']);
      const hits = readOr(tmp, '').split('\n').filter((l) => l.split(/\s+/)[0] === a[0]);
      fs.appendFileSync(log, hits.length ? `${hits.join('\n')}\n` : `no definition of ${a[0]} found\n`);
      return [s, 'info'];
    }
    default: return [2, 'check'];
  }
}

function summarize(text, status, kind) {
  const lines = text.split(/\r?\n/).filter((l) => l.trim() !== '');
  if (status !== 0) {
    // Show the failing program's own output: earlier steps (a build before a test run) succeeded.
    const last = lines.map((l, i) => (l.startsWith('$ ') ? i : -1)).filter((i) => i >= 0).pop();
    const own = last === undefined ? lines : lines.slice(last);
    if (own.some((l) => /^0 tests, /.test(l))) return [...own.map(clip), 'No test name contains that filter. Filters match part of a TEST(name); `grep "TEST\\(" engine/tests` lists them.'];
    const problems = own.filter((l) => PROBLEM.test(l) && !/^\s*(PASS|ok)\b/.test(l));
    const tail = own.slice(-12);
    const pick = [...new Set([...problems.slice(0, FAIL_LINES - tail.length), ...tail])];
    return pick.map(clip);
  }
  if (kind === 'info') {
    const body = lines.filter((l) => !l.startsWith('$ '));
    const shown = body.slice(0, INFO_LINES).map(clip);
    if (body.length > INFO_LINES) shown.push(`… ${body.length - INFO_LINES} more lines (narrow the search)`);
    return shown.length ? shown : ['(no output)'];
  }
  return lines.filter((l) => !l.startsWith('$ ')).slice(-PASS_TAIL).map(clip);
}

function rulesFor(changed) {
  const dir = path.join(ROOT, '.claude', 'rules');
  const toRe = (g) => new RegExp(`^${g.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*\//g, '\u0000').replace(/\*\*/g, '\u0001')
    .replace(/\*/g, '[^/]*').replace(/\u0000/g, '(.*/)?').replace(/\u0001/g, '.*')}$`);
  let files = [];
  try { files = fs.readdirSync(dir).filter((f) => f.endsWith('.md')).sort(); } catch { return []; }
  return files.filter((f) => {
    const m = readOr(path.join(dir, f), '').replace(/\r\n/g, '\n').match(/^---\npaths:\n([\s\S]*?)\n---/);
    const globs = m ? m[1].split('\n').map((l) => l.replace(/^\s*-\s*"?|"?\s*$/g, '')).filter(Boolean) : [];
    return globs.some((g) => changed.some((c) => toRe(g).test(c)));
  }).map((f) => `.claude/rules/${f}`);
}

function run(o) {
  const p = JSON.parse(fs.readFileSync(o.plan, 'utf8'));
  const logDir = path.join(ROOT, 'logs');
  fs.mkdirSync(logDir, { recursive: true });
  const results = p.steps.map((step, i) => {
    if (step.error) return { step, result: 'INVALID', seconds: 0, lines: [step.error] };
    const log = path.join(logDir, `${i + 1}-${step.name}.log`);
    fs.writeFileSync(log, '');
    const t0 = Date.now();
    const [status, kind] = runStep(step, log, o.base || 'origin/Main');
    const seconds = Math.round((Date.now() - t0) / 1000);
    return { step, result: status === 0 ? 'PASS' : 'FAIL', seconds, lines: summarize(readOr(log, ''), status, kind) };
  });
  const verdict = results.length && results.every((r) => r.result === 'PASS') ? 'PASS' : 'FAIL';
  const rules = rulesFor(p.changed);
  const md = [`# Quick check: ${o.branch || '(unknown branch)'}`, ''];
  md.push(`- Commit: \`${o.commit || 'unknown'}\` (trust this report only if it is your latest commit)`);
  md.push(`- Finished: ${new Date().toISOString().replace(/\.\d+Z$/, 'Z')}`);
  md.push(`- Verdict: **${verdict}**`);
  md.push(`- Commands: ${p.source === 'requested' ? 'as requested by `run:` lines in the commit message' : 'default set (no `run:` lines in the commit message)'}`);
  if (rules.length) md.push(`- Rules for the files you changed: ${rules.map((r) => `\`${r}\``).join(', ')} (all bundled in \`START.md\` on \`agent-results\`)`);
  if (o.run) md.push(`- Full logs: ${o.run}`);
  md.push('', '| # | Command | Result | Time |', '| --- | --- | --- | --- |');
  results.forEach((r, i) => md.push(`| ${i + 1} | \`${r.step.text.replace(/\|/g, '\\|').replace(/`/g, "'")}\` | ${r.result} | ${r.seconds}s |`));
  results.forEach((r, i) => md.push('', `## ${i + 1}. ${r.step.text}: ${r.result}`, '', '```text', ...r.lines, '```'));
  md.push('', verdict === 'PASS'
    ? 'Next: if the task is finished, run the default set (a commit with no `run:` lines), then open the pull request. Otherwise do the next step.'
    : 'Next: fix only what the failing sections name, push once (with `run:` lines for just the failing commands), then read this file again for the new commit.', '');
  fs.writeFileSync(o.out, md.join('\n'));
  if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, `verdict=${verdict}\n`);
  console.log(`PASS agent-run - verdict ${verdict}: ${results.map((r) => `${r.step.text} ${r.result}`).join('; ')} (${o.out})`);
}

const o = args(process.argv.slice(2));
const mode = o._[0];
if (mode === 'plan' && o.out) plan(o);
else if (mode === 'run' && o.plan && o.out) run(o);
else if (mode === 'help') for (const [n, s] of Object.entries(COMMANDS)) console.log(`${n.padEnd(10)} ${s[3]}`);
else { console.log('FAIL agent-run - usage: agent-run.js plan|run|help (see the header comment)'); process.exit(1); }
