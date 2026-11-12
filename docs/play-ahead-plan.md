---
title: Play-ahead and run-anywhere plan (1.2.0)
summary: The owner's 2026-11-12 direction for release 1.2.0: render untouched tracks ahead on workers and switch to real time silently, a hardware ladder down to a calculator stunt, the optimisations that go with it, measurements and open questions; planned, not built.
updated: 2026-11-12
---

# Play-ahead and run-anywhere plan (1.2.0)

**[Proposal]** Nothing in this note is built. Tracked in issue #191. The owner's direction is fact; the design, estimates and order are Claude's proposals, to be confirmed by the owner where marked. What gets built is recorded in the notes that own each area, not here.

## The owner's direction (2026-11-12)

- **Dynamic play-ahead:** render things ahead of time and in batches where it makes sense. It must be completely invisible: when the user starts to use something that needs low latency, that part switches to real time "quickly and silently so no one ever notices".
- **Run anywhere:** the app changes according to the hardware and then runs, so nothing beats C.A.W. The publicity target is a hacked graphing calculator: "it's a stunt, if it works it's fine".
- **Release:** 1.2.0, after the open alpha (1.0.0-alpha.1, [beta readiness plan](beta-readiness-plan.md)).
- **Unchanged rules it must keep:** a real-time-safe callback (`.claude/rules/engine.md`); output perceptually identical between live playback and export ([decisions](decisions.md), 2026-11-12 "Perceptually identical"); no shared buses, REAPER-style routing ([decisions](decisions.md), 2026-11-12); no audible change without asking the owner; every speed claim measured.

## What it builds on (facts, checked in the code 2026-11-12)

- **One mix graph for live and offline** (`GraphExecutor`, [engine status](engine-build-status.md)): an export runs the same Engine on a worker, faster than real time ([how it works](how-it-works.md)).
- **A bounded worker pool** (`engine/src/scheduler.*`, up to 16 workers, priorities, cancellation) that already runs project compiles, source checks and offline renders, sized by a workload plan (`engine/src/execution.h`: `WorkloadClass` InteractiveAudition, InteractivePreview, BackgroundGeneration, OfflineRender, Idle; `DevicePressure` from battery saver to thermal critical; `ExecutionPlan::preferredBatchFrames`, 256 by default).
- **A hardware probe and memory budget** (`engine/src/hardware.*`, `makeEngineResourceBudget`, `maxLayers()` from the graph-working budget).
- **Sound quality** Eco, Normal, High (`engine/src/quality.h`, the app's `SoundQuality`): Eco spends less on oversampling (Flagship's warps at 1×, unison capped at 4). An export's own engine builds at Normal (`buildingQuality()`).
- **Components that sleep:** a component that says it is `quiet()` is skipped until its input or notes wake it (`ComponentChain`, `engine/src/component_chain.cpp`); only components that declare it, so sleep never depends on the buffer size.
- **Crossfade paths** for code swaps (lane 2) and loop seams (lane 1) on every track's graph edges.
- **The app reads meters by the time they are heard** (`meterAt(us)`, `audibleMeters`) for latency compensation ([app](app.md)), and Buffer mode Auto already switches to the small buffer while recording.
- **The live CPU meter** times the whole device callback against its length (`Engine::reportLoad`, [performance](performance.md), "The CPU meter"); the S22+ renders in 1024-frame device buffers.
- **Performance profiles** (Full, Balanced, Lightweight, Minimal; Lightweight on overload): Lightweight and Minimal reduce the voice budget to 4 per pattern layer ([performance](performance.md)).
- **Component state** in the SDK (`saveState`/`loadState`, `maxStateBytes` in `engine/include/caw/module.hpp`) is the *settings* state. There is no call that copies a component's running DSP state (filter memories, delay lines, voices).

## 1. Play-ahead engine

### 1.1 Which parts run live

Each chunk the Engine splits the routing into two sets:

- **Live set:** every track with a live source, and everything downstream of it. Live sources: record-armed or monitored tracks, a track being played from MIDI or the on-screen keys, audio input, the audition, and any track a user is *about to change* (1.4). Downstream: the folder that receives it, up to the root; a track that reads its exports or its sidechain.
- **Ahead set:** everything else. The **master node always runs live**: its limiter and stop fade act on the whole mix, and it is cheap.

