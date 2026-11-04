# Handoff

Commit: 7f17afc
Branch: claude/caw-engine-foundation-skpirb (F5.2 on top of Main ab1d72f; PR to Main)

## Goal
Owner (2026-11-03): finish the roadmap Foundation stage (#28): F5 → F6 → F7 → F8, plus F10 (seeded randomness); F9 is deferred to Release 1, since no project compatibility is needed yet.
- One small PR per step, targeting `Main`. Claude merges when CI is green, and updates the #28 progress comment (id 6609966082).
- Rules: no allocation, locks or I/O in the callback; exports bit-identical across platforms; stereo low-overhead (callgrind, `caw_bench 1|2 N` difference / 250); never weaken tests, and a bug fix starts with a failing test; audio-reviewer and release-check before each PR; each PR updates the roadmap row and `docs/engine-build-status.md`.
- Ask the owner before SDK ABI changes, new dependencies, or app/ changes.

## Done and verified
- On Main: F3 (#72), F4 (#74, #75, #77, #79) and F5.1 (#80).
- F5.2 event ports are on the branch (`a75493f`, docs `893ea8a`, review fixes `7f17afc`).
  - Owner's format (2026-11-04): a C.A.W `Event` with a note id, carrying raw UMP. Tests: caw_tests 240/240, caw_rt_tests 50/50, sanitizers clean. Callgrind: playback +0.001–0.02%, graph +0.06%.
  - Audio review: no defects; host-count bound and size_t offsets fixed. Unconnected merging inputs keep a full (budgeted) buffer; accepted.

## Open
- Issue #78: swap-fade import buffers are renumbered (an older bug).
- F10 seeds for native plugins need an SDK ABI change, so the owner must approve it.
- F6 design (architect, 2026-11-04):
  - A `ParameterResolver` (`engine/src/params.*`) per executor node, with values passed to processors through `ProcessBlock`.
  - Order: base (manual or MIDI CC; an automation lane replaces it), normalize, modulation links in link-id order (add/mul/min/max/replace), clamp, denormalize, step.
  - Per-sample only when something is active; otherwise constant.
  - PRs F6.1–F6.6, with F6.6 moving the Engine's .caw params and globals onto it (golden hashes unchanged).
  - Owner questions: manual move vs automation; depth units; whether CC sets the base or modulates; whether native modules stay at one value per block (an ABI change otherwise).

## Next
1. Merge the F5.2 PR when CI is green, and update #28.
2. Ask the owner the F6 questions, record the answers in `docs/decisions.md`, then F6.1 (resolver and descriptor fields).

## Read first
- `docs/roadmap.md`
- `docs/decisions.md`
- `docs/engine-next.md` ("One parameter model")
- `engine/src/module.h`
- `engine/src/graph.h`
