---
paths:
  - "docs/**"
  - "README.md"
---

# Notes in docs/

Docs stay clean and current: a note says what is true now, not how it got there.

- **One home per fact.** Before writing, Grep `docs/` for the topic and edit the note that owns it; link instead of repeating. A new note earns its place only for a new topic, and goes in `docs/index.md`.
- **Rewrite, don't append.** When a fact, plan or decision changes, replace the old text where it stands. History goes only to `log.md` (one dated line per session's changes) and `decisions.md` (what was chosen and why, newest first). Delete notes, sections and examples that no longer apply; never leave "old"/"deprecated" text in place.
- **Label certainty.** Mark claims **[Fact]** (verified, with source and date when it can change), **[Proposal]** or **[Assumption]**. Owner questions go in the open-questions register in `vision.md`. Never describe planned code as built.
- **Check before writing.** Notes describe what the repository actually does: check the code or config first, and keep notes short.
- **Frontmatter** on every note: `title`, `summary` (one line, shown in the repo map), `covers` (when the note describes code: a one-line list of files, `dir/` folders or `*` globs, e.g. `[engine/vm/, scripts/docs-test.js]`), `updated` (YYYY-MM-DD).
- When code a note covers changes, re-check that note in the same change and bump `updated`. New code areas get a `covers:` entry. `node scripts/docs-test.js` checks all of this; the Stop hook reminds you, and CI fails a stale note on pull requests (`--strict`).
- `README.md` is the front door: it must name every top-level folder, workflow and npm script (the check fails otherwise), and its `covers:` list is the HTML comment on its first line.
- Relative markdown links (`[text](other.md)`), not `[[wikilinks]]`. Tasks live in GitHub Issues, not here.
