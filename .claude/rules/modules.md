---
paths:
  - "examples/**"
  - "**/*.caw"
---

# Sound modules (.caw)

- One module per file: a metadata header (`caw` format version, `kind`, `name`, `summary`, `params`) then code. The implemented format and syntax are in `docs/engine.md`; change that reference and its tests when the format changes.
- `summary:` is one line saying what the sound is; the repo map shows it.
- Only original work or work with a licence that allows redistribution. Never paste community bytebeat formulas without the author's permission; credit and licence go in the header.
- Every example must pass the current CLI validation/render checks and the Engine CI example-render gate; do not describe the CLI as future work.
