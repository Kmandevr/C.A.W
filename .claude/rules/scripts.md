---
paths:
  - "scripts/**"
---

# Repository scripts

- Plain Node (22), CommonJS, no npm packages: they run in CI and locally as `node scripts/<name>.js`. They are repository tools, never part of the app.
- Output is `PASS|WARN|FAIL <check> - <detail> (<file>)` lines, exit code 1 on any FAIL, so skills and CI read them the same way.
- Start each file with a one-line `//` comment saying what it is for (the repo map reads it).
