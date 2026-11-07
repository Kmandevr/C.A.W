# Quick check: gpt/119-native-component-host

- Commit: `4ca76c0d20bef9ee7c5b32031fb86f7c8166701f` (trust this report only if it is your latest commit)
- Finished: 2026-11-07T02:23:41Z
- Status: FINISHED
- Verdict: **FAIL**
- Environment: GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner's device runs can.
- Commands: as requested by `run:` lines in the commit message
- Rules for the files you changed: `.claude/rules/app.md`, `.claude/rules/ci.md`, `.claude/rules/docs.md`, `.claude/rules/engine.md`, `.claude/rules/modules.md`, `.claude/rules/scripts.md` (all bundled in `START.md` on `agent-results`)
- Full logs: https://github.com/Kmandevr/C.A.W/actions/runs/42328472343

| # | Command | Result | Time |
| --- | --- | --- | --- |
| 1 | `test native_component` | FAIL | 36s |
| 2 | `test trusted_native_stereo_master_effect` | FAIL | 0s |
| 3 | `dart-test app/test/engine_test.dart` | FAIL | 9s |

## 1. test native_component: FAIL

```text
wrong-ID component load returned error 3: A component path and expected stable component ID are required.
trusted component load returned error 3: A component path and expected stable component ID are required.
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:73): CHECK(path != nullptr)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:74): CHECK(path && path[0] != '\0')
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:92): CHECK(mismatch.error == ModuleLoadError::ComponentIdMismatch)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:99): CHECK(loaded.success)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:100): CHECK(loaded.error == ModuleLoadError::None)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:101): loaded.componentId == std::string(kComponentId):  vs org.caw.tests.native-loader
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:102): CHECK(registry.find(kComponentId) != nullptr)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:103): registry.size() == 1u: 0 vs 1
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:107): CHECK(duplicate.error == ModuleLoadError::DuplicateId)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:110): CHECK(instance != nullptr)
FAIL module_registry_loads_native_components_only_after_explicit_trust (/home/runner/work/C.A.W/C.A.W/engine/tests/native_component_test.cpp:126): CHECK(registry.unload(kComponentId))
2 tests, 11 failures (shard 1/1)
```

## 2. test trusted_native_stereo_master_effect: FAIL

```text
FAIL engine_runs_trusted_native_stereo_master_effect_before_the_safety_limiter (/home/runner/work/C.A.W/C.A.W/engine/tests/engine_test.cpp:74): CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos)
FAIL engine_runs_trusted_native_stereo_master_effect_before_the_safety_limiter (/home/runner/work/C.A.W/C.A.W/engine/tests/engine_test.cpp:79): CHECK(std::fabs(left[1145]) > 0.9f)
FAIL engine_runs_trusted_native_stereo_master_effect_before_the_safety_limiter (/home/runner/work/C.A.W/C.A.W/engine/tests/engine_test.cpp:82): CHECK(!e.unloadNativeComponent(componentId))
FAIL engine_runs_trusted_native_stereo_master_effect_before_the_safety_limiter (/home/runner/work/C.A.W/C.A.W/engine/tests/engine_test.cpp:87): CHECK(e.unloadNativeComponent(componentId))
$ engine/build/caw_tests trusted_native_stereo_master_effect
1 tests, 4 failures (shard 1/1)
```

## 3. dart-test app/test/engine_test.dart: FAIL

```text
::group::❌ native component loading requires an explicit trust choice (failed)
package:matcher             fail
::error::4 tests passed, 1 failed.
#18     _CustomZone.bindCallbackGuarded.<anonymous closure> (dart:async/zone.dart:743:23)
#19     _microtaskLoop (dart:async/schedule_microtask.dart:40:35)
#20     _startMicrotaskLoop (dart:async/schedule_microtask.dart:49:5)
test/engine_test.dart 74:7  main.<fn>
::endgroup::
::group::✅ Passing tests
✅ a project cannot use a native component before an explicit trust load
✅ a generator plays the notes of a pattern
✅ the function library and library modules come through the C API
```

Next: fix only what the failing sections name, push once (with `run:` lines for just the failing commands), then read this file again for the new commit.
