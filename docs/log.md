---
title: Log
summary: Dated history of changes, newest first.
updated: 2026-11-02
---

# Log

- 2026-11-02: Native-engine CI repair follow-up. Engine tests now cover clearing stale project state when the 8 MiB parser budget rejects input. Docs CI caught a malformed log frontmatter replacement; restore the canonical log history and preserve its frontmatter. Retirement overflow remains a known ownership defect requiring a callback-safe backpressure design.

- 2026-11-02: Established docs/roadmap.md as the permanent canonical C.A.W. roadmap. Consolidated the long-term production direction into ordered stages, including audio/MIDI recording, monitoring and latency compensation, loop recording, take lanes/comping, plugin hosting, tempo maps, control surfaces, mastering tools, optional collaboration and surround/immersive audio. Explicitly excluded video synchronization for now. Converted the former two-part core plan into a compatibility pointer and the music workflow plan into a factual gap reference; aligned vision and UI scope notes.

- 2026-11-01: Repository-wide documentation accuracy pass: reconciled current app/engine facts, corrected piano-roll curves and generator status, separated shipped/partial/deferred capabilities, updated synth and worker-pool references, and removed stale claims of AI, MIDI-device, audio-recording, plugin-host and platform support.

- 2026-11-01: Consolidated the owner-discussed work into a two-part master plan: core build order and complete feature inventory. This interim planning structure was superseded on 2026-11-02 by the permanent single roadmap.

