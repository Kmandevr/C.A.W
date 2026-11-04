---
title: Decisions
summary: Dated record of what was chosen and why, newest first.
updated: 2026-11-04
---

# Decisions

## 2026-11-04: F6 parameter model: resolution order and owner choices

- **Owner choices (2026-11-04):**
  - A manual change while automation exists is a *touch*: the manual value wins until playback restarts, then the lane rules again.
  - Modulation depth is a fraction of the parameter's range on its curve (normalized 0..1), the same for every parameter.
  - A mapped MIDI CC sets the base like a knob, jumping straight to the controller's value. Soft takeover can come later.
  - Native SDK modules keep one value per block, the block's first frame, so the ABI does not change. Built-in and .caw modules get per-frame values when a parameter varies.
- **Resolution order (after an architect review).** Each frame resolves in this order:
  1. Base: automation, unless touched; otherwise the manual or MIDI value, smoothed linearly over `smoothingFrames` (at most 2^20) from the value last resolved, so touching during automation starts from what was playing.
  2. A link without a signal (disconnected, bypassed) is skipped. With no link carrying a signal, the base is only clamped and stepped, so plain values pass bit for bit, as on the Engine's automation path.
  3. Otherwise: normalize, apply the links in ascending link id (never graph or UI order), clamp to 0..1, denormalize, clamp and step.

  Links are `ModulationOp` Add, Multiply, Min, Max or Replace, each blended from the current value toward its target by depth (−1..1), at most 8 per parameter. A NaN or inf sample from a connected source reads 0. Exponential curves use `detLog`/`detExp` and their endpoints are exact. A block with nothing varying is one constant, which keeps stereo playback cheap.
- **Split:**
  - F6.1: resolver and descriptor fields (curve, step, smoothing, unit).
  - F6.2: values to processors through the executor.
  - F6.3: modulation links.
  - F6.4: automation lanes.
  - F6.5: MIDI CC mappings.
  - F6.6: the Engine's .caw params and globals move onto the resolver, with golden hashes unchanged.

## 2026-11-04: F5.2 event ports in the graph executor

- **Event format (owner).** A C.A.W event with a stable note id: `{frame, kind, flags, noteId, data[4]}` (28 bytes). `data` carries the raw MIDI 2.0 UMP words, so MIDI 1.0/2.0 convert at the edges without loss. Chosen over raw UMP alone, which cannot tell two overlapping notes of the same pitch apart. The executor never interprets kind, flags, note id or data.
- **Bounded per block.** Each event output and each merging input holds `GraphResourceBudget::maxEventsPerPort` events (default 1024, counted in the working-memory budget). A summing event input merges its sources by frame, ties in connection order, keeps the earliest events and counts the rest (`eventsDropped()`). A processor's output must be in frame order and in range or the block fails, so later nodes never misread it.
- **Host events** go to each node's first unconnected event input, like host audio; dynamic routing stays audio-only.

## 2026-11-04: F5.1 typed ports in the graph executor

- **Port semantics (after an architect review).** Modulation is one float per frame and may sum like a mix bus; control is one value per block, takes one source, reads its port default when unconnected and holds its last value, saturated after each block like routing (NaN reads 0) so a bad value never latches. Only a node's first audio input reads the host input; other audio inputs (sidechains) and modulation read silence when unconnected. No type is ever converted implicitly: a follower or converter is its own node.
- **Typed nodes are checked at prepare.** A processor with more than one audio port or any other port opts in with `usesProcessPorts()`; otherwise `prepare()` fails, so a correct-looking graph never fails on its first block. One-in/one-out audio nodes keep the old call (callgrind: playback +0.05–0.09%).
- **Parameters are not ports.** F6 decides how a port binds to a parameter (base value plus modulation); F5 does not settle it.

## 2026-11-04: F4.4, every track module is a graph node

- **Done now, with float edges (owner).** Asked whether to split tracks into module nodes now or with parallel effects (2.3), the owner chose now, with 32-bit float edges between modules (the F4.2 rule). Each module's output rounds to float, so 9 template and 8 mixer golden hashes were re-recorded. **[Fact, 2026-11-04]** The old engine with only that rounding added renders the new hashes bit for bit, including new effect-chain, seam, pattern and code-swap cases; 24-bit renders differ from before by at most 1 LSB.
- **A track has 32 module nodes.** The mix graph is prepared once, at Engine construction, so each slot gets a fixed set of module nodes; a longer chain is refused with a layer error, never cut short. F7 may replace the number with a budget.
- **Seams and code swaps run as lanes, not extra graph shapes.** Module edges carry three lanes (current chain, seam shadow, replaced chain), and chunks end at each playing track's loop restarts and swap points, so every node runs whole segments and the order of state hand-overs stays as before.

