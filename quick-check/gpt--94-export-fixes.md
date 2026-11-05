# Quick check: gpt/94-export-fixes

- Commit: `62b1ceb8d54c07ba8ddd09b2f3b0af21a1697354` (trust this report only if it is your latest commit)
- Finished: 2026-11-05T22:41:24Z
- Status: FINISHED
- Verdict: **FAIL**
- Environment: GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner's device runs can.
- Commands: as requested by `run:` lines in the commit message
- Rules for the files you changed: `.claude/rules/engine.md` (all bundled in `START.md` on `agent-results`)
- Full logs: https://github.com/Kmandevr/C.A.W/actions/runs/42122864244

| # | Command | Result | Time |
| --- | --- | --- | --- |
| 1 | `test offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback` | FAIL | 32s |

## 1. test offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback: FAIL

```text
FAIL offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback (/home/runner/work/C.A.W/C.A.W/engine/tests/export_test.cpp:233): rendered.frames == int64_t{512}: 4800 vs 512
FAIL offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback (/home/runner/work/C.A.W/C.A.W/engine/tests/export_test.cpp:246): left[256] ~= static_cast<float>(0.5 * 0.7071067811865476): 0.20929674804210663 vs 0.3 …
$ engine/build/caw_tests offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback
1 tests, 2 failures (shard 1/1)
```

Next: fix only what the failing sections name, push once (with `run:` lines for just the failing commands), then read this file again for the new commit.
