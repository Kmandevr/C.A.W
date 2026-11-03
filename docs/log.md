---
title: Log
summary: Dated history of changes, newest first.
updated: 2026-11-03
---

# Log

- 2026-11-03: Reworked the roadmap with the owner: a Foundation stage for the engine graph and N-channel core (#28) now comes first, Release 1 sits after Stage 7, missing items (app-wide undo, crash recovery, project migrations, output settings, onboarding/help/presets) were placed, and every stage is a per-item table with status, where, dependencies and gaps. Notes that said graph work was paused were rewritten. The product goal is now stated in vision, roadmap and architecture: not a conventional DAW, but able to do everything a good DAW can, since there is no good one on mobile.

- 2026-11-03: Recorded owner engine decisions (one graph runs everything, Stage 0 SFZ = import + mapping, bit-identical exports, per-item Isolated/Trusted/Blocked trust modes for third-party native code, project folders with package build and AutoStacc cloud-library compatibility, per-clip musical/fixed timing, N-channel graph shipping stereo, plugin-exportable nodes, project render sample rate) plus graph resumption before Stage 2, budget-phone floor, 32-bit float buffers and adjustable latency, in decisions, roadmap, engine-next, ledger and native SDK notes. Engine-plan consistency pass: marked module/global automation (PR #68, CI green) implemented in the ledger, roadmap and architecture; split the next steps into WAV/SFZ multisample then stems export; renamed the paused "Stage 5" graph integration to avoid clashing with roadmap Stage 5 (live MIDI); mapped old architecture "Stage 5" references to roadmap stages; aligned engine-next recording text with roadmap Stage 7; relabelled engine-next §12 as dependency order, not schedule.

- 2026-11-03: Added the chat-agent route: `gpt/**` branches run the Quick check (commands chosen by `run:` lines in the commit message, else a default Linux set; no app builds) and get a report file on `agent-results`, and a generated `START.md` there bundles everything a chat must read first; `AGENTS.md` now holds the loop and stop rules that keep GPT from re-review cycles.

- 2026-11-03: Agent tooling made the default and fully wired: Serena's remind hook now covers Bash and Serena calls, the session-start hook prints the Graphify/Serena navigation order and restores a missing `origin/HEAD` so the docs Stop hook's stale check runs.

- 2026-11-02: Added callback-safe retirement backpressure to the native Engine. SPSC now supports non-consuming peek and writable-capacity inspection; command processing reserves worst-case retirement capacity, and callback-side swaps/removals defer instead of dropping object ownership when the retirement queue plus pending list are full. Added queue-capacity regression coverage. Engine/App/Docs CI pending at the current checkpoint.

- 2026-11-02: Follow-up parser safety: `parseProject` clears prior `ProjectSpec` output and stale error text before rejecting JSON over the 8 MiB input budget; regression coverage verifies stale state is not retained.

- 2026-11-02: M0 repository recovery and architecture audit is verified. Confirmed PR #68 is merged, no open PR exists, and feature/native-engine-refactor-integration is 29 commits ahead/0 behind Main. Completed inspection of parameter/automation, MIDI, persistence/state migration, scheduler, project serialization, C API, Flutter bridge, relevant tests and CI. The active graph executor remains unintegrated; see engine-progress.md for the complete audit.
- 2026-11-02: M1 first code slice removes the graph compiler's former 1,024-node/8,192-connection caps and the executor's 8,192-frame cap, adds allocation-failure reporting, fixes node-source sentinel width and tests 8,195 nodes/8,194 edges/8,193 frames. Code commit 07c796f adds mandatory graph working-memory budgets, optional caller-supplied count ceilings, preflight compile/executor estimates and boundary tests. It passed Engine, App and Docs CI at checkpoint 1269019. Follow-up commit e815b495 adds direct compiler working-set rejection coverage; its CI is pending.
- 2026-11-02: Reliability audit found that Engine::send can drop install/pattern commands after a two-second queue timeout without returning failure; retirement can leak when its 1,024-entry queue and 256-item pending list fill; freeSlot exhaustion can skip a planned layer; and project-state exhaustion can leave a layer silent. These are tracked as M1 correctness work, not accepted limitations.

- 2026-11-02: Started from the verified 49ba277 planning checkpoint, preserving its approved engine blueprint and permanent roadmap. The current implementation branch contains the first graph compiler scaling changes and a durable milestone/recovery record; the exact verified status is maintained above and in engine-progress.md.

- 2026-11-02: Added adaptive concurrency and batching as foundational engine requirements, including dependency-aware scheduling, bounded worker pools, SIMD/accelerator selection, deterministic behavior, deadline-safe fallbacks and measurement of total overhead.


- 2026-11-02: Expanded the engine foundation requirements to target universal creative capability, typed audio/MIDI/control routing, first-class cross-domain sidechains, feedback networks, and resource-based rather than arbitrary architectural limits.

- 2026-11-02: Added safe extensibility requirements so developers can implement unconventional creative behavior through declared, bounded extension points without compromising core stability, real-time safety or project compatibility.

- 2026-11-02: Extended the native engine refactor plan with one unified parameter model for visible manual controls, conventional automation and hidden modulation; specified deterministic source combination, sample/block-rate evaluation, mathematical generators/effects, bounded expression execution and resource-aware fallbacks.

- 2026-11-02: Established docs/roadmap.md as the permanent canonical C.A.W. roadmap. Consolidated the long-term production direction into ordered stages, including audio/MIDI recording, monitoring and latency compensation, loop recording, take lanes/comping, plugin hosting, tempo maps, control surfaces, mastering tools, optional collaboration and surround/immersive audio. Explicitly excluded video synchronization for now. Converted the former two-part core plan into a compatibility pointer and the music workflow plan into a factual gap reference; aligned vision and UI scope notes.

- 2026-11-01: Repository-wide documentation accuracy pass: reconciled current app/engine facts, corrected piano-roll curves and generator status, separated shipped/partial/missing capabilities, updated synth and worker-pool references, and removed stale claims of AI, MIDI-device, audio-recording, plugin-host and platform support.

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

- 2026-11-02: The docs-only checkpoint 1370a43 triggered a delayed Windows build that remained in Build for over 15 minutes but eventually passed; all four Engine targets completed successfully in run 41402930328. The later full Engine matrix at 1269019 also passed.
- 2026-11-02: Removed the fixed nine-module/eight-effect chain ceiling from project parsing, synth patch parsing and Engine chain preparation. Added regression coverage for a 12-module parsed project chain and a nine-effect synth patch. Updated engine/synth documentation. Native CI for this new code checkpoint has not yet been observed; do not treat the earlier graph-budget CI as verification of these changes.

- 2026-11-02: Removed further content ceilings: project parsing now retains all modules and clips instead of stopping at 256/512; removed the 256 project-parameter automation binding cutoff; arrangement compilation no longer silently stops at 4096 notes; pattern parsing no longer has a 4096-note cap; MIDI import defaults to a caller-configurable note allowance. Added parser and late-arrangement-audio regression tests. Latest code/test checkpoint: 8f310708617e742a53cb00896a9715d41883d5cd. Fresh CI result is not yet inspectable through the current GitHub workflow-run reader.

- 2026-11-02: Removed fixed project-level parameter/global automation lane and point cutoffs; added regression coverage for 257 lanes with 129 points each. Layer volume/pan automation still uses fixed callback arrays and remains separate work.

- 2026-11-02: Layer volume/pan automation parsing now rejects lanes above the currently supported 128-point callback capacity rather than silently retaining only the first 128. Added a regression test for the explicit error. Dynamic callback storage/ownership remains future work; the parser no longer silently discards authored automation.

- 2026-11-02: Replaced fixed layer volume/pan automation arrays with immutable vector-backed AutomationData prepared on the control thread, adopted by the audio thread without allocation and retired for off-callback destruction. Removed the 128-point parser cap and added a 129-point end-to-end audio test. Engine::send now reports queue acceptance; project updates propagate failures and retain retryable layer state rather than treating dropped installs as active. Slot exhaustion and project-state overflow now surface as project errors. Latest code checkpoint: 787e9fed0a56607b102c988a15089fc714c7538f. Fresh CI remains uninspected.

- 2026-11-02: Removed the 32-parameter, 64-synth-parameter and 32-import ceilings. VM BlockCtx now borrows a dynamic parameter pointer table with an explicit count and per-voice sample offset; Engine prepares per-chain parameter buffers before playback. Import tables remain vector-backed and are no longer compiler-capped. Added tests for 40 parameters with runtime automation, 40 VM imports, and synth patches exposing more than 64 generated parameters. Latest code checkpoint: 8f43d76036cadcc3998eed6747a94d9e0c3f0480.

- 2026-11-02: Added hardware-derived EngineResourceBudget. Detected conservative memory is split into project-state (1/2), graph working (1/4), compile working (1/8) and retirement (1/8) shares; unknown memory uses a 128 MiB total fallback to preserve the existing 64 MiB project-state allowance. Engine default construction probes on the control thread, supports injected budgets, and enforces project-state in bytes. Added budget partition/fallback and low-memory project rejection tests. Latest code checkpoint: bba9bc1a8b47534ab11e51a1657807183e6a16a2 plus tests ebf009d and 4b3db68. Fresh CI is not yet inspectable.

- 2026-11-02: Added makeGraphResourceBudget(EngineResourceBudget) so graph compile/prepare policy can consume the hardware-derived graph-working share; added a conversion test. This does not mean GraphExecutor is integrated into Engine playback. Latest graph budget conversion test checkpoint: 3d99a652bddf3dfae3a1348b0471660eef912d08.

- 2026-11-02: Removed the fixed 4096-step pattern and MIDI-import limit; signed 32-bit step representation and existing file/event safety budgets remain. Replaced fixed 16-point note-expression curve arrays with dynamic vectors and prepared per-voice curve capacity off callback; hot-swap capacity is at least the prior chain's capacity to avoid callback allocations while copying held voices. Added 5000-step, 20-point curve and Engine playback regressions. Latest code/test checkpoint: 3d9bdf1cf18fbc823cd3b905728c11759ac75199. Fresh CI is not yet inspectable.

- 2026-11-02: Corrected pattern hot-swap command ordering: install the chain with its pre-reserved curve capacity before publishing a changed pattern. If the chain install is rejected, the old pattern remains active; this prevents an oversized new expression from reaching a chain whose voice vectors were prepared for fewer points. Latest code checkpoint: ff8b5a566e6ab2d8b3cb8282eeb520d857d2aa56.

- 2026-11-02: Removed the 16-export compiler/runtime cap. Each Engine now lazily allocates stable per-slot export buffers from the hardware-derived graph-working share; a fixed pointer table and heap-stable buffers keep import addresses valid across project updates. Export counts are checked before installation, failures are explicit, and inactive/muted export sources are zeroed without double-clearing active producers. Added 20-export compiler and end-to-end import routing tests plus a low-memory budget rejection test. Latest code/test checkpoint: 80e2664a5f9af2c3f6628ba94a0529ead4a42165. Fresh CI is not yet inspectable.
