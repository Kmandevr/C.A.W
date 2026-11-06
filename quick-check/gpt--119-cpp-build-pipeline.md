# Quick check: gpt/119-cpp-build-pipeline

- Commit: `0032a8c51d74929c2551ba8ed4369bde891d35fb` (trust this report only if it is your latest commit)
- Finished: 2026-11-06T23:14:25Z
- Status: FINISHED
- Verdict: **PASS**
- Environment: GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner's device runs can.
- Commands: default set (no `run:` lines in the commit message)
- Rules for the files you changed: `.claude/rules/app.md`, `.claude/rules/ci.md`, `.claude/rules/docs.md`, `.claude/rules/engine.md`, `.claude/rules/modules.md`, `.claude/rules/scripts.md` (all bundled in `START.md` on `agent-results`)
- Full logs: https://github.com/Kmandevr/C.A.W/actions/runs/42310239678

| # | Command | Result | Time |
| --- | --- | --- | --- |
| 1 | `docs` | PASS | 0s |
| 2 | `build` | PASS | 8s |
| 3 | `test` | PASS | 4s |
| 4 | `examples` | PASS | 1s |
| 5 | `analyze` | PASS | 11s |
| 6 | `dart-test` | PASS | 44s |

## 1. docs: PASS

```text
PASS docs - 28 notes and 18 other docs: frontmatter, links, paths and index hold
PASS uncovered - every code area is covered by a note
PASS stale - every note covering code changed since origin/Main was updated too
```

## 2. build: PASS

```text
[ 97%] Linking CXX executable caw
[ 97%] Built target caw_cli
[ 98%] Linking CXX executable caw_rt_tests
[ 98%] Built target caw_rt_tests
[100%] Linking CXX executable caw_bench
[100%] Built target caw_bench
```

## 3. test: PASS

```text
2/5 Test #1: caw_tests_shard_0 ................   Passed    1.17 sec
3/5 Test #5: caw_rt_tests .....................   Passed    0.55 sec
4/5 Test #4: caw_tests_shard_3 ................   Passed    1.82 sec
5/5 Test #2: caw_tests_shard_1 ................   Passed    2.87 sec
100% tests passed, 0 tests failed out of 5
Total Test time (real) =   2.93 sec
```

## 4. examples: PASS

```text
examples/hats.caw: ok (generator, 1 params)
examples/init-synth.caw: ok (synth, 24 params, 2 effect steps)
examples/kick.caw: ok (generator, 2 params)
examples/wavetable-pad.caw: ok (generator, 6 params)
ok   docs/library.md is up to date
ok   docs/agent-guide.md is up to date
```

## 5. analyze: PASS

```text
  xml 7.0.1 (7.1.0 available)
Got dependencies!
17 packages have newer versions incompatible with dependency constraints.
Try `flutter pub outdated` for more information.
Analyzing app...                                                
No issues found! (ran in 9.4s)
```

## 6. dart-test: PASS

```text
✅ /home/runner/work/C.A.W/C.A.W/app/test/pattern_editor_test.dart: the Curve tool: two taps in the velocity lane ramp the notes between them
✅ /home/runner/work/C.A.W/C.A.W/app/test/history_test.dart: undoing typed code shows the old code in the editor, and the next keystroke keeps the undo
✅ /home/runner/work/C.A.W/C.A.W/app/test/pattern_editor_test.dart: touch: a double tap on a note deletes it, a single tap keeps it
✅ /home/runner/work/C.A.W/C.A.W/app/test/pattern_editor_test.dart: the Curve tool draws a pitch bend on a selected note, and the extras panel adds vibrato
::endgroup::
🎉 332 tests passed.
```

Next: if the task is finished, run the default set (a commit with no `run:` lines), then open the pull request. Otherwise do the next step.
