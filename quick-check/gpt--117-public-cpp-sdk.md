# Quick check: gpt/117-public-cpp-sdk

- Commit: `134276f7489ca7e43d97fe46f224677036d4b1a4` (trust this report only if it is your latest commit)
- Finished: 2026-11-05T18:15:55Z
- Status: FINISHED
- Verdict: **FAIL**
- Environment: GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner's device runs can.
- Commands: as requested by `run:` lines in the commit message
- Rules for the files you changed: `.claude/rules/docs.md`, `.claude/rules/engine.md` (all bundled in `START.md` on `agent-results`)
- Full logs: https://github.com/Kmandevr/C.A.W/actions/runs/42082393249

| # | Command | Result | Time |
| --- | --- | --- | --- |
| 1 | `test public_cpp_sdk` | PASS | 36s |
| 2 | `docs` | FAIL | 0s |

## 1. test public_cpp_sdk: PASS

```text
  232 |     const ModuleDescriptor withParameter{effect.id, 1, effect.ports, effect.portCount, &gainParameter, 1};
      |                                                                                                         ^
[100%] Linking CXX executable caw_tests
[100%] Built target caw_tests
ok   public_cpp_sdk_component_uses_typed_contract_and_state
1 tests, 0 failures (shard 1/1)
```

## 2. docs: FAIL

```text
FAIL stale - covers changed files (engine/CMakeLists.txt, engine/include/caw/module.hpp, engine/src/module.h, engine/tests/public_cpp_sdk_test.cpp); check it still holds and update it if not (docs/architecture.md)
FAIL stale - covers changed files (engine/CMakeLists.txt, engine/include/caw/module.hpp, engine/src/module.h, engine/tests/public_cpp_sdk_test.cpp); check it still holds and update it if not (docs/engine-integration.md)
FAIL stale - covers changed files (engine/CMakeLists.txt, engine/include/caw/module.hpp, engine/src/module.h, engine/tests/public_cpp_sdk_test.cpp); check it still holds and update it if not (docs/engine-next.md)
FAIL stale - covers changed files (engine/CMakeLists.txt, engine/include/caw/module.hpp, engine/src/module.h, engine/tests/public_cpp_sdk_test.cpp); check it still holds and update it if not (docs/engine-progress.md)
FAIL stale - covers changed files (engine/CMakeLists.txt, engine/include/caw/module.hpp, engine/src/module.h, engine/tests/public_cpp_sdk_test.cpp); check it still holds and update it if not (docs/engine-recovery.md)
FAIL stale - covers changed files (engine/CMakeLists.txt, engine/include/caw/module.hpp, engine/src/module.h, engine/tests/public_cpp_sdk_test.cpp); check it still holds and update it if not (docs/engine.md)
FAIL stale - covers changed files (engine/CMakeLists.txt, engine/include/caw/module.hpp, engine/src/module.h, engine/tests/public_cpp_sdk_test.cpp); check it still holds and update it if not (docs/lightweight-creative-audio-systems.md)
FAIL stale - covers changed files (engine/CMakeLists.txt, engine/include/caw/module.hpp, engine/src/module.h, engine/tests/public_cpp_sdk_test.cpp); check it still holds and update it if not (docs/music-workflow-feature-gap-plan.md)
FAIL stale - covers changed files (engine/src/module.h); check it still holds and update it if not (docs/native-module-sdk.md)
FAIL stale - covers changed files (engine/CMakeLists.txt, engine/include/caw/module.hpp, engine/src/module.h, engine/tests/public_cpp_sdk_test.cpp); check it still holds and update it if not (docs/performance.md)
$ node scripts/docs-test.js --strict --base origin/Main
PASS uncovered - every code area is covered by a note
```

Next: fix only what the failing sections name, push once (with `run:` lines for just the failing commands), then read this file again for the new commit.
