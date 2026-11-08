# Quick check: gpt/127-native-expression-channel-model

- Commit: `3e24101bbd6f94e3c4b1ad419e1b6ee22204bd4b` (trust this report only if it is your latest commit)
- Finished: 2026-11-08T17:21:18Z
- Status: FINISHED
- Verdict: **FAIL**
- Environment: GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner's device runs can.
- Commands: as requested by `run:` lines in the commit message
- Rules for the files you changed: `.claude/rules/docs.md` (all bundled in `START.md` on `agent-results`)
- Full logs: https://github.com/Kmandevr/C.A.W/actions/runs/42504485951

| # | Command | Result | Time |
| --- | --- | --- | --- |
| 1 | `test offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback` | FAIL | 25s |

## 1. test offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback: FAIL

```text
FAIL offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback (/home/runner/work/C.A.W/C.A.W/engine/tests/export_test.cpp:248): left[256] ~= static_cast<float>(0.5 * 0.7071067811865476): 0.29899534583091736 vs 0.3 …
$ engine/build/caw_tests offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback
1 tests, 1 failures (shard 1/1)
```

Next: fix only what the failing sections name, push once (with `run:` lines for just the failing commands), then read this file again for the new commit.
