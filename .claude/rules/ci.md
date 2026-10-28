---
paths:
  - ".github/**"
---

# GitHub Actions and repository config

- CI is the owner's build machine: the APK, engine tests and docs checks all run here, and every result must be readable from a phone (clear job names, artifacts with obvious names, a one-line failure reason).
- Least privilege: set `permissions:` on every workflow, default `contents: read`. Never echo secrets, never run code from fork pull requests with secrets available (`pull_request`, not `pull_request_target`).
- Pin third-party actions to a major version from a known publisher (`actions/*`), or to a commit SHA otherwise.
- Debug APKs are signed with one fixed keystore kept in repository secrets, so each build installs over the last. Never commit a keystore.
- Start each file with a one-line `#` comment saying what it is for (the repo map reads it).