- 2026-10-31: Corrected low-memory scheduling inputs: removed the 16 MiB budget floor, preserved exhausted finite cgroup memory limits as a constrained signal, and added boundary tests for the budget conversion (#46).
- 2026-10-31: Added an explicit unknown-pressure state and event-driven Android thermal/battery-saver feeds; app lifecycle and audio transitions now refresh the native worker budget (#46).

- 2026-10-31: Native worker-pool threads are now created on demand as queued/running work requires them, rather than eagerly at pool startup; added scheduler lifecycle/scale-up tests and updated the performance audit (Issue #44).
- 2026-10-31: Added the public native worker-pool job API and routed app project compilation, source checks and offline WAV renders through it. Job handles expose status/progress, cancellation and owned results; project jobs retain engine lifetime, and pool shutdown drains accepted work. Added native C API and Flutter integration tests (Issue #38).

- 2026-10-30: Connected the app's isolate work scheduling to the engine's hardware profile and workload policy; added native capability diagnostics in Settings and FFI/scheduler tests.

- 2026-10-30: Briefly added touchscreen Vim controls and an editable command line (Issue #22); the touch controls were later removed after the owner clarified Vim is for attached physical keyboards.
- 2026-10-30: Replaced the proposed touchscreen Vim key panel with customizable touch quick actions in Sounds, Tracks and Export. Actions run directly, and per-area toolbars reuse the persistent keymap format; Vim remains for attached physical keyboards (Issue #23).

- 2026-10-30: The piano-roll toolbar now exposes touch-friendly Copy and Paste for selected notes; dragging a selected note moves the entire group without accidentally resizing it (Issue #21).

- 2026-10-30: Focused text fields now receive Backspace, Delete and text-navigation keys even in code-editor Vim normal mode; ordinary Vim letters and command-line handling remain with Vim (Issue #20).

- 2026-10-30: Tap tempo now shares timing state between the project settings button and the global T shortcut; the shortcut is routed, tap timing resets after a pause, and the on-screen target is larger (Issue #19).

- 2026-10-30: Note-expression curve points now snap to the piano-roll grid when enabled and stay within the note's normalised duration; added model tests and updated the app reference (Issue #15).

Newest first.

- 2026-10-29: Per-note expression in the roll: bent notes drawn as lines, pitch points drawn on a selected note with the Curve tool, and vibrato, presets and pitch/volume/timbre curve editors in the extras panel ([app](app.md)).
- 2026-10-29: Per-note expression in the engine: bend, vib, press and timbre note extras, the press and timbre variables, freq following the bend, and MPE .mid export ([engine](engine.md#patterns)).
- 2026-10-29: Synth stage 1.3: kind: synth patch files (oscillators, sub, noise, two filters, the volume envelope, effects in line order including project effect modules) translate to ordinary code (engine/src/synth.cpp); caw check --code; the Init synth template; the app plays synths as sounds ([synth](synth.md)).
- 2026-10-29: Synth stage 1.2: a generator's voices header (1–32, default 8) sets its notes at once; the project's voices is now a cap (default 32, Light mode 4). wt latches its table and unison count at the note start and follows detune per sample, so live and export agree on every buffer size.
- 2026-10-29: Synth stage 1.1: wavetables (engine/src/tables.cpp, band-limited per octave with our own deterministic FFT), the wt oscillator with up to 16 unison voices, table.* constants, and the Wavetable pad template ([synth](synth.md)).
- 2026-10-29: Merged the friendlier layout (PR #6) with the roll and editor work: the roll keeps the newer touch handling plus the double tap that deletes a note; the Solo headphones button can be hidden; the phone's Controls | Code switch replaces the "Controls above the code" setting.
- 2026-10-29: Curve tool for the velocity and chance lanes (points and bendable segments; part of #11).
- 2026-10-29: Code editor layout in Settings (part of #10): key row, completion chips, which buttons and the scope show, Run bar position, compact and foldable controls. Syntax for new controls and for curves proposed on #10 and #11 for the owner.
- 2026-10-29: Roll customisation (#9): Settings → Piano roll (sizes, grid strength, key names, grab zone, hold time, empty-grid drag), a toolbar you edit (actions and macros), and the generators (euclid, random in key, arpeggiate, humanize, chord stamp, reverse, invert pitch).
- 2026-10-29: The piano roll works inline in the Builder (it claims its touches; one finger on empty grid scrolls, a tap draws). New [how it works](how-it-works.md) note for agents. Owner's plan for roll, editor and curve work in [decisions](decisions.md).
- 2026-10-28: Piano roll on touch: one finger scrolls from empty space, a double tap deletes a note (owner) ([app](app.md)).
- 2026-10-28: Friendlier layout (owner's choice: track-first, more visual, less cluttered; scenes later): areas renamed Sounds, Tracks and Export; Tracks has a project strip, visual track cards and a track panel; Sounds opens on controls with the code one tap away ([app](app.md)).
- 2026-10-28: Light mode (owner OK), auto-update while typing, the key router (keymaps, Vim, counts, macros, action list, code-editor Vim), roll extras panel, lanes, triplets and MIDI import/export buttons; engine voices limit ([app](app.md)).
- 2026-10-28: Piano roll and drum grid built for pattern modules: adaptive grid, key rows, velocity lane, draw/select/erase, the owner's WASD/Q/E keys ([app](app.md)).
- 2026-10-28: Performance audit, app part. Each keystroke or slider step rebuilt about 3,520 widgets; now 10 and 169 (measured). The meter poll ran every frame even when stopped; now nothing runs when stopped or hidden, and the audio device closes after 30 s idle ([performance](performance.md)).

- 2026-10-28: Owner's performance audit, engine part. caw_bench plus callgrind found the bitwise and % conversions and a per-layer solo scan; exact fast paths cut 10–20% of instructions with output unchanged ([performance](performance.md)). Merged MIDI file import/export, the app's pattern model, the actions/keys/Vim core, and themes, fonts, density, settings, the startup screen and blank modules.

- 2026-10-28: Building the go'd plan. Engine live editing done: code swaps keep the running state of unchanged calls, can wait for the next beat or bar, and pattern edits let sounding notes finish ([engine](engine.md#playback)).

- 2026-10-28: Owner asked for blank new files (with a faint hint, and templates optional) and a startup choice: continue, blank or template ([UI design](ui.md)). Still waiting for the go.

- 2026-10-28: Owner confirmed the adaptive grid reading, and asked for live editing while playing: code auto-update with a delay you can set and an off switch, swap timing you can choose, pattern edits from a note's next play, and sound state carried across code swaps ([architecture](architecture.md#live-editing-while-playing-proposal)). Still waiting for the go.

- 2026-10-28: Owner set the adaptive grid: the chosen resolution (1 down to 1/128, or off) is its finest level and the snap, Shift-drag ignores it, and tapping keeps 48 dp cells ([UI design](ui.md#editors)). Still waiting for the go.

- 2026-10-28: Owner answered the remaining key questions (WASD in the code editor's Vim mode, Alt+Q to record, Ctrl+1/2/3 for areas, the cursor keys, the phone toolbar); updated [actions](actions.md). Still waiting for the go.
