---
paths:
  - "examples/**"
  - "**/*.caw"
---

# Sound modules (.caw)

- One module per file: a metadata header (`caw` format version, `kind`, `name`, `summary`, `params`) then code. The format is in `docs/architecture.md` ("Module file"); change it there first.
- `summary:` is one line saying what the sound is; the repo map shows it.
- Only original work or work with a licence that allows redistribution. Never paste community bytebeat formulas without the author's permission; credit and licence go in the header.
- Every example must pass `caw check` and render to non-silent, non-clipping audio once the CLI exists.
