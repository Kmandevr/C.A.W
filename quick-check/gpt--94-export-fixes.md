# Quick check: gpt/94-export-fixes

- Commit: `fdafbf633bc6b2915b37e4aa7973a427c5d5bfed` (trust this report only if it is your latest commit)
- Finished: 2026-11-05T20:04:09Z
- Status: FINISHED
- Verdict: **FAIL**
- Environment: GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner's device runs can.
- Commands: as requested by `run:` lines in the commit message
- Rules for the files you changed: `.claude/rules/engine.md` (all bundled in `START.md` on `agent-results`)
- Full logs: https://github.com/Kmandevr/C.A.W/actions/runs/42099416643

| # | Command | Result | Time |
| --- | --- | --- | --- |
| 1 | `build caw_tests` | FAIL | 10s |
| 2 | `def Engine::setProject` | INVALID | 0s |
| 3 | `def send` | PASS | 0s |
| 4 | `def applyCommands` | PASS | 0s |

## 1. build caw_tests: FAIL

```text
   44 |     do { if (!(c)) cawtest::fail(__FILE__, __LINE__, "CHECK(" #c ")"); } while (0)
/home/runner/work/C.A.W/C.A.W/engine/tests/export_test.cpp:236:20: error: ‘class caw::Engine’ has no member named ‘setProjectOffline’; did you mean ‘setProjectJson’?
gmake[3]: *** [CMakeFiles/caw_tests.dir/build.make:121: CMakeFiles/caw_tests.dir/tests/export_test.cpp.o] Error 1
gmake[2]: *** [CMakeFiles/Makefile2:202: CMakeFiles/caw_tests.dir/all] Error 2
gmake[1]: *** [CMakeFiles/Makefile2:209: CMakeFiles/caw_tests.dir/rule] Error 2
gmake: *** [Makefile:174: caw_tests] Error 2
In file included from /home/runner/work/C.A.W/C.A.W/engine/tests/export_test.cpp:13:
/home/runner/work/C.A.W/C.A.W/engine/tests/export_test.cpp: In function ‘void test_offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback()’:
  236 |     CHECK(playback.setProjectOffline(p).find(R"("ok":true)") != std::string::npos);
      |                    ^~~~~~~~~~~~~~~~~
/home/runner/work/C.A.W/C.A.W/engine/tests/test.h:44:16: note: in definition of macro ‘CHECK’
      |                ^
```

## 2. def Engine::setProject: INVALID

```text
"Engine::setProject" is not a symbol name
```

## 3. def send: PASS

```text
send             function    724 engine/src/engine.cpp bool Engine::send(const Cmd& c) {
```

## 4. def applyCommands: PASS

```text
applyCommands    function   2000 engine/src/engine.cpp void Engine::applyCommands() noexcept {
```

Next: fix only what the failing sections name, push once (with `run:` lines for just the failing commands), then read this file again for the new commit.
