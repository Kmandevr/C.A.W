<!-- How to write a changes/ file: one per change, joined into CHANGELOG.md's entry when a version is released. -->
# Changes waiting for a release

Every change a user would notice adds one file here, in the same pull request, instead of editing `CHANGELOG.md`. Two pull requests then never touch the same lines, and the release pull request doesn't have to recall what changed.

**A file** is `changes/<short-name>.md` (for example `curlew-piccolo.md`; the name only sets the order within a group, alphabetical). It holds a group line and one bullet, written as the changelog reads, for a player of the app:

```markdown
### New
- **Piccolo in Curlew:** sings up to A7, shaped by a free recording of the real instrument.
  - Its card has a drawing of its own.
```

- The group is `### New`, `### Changed` or `### Fixed`.
- One top-level `- ` bullet, starting with a **bold name** and a colon, as in [CHANGELOG.md](../CHANGELOG.md). It may continue on lines indented by two spaces, and carry nested bullets indented by 2, 4 or 6 spaces. No blank lines, tabs or headings inside it.
- At most 40 lines and 4000 characters. `node scripts/changelog-join.js --check` parses every file here (CI runs it with the script tests).

**At release** the version pull request runs `node scripts/changelog-join.js <version> <date> --summary "<one line>"` (for example `1.1.3-alpha.7 2026-11-28`). It writes the version's `## <version> (<date>)` entry, groups in the order New, Changed, Fixed, at the top of both `CHANGELOG.md` and `app/assets/CHANGELOG.md`, and deletes the files it joined. Nothing is written if a file fails to parse, the two copies differ or the version already has an entry. Edit the joined entry by hand afterwards if it reads better reordered, in both copies.