A track in the ahead set that reads exports from a live track joins the live set (the upstream closure), so no ahead render ever waits for live data.

### 1.2 Rendering ahead

- Each ahead track (or folder subtree) is rendered by a pool worker into its own single-producer, single-consumer ring of stereo float audio, plus its meter values and the transport position each block belongs to. The audio callback reads the rings, mixes them with the live set's output into the master and never waits: a ring that is not filled in time is an **underrun of that track**, handled in 1.6.
- Workers render in **large batches** (proposal: 2,048–8,192 frames), not device buffers, and at no deadline tighter than the ring's depth. Batches are also where voice-level parallelism becomes safe (section 3, item 8).
- **Depth adapts** (proposal): deep (500 ms–2 s) when nothing is touched, shallow (50–100 ms) while the user is near a control (a device page or the code editor open), so a switch (1.5) drains quickly.
- The ahead render runs at the live Sound quality, so a track sounds the same in both sets.
- New work class: `WorkloadClass::PlayAhead` (proposal), between the interactive and background classes, so a compile still comes first and an export can't starve playback.

### 1.3 Meters and the UI

Ahead-rendered meters are timestamped with their transport position and land in the same timeline the app already reads by heard time (`meterAt`), so meters, scopes and the playhead stay in step without app changes beyond the source. Waveform peaks of ahead-rendered tracks can be produced by the workers for free (section 3, item 10).

### 1.4 When to switch to live: intent

The switch is triggered by the first sign of intent, before any value changes (proposal; the list is for the owner to confirm):

- a finger or mouse down on a track's control, a device page or the C++ editor opened for that track
- a key press or MIDI note aimed at a track; record-arm; input monitoring on
- automation being written

A track returns to the ahead set after a few seconds without intent (proposal: 3 s).

### 1.5 How to switch without a sound

Two handover modes, chosen per component:

- **Drain (always works):** stop refilling the track's ring; when the playhead reaches the end of what was rendered, the audio thread takes the same component instances and continues from their state. Nothing is re-rendered, so there is no discontinuity at all. The switch takes as long as the ring's depth, which is why depth shrinks near controls (1.2). Intent arrives before a value changes, so a shallow ring hides it. **[Assumption]** The gap between a touch landing and the first value change is long enough at 50–100 ms; to measure.
- **Snapshot (instant):** components that support a new SDK call that copies their running state (proposal: `snapshotRuntime`/`restoreRuntime`, bounded by a declared size, never allocating on the audio thread) are snapshotted at each batch boundary into a small ring; a switch restores the snapshot at the playhead and the live instance continues from there. Built-ins can support it; third-party components that don't use Drain. A reverb's state can be several MB, so on low-memory tiers Drain is used.

**Code swaps** need neither: compiling already takes longer than a shallow ring, so the swap is planned at the end of the rendered audio and goes through the existing crossfade.

### 1.6 Transport, edits and failure

- **Seek, loop, tempo or project changes** drop the affected rings. While stopped, the first half-second from the cursor is kept rendered (section 3, item 1), so Play still starts at once.
- **An ahead track's underrun** (the worker fell behind): the callback renders that track live for the rest of the chunk using the Drain handover, and the scheduler lowers the depth or moves it to live; it never plays silence. If the live set itself overloads, the existing overload handling applies.
- **An edit to an ahead track** (a value from the app, an automation change) arrives as a command; its ring is cut at the command's time and re-rendered from there by Snapshot, or the command waits for the ring's end by Drain. **[Open question]** whether a change that lands up to the ring's depth late is acceptable for edits that come without intent (for example an automation lane edited while another track is touched).

### 1.7 The CPU meter

With play-ahead the device callback mostly mixes rings, so the current meter would fall to a few percent while the same work runs on the workers. Proposal: show **live load** (the callback, as now) and **ahead load** (worker time per second of audio rendered, against the cores the plan allows) side by side, and base Lightweight-on-overload on ahead underruns as well as the live meter. **[Open question]** how the meter should look (UI: ask first).

## 2. Run anywhere: the hardware ladder

The same project opens everywhere; the hardware decides how much is live, how deep the rings are and which Sound quality preview uses. Proposal:

