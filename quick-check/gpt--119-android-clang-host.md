# Quick check: gpt/119-android-clang-host

- Commit: `c3d42ecfd650a0dbbf35c3c8924f8c578d731bd6` (trust this report only if it is your latest commit)
- Finished: 2026-11-08T21:43:15Z
- Status: FINISHED
- Verdict: **FAIL**
- Environment: GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner's device runs can.
- Commands: as requested by `run:` lines in the commit message
- Rules for the files you changed: `.claude/rules/app.md` (all bundled in `START.md` on `agent-results`)
- Full logs: https://github.com/Kmandevr/C.A.W/actions/runs/42526540884

| # | Command | Result | Time |
| --- | --- | --- | --- |
| 1 | `analyze app/lib/platform/cpp_toolchain.dart app/lib/platform/cpp_build.dart` | PASS | 3s |
| 2 | `dart-test app/test/cpp_toolchain_test.dart` | FAIL | 12s |

## 1. analyze app/lib/platform/cpp_toolchain.dart app/lib/platform/cpp_build.dart: PASS

```text
  xml 7.0.1 (7.1.0 available)
Got dependencies!
17 packages have newer versions incompatible with dependency constraints.
Try `flutter pub outdated` for more information.
Analyzing 2 items...                                            
No issues found! (ran in 1.7s)
```

## 2. dart-test app/test/cpp_toolchain_test.dart: FAIL

```text
::group::❌ rejects traversal, absolute paths and duplicate artifact paths (failed)
::error::6 tests passed, 1 failed.
Expected: throws <Instance of 'FormatException'>
  Actual: <Closure: () => CppToolchainManifest>
   Which: returned <Instance of 'CppToolchainManifest'>
package:matcher                                     expect
package:flutter_test/src/widget_tester.dart 473:18  expect
test/cpp_toolchain_test.dart 83:7                   main.<fn>
::endgroup::
::group::✅ Passing tests
✅ requires valid SHA-256 and positive artifact size
✅ decodes JSON and rejects unknown manifest versions
```

Next: fix only what the failing sections name, push once (with `run:` lines for just the failing commands), then read this file again for the new commit.
