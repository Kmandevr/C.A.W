# Handoff

Commit: 6ffab93 on ccr-bd7ac4df-86w0bh: Curlew's piccolo, oboe and tuba (cards in two rows), not yet a PR when
written. Main has #273 (Starling treble) and #274 (docs) unreleased; alpha.6 ships them with Curlew. Released:
1.1.3-alpha.5. The owner (2026-11-26): Claude merges and releases when ready, and takes its own recommended option
for any question (docs/decisions.md). A 5-hourly scheduled wake-up resumes this session. Standing rules:
`.claude/rules/done.md`, docs/decisions.md 2026-11-25.

## Goal
Finish 1.1.3, then 1.1.4 (automation choices and VCA groups #210, receives/parallel/multi-out #217, MIDI out and
clock #211).

## Done and verified (this branch)
- Curlew variants 6-8 (piccolo G5-A7, oboe B3-F6, tuba B1-D4); bassoon not built (slow low notes, decisions.md).
  Tuba release step fixed (lipCloseK 1, brassLp 0.5); the old six keep their pitch clamp 34..100.
- Local: caw_tests all green but the native-loader test (needs CTest's CAW_TEST_COMPONENT_PATH); caw_rt_tests
  139/139; flutter analyze clean, flutter test full pass; docs guard --strict pass. Audio review: no defects, its
  hardening points applied.

## Open
- Owner: Hub #33 (rear Antiphonal stops, where the rock organ lives); otherwise my recommendations stand.

## Next
1. Code review of the app part (running), PR, CI, merge, release 1.1.3-alpha.6 (version, changelog, four version
   goldens, architecture.md version fact).
2. The rest of 1.1.3 (recommended to the owner 2026-11-26): the maintenance list (split big files and CI jobs,
   per-build compat tables job, per-build references, changelog per file, one list for bench and C API numbers,
   worktree backup) and the hidden collaboration groundwork G1-G3 (Hub docs/caw/collaboration-design.md); two
   playing modes (#11) and the main panel refinement (#10) move to 1.1.4.
3. Issue #271 (close after green Windows runs), #268.