| Tier | Example | Live | Ahead | Preview quality | Export |
|---|---|---|---|---|---|
| Desktop and flagship | S22+, Windows PC | Most tracks where it helps | Big projects, for headroom | High or Normal | Normal or High, unchanged |
| Mid and low-end phone | 4–8 little cores, 3–4 GB | What is touched or played | Everything else | Normal; Eco for heavy patches on overload | Unchanged |
| Very weak device | old phone, small board | One track | The rest | Eco | Unchanged, slower |
| Calculator (stunt) | section 4 | One simple voice | The whole song, before Play | Its own reduced engine | Not offered |

- **Exports never change** ([lightweight creative audio systems](lightweight-creative-audio-systems.md): "never silently change the sound of a saved/offline export to save CPU"). An export always runs at its own quality, as today.
- **Choosing the tier** uses the existing probe and plan (cores, memory budget, `DevicePressure`) plus a short measured calibration on first run (proposal: render a fixed project offline for one second and time it), so a tier never relies on the device's name.
- **The voice budget:** with play-ahead, Lightweight's 4-voice cap might be lifted for ahead tracks, so weak phones play the full sound. That changes how songs sound on those phones, so it is the owner's choice (open question).
- **"Invisible" has a floor:** on very weak hardware the wait for a ring to fill becomes visible. The app should show what is ready; how it looks is a UI question for the owner.

## 3. Optimisations that go with it

Ranked by expected gain for the effort. Each needs its own before/after measurement.

1. **Pre-roll while stopped.** Keep the first 0.5 s from the cursor rendered while the transport is stopped and settled. Fixes the first callback after Play (A3, 2–8× the mean, [engine performance](engine-performance.md)) and makes Play instant on every tier.
2. **Batches sized for the cache, not the device.** Render ahead in batches the workload plan picks per device (`preferredBatchFrames`), so per-block overhead (planning, routing, parameter resolution) is paid far less often than at 192–1024-frame callbacks. **[Assumption]** 5–15% on top; to measure.
3. **Sleeping tracks cost nothing.** When every component of an ahead track is asleep (`quiet()`), the worker writes a "silent span" marker instead of audio, and the mixer skips it. Same rule as today (only components that declare it), so it never depends on the batch size.
4. **Automatic freeze of passes that repeat.** If a track's pass over a loop has no free-running state (no unsynced LFO, no unseeded random, tails settled), the next pass is the same sound and can be replayed from the cache. Proof is per component (a declared "loop-stable" flag, proposal); otherwise the track is simply rendered ahead. Roadmap item 1.2 **Freeze** becomes the saved, user-chosen form of the same cache: a frozen track is a stored ring that survives restarts. Memory: stereo float at 48 kHz is about 384 KB per second per track.
5. **Exports reuse the cache.** When nothing changed and the ahead render ran at the export's quality, the export, stems and the music video's song render ([decisions](decisions.md), music video) can take the cached audio instead of rendering again. Allowed by the 2026-11-12 "perceptually identical" decision; still checked by a tolerance test.
6. **Pressure-aware depth and tier.** Battery saver and thermal states (`DevicePressure`) deepen the rings and lower the worker count, so the phone renders in fewer, longer bursts and can sleep between them. **[Assumption]** bursts save battery (race to idle); to measure, not to claim.
7. **A smaller buffer for the live set.** The callback only renders the live set and the master, so Buffer mode Auto can choose a smaller device buffer whenever someone plays live, not only while recording. **[Assumption]** the S22+ could go from 1024 to about 256 frames; depends on the device's audio path.
8. **Heavy tracks split across workers.** Without a deadline, one heavy track (Flagship, 64 voices) can split its voices across workers and sum them in a fixed order (allowed by the 2026-11-12 decision). This helps the one case the parallel mixer can't (A2).
9. **Compact cache on low memory.** On the lowest tiers, preview rings could hold 16-bit or half-float audio. That is below the reference tests' −120 dBFS null, so it would be a preview-only, labelled choice for the owner; exports never read it.
10. **UI data from the workers.** Waveform peaks and meter values of ahead tracks are computed where the audio is rendered, so the UI thread does less on weak phones.

Not proposed: shared reverb buses or similar routing tricks (dropped by the owner, 2026-11-12).

## 4. The calculator stunt

