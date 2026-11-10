# Handoff

Commit: 4b72163

Branch: ccr-56285e11-0xrj3h (PR #153 open, subscribed)

## Goal
Owner (2026-11-10): "start building the ui out, I want it done when I come back", with the C++ work in it; aim for an open beta, not just a v1.
- The layout is the owner's plan in `docs/decisions.md` ("The app's layout"): compact, keep the glass look, REAPER-like DAW, Unity-like Files.

## Done and verified
- Frame, Arrange focus view and FX stack, Files, C++ Builder, MIDI keyboards, docking windows, open-beta bits: all in PR #153 (Issues #142-#151).
- `flutter analyze` clean; `CAW_LIB=<scratchpad>/build-rel/libcaw.so flutter test` in `app/`: 424 passed.
- `node scripts/docs-test.js`: pass. Two independent code reviews; their findings are fixed.

## Open
- CI's Compiler workflow is the first build of the `engine/compiler/caw_compiler.cpp` change (stdout capture for completion).
- A security review of loading, trust, MIDI and file paths was running at this commit.
- Nothing is checked on a phone yet; MIDI is untested with hardware; check/completion cost on the phone is unmeasured.
- Owner's call: the APK is 114 MB because Android stores the 78 MB compiler library uncompressed.
- Not built: .caw effect bypass, "Automate" on FX knobs, S Pen tuning, audio recording, desktop MIDI.

## Next
- Fix any security findings and CI failures on PR #153; merge when green.

## Read first
- `docs/decisions.md`
- `docs/app.md`
