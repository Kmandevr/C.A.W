# Handoff

Commit: 4105764

Branch: ccr-56285e11-0xrj3h (PR #136 open, CI and an audio review running)

## Goal
Owner (2026-11-09): Claude builds the engine; GPT is paused.
- Order: #120 → #17 → #121 → #122 (issue #123). Merge own engine PRs when CI is green and an audio review finds nothing blocking.
- Use judgment, but never a whole change of direction. Fix tooling that gets in the way. Ask the owner how UI should look before building it.

## Done and verified (merged)
- #130: GPT's note/channel docs, Android toolchain manifest and component host, with fixes.
- #131: seed fields keep edits (#20). The issue awaits the owner's phone check.
- #132: CP.2 descriptor and the plain-C component interface, `engine/include/caw_component.h`.
- #134: export buffers held to a project-wide budget (#133 items 1, 4, 5).
- #135: `caw_engine_components` listing, bundles, owner decisions (mono stays mono until stereo; packages), narrowed doc coverage.

## In review
- #136:
  - Public deterministic maths in `engine/include/caw/detmath.hpp`.
  - The pan law in `engine/include/caw/library/stereo.hpp`, which the mixer uses (goldens unchanged).
  - SDK float flags, interface v3, UTF-8-safe JSON.

## Next
- #17: the 3-PR plan is in the issue. First, stereo-capable lanes with a per-lane mono/stereo flag (no sound change). Then C++ components in track chains. Then dual-mono .caw effects after the stereo point.
- #121: master-chain parameters, then built-in pan/balance/width wrappers registered in the Engine's registry.
- #133 items 2 and 3, with callgrind before and after.

## Open (owner)
- #20: phone check of Backspace with the Samsung keyboard.
- The owner deletes old merged branches by hand, since git deletes are blocked here. The list is in the chat.

## Read first
- `docs/native-module-sdk.md`
- `docs/decisions.md`
- `engine/src/engine.cpp`
