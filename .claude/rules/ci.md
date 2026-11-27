---
paths:
  - ".github/**"
---

# GitHub Actions and repository config

- CI is the owner's build machine: Android and Windows app artifacts, Dart analysis/tests, engine tests (Linux x64/Arm64, Windows x64 and Linux sanitizers) and docs checks run here. iOS/macOS app builds are not currently configured. Every result must be readable from a phone (clear job names, obvious artifacts and a one-line failure reason).
- Least privilege: set `permissions:` on every workflow, default `contents: read`. Never echo secrets, never run code from fork pull requests with secrets available (`pull_request`, not `pull_request_target`).
- Pin third-party actions to a major version from a known publisher (`actions/*`), or to a commit SHA otherwise.
- Apple targets (iOS, macOS) need macOS runners, which cost more: build them on release branches or on demand, not on every push.
- Android debug APKs are signed with one fixed keystore kept in repository secrets, so each build installs over the last. Never commit a keystore.
- Start each file with a one-line `#` comment saying what it is for (the repo map reads it).
- The *Dart tests (N/4)* jobs split the files by `app/test/test_times.json` (`scripts/dart-test-shard.js`); after adding or growing heavy test files, re-measure with a full local `flutter test --file-reporter json:<report>` and `node scripts/dart-test-times.js <report>`.
- A failed *Dart tests (N/4)* or engine test job names each failing test in its summary and annotations (`scripts/dart-test-summary.js`, `scripts/ctest-summary.js`); for the full output download the job log (`get_job_logs` without content, then the URL) and search for `❌` (Dart) or `FAIL ` (engine). A failure gets one re-run, and only after the test passes locally alone and with its file (known timing-sensitive: the startup reveal, Arrange's focus double tap).
- `flutter analyze && flutter test` skips the tests when analyze finds anything: check that the tests ran.
