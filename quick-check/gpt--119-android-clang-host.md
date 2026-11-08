# Quick check: gpt/119-android-clang-host

- Commit: `a94476ccf74d65ae02036d7613ee8bb9dd2c275a` (trust this report only if it is your latest commit)
- Finished: 2026-11-08T18:01:35Z
- Status: FINISHED
- Verdict: **PASS**
- Environment: GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner's device runs can.
- Commands: default set (no `run:` lines in the commit message)
- Full logs: https://github.com/Kmandevr/C.A.W/actions/runs/42507776976

| # | Command | Result | Time |
| --- | --- | --- | --- |
| 1 | `docs` | PASS | 0s |
| 2 | `build` | PASS | 37s |
| 3 | `test` | PASS | 3s |
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

## 3. test: PASS

```text
2/5 Test #1: caw_tests_shard_0 ................   Passed    1.09 sec
3/5 Test #5: caw_rt_tests .....................   Passed    0.55 sec
4/5 Test #4: caw_tests_shard_3 ................   Passed    1.65 sec
5/5 Test #2: caw_tests_shard_1 ................   Passed    2.70 sec
100% tests passed, 0 tests failed out of 5
Total Test time (real) =   2.74 sec
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

Next: if the task is finished, run the default set (a commit with no `run:` lines), then open the pull request. Otherwise do the next step.
