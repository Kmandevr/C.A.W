# Quick check: ccr-55caa33d-vxei5s

- Commit: `edf37dc14190ac7f1fafaeed2849ccb4409cc61b` (trust this report only if it is your latest commit)
- Finished: 2026-11-03T14:17:39Z
- Status: FINISHED
- Verdict: **FAIL**
- Environment: GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner's device runs can.
- Commands: as requested by `run:` lines in the commit message
- Rules for the files you changed: `.claude/rules/app.md`, `.claude/rules/ci.md`, `.claude/rules/claude.md`, `.claude/rules/docs.md`, `.claude/rules/scripts.md` (all bundled in `START.md` on `agent-results`)
- Full logs: https://github.com/Kmandevr/C.A.W/actions/runs/41651949472

| # | Command | Result | Time |
| --- | --- | --- | --- |
| 1 | `screenshot app/test/zz_agent_screenshot_test.dart` | PASS | 64s |
| 2 | `log 3` | PASS | 0s |
| 3 | `diff scripts/agent-run.js` | PASS | 0s |
| 4 | `grep "a;b" scripts` | FAIL | 0s |
| 5 | `frobnicate` | INVALID | 0s |

## 1. screenshot app/test/zz_agent_screenshot_test.dart: PASS

```text
-- The C compiler identification is GNU 13.3.0
-- The CXX compiler identification is GNU 13.3.0
-- Detecting C compiler ABI info
-- Detecting C compiler ABI info - done
-- Check for working C compiler: /usr/bin/cc - skipped
-- Detecting C compile features
-- Detecting C compile features - done
-- Detecting CXX compiler ABI info
-- Detecting CXX compiler ABI info - done
-- Check for working CXX compiler: /usr/bin/c++ - skipped
-- Detecting CXX compile features
-- Detecting CXX compile features - done
-- Performing Test CMAKE_HAVE_LIBC_PTHREAD
-- Performing Test CMAKE_HAVE_LIBC_PTHREAD - Success
-- Found Threads: TRUE
-- Configuring done (11.8s)
-- Generating done (0.0s)
-- Build files have been written to: /home/runner/work/C.A.W/C.A.W/engine/build
[  3%] Building CXX object CMakeFiles/caw_core.dir/src/builtins.cpp.o
[  6%] Building CXX object CMakeFiles/caw_core.dir/src/compile.cpp.o
[  9%] Building CXX object CMakeFiles/caw_core.dir/src/detmath.cpp.o
[ 12%] Building CXX object CMakeFiles/caw_core.dir/src/pattern.cpp.o
[ 16%] Building CXX object CMakeFiles/caw_core.dir/src/docs.cpp.o
[ 19%] Building CXX object CMakeFiles/caw_core.dir/src/engine.cpp.o
[ 22%] Building CXX object CMakeFiles/caw_core.dir/src/execution.cpp.o
[ 25%] Building CXX object CMakeFiles/caw_core.dir/src/module_registry.cpp.o
[ 32%] Building CXX object CMakeFiles/caw_core.dir/src/scheduler.cpp.o
[ 41%] Building CXX object CMakeFiles/caw_core.dir/src/midi2.cpp.o
[ 45%] Building CXX object CMakeFiles/caw_core.dir/src/module.cpp.o
[ 35%] Building CXX object CMakeFiles/caw_core.dir/src/dependency.cpp.o
[ 38%] Building CXX object CMakeFiles/caw_core.dir/src/hardware.cpp.o
[ 45%] Building CXX object CMakeFiles/caw_core.dir/src/graph.cpp.o
[ 51%] Building CXX object CMakeFiles/caw_core.dir/src/midifile.cpp.o
[ 54%] Building CXX object CMakeFiles/caw_core.dir/src/project.cpp.o
[ 61%] Building CXX object CMakeFiles/caw_core.dir/src/vm.cpp.o
[ 61%] Building CXX object CMakeFiles/caw_core.dir/src/synth.cpp.o
[ 64%] Building CXX object CMakeFiles/caw_core.dir/src/render.cpp.o
[ 48%] Building CXX object CMakeFiles/caw_core.dir/src/json.cpp.o
[ 67%] Building CXX object CMakeFiles/caw_core.dir/src/tables.cpp.o
[ 70%] Building CXX object CMakeFiles/caw_core.dir/src/wav.cpp.o
[ 74%] Building CXX object CMakeFiles/caw_core.dir/caw_stdlib.cpp.o
[ 77%] Building CXX object CMakeFiles/caw_core.dir/caw_templates.cpp.o
[ 80%] Linking CXX static library libcaw_core.a
[ 80%] Built target caw_core
[ 83%] Building CXX object CMakeFiles/caw_engine.dir/src/capi.cpp.o
[ 87%] Building CXX object CMakeFiles/caw_engine.dir/src/execution_capi.cpp.o
[ 90%] Building CXX object CMakeFiles/caw_engine.dir/src/worker_api.cpp.o
[ 93%] Building C object CMakeFiles/caw_engine.dir/platform/miniaudio_impl.c.o
[ 96%] Building CXX object CMakeFiles/caw_engine.dir/platform/audio_miniaudio.cpp.o
[100%] Linking CXX shared library libcaw.so
[100%] Built target caw_engine
Analytics reporting disabled.
Resolving dependencies...
Downloading packages...
  code_assets 1.2.1 (2.1.0 available)
  cross_file 0.3.5+5 (0.4.0 available)
  cupertino_icons 1.0.9 (2.0.0 available)
  file_picker 13.1.0 (13.3.1 available)
  file_picker_darwin 2.4.0 (2.4.1 available)
  hooks 2.0.2 (2.2.0 available)
  material_color_utilities 0.13.0 (0.13.1 available)
  meta 1.18.3 (1.19.0 available)
  objective_c 9.5.0 (9.6.2 available)
  petitparser 7.0.2 (7.1.0 available)
  record_use 0.6.0 (1.1.1 available)
  test_api 0.7.12 (0.7.15 available)
  vector_math 2.4.0 (2.4.4 available)
  xml 7.0.1 (7.1.0 available)
Got dependencies!
14 packages have newer versions incompatible with dependency constraints.
Try `flutter pub outdated` for more information.
Resolving dependencies...
Downloading packages...
  code_assets 1.2.1 (2.1.0 available)
  cross_file 0.3.5+5 (0.4.0 available)
  cupertino_icons 1.0.9 (2.0.0 available)
  file_picker 13.1.0 (13.3.1 available)
  file_picker_darwin 2.4.0 (2.4.1 available)
  hooks 2.0.2 (2.2.0 available)
  material_color_utilities 0.13.0 (0.13.1 available)
  meta 1.18.3 (1.19.0 available)
  objective_c 9.5.0 (9.6.2 available)
  petitparser 7.0.2 (7.1.0 available)
  record_use 0.6.0 (1.1.1 available)
  test_api 0.7.12 (0.7.15 available)
  vector_math 2.4.0 (2.4.4 available)
  xml 7.0.1 (7.1.0 available)
Got dependencies!
14 packages have newer versions incompatible with dependency constraints.
Try `flutter pub outdated` for more information.
::group::✅ Passing tests
✅ agent screenshot self-test
::endgroup::
🎉 1 test passed.
Screenshots (they appear a few minutes after the report):
https://raw.githubusercontent.com/Kmandevr/C.A.W/agent-results/screens/ccr-55caa33d-vxei5s/screens-selftest.png
```