## 2026-11-03: Seeded randomness everywhere, per project and per module

- **Every random source is seeded (owner).** Any randomness in `.caw` modules, built-in nodes and native plugins comes from a seed, so the same project gives the same result every time. **[Fact, 2026-11-03]** `.caw` already works this way for `rand`, `randi`, `hash`, `noise` and pattern note probability, all from the single project seed; there is no per-module seed, and the native SDK (`caw_module_sdk.h` v1) passes plugins no seed and offers no random source.
- **Per-module seeds follow the project unless pinned (owner).** By default a module's seed is derived from the project seed with a per-module offset, so modules differ but all move when the project seed changes. A module can be pinned to its own seed, which then ignores project seed changes.
- **Seeding can be switched off per module or per project (owner).** Off means fresh randomness on each play or export.
- **[Proposal]** When seeding is off, the seed actually used is still recorded (shown and saved with each export), so a take you like can be pinned and reproduced; exports with seeding on stay bit-identical across platforms.
- **Open:** giving native plugins a seed needs a native SDK ABI change, which the owner approves when that step is built (roadmap F10).

## 2026-11-03: Reliability over old-engine compatibility

- **The old engine's sound and behavior carry no weight (owner).** The goal is the most reliable engine possible. There is no need to reproduce how the pre-Foundation engine sounded or worked, and no support for its quirks.
- **Golden hashes guard determinism and regressions, not the old sound.** Same source and settings must still give the same bits on every platform and every run. When an intended engine change alters output, the pull request re-records the hashes and states why, with a measurement; it does not need the owner's approval first. This replaces the earlier rule that every golden-hash change goes to the owner.
- **Unchanged:** exports bit-identical across platforms; a real-time-safe callback; tests never weakened; bug fixes start with a failing test; the owner is asked before native SDK ABI changes and new dependencies.

## 2026-11-03: Merging, and no project compatibility before Release 1

- **Claude may merge (owner).** Claude may merge its own pull requests, including the #28 engine branch into `Main`, when CI is green and nothing breaks. The no-merge rule is for the chat-agent (GPT) route. Flow: each Foundation item reaches `Main` once its CI is green. Until 2026-11-03 that went through `feature/native-engine-refactor-integration`; that branch merged fully into `Main` in PR #73 and was then deleted by the repository's delete-on-merge setting, so Foundation pull requests now target `Main` directly.
- **No backwards compatibility before Release 1 (owner).** The app hasn't shipped and the owner, its only user, has no projects to keep, so older project files need not keep opening. The project file format stays at version 2; real versioning starts at Release 1, once adding features no longer needs core rework. Roadmap F9 (migrations) moves to before Release 1 (R.7), and Foundation changes to the project model need no migration. Changes to the project file are still listed in each pull request.
- **F4 precision: float graph edges, golden hashes re-recorded once (owner).** The live mixer sums tracks, folder buses and the master in 64-bit `double`, while graph audio edges are 32-bit float. Measured on 2026-11-03: rounding each track's output to float where it enters a bus or the master changes 10 of the 12 golden hashes (rounding of about 1e-7, inaudible). The owner chose to keep float edges and re-record those hashes once, in F4.2, where the old mixer is changed to round at exactly the points the graph will. F4.3 (the graph runs playback) reproduces the F4.2 hashes bit-for-bit. Later golden-hash changes follow the 2026-11-03 "reliability over old-engine compatibility" entry above.

## 2026-11-03: Roadmap order, first release and per-item tables

