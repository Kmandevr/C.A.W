---
paths:
  - "examples/*.caw"
---

# Example patterns (examples/*.caw)

- The two files here are note patterns (`kind: pattern`), the text the app bundles as its pattern examples (`app/lib/model/pattern_templates.dart`, which must match them word for word: `app/test/pattern_templates_test.dart`). The format is in `docs/engine.md` ("Patterns"); change that reference and its tests when the format changes.
- `summary:` is one line saying what the pattern is; the repo map shows it.
- Only original work, or work with a licence that allows redistribution; credit and licence go in the header.
- C++ starters live in `examples/cpp/` and follow the SDK's rules (`docs/native-module-sdk.md`).
