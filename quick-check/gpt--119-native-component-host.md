# Quick check: gpt/119-native-component-host

- Commit: `5bc2a09f46b830d824b568ed4c39a8e4b1a3ebe0` (trust this report only if it is your latest commit)
- Finished: 2026-11-06T23:25:35Z
- Status: FINISHED
- Verdict: **FAIL**
- Environment: GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner's device runs can.
- Commands: default set (no `run:` lines in the commit message)
- Rules for the files you changed: `.claude/rules/app.md`, `.claude/rules/ci.md`, `.claude/rules/docs.md`, `.claude/rules/engine.md`, `.claude/rules/modules.md`, `.claude/rules/scripts.md` (all bundled in `START.md` on `agent-results`)
- Full logs: https://github.com/Kmandevr/C.A.W/actions/runs/42311574364

| # | Command | Result | Time |
| --- | --- | --- | --- |
| 1 | `docs` | PASS | 0s |
| 2 | `build` | PASS | 37s |
| 3 | `test` | FAIL | 2s |
| 4 | `examples` | PASS | 1s |
| 5 | `analyze` | PASS | 8s |
| 6 | `dart-test` | FAIL | 35s |

## 1. docs: PASS

```text
PASS docs - 28 notes and 18 other docs: frontmatter, links, paths and index hold
PASS uncovered - every code area is covered by a note
PASS stale - every note covering code changed since origin/Main was updated too
```

## 2. build: PASS

```text
[ 97%] Linking CXX executable caw_rt_tests
[ 97%] Built target caw_rt_tests
[ 98%] Linking CXX executable caw_bench
[ 98%] Built target caw_bench
[100%] Linking CXX executable caw_tests
[100%] Built target caw_tests
```

## 3. test: FAIL

```text
$ ctest --test-dir engine/build --output-on-failure --parallel 4
1/5 Test #3: caw_tests_shard_2 ................***Failed    0.46 sec
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:72): CHECK(mismatch.error == ModuleLoadError::ComponentIdMismatch)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:76): CHECK(loaded.success)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:77): CHECK(loaded.error == ModuleLoadError::None)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:79): CHECK(registry.find(kComponentId) != nullptr)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:80): registry.size() == 1u: 0 vs 1
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:84): CHECK(duplicate.error == ModuleLoadError::DuplicateId)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:87): CHECK(instance != nullptr)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:103): CHECK(registry.unload(kComponentId))
2/5 Test #1: caw_tests_shard_0 ................***Failed    0.71 sec
FAIL c_api_native_component_load_requires_an_explicit_trust_level (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:47): CHECK(json.find(R"("ok":true)") != std::string::npos)
FAIL c_api_native_component_load_requires_an_explicit_trust_level (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:50): caw_engine_unload_component(engine, "org.caw.tests.native-loader") == 1: 0 vs 1
60% tests passed, 2 tests failed out of 5
The following tests FAILED:
	  1 - caw_tests_shard_0 (Failed)
	  3 - caw_tests_shard_2 (Failed)
ok   worker_api_cancels_offline_render_and_keeps_released_handles_safe
ok   public_cpp_sdk_component_uses_typed_contract_and_state
68 tests, 2 failures (shard 1/4)
3/5 Test #5: caw_rt_tests .....................   Passed    0.40 sec
4/5 Test #4: caw_tests_shard_3 ................   Passed    1.07 sec
5/5 Test #2: caw_tests_shard_1 ................   Passed    1.79 sec
Total Test time (real) =   1.85 sec
Errors while running CTest
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
No issues found! (ran in 6.3s)
```

## 6. dart-test: FAIL

```text
::group::❌ /home/runner/work/C.A.W/C.A.W/app/test/engine_test.dart: native component loading requires an explicit trust choice (failed)
✅ /home/runner/work/C.A.W/C.A.W/app/test/opening_test.dart: a missing last project opens the template without an error
✅ /home/runner/work/C.A.W/C.A.W/app/test/actions_vim_test.dart: a self-calling macro on a key gives an error toast, not a hang
✅ /home/runner/work/C.A.W/C.A.W/app/test/actions_keymap_test.dart: bad lines are warnings, a wrong header is an error
✅ /home/runner/work/C.A.W/C.A.W/app/test/motion_test.dart: settings saves that overlap never fail and leave the last state on disk
Shell: ALSA lib conf.c:5208:(_snd_config_evaluate) function snd_func_card_inum returned error: No such file or directory
Shell: ALSA lib confmisc.c:422:(snd_func_concat) error evaluating strings
Shell: ALSA lib conf.c:5208:(_snd_config_evaluate) function snd_func_concat returned error: No such file or directory
Shell: ALSA lib confmisc.c:1342:(snd_func_refer) error evaluating name
Shell: ALSA lib conf.c:5208:(_snd_config_evaluate) function snd_func_refer returned error: No such file or directory
Shell: ALSA lib conf.c:5731:(snd_config_expand) Evaluate error: No such file or directory
Shell: ALSA lib conf.c:5208:(_snd_config_evaluate) function snd_func_card_id returned error: No such file or directory
✅ /home/runner/work/C.A.W/C.A.W/app/test/history_test.dart: ProjectHistory undo in the middle of a burst ends it first, so nothing is lost
✅ /home/runner/work/C.A.W/C.A.W/app/test/history_test.dart: ProjectHistory only the newest steps are kept
✅ /home/runner/work/C.A.W/C.A.W/app/test/pattern_editor_test.dart: tap draws a note, D moves it, Delete removes it
✅ /home/runner/work/C.A.W/C.A.W/app/test/pattern_editor_test.dart: inside a scrolling page a tap still draws, and a drag on empty grid scrolls instead
✅ /home/runner/work/C.A.W/C.A.W/app/test/pattern_editor_test.dart: the menu runs a generator: Euclid writes 3 hits in 8 steps
✅ /home/runner/work/C.A.W/C.A.W/app/test/pattern_editor_test.dart: the Curve tool: two taps in the velocity lane ramp the notes between them
✅ /home/runner/work/C.A.W/C.A.W/app/test/history_test.dart: AppState undo and redo undo and redo go back and forth over project edits, one step per burst
✅ /home/runner/work/C.A.W/C.A.W/app/test/history_test.dart: undoing typed code shows the old code in the editor, and the next keystroke keeps the undo
✅ /home/runner/work/C.A.W/C.A.W/app/test/pattern_editor_test.dart: touch: a double tap on a note deletes it, a single tap keeps it
✅ /home/runner/work/C.A.W/C.A.W/app/test/pattern_editor_test.dart: the Curve tool draws a pitch bend on a selected note, and the extras panel adds vibrato
::endgroup::
::error::332 tests passed, 1 failed.
```

Next: fix only what the failing sections name, push once (with `run:` lines for just the failing commands), then read this file again for the new commit.
