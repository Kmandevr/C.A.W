# Quick check: gpt/119-native-component-host

- Commit: `505342c1aa68c63636078fdb08b18e15852c17e6` (trust this report only if it is your latest commit)
- Finished: 2026-11-07T02:16:07Z
- Status: FINISHED
- Verdict: **FAIL**
- Environment: GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner's device runs can.
- Commands: as requested by `run:` lines in the commit message
- Rules for the files you changed: `.claude/rules/app.md`, `.claude/rules/ci.md`, `.claude/rules/docs.md`, `.claude/rules/engine.md`, `.claude/rules/modules.md`, `.claude/rules/scripts.md` (all bundled in `START.md` on `agent-results`)
- Full logs: https://github.com/Kmandevr/C.A.W/actions/runs/42328084528

| # | Command | Result | Time |
| --- | --- | --- | --- |
| 1 | `docs` | PASS | 0s |
| 2 | `test native_component` | FAIL | 31s |
| 3 | `test trusted_native_stereo_master_effect` | FAIL | 0s |
| 4 | `dart-test app/test/engine_test.dart` | FAIL | 10s |

## 1. docs: PASS

```text
PASS docs - 28 notes and 18 other docs: frontmatter, links, paths and index hold
PASS uncovered - every code area is covered by a note
PASS stale - every note covering code changed since origin/Main was updated too
```

## 2. test native_component: FAIL

```text
wrong-ID component load returned error 3: A component path and expected stable component ID are required.
trusted component load returned error 3: A component path and expected stable component ID are required.
FAIL c_api_native_component_load_requires_an_explicit_trust_level (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:32): CHECK(path != nullptr)
FAIL c_api_native_component_load_requires_an_explicit_trust_level (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:33): CHECK(path && path[0] != 0)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:72): CHECK(path != nullptr)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:73): CHECK(path && path[0] != '\0')
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:91): CHECK(mismatch.error == ModuleLoadError::ComponentIdMismatch)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:98): CHECK(loaded.success)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:99): CHECK(loaded.error == ModuleLoadError::None)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:100): loaded.componentId == std::string(kComponentId):  vs org.caw.tests.native-loader
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:101): CHECK(registry.find(kComponentId) != nullptr)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:102): registry.size() == 1u: 0 vs 1
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:106): CHECK(duplicate.error == ModuleLoadError::DuplicateId)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:109): CHECK(instance != nullptr)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:125): CHECK(registry.unload(kComponentId))
2 tests, 13 failures (shard 1/1)
```

## 3. test trusted_native_stereo_master_effect: FAIL

```text
FAIL engine_runs_trusted_native_stereo_master_effect_before_the_safety_limiter (/home/runner/work/C.A.W/C.A.W/engine/tests/engine_test.cpp:62): CHECK(path != nullptr)
FAIL engine_runs_trusted_native_stereo_master_effect_before_the_safety_limiter (/home/runner/work/C.A.W/C.A.W/engine/tests/engine_test.cpp:63): CHECK(path && path[0] != 0)
$ engine/build/caw_tests trusted_native_stereo_master_effect
1 tests, 2 failures (shard 1/1)
```

## 4. dart-test app/test/engine_test.dart: FAIL

```text
::group::❌ native component loading requires an explicit trust choice (failed)
::error::4 tests passed, 1 failed.
package:caw/engine/engine.dart 365:36  Engine.loadNativeComponent.<fn>
===== asynchronous gap ===========================
dart:async                             Future.then
package:caw/engine/engine.dart 363:21  Engine.loadNativeComponent
test/engine_test.dart 66:34            main.<fn>
::endgroup::
::group::✅ Passing tests
✅ a project cannot use a native component before an explicit trust load
✅ a generator plays the notes of a pattern
✅ the function library and library modules come through the C API
```

Next: fix only what the failing sections name, push once (with `run:` lines for just the failing commands), then read this file again for the new commit.
