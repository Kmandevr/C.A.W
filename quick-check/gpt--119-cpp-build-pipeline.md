# Quick check: gpt/119-cpp-build-pipeline

- Commit: `cb04dded24196a5e2caae213ac9ab88fef810c42` (trust this report only if it is your latest commit)
- Finished: 2026-11-06T21:35:14Z
- Status: FINISHED
- Verdict: **FAIL**
- Environment: GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner's device runs can.
- Commands: default set (no `run:` lines in the commit message)
- Rules for the files you changed: `.claude/rules/ci.md`, `.claude/rules/docs.md`, `.claude/rules/engine.md`, `.claude/rules/modules.md`, `.claude/rules/scripts.md` (all bundled in `START.md` on `agent-results`)
- Full logs: https://github.com/Kmandevr/C.A.W/actions/runs/42297758137

| # | Command | Result | Time |
| --- | --- | --- | --- |
| 1 | `docs` | PASS | 0s |
| 2 | `build` | PASS | 35s |
| 3 | `test` | FAIL | 2s |
| 4 | `examples` | PASS | 1s |

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
4/5 Test #4: caw_tests_shard_3 ................***Failed    0.99 sec
FAIL offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback (/home/runner/work/C.A.W/C.A.W/engine/tests/export_test.cpp:248): left[256] ~= static_cast<float>(0.5 * 0.7071067811865476): 0.29899534583091736 vs 0.3 …
80% tests passed, 1 tests failed out of 5
The following tests FAILED:
	  4 - caw_tests_shard_3 (Failed)
ok   project_json_rejects_invalid_dependency_scope_and_unpinned_versions
ok   engine_resource_budget_scales_with_available_memory
ok   worker_api_submits_checks_and_returns_owned_results
ok   mute_and_solo_mixes_equal_projects_without_the_silenced_tracks
ok   code_swaps_between_chains_of_different_lengths_match_golden_renders
65 tests, 1 failures (shard 4/4)
5/5 Test #2: caw_tests_shard_1 ................   Passed    1.67 sec
Total Test time (real) =   1.72 sec
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

Next: fix only what the failing sections name, push once (with `run:` lines for just the failing commands), then read this file again for the new commit.