**[Proposal]** A separate, small renderer, not the app: the Flutter app can't run there, and the engine as built needs threads, megabytes of memory, floats and an audio device. C.A.W's language is C++ since 2026-11-11, so the calculator can't run a user's own C++ components unless they are cross-compiled for it; the stunt plays a project made from a few built-ins (proposal: one synth voice, drums, a delay) with reduced versions written for it.

- **Shape:** reads the same project file (a subset: tracks, patterns, those built-ins), mono, about 8–11 kHz, 8-bit or 1-bit output, no allocation while playing, a text screen.
- **Play-ahead is the whole idea there:** render the song into memory while the screen shows it, then play it back from memory, with at most one live voice on the keys. 8 kHz 8-bit mono is 8 KB per second, so 3 minutes is about 1.4 MB.
- **Which calculator** decides between a small live engine and an offline renderer (open question). Hardware, sound output, how native code runs and the toolchains' licences: see [Calculator facts](#calculator-facts).
- **Licences come first:** C.A.W bans GPL/AGPL dependencies; the calculator's SDK, firmware and any runtime library linked into the program must be checked before anything is built, and recorded in [decisions](decisions.md).

### Calculator facts

To be filled from primary sources (research in progress, 2026-11-12).

## 5. Expected gains

**[Assumption]** Estimates from the engine's structure, not measurements; the Benchmark (beta plan C) turns them into facts.

| Case | S22+ | Low-end phone |
|---|---|---|
| Dense song, playback | 2–4× more tracks before dropouts; dropouts mostly gone | 2–6× |
| One heavy track | 1.3–2× | 1.5–2.5× |
| Playing live | lower latency (smaller buffer), not more speed | far fewer dropouts |
| Repeating loops | close to free after the first pass, where provable | same, and the only cut in total work |
| Total work, heat | about the same; slightly more for snapshots and re-renders | heat remains the ceiling |

Where the gain comes from: workers on several cores instead of one, budgeting for the average instead of the worst block, and longer bursts that **[Assumption]** let the scheduler raise the clock. A1 (the audio thread's platform hint) may close much of the S22+'s gap by itself; measure A1 first, then play-ahead on top.

## 6. Measuring it

- **Bench:** a play-ahead scenario in `caw_bench` (ahead load, live load, underruns, memory) beside the current ones, recorded in [engine performance](engine-performance.md).
- **Stress test** (beta plan C): the maximum tracks before a dropout, with and without play-ahead, on the S22+ and Windows.
- **Low-end on the S22+:** a test build that pins the engine's threads to the little cores and caps their clock, to estimate the low-end tier before a real cheap phone confirms it.
- **Invisible switch:** a test that touches a control on an ahead track mid-note and checks the output against an all-live render within the reference tolerance, for Drain and Snapshot, at several depths and buffer sizes; real-time safety tests (no allocation, no lock) through every switch.
- **Reviews:** architect before the build (it changes the engine's structure), audio-reviewer after each engine change.

## 7. Order (proposal)

1. After 1.0.0-alpha.1: A1 and the parallel mixer (phase 5) merge and are measured; A3's pre-roll (section 3, item 1) can land early, alone.
2. Play-ahead core: the split (1.1), rings and workers (1.2), Drain (1.5), meters (1.3), the two-part CPU meter (1.7, after the owner picks its look).
3. Intent signals from the app (1.4) and adaptive depth.
4. Snapshot handover for built-ins; sleeping-track spans, bigger batches, pressure-aware depth and the smaller live buffer (section 3, items 2, 3, 6, 7).
5. Tiers and calibration (section 2); voice budget and compact cache if the owner agrees.
6. Automatic freeze and user Freeze, export reuse and voice splitting (section 3, items 4, 5, 8).
7. The calculator renderer (section 4), once the owner picks the calculator; it can run in parallel with 4–6, as it shares no code paths with the app.

## Open questions for the owner

Also in the [vision register](vision.md#open-owner-decisions).

1. Which calculator for the stunt.
2. What counts as intent (1.4), and whether an edit without intent may be heard up to the ring's depth late.
3. Whether ahead tracks on weak phones may keep their full voices (lifting Lightweight's cap), which changes how songs sound there.
4. Whether a 16-bit preview cache on the lowest tier is acceptable (preview only).
5. The look of the two-part CPU meter and of "what's ready to play" on weak hardware.
6. Whether Freeze stays a user action, becomes automatic, or both.