## 2. log 3: PASS

```text
edf37dc 2026-11-03 Add git, screenshot and job-tracking commands for chat agents; publish failing reports
7b4d8d6 2026-11-03 Let chat agents choose their CI commands with run: lines
cd11db7 2026-11-03 Remove the temporary self-test triggers
```

## 3. diff scripts/agent-run.js: PASS

```text
 scripts/agent-run.js | 368 +++++++++++++++++++++++++++++++++++++++++++++++++++
 1 file changed, 368 insertions(+)
diff --git a/scripts/agent-run.js b/scripts/agent-run.js
new file mode 100644
index 0000000..6ff44fd
--- /dev/null
+++ b/scripts/agent-run.js
@@ -0,0 +1,368 @@
+// Runs a chat agent's requested commands in CI (tests, builds, search, Graphify) and writes its Quick check report.
+// Usage: node scripts/agent-run.js plan --message-file F [--request TEXT] [--changed F] [--app true] --out plan.json
+//        node scripts/agent-run.js running --plan plan.json --out report.md --branch B --commit SHA [--run URL]
+//        node scripts/agent-run.js run --plan plan.json --out report.md --branch B --commit SHA [--run URL] [--base REF]
+// A commit message line `run: <command> [args]` (several lines, or `;` between commands) asks for exactly those
+// commands; with none, the default set runs. Commands are a fixed list run without a shell, so arguments can't inject.
+'use strict';
+const fs = require('fs');
+const path = require('path');
+const { spawnSync } = require('child_process');
+
+const ROOT = path.join(__dirname, '..');
+const MAX_COMMANDS = 20;
+const MAX_LINE_CHARS = 240;
+const INFO_LINES = 120;     // output shown for search and navigation commands
+const PASS_TAIL = 6;        // output shown for a passing build or test
+const FAIL_LINES = 40;      // output shown for a failure
+const BUILD = { release: 'engine/build', asan: 'engine/build-asan' };
+const TARGETS = ['caw_core', 'caw_engine', 'caw_cli', 'caw_tests', 'caw_bench'];
+const GRAPH_SUBCOMMANDS = ['query', 'explain', 'affected'];
+const LONG_LINES = 300;     // output shown for diff, show and blame
+const ENVIRONMENT = 'GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner\'s device runs can.';
+const RAW = 'https://raw.githubusercontent.com/Kmandevr/C.A.W/agent-results';
+const PROBLEM = /\b(error|FAIL(ED)?|failed|failure|Exception|assert(ion)?|undefined reference|No such file)\b|^\s*(✗|x) /i;
+
+// name: [needs, minArgs, maxArgs, one-line help]. `needs` decides which toolchains the workflow installs.
+const COMMANDS = {
+  docs: [[], 0, 0, 'docs guard, strict (stale notes fail)'],
+  build: [['engine'], 0, 1, `engine build; optional target: ${TARGETS.join(', ')}`],
+  test: [['engine'], 0, 1, 'engine tests; optional name filter (substring), else the full ctest suite'],
+  sanitize: [['engine'], 0, 1, 'engine tests under AddressSanitizer/UBSan (Debug); optional name filter'],
+  examples: [['engine'], 0, 0, 'caw check of every example and the generated language-docs check'],
+  check: [['engine'], 1, 20, 'caw check of the given .caw files'],
+  render: [['engine'], 1, 2, 'caw render of one .caw file to WAV (artifact); optional BPM, default 140'],
+  bench: [['engine'], 0, 0, 'engine benchmark (callback time, real-time load, memory)'],
+  analyze: [['flutter'], 0, 20, 'flutter analyze; optional paths under app/'],
+  'dart-test': [['flutter', 'engine'], 0, 2, 'flutter test against the native engine; optional test path under app/, then a name filter'],
+  screenshot: [['flutter', 'engine'], 1, 2, 'runs one widget test under app/test with --update-goldens and publishes the PNGs it writes (matchesGoldenFile); optional name filter'],
+  diff: [[], 0, 1, 'this branch against the default branch: changed files, then the patch; optional path'],
+  log: [[], 0, 2, 'recent commits on this branch; optional count (default 20), then a path'],
+  show: [[], 1, 2, 'one commit (hash or HEAD~N) with its patch; optional path'],
+  blame: [[], 1, 2, 'who last changed each line; file, then optional START-END lines'],
+  grep: [[], 1, 20, 'ripgrep: regex, then optional paths'],
+  refs: [[], 1, 1, 'whole-word uses of an identifier in engine/, app/, examples/ and scripts/'],
+  tree: [[], 0, 1, 'repo map with each file\'s purpose; optional directory'],
+  graph: [['graph'], 2, 10, `Graphify: ${GRAPH_SUBCOMMANDS.join('|')} then its arguments`],
+  symbols: [['ctags'], 1, 1, 'symbols defined in one file, with line numbers'],
+  def: [['ctags'], 1, 1, 'where a symbol is defined (engine and app sources)'],
+};
+const DEFAULT = ['docs', 'build', 'test', 'examples'];
+const DEFAULT_APP = ['analyze', 'dart-test'];
+
+function args(argv) {
+  const o = { _: [] };
+  for (let i = 0; i < argv.length; i++) {
+    if (argv[i].startsWith('--')) o[argv[i].slice(2)] = argv[i + 1] === undefined ? '' : argv[++i];
+    else o._.push(argv[i]);
+  }
+  return o;
+}
+const readOr = (f, d) => { try { return fs.readFileSync(f, 'utf8'); } catch { return d; } };
+const clip = (l) => (l.length > MAX_LINE_CHARS ? l.slice(0, MAX_LINE_CHARS) + ' …' : l);
+
+// Shell-like words: spaces separate, "..." or '...' group. No expansion of any kind.
+function words(text) {
+  const out = []; let cur = ''; let q = null; let has = false;
+  for (const ch of text) {
+    if (q) { if (ch === q) q = null; else cur += ch; continue; }
+    if (ch === '"' || ch === "'") { q = ch; has = true; continue; }
+    if (/\s/.test(ch)) { if (has || cur) out.push(cur); cur = ''; has = false; continue; }
+    cur += ch;
+  }
+  if (has || cur) out.push(cur);
+  return out;
+}
+
+// Splits on `;` outside quotes, so `grep "a;b"` stays one command.
+function splitCommands(text) {
+  const out = []; let cur = ''; let q = null;
+  for (const ch of text) {
+    if (q) { if (ch === q) q = null; cur += ch; continue; }
+    if (ch === '"' || ch === "'") { q = ch; cur += ch; continue; }
+    if (ch === ';') { out.push(cur); cur = ''; continue; }
+    cur += ch;
+  }
+  out.push(cur);
+  return out.map((s) => s.trim()).filter(Boolean);
+}
+
+function requested(message, extra) {
+  const lines = [];
+  for (const l of `${message}\n${extra || ''}`.split(/\r?\n/)) {
+    const m = l.match(/^\s*run:\s*(.*)$/i);
+    if (m) lines.push(...splitCommands(m[1]));
+  }
+  return lines;
+}
+
+// Paths must stay inside the repository and can't pose as options.
+function safePath(p, { mustExist = true, under = null } = {}) {
+  const n = path.posix.normalize(p.replace(/\\/g, '/'));
+  if (!p || p.startsWith('-') || path.isAbsolute(p) || n.startsWith('..') || n.split('/').includes('..')) return `path "${p}" must be relative to the repository root`;
+  if (under && !(n === under || n.startsWith(`${under}/`))) return `path "${p}" must be under ${under}/`;
+  if (mustExist && !fs.existsSync(path.join(ROOT, n))) return `path "${p}" does not exist`;
+  return null;
+}
+
+function validate(name, a) {
+  const spec = COMMANDS[name];
+  if (!spec) return `unknown command "${name}"; known: ${Object.keys(COMMANDS).join(', ')}`;
+  if (a.length < spec[1] || a.length > spec[2]) return `"${name}" takes ${spec[1]}–${spec[2]} arguments (${spec[3]})`;
+  if (name === 'build' && a[0] && !TARGETS.includes(a[0])) return `unknown target "${a[0]}"; known: ${TARGETS.join(', ')}`;
+  if ((name === 'test' || name === 'sanitize') && a[0] && a[0].startsWith('-')) return 'a test filter can\'t start with "-"';
+  if (name === 'check' || name === 'render') {
+    const files = name === 'render' ? a.slice(0, 1) : a;
+    for (const f of files) { const e = safePath(f); if (e) return e; if (!f.endsWith('.caw')) return `"${f}" is not a .caw file`; }
+    if (name === 'render' && a[1] && !/^\d{2,3}(\.\d+)?$/.test(a[1])) return `BPM "${a[1]}" must be a number`;
+  }
+  if (name === 'analyze') for (const p of a) { const e = safePath(p, { under: 'app' }); if (e) return e; }
+  if (name === 'dart-test' && a[0]) { const e = safePath(a[0], { under: 'app' }); if (e) return e; }
+  if (name === 'screenshot') { const e = safePath(a[0], { under: 'app/test' }); if (e) return e; if (!a[0].endsWith('_test.dart')) return `"${a[0]}" is not a *_test.dart file`; }
+  if (name === 'diff' && a[0]) { const e = safePath(a[0], { mustExist: false }); if (e) return e; }
+  if (name === 'log') {
+    if (a[0] && !/^\d{1,3}$/.test(a[0])) return `count "${a[0]}" must be a number up to 999`;
+    if (a[1]) { const e = safePath(a[1], { mustExist: false }); if (e) return e; }
+  }
+  if (name === 'show') {
+    if (!/^([0-9a-f]{7,40}|HEAD(~\d{1,3})?)$/.test(a[0])) return `"${a[0]}" must be a commit hash or HEAD~N`;
+    if (a[1]) { const e = safePath(a[1], { mustExist: false }); if (e) return e; }
+  }
+  if (name === 'blame') {
+    const e = safePath(a[0]); if (e) return e;
+    if (a[1] && !/^\d+-\d+$/.test(a[1])) return `lines "${a[1]}" must look like 40-80`;
+  }
+  if (name === 'grep') for (const p of a.slice(1)) { const e = safePath(p); if (e) return e; }
+  if (name === 'refs' && !/^[A-Za-z_][A-Za-z0-9_:~]*$/.test(a[0])) return `"${a[0]}" is not an identifier`;
+  if (name === 'tree' && a[0]) { const e = safePath(a[0]); if (e) return e; }
+  if (name === 'graph') {
+    if (!GRAPH_SUBCOMMANDS.includes(a[0])) return `graph subcommand must be one of ${GRAPH_SUBCOMMANDS.join(', ')}`;
+    if (a.slice(1).some((x) => x.startsWith('-'))) return 'graph arguments can\'t start with "-"';
+  }
+  if (name === 'symbols') { const e = safePath(a[0]); if (e) return e; }
+  if (name === 'def' && !/^[A-Za-z_][A-Za-z0-9_]*$/.test(a[0])) return `"${a[0]}" is not a symbol name`;
+  return null;
+}
+
+function plan(o) {
+  const lines = requested(readOr(o['message-file'], ''), o.request);
+  const changed = readOr(o.changed, '').split('\n').filter(Boolean);
+  const app = o.app === 'true' || changed.some((f) => f.startsWith('app/'));
+  const source = lines.length ? 'requested' : 'default';
+  const text = lines.length ? lines : [...DEFAULT, ...(app ? DEFAULT_APP : [])];
+  const steps = text.slice(0, MAX_COMMANDS).map((t) => {
+    const [name, ...a] = words(t);
+    return { text: t, name, args: a, error: validate(name, a) };
+  });
+  if (text.length > MAX_COMMANDS) steps.push({ text: `(${text.length - MAX_COMMANDS} more)`, name: '-', args: [], error: `at most ${MAX_COMMANDS} commands per push` });
+  const needs = new Set();
+  for (const s of steps) if (!s.error) for (const n of COMMANDS[s.name][0]) needs.add(n);
+  fs.writeFileSync(o.out, JSON.stringify({ source, changed, steps }, null, 2));
+  if (process.env.GITHUB_OUTPUT) {
+    fs.appendFileSync(process.env.GITHUB_OUTPUT, ['engine', 'flutter', 'graph', 'ctags'].map((n) => `${n}=${needs.has(n)}\n`).join(''));
+  }
+  console.log(`PASS agent-run - ${source} plan: ${steps.map((s) => s.text).join('; ')} (${o.out})`);
+}
+
+// Runs one program with stdout and stderr interleaved into a single log, as a terminal would show them.
+function exec(log, program, argv, { cwd = ROOT, env = {}, timeoutSec = 1200 } = {}) {
+  fs.appendFileSync(log, `$ ${program} ${argv.join(' ')}\n`);
+  const fd = fs.openSync(log, 'a');
+  const r = spawnSync(program, argv, { cwd, env: { ...process.env, ...env }, stdio: ['ignore', fd, fd], timeout: timeoutSec * 1000 });
+  fs.closeSync(fd);
+  if (r.error) fs.appendFileSync(log, `${r.error.code === 'ETIMEDOUT' ? `timed out after ${timeoutSec}s` : r.error.message}\n`);
+  return r.status === null ? 124 : r.status;
+}
+
+const configured = new Set();
+const flutterReady = { done: false };
+function configure(log, kind) {
+  if (configured.has(kind)) return 0;
+  const flags = kind === 'asan' ? ['-DCMAKE_BUILD_TYPE=Debug', '-DCAW_SANITIZE=ON'] : ['-DCMAKE_BUILD_TYPE=Release'];
+  const s = exec(log, 'cmake', ['-S', 'engine', '-B', BUILD[kind], ...flags, '-DCMAKE_C_COMPILER_LAUNCHER=ccache', '-DCMAKE_CXX_COMPILER_LAUNCHER=ccache']);
+  if (s === 0) configured.add(kind);
+  return s;
+}
+function build(log, kind, target) {
+  const c = configure(log, kind);
+  if (c !== 0) return c;
+  return exec(log, 'cmake', ['--build', BUILD[kind], '--parallel', ...(target ? ['--target', target] : [])]);
+}
+function flutterSetup(log) {
+  if (flutterReady.done) return 0;
+  const s = exec(log, 'flutter', ['--disable-analytics'], { cwd: path.join(ROOT, 'app') })
+    || exec(log, 'flutter', ['pub', 'get'], { cwd: path.join(ROOT, 'app') });
+  if (s === 0) flutterReady.done = true;
+  return s;
+}
+const seq = (...fns) => { for (const f of fns) { const s = f(); if (s !== 0) return s; } return 0; };
+
+// PNGs a screenshot test wrote or changed under app/, copied to screens/ for publishing.
+function collectScreens(slug) {
+  const r = spawnSync('git', ['status', '--porcelain', '--untracked-files=all', '--', 'app'], { cwd: ROOT, encoding: 'utf8' });
+  const pngs = (r.stdout || '').split('\n').map((l) => l.slice(3).trim()).filter((f) => f.endsWith('.png'));
+  if (!pngs.length) return ['No PNG was written. Add `await expectLater(find.byType(MaterialApp), matchesGoldenFile(\'screens/<name>.png\'));` to the test.'];
+  fs.mkdirSync(path.join(ROOT, 'screens'), { recursive: true });
+  return pngs.map((f) => {
+    const name = f.replace(/^app\/test\//, '').replace(/[^A-Za-z0-9._-]+/g, '-');
+    fs.copyFileSync(path.join(ROOT, f), path.join(ROOT, 'screens', name));
+    return `${RAW}/screens/${slug}/${name}`;
+  });
+}
+
+// Returns [exit status, kind] for one validated step; kind 'info' shows its output, 'check' only a tail or errors.
+function runStep(step, log, base, slug) {
+  const a = step.args;
+  const cli = `${BUILD.release}/caw`;
+  switch (step.name) {
+    case 'docs': return [exec(log, 'node', ['scripts/docs-test.js', '--strict', '--base', base]), 'check'];
+    case 'build': return [build(log, 'release', a[0]), 'check'];
+    case 'test': return [a[0]
+      ? seq(() => build(log, 'release', 'caw_tests'), () => exec(log, `${BUILD.release}/caw_tests`, [a[0]]))
+      : seq(() => build(log, 'release', 'caw_tests'), () => exec(log, 'ctest', ['--test-dir', BUILD.release, '--output-on-failure', '--parallel', '4'])), 'check'];
+    case 'sanitize': return [seq(() => build(log, 'asan', 'caw_tests'), () => exec(log, `${BUILD.asan}/caw_tests`, a[0] ? [a[0]] : [])), 'check'];
+    case 'examples': {
+      const ex = fs.readdirSync(path.join(ROOT, 'examples')).filter((f) => f.endsWith('.caw')).sort().map((f) => `examples/${f}`);
+      return [seq(() => build(log, 'release', 'caw_cli'), () => exec(log, cli, ['check', ...ex]), () => exec(log, cli, ['docs', '--check', '--dir', 'docs'])), 'check'];
+    }
+    case 'check': return [seq(() => build(log, 'release', 'caw_cli'), () => exec(log, cli, ['check', ...a])), 'info'];
+    case 'render': {
+      fs.mkdirSync(path.join(ROOT, 'renders'), { recursive: true });
+      const out = `renders/${path.basename(a[0], '.caw')}.wav`;
+      return [seq(() => build(log, 'release', 'caw_cli'), () => exec(log, cli, ['render', a[0], '-o', out, '--bpm', a[1] || '140'])), 'info'];
+    }
+    case 'bench': return [seq(() => build(log, 'release', 'caw_bench'), () => exec(log, `${BUILD.release}/caw_bench`, [], { timeoutSec: 300 })), 'info'];
+    case 'analyze': return [seq(() => flutterSetup(log), () => exec(log, 'flutter', ['analyze', ...a.map((p) => path.posix.relative('app', p) || '.')], { cwd: path.join(ROOT, 'app') })), 'check'];
+    case 'dart-test': {
+      const t = a[0] ? [path.posix.relative('app', a[0]) || '.'] : [];
+      const name = a[1] ? ['--plain-name', a[1]] : [];
+      return [seq(() => build(log, 'release', 'caw_engine'), () => flutterSetup(log),
+        () => exec(log, 'flutter', ['test', '--concurrency=4', ...t, ...name], { cwd: path.join(ROOT, 'app'), env: { CAW_LIB: path.join(ROOT, BUILD.release, 'libcaw.so') } })), 'check'];
+    }
+    case 'screenshot': {
+      const name = a[1] ? ['--plain-name', a[1]] : [];
+      const s = seq(() => build(log, 'release', 'caw_engine'), () => flutterSetup(log),
+        () => exec(log, 'flutter', ['test', '--update-goldens', path.posix.relative('app', a[0]), ...name], { cwd: path.join(ROOT, 'app'), env: { CAW_LIB: path.join(ROOT, BUILD.release, 'libcaw.so') } }));
+      fs.appendFileSync(log, `Screenshots (they appear a few minutes after the report):\n${collectScreens(slug).join('\n')}\n`);
+      return [s, 'info'];
+    }
+    case 'diff': {
+      const only = a[0] ? ['--', a[0]] : [];
+      return [seq(() => exec(log, 'git', ['diff', '--stat', `${base}...HEAD`, ...only]), () => exec(log, 'git', ['diff', `${base}...HEAD`, ...only])), 'long'];
+    }
+    case 'log': return [exec(log, 'git', ['log', '--format=%h %ad %s', '--date=short', '-n', a[0] || '20', ...(a[1] ? ['--', a[1]] : [])]), 'info'];
+    case 'show': return [exec(log, 'git', ['show', '--stat', '--patch', a[0], ...(a[1] ? ['--', a[1]] : [])]), 'long'];
+    case 'blame': return [exec(log, 'git', ['blame', '--date=short', ...(a[1] ? ['-L', a[1].replace('-', ',')] : []), '--', a[0]]), 'long'];
+    case 'grep': {
+      const s = exec(log, 'rg', ['-n', '--no-heading', '--max-columns', '300', '-e', a[0], ...(a.length > 1 ? a.slice(1) : ['.'])]);
+      return [s === 1 ? 0 : s, 'info'];
+    }
+    case 'refs': {
+      const s = exec(log, 'rg', ['-n', '--no-heading', '-w', '-F', '-e', a[0], 'engine', 'app/lib', 'app/test', 'examples', 'scripts']);
+      return [s === 1 ? 0 : s, 'info'];
+    }
+    case 'tree': return [exec(log, '.claude/tools/tree.sh', a), 'info'];
+    case 'graph': return [exec(log, '.claude/tools/graph.sh', a, { timeoutSec: 900 }), 'info'];
+    case 'symbols': return [exec(log, 'ctags', ['-x', '--sort=no', a[0]]), 'info'];
+    case 'def': {
+      const tmp = `${log}.tags`;
+      const s = exec(tmp, 'ctags', ['-x', '-R', 'engine/src', 'engine/include', 'engine/platform', 'app/lib']);
+      const hits = readOr(tmp, '').split('\n').filter((l) => l.split(/\s+/)[0] === a[0]);
+      fs.appendFileSync(log, hits.length ? `${hits.join('\n')}\n` : `no definition of ${a[0]} found\n`);
+      return [s, 'info'];
+    }
+    default: return [2, 'check'];
+  }
+}
+
+function summarize(text, status, kind) {
+  const lines = text.split(/\r?\n/).filter((l) => l.trim() !== '');
+  if (status !== 0) {
+    // Show the failing program's own output: earlier steps (a build before a test run) succeeded.
+    const last = lines.map((l, i) => (l.startsWith('$ ') ? i : -1)).filter((i) => i >= 0).pop();
+    const own = last === undefined ? lines : lines.slice(last);
+    if (own.some((l) => /^0 tests, /.test(l))) return [...own.map(clip), 'No test name contains that filter. Filters match part of a TEST(name); `grep "TEST\\(" engine/tests` lists them.'];
+    const problems = own.filter((l) => PROBLEM.test(l) && !/^\s*(PASS|ok)\b/.test(l));
+    const tail = own.slice(-12);
+    const pick = [...new Set([...problems.slice(0, FAIL_LINES - tail.length), ...tail])];
+    return pick.map(clip);
+  }
+  if (kind === 'info' || kind === 'long') {
+    const limit = kind === 'long' ? LONG_LINES : INFO_LINES;
+    const body = lines.filter((l) => !l.startsWith('$ '));
… 76 more lines (narrow it with a path or line range)
```

## 4. grep "a;b" scripts: FAIL

```text
$ rg -n --no-heading --max-columns 300 -e a;b scripts
spawnSync rg ENOENT
```

## 5. frobnicate: INVALID

```text
unknown command "frobnicate"; known: docs, build, test, sanitize, examples, check, render, bench, analyze, dart-test, screenshot, diff, log, show, blame, grep, refs, tree, graph, symbols, def
```

Next: fix only what the failing sections name, push once (with `run:` lines for just the failing commands), then read this file again for the new commit.