- **Goal restated (owner):** C.A.W. is not trying to be a conventional DAW and needn't work like one, but it must be able to do everything a good DAW can do, because there is no good DAW for mobile. This replaces the older "lightweight DAW in a pinch, no full feature parity" wording in `architecture.md`. The goal is stated in [vision](vision.md).
- **Graph first.** The engine graph and N-channel core (issue #28) is the roadmap's new **Foundation** stage, before the remaining Stage 0 (SFZ, stems) and Stage 1 features, so they are built on the graph once rather than on the old mixer and then migrated. This replaces the same day's decision to pause graph integration until after Stage 1.
- **First release after Stage 7.** Release 1 (signed builds, onboarding/help, docs, licensing, distribution) comes after recording works, on Android and Windows; Stages 8–10 ship as updates. It was previously the last stage.
- **Gaps added to the roadmap:** app-wide undo/redo and crash recovery (Stage 1), project format versions and migration (Foundation, before the project model changes), audio output settings (Stage 5), and onboarding, help and a preset/template browser (Release 1).
- **Layout:** each stage is a table of items with status, where (engine/app), dependencies and what's missing, so progress and gaps are visible per item.

## 2026-11-03: Engine shape, formats and trust decisions to avoid later rework

- **One graph runs everything (eventual engine core).** Code (.caw) layers, synth voices, effects, folder buses, sends and master all become nodes of the one typed module graph. The current layer → effects → folder bus → master mixer is migrated into it, not kept as a parallel path. Timing: first, as the roadmap's Foundation stage (see the next entry).
- **Stage 0 SFZ means full import and mapping.** The first multisample version imports WAV samples (own or third-party), maps zones (key ranges, velocity layers) by hand, plays them in C.A.W and exports WAV + .sfz. This pulls the needed parts of roadmap Stage 3 (audio import) and Stage 4 (sampler zones, WAV/SFZ interchange) into Stage 0.
- **Exports are always bit-identical.** Offline renders and exports produce the same bits on every platform. Live preview may use faster maths (SIMD, threads, reduced quality) only when it is labelled as a preview mode; golden tests cover the export path.
- **Low-end target includes budget phones:** Galaxy A1x-class, 3–4 GB RAM, Android 10+. Voice counts, buffer sizes and benchmark budgets are set for that class.
- **Precision:** graph audio buffers are 32-bit float; 64-bit is used where accuracy needs it (phase/time accumulators, sensitive filter state). The .caw VM keeps its 64-bit JavaScript number semantics, which bytebeat compatibility requires.
- **Latency is adjustable:** a low-latency mode for playing live when timing matters, and a lighter, more stable mode (larger buffers, less CPU) when it doesn't. This is the workload-policy model in [engine-next](engine-next.md) §9.
- **Third-party native code: the user chooses per item.** Each external plugin (CLAP/VST3/AU) or third-party native module runs in one of three modes the user sets: **Isolated** (separate process), **Trusted** (in-process, no isolation, for code the user trusts) or **Blocked**. Shared .caw source stays sandboxed as before. The default mode for code not seen before is an open question in [vision](vision.md#open-owner-decisions).
- **Projects are folders that work like a repository.** A project folder holds the project file and its local assets; assets can also be linked from the global library. "Package build" collects every dependency into the folder so it works on its own. The format must stay compatible with a future **AutoStacc cloud library** (the owner's synced personal asset library). That sync is optional; core work never needs the network.
- **Audio clip timing is chosen per clip.** Clip positions are stored in musical time (beats). Each audio clip is either *musical* (follows tempo changes, time-stretched) or *fixed* (plays at original speed in seconds).
- **Graph is N-channel by design, stereo in practice.** Ports and buses carry a channel-layout field and are not hard-coded to two channels; only mono and stereo are implemented until surround (roadmap Stage 10).
- **Everything in the graph must be plugin-exportable.** Built-in graph nodes may not depend on the app or the OS, so any graph can become a CLAP/VST3 plugin (roadmap Stage 9).
- **Projects set their own render sample rate** (default 48 kHz; 44.1 and 96 kHz selectable). Live playback resamples to the device when they differ; exports always use the project rate.

## 2026-11-03: A separate test route for chat agents

- Owner: GPT works from a chat window with only a GitHub connector, can't run tests itself, and gets stuck re-reviewing when its context grows. It needs a way to run tests without opening pull requests or building the app, plus a workflow that survives a new chat.
- Chosen: `gpt/**` branches run only the Quick check (`.github/workflows/quick-check.yml`, `scripts/agent-run.js`). `run:` lines in the last commit message choose exactly which commands run (a filtered test, a sanitizer run, one build target, a render, ripgrep, Graphify, ctags lookups), so the agent tests what it needs while it builds, much like a terminal. With none, a default set runs (docs guard, Linux build and tests, examples, Dart checks when `app/` changed). Commands are a fixed list run without a shell. The same runner covers ChatGPT's own list of gaps (2026-11-03): git `diff`/`log`/`show`/`blame`; app interaction through widget tests, accessibility guidelines and published `screenshot` PNGs; a RUNNING notice and `INDEX.md` for job tracking; and an environment line in every report so a CI pass is never presented as a hardware result. It publishes a short report file per branch on the `agent-results` branch, because a file is what the connector reads reliably. **[Assumption]** It is not verified that the connector can read Actions logs or trigger `workflow_dispatch`, so the route needs neither.
- Full Engine, App and Docs CI is skipped on `gpt/**` pushes and runs on the pull request, which is still the merge gate. The report's write token sits in a separate job that never runs branch code.
- Start-of-chat context is generated, not remembered: `START.md` on `agent-results` bundles `AGENTS.md`, `CLAUDE.md`, `docs/vision.md` and every area rule, rebuilt from `Main` when any of them changes. A start prompt in the ChatGPT project's instructions (text in `AGENTS.md`) makes each chat fetch it first and confirm what it read, since ChatGPT has no hooks.
- The loop and stop rules live in `AGENTS.md` ("Chat-agent route"): a progress comment on the issue replaces chat memory, each file is reviewed at most once per chat, two failed fixes means stop and report, and a long chat hands off to a new one.

## 2026-11-03: Agent navigation tools are the default path

- Owner: Graphify and Serena (with the repo map) are how agents find and read code by default; plain Read, Grep and shell `cat`/`sed`/`grep` are for what those tools already named.
- Enforced by tooling rather than wording: the session-start hook prints the navigation order and how to load Serena's deferred tools, and Serena's `remind` hook now watches Bash and Serena calls as well as Read/Grep (`.claude/README.md`).

## 2026-11-02: Prepared project snapshots are the project-publication unit

- Build the complete project runtime on a control/worker thread as one owned prepared snapshot: module instances, VM chains, graph topology, routing, buffers, schedules, parameters, automation, event storage and a bounded state-migration plan.
- Publish one pending snapshot atomically and let the audio callback adopt it only at a block boundary. The callback must not allocate, lock, compile, wait for workers or call the UI.
- Keep the active snapshot alive while it is processed; retire superseded snapshots through preallocated/intrusive retirement records and reclaim them only on a control thread. Replacing an unconsumed pending snapshot must be safe and must not leak.
- Treat project replacement as a transaction. Do not send hundreds of independent layer-install commands that can partially apply when the fixed command queue fills. Keep any remaining live-control queue bounded, coalesced where appropriate, and report overflow to the caller.
- Prepare migration metadata off-thread. Apply only bounded, preallocated state-transfer work at safe block boundaries; if a migration cannot fit the configured real-time budget, defer activation or return an actionable error rather than blocking or silently resetting state.
- This is the target M1 architecture; it is a decision, not a claim that the current Engine already implements it. The current command queue can drop installs after its timeout, the retirement pending list can leak on overflow, and slot exhaustion can skip a layer.

## 2026-11-02: Reopen and complete native engine integration

- The owner explicitly authorizes the full native engine refactor and integration, superseding the earlier note that graph-to-Engine integration was paused.
- Start from the verified native-engine-foundation branch history, but integrate into the existing Engine/VM/mixer. Do not create a second engine or stop at interfaces and documentation.
- Keep the permanent engine blueprint, milestone ledger and recovery guide current; one coherent review PR is the delivery target.
- The graph compiler must not impose arbitrary node/connection/block caps. Resource limits must reflect actual memory, hardware and host safety budgets, with explicit errors and no silent content loss.


## 2026-11-02: Adaptive concurrency and batching

- Concurrency and batching are foundational capabilities, selected automatically according to graph dependencies, workload size, deadlines and available hardware.
- Parallelize independent work across graph branches, tracks, voices, channels and offline tasks where it yields a net benefit; batch compatible operations and use SIMD/accelerators when transfer and setup costs justify them.
- Avoid arbitrary thread counts and unconditional parallelism. Use bounded worker pools, adaptive task granularity, serial fast paths and controls against oversubscription.
- Preserve sample accuracy, deterministic semantics where required, audio deadlines and stable fallbacks. The audio callback must not block waiting for workers or accelerators.
- Optimize measured end-to-end performance, including scheduling, synchronization, memory movement, power and worst-case deadline margin—not just throughput or thread utilization.
- Full requirements: [Native engine refactor, Section 17](engine-next.md#17-adaptive-concurrency-batching-and-minimum-overhead-execution).

## 2026-11-02: Universal creative capability and routing

- The engine must make any technically realizable music/audio idea straightforward to create and combine; standard workflows are defaults, not creative limits.
- Use a universal typed multi-domain graph for audio, multichannel streams, sidechains, control/modulation, MIDI 1.0/2.0, notes, per-note expression, transport and timestamped events. Support cross-domain routing and explicit feedback/delay boundaries.
- Sidechain is first-class and can accept any compatible source, including audio, buses, tracks, external inputs, MIDI/events, envelopes and control signals. It must work across channels, processors and buses through the shared routing model.
- Avoid arbitrary fixed caps on project objects or graph complexity. Real constraints are available resources, platform/format requirements and explicit safety budgets. Surface unavoidable limits and never silently truncate.
- Make resource budgets configurable within host safety policy; enforce real-time bounded work, isolation, diagnostics, graceful bypass/recovery and clear failure reporting.
- Keep common workflows simple and fast while providing advanced extension interfaces for unusual processing, routing and execution models.
- Full requirements: [Native engine refactor, Section 16](engine-next.md#16-universal-creative-capability-safe-extensibility-and-unrestricted-composition).

## 2026-11-02: Safe extensibility for unconventional engine behavior

- The standard engine path is the efficient default, not a creative limitation. Developers must be able to build unusual generators, processors, effects, routing, modulation, synthesis and execution behaviors through explicit extension points.
- Provide composable standard interfaces and advanced interfaces where a generic abstraction would constrain a technique or add unnecessary overhead.
- Extensions declare capabilities, channel/event types, latency, resource needs, state and real-time requirements; validate and prepare them before activation.
- Protect the audio thread with bounded work, preallocated resources, defined failure/bypass/recovery behavior and clear isolation boundaries. In-process native extensions are trusted, not sandboxed; sandboxed VM modules remain constrained.
- Version extension APIs and state, preserve project compatibility through migration/capability negotiation, and isolate experimental interfaces from stable core contracts.
- Full requirements and verification are in [Native engine refactor](engine-next.md#16-safe-extensibility-and-deliberate-departures-from-standard-engine-behavior).

## 2026-11-02: Unified parameter, modulation and mathematical processing model

- Manual controls, project automation and internal/hidden modulation must use one shared parameter model across instruments, effects, tracks, buses, native modules and the .caw VM.
- Parameters may be exposed as simple user controls or remain internal; advanced modulation must not clutter ordinary workflows, and every exposed parameter should remain manually controllable.
- Support conventional automation, MIDI/controller input, macros, envelopes, LFOs, note expression, modulation links and sidechain/audio-following sources where available.
- Define explicit, deterministic source-combination, precedence, scaling, clamping and smoothing rules. Evaluate sample-accurately only where required; use block/control-rate processing where it preserves behavior and saves work.
- Mathematical expressions are first-class generators, waveform sources, modulation/control sources and audio effects, with bounded sandboxed execution and the existing .caw VM retained.
- Keep the cheapest correct path: constants stay constant, shared modulation is computed once where possible, and tables/precomputation are used only when worthwhile with a correct fallback.
- Detailed requirements and tests are in [Native engine refactor](engine-next.md#15-unified-parameters-modulation-automation-and-mathematical-modules).

## 2026-11-01: Native engine refactor and efficiency-first architecture

- The next major engine work is a refactor and integration of the existing CAW engine, not a ground-up rewrite or a parallel engine.
- Use proven professional audio-engine foundations and integrate the existing VM, synth, mixer, automation, renderer, typed module/graph and adaptive execution work into one coherent system.
- Avoid unnecessary work and complexity. Use the simplest correct implementation, and introduce additional processing only when requirements justify it.
- Prefer efficient mathematical/procedural DSP for suitable operations; use tables, wavetables, caches and precomputation when repeated work makes them worthwhile and memory permits. Keep the normal calculation path as a safe fallback.
- Detect and use compatible CPU, SIMD, GPU, memory, audio-device, connected-device, power and thermal capabilities when they provide a measured benefit. Keep portable implementations and safe fallbacks; optional hardware must never be required for project correctness.
- Evaluate existing permissively licensed/commercially usable libraries and proven algorithms before writing replacements. No GPL/AGPL, revenue-capped or commercial-only dependency without an explicit owner exception. Review exact versions and transitive licences and record every adopted dependency.
- Keep stereo as the efficient default while making the architecture capable of explicit mono and future multichannel processing.
- Preserve existing projects, modules, sound semantics, deterministic behavior, real-time callback invariants and live/offline render parity.
- The detailed technical plan is [Native engine refactor](engine-next.md). The canonical sequencing is [Roadmap](roadmap.md).

## 2026-11-02: Permanent roadmap and full production direction

- The C.A.W. roadmap is the permanent, canonical plan. It owns feature scope, sequencing, long-term capabilities, performance gates and explicit exclusions.
- Do not maintain competing master plans or separate feature-sequencing documents. Supporting notes may record factual implementation gaps or detailed technical designs, but the roadmap controls ordering.
- The long-term product direction includes the DAW capabilities discussed: non-destructive audio editing, sample authoring, complete mixer/routing, live MIDI and control surfaces, tempo maps, audio/MIDI recording, monitoring, latency compensation, punch/loop recording, takes/comping, plugin hosting, platform support, practical mastering tools, optional collaboration and surround/immersive audio.
- These capabilities are planned in dependency order, not claimed as implemented or all scheduled for immediate work.
- Video synchronization is not a current priority and is excluded from the roadmap unless the owner changes this decision.
- No in-app AI integration remains the current direction.

## 2026-11-01: No in-app AI integration in current scope

- Do not add AI generation, AI editing, source separation, model inference, cloud audio processing or AI-dependent sound features to C.A.W. for now.
- AI coding assistants may still be used externally as development tools; that does not authorize AI functionality in the shipped app or engine.
- Keep GitHub library synchronization/source picking separate and deferred; it is not implemented as an app workflow.

## 2026-10-31: Arrangement-first composition replaces the session grid

- **The old session grid is retired completely.** The Arranger is a horizontal song timeline with track lanes and reusable MIDI clip instances; no clip-launcher/session-grid alternate mode is retained.
- **Track ownership:** generators, effects and mix controls belong to tracks. Clips reference reusable pattern sources and own their start, length, source offset and loop behavior.
- **Folder routing:** nested folders can be organizational or stereo group buses. A bus sums child audio once and applies group volume/pan before routing to its parent or master.
- **Automation:** track volume and pan lanes follow song time and are interpolated in the native callback. Global and module-parameter automation remain future work.
- **Piano-roll multi-clip behavior:** selected companion clips are visible as read-only references; linked clips that share a source edit together. Editing multiple independent sources as one operation remains a follow-up.


## 2026-11-02: Graph compile and preparation require an explicit working-memory budget

- Graph compilation and prepared execution require a non-zero GraphResourceBudget.maxWorkingBytes; the API does not silently choose an arbitrary fixed node or connection cap.
- Optional maxNodes and maxConnections ceilings default to the representational maximum and may be set by host policy when a specific count ceiling is justified.
- Preflight estimates cover internal compiler temporaries and prepared executor buffers; caller-owned graph input and processor instances are excluded. The estimate is a preflight guard, not a replacement for handling allocator failure, which remains a distinct OutOfMemory result.
- The active Engine must eventually derive this budget from the hardware-aware EngineResourceBudget and pass it when preparing the graph. Until that integration exists, the graph API is budget-safe only when callers supply a realistic budget.
- This is implemented in code commit 07c796f8 and passed Engine, App and Docs CI at checkpoint 1269019. Follow-up commit e815b495 adds direct compiler-budget rejection coverage and awaits CI.

## 2026-11-02 — Effect-chain length is resource-governed, not a fixed product cap

Project layers and synth patches may describe dynamically sized module/effect chains. Parsing and engine preparation must preserve every authored chain element; no silent truncation or arbitrary eight-effect ceiling is allowed. Memory and processing costs are handled by explicit host resource budgets and clear preparation errors. This change does not remove unrelated limits such as the current project layer-slot model or export-buffer capacity; those remain separate integration work.
