// Tests for number-lists.js: a bench mode or C API version used twice, a stale copy or an unlisted caw_bench call fails.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { benchModes, apiHistory, benchCalls, check } = require('./number-lists.js');

const modes = (rows) => `inline constexpr Mode kModes[] = {\n${rows.join('\n')}\n};\n`;
const okModes = ['    {-1, "graph", "", "", "graph"},', '    {301, "tools", "caw_tools_cost", "0.5", "tools"},', '    {602, "spikes", "caw_spike_check", "1 --runs 3 --check 3", "spikes"},'];
const cawH = (history, current) => `#pragma once\n/* ${history.join('\n   ')} */\n#define CAW_API_VERSION ${current}\n`;
const okHistory = ['2 (2026-11-09): scope.', '3 (2026-11-09): components,\n   16 pieces (pc1_*) continue the line.', '4: not used.', '5 (2026-11-10): meters.'];

// A repository in a temporary folder with these files; check()'s lines.
function run(files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'number-lists-'));
  try {
    for (const [f, text] of Object.entries(files)) {
      fs.mkdirSync(path.dirname(path.join(root, f)), { recursive: true });
      fs.writeFileSync(path.join(root, f), text);
    }
    return check(root, Object.keys(files));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}
const fails = (lines) => lines.filter((l) => l.startsWith('FAIL'));
const base = () => ({
  'engine/bench/bench_modes.h': modes(okModes),
  'engine/include/caw.h': cawH(okHistory, 5),
  'app/lib/engine/bindings.dart': '// x\nconst int cawApiVersion = 5;  // must equal CAW_API_VERSION\n',
  'docs/engine.md': 'Run `caw_bench SECONDS 301` and `caw_bench 1 602 --runs 3`; the C API (`CAW_API_VERSION`, 5).\n- **C API 3:** Dart: `cawApiVersion` 3.\n',
});

test('the rows, the history and the calls are read', () => {
  assert.deepStrictEqual(benchModes(modes(okModes)).map((r) => [r.number, r.name, r.ctest]), [[-1, 'graph', ''], [301, 'tools', 'caw_tools_cost'], [602, 'spikes', 'caw_spike_check']]);
  assert.deepStrictEqual(apiHistory(cawH(okHistory, 5)), { entries: [2, 3, 4, 5], current: 5 });
  assert.deepStrictEqual(benchCalls('a `caw_bench 0.5 301` b\n build/caw_bench "$SECONDS_PER" 500 --runs 3\ncaw_bench.exe S -1').map((c) => c.mode), [301, 500, -1]);
});

test('a consistent repository passes', () => {
  const out = run(base());
  assert.deepStrictEqual(fails(out), []);
  assert.strictEqual(out.filter((l) => l.startsWith('PASS')).length, 2);
});

test('a bench mode number listed twice fails', () => {
  const f = base();
  f['engine/bench/bench_modes.h'] = modes([...okModes, '    {301, "sampler", "caw_sampler_cost", "0.5", "sampler"},']);
  assert.match(fails(run(f)).join('\n'), /bench-modes - mode 301 is listed twice/);
});

test('a ctest listed twice fails', () => {
  const f = base();
  f['engine/bench/bench_modes.h'] = modes([...okModes, '    {308, "sampler", "caw_tools_cost", "0.5", "sampler"},']);
  assert.match(fails(run(f)).join('\n'), /ctest caw_tools_cost is listed twice/);
});

test('a caw_bench call naming an unlisted mode fails', () => {
  const f = base();
  f['.github/workflows/bench.yml'] = 'run: build/caw_bench 2 308\n';
  assert.match(fails(run(f)).join('\n'), /bench-calls - line 1 runs caw_bench mode 308/);
});

test('the dated history may name retired modes and old versions', () => {
  const f = base();
  f['docs/log.md'] = '- `caw_bench 2 308` timed Timber; `cawApiVersion` 2.\n';
  assert.deepStrictEqual(fails(run(f)), []);
});

test('a C API version with two history entries fails', () => {
  const f = base();
  f['engine/include/caw.h'] = cawH([...okHistory, '5 (2026-11-10): the other branch.'], 5);
  assert.match(fails(run(f)).join('\n'), /version 5 has two history entries/);
});

test('a define past the history, a gap or an app behind it fails', () => {
  const f = base();
  f['engine/include/caw.h'] = cawH(okHistory, 6);
  const out = fails(run(f)).join('\n');
  assert.match(out, /CAW_API_VERSION is 6 but the history's last entry is 5/);
  assert.match(out, /cawApiVersion is 5, CAW_API_VERSION 6/);
  const g = base();
  g['engine/include/caw.h'] = cawH([...okHistory, '7 (2026-11-11): skipped one.'], 7);
  assert.match(fails(run(g)).join('\n'), /history goes from 5 to 7/);
});

test('a note naming a stale version fails, unless its line is about that version', () => {
  const f = base();
  f['docs/app.md'] = 'The app (`cawApiVersion` 4, equal to `CAW_API_VERSION`).\n- **C API 3:** Dart: `cawApiVersion` 2.\n';
  const out = fails(run(f));
  assert.strictEqual(out.length, 2);
  assert.match(out[0], /line 1 says `cawApiVersion` 4/);
  assert.match(out[1], /line 2 says `cawApiVersion` 2; the current version is 5 \(or the line's own C API 3\)/);
});
