---
title: Visual creation and signal routing
summary: Design for the two visual workspaces, typed project routing and conditional workflows, plus evaluated DSP and engine reuse candidates.
updated: 2026-11-09
---

# Visual creation and signal routing

**Status: [Proposal]** This note expands the canonical [roadmap](roadmap.md) and the [C++ creation platform](cpp-creation-platform.md). It records owner-approved product direction and technical proposals; it does not describe shipped editors or a complete routing runtime.

## 1. Keep song-making familiar; add visual workspaces

The normal song-making workflow remains the arrangement, piano roll, clips, recording, conventional mixer controls and export. Visual routing is an additional way to understand and manipulate the project, not a replacement for arranging or editing notes.

C.A.W. has two visual workspaces built on one reusable visual framework:

1. **Component workspace — build a thing.** An ordinary, always-visible workspace for everyone (owner, 2026-11-09). Create instruments, effects, generators, processors and reusable operations. A component can be authored in ordinary C++, in Faust for specialist DSP, or assembled visually from typed operations and existing components. Its DSP behavior can be edited visually; its source remains available where applicable. Parameter metadata generates a useful control surface by default, with optional custom/hybrid UI design.
2. **Project/track workspace — make the song behave.** Inspect and edit a selected track's parameters, input/output, sends and destinations, buses, sidechains, channel mapping, effect-chain order and conditional behaviors together. It opens two ways (owner, 2026-11-09): a slide-up panel for the selected track over the arrangement, and a full page for the whole project. Conventional mixer controls remain available.

The shared framework supplies canvas navigation, touch/desktop gestures, nodes, ports, connection drawing, grouping, selection, parameter inspectors, undo/redo and accessible controls. The workspaces do not share one undifferentiated graph model: each graph has its own domain rules and persistence.

## 2. Three related graph domains

Keep these models distinct and connect them through explicit contracts:

- **Component/DSP graph:** describes how one instrument, effect, generator or reusable processor transforms audio, events, control and modulation. Visual DSP graphs compile/prepare into the same native execution system as C++ components; there is no separate interpreted DSP engine.
- **Project/routing graph:** describes tracks, instruments, effects, buses, sends/returns, sidechains, hardware endpoints, channel maps and project-level signal flow. It belongs to the project and engine routing model, not to an individual effect's internal DSP graph.
- **Condition/workflow graph:** describes event sources, predicates, state, branches, conversions and actions. It can affect project routes and component parameters through declared, typed endpoints. It must not become a general-purpose unbounded script running on the audio callback.

All three use the shared descriptor/port/parameter/event contracts where relevant. A component may expose audio, MIDI/event, control, modulation, analysis and logic endpoints; the project graph decides how instances connect, and the condition graph decides when or how permitted connections/actions are activated.

## 3. Typed routing and explicit conversion

The project routing model should support:

| Domain | Examples |
|---|---|
| Audio | Mono, stereo, arbitrary N-channel, surround/discrete layouts |
| MIDI/events | Note on/off, velocity, pitch, pressure, per-note expression, CC, program and timestamped events |
| Control | Parameter values, macros, scalar/structured control signals |
| Modulation | LFOs, envelopes, followers, modulation sources and destinations |
| Analysis | Peak, RMS, envelope, onset or other declared measurements |
| Logic/state | Boolean conditions, comparisons, track/clip/transport state, triggers |

Connections are typed and validated before activation. No silent type coercion, channel collapse, loss of note identity or implicit rate conversion. Provide explicit conversion/adapter nodes, for example:

- audio → peak/RMS/envelope follower;
- MIDI velocity or pitch → normalized control/frequency;
- MIDI event → trigger/gate;
- control value → parameter or MIDI CC;
- envelope → modulation;
- multichannel audio → named channel split/map/merge;
- event count/timing → control or trigger.

Each conversion declares units, update rate, latency, channel behavior, allocation and real-time requirements. Visual styling distinguishes connection domains without relying on color alone.

## 4. Conditional routing and workflows

A rule is composed from **source/event → optional condition(s) → branch(es) → action(s)**. Support both event-triggered rules and conditions that are continuously evaluated at a declared rate.

Potential sources include:

- MIDI notes/controllers/expressions arriving on a named track or component;
- audio measurements such as peak, RMS or envelope crossing a threshold;
- parameter or modulation values;
- track state such as mute, solo, armed, highlighted/selected or enabled;
- clip, region, note and arrangement-section enter/exit events;
- transport, beat/bar, timer and project-state events;
- sends, sidechain activity and component-declared custom events.

Predicates and combinators include comparisons/ranges, AND/OR/NOT, rising/falling edges, duration, count, probability, priority and explicit state/latch/reset behavior. Hysteresis, debounce, minimum hold time and retrigger limits prevent threshold chatter and accidental repeated triggers.

Actions may adjust a parameter, enable/bypass a preloaded path, change a send level or route, select a destination, trigger a component/sample, emit MIDI/control events, start/stop a permitted sequence, or invoke another bounded workflow. Cross-track actions require explicit target references and visible routing; no hidden global side effects.

**First target (owner, 2026-11-09):** the kick-to-bass duck below, built after sends, sidechains and parallel paths.

Examples:

- If a MIDI note/event arrives on the kick track, trigger a ducking envelope on the bass track.
- If a track's RMS exceeds a threshold, blend in a preloaded distortion path.
- If playback enters a region or clip, activate a parallel effect path only for that region, without drawing a traditional automation lane.
- If a particular note/velocity is played, trigger another instrument or alter a parameter.
- If a track is highlighted, temporarily route it to an audition/monitor path. This is UI state, not a musical event: it only changes what is heard while working and never changes an export (owner, 2026-11-09).
- If a clip ends, switch to a declared next route or trigger a bounded action.

Regional behavior can be attached to clips, time selections, arrangement sections, notes or track contexts. Effects and alternate routes are prepared before activation; no plugin loading, graph compilation, memory allocation or destruction occurs in the audio callback.

## 5. Scheduling, safety and deterministic behavior

The engine must distinguish:
- **Audio-rate work:** sample processing in the audio graph.
- **Block/control-rate work:** bounded parameter and analysis updates at a declared rate.
- **Timestamped event work:** MIDI, note and transport events ordered at sample/frame positions.
- **Non-real-time work:** graph construction, validation, resource loading, compilation, UI interaction, persistence and diagnostics.

Rules are compiled/validated and their resources prepared off the callback. Runtime execution uses bounded queues, fixed/preallocated state and explicit scheduling budgets. Define safe semantics for delayed feedback and stateful cycles; reject accidental zero-delay cycles and prevent unbounded recursive rule triggering. Live playback and offline rendering use the same rule semantics and deterministic ordering. Expose rule activity/trace diagnostics without logging or UI calls from the callback.

Preserve per-note, per-voice and per-channel identity and arbitrary channel layouts through compatible routes. Conversions or deliberate merges must declare what identity/layout information they consume or discard. Keep small-project overhead near zero by activating only the sources, analysis and rules actually used.

## 6. Faust, C++ and visual DSP

C++ remains C.A.W.'s primary general-purpose programming language and the native component ABI/runtime target. Faust is an optional specialist DSP authoring language/backend, not a replacement for C++ and not a second mandatory runtime.

**Timing (owner, 2026-11-09):** Faust work starts only after on-device C++ building works. **Preferred first integration experiment:** compile Faust source to generated C++ and feed it through the existing local/offline C++ component build pipeline. Adapt generated DSP to the C.A.W. component contract (ports, parameters/UI metadata, lifecycle, process buffers, state and declared capabilities). This reuses the C.A.W. native engine and avoids requiring LLVM JIT in every app installation.

A later optional embedded-libfaust/JIT path may improve rapid auditioning, but only after measuring binary/package size, startup, memory, compile latency, CPU, Android compatibility and trust boundaries. The engine—not Faust's optional parallel scheduler—owns real-time scheduling. Validate channel layout, in-place/buffer semantics, polyphony, MIDI/per-note expression, event timing and live/offline parity before claiming complete integration.

Faust compiler and generated-code licensing are separate questions. The compiler is LGPL-2.1-or-later; generated code's obligations depend on source, libraries and architecture files used. Audit the exact version, standard library and architecture files included in each distribution. Record notices/source obligations and confirm compatibility with C.A.W.'s chosen source and distribution licences before bundling. See [Faust](https://github.com/grame-cncm/faust), [documentation](https://faustdoc.grame.fr/) and its [licensing FAQ](https://faustdoc.grame.fr/manual/faq/).

## 7. Existing projects and reuse policy

Evaluate existing open-source technology at every scale, from algorithms and libraries to complete subsystems or applications. Prefer reuse/adaptation when it offers better capability, quality, performance, platform coverage or delivery speed than rebuilding, provided workflow fit, integration cost, maintenance, resource use and licence obligations are acceptable. Do not adopt an entire application blindly or let it dictate C.A.W.'s project model and interaction.

| Candidate | Intended role in C.A.W. | Decision / next evaluation |
|---|---|---|
| Faust | Optional DSP authoring/compiler; generated native C++ components first, embedded JIT later if justified | Strong candidate. Prototype generated-C++ adapter and audit exact compiler, library and architecture-file licences. Keep C++ first-class. |
| Pure Data / libpd | Optional compatibility/runtime for existing Pd patches and experiments | Prototype only. Not the primary engine or required workflow. Benchmark 64-frame tick adaptation, latency, CPU/RAM on weak Android, multi-instance behavior, external objects and real-time safety against equivalent native C++ components. Keep patches/components optional and clearly bounded. |
| Tracktion Engine | Engineering reference only | Study graph scheduling, plugin delay compensation, lock-free recording/file access, arrangement, automation, MIDI and background rendering. GPL-3.0-or-later and depends on JUCE, so no code is taken (permissive licence, owner 2026-11-09). |
| JUCE | Reference only | JUCE 9 is AGPLv3/commercial, so it is not used. |
| LMMS | Readable source-code and implementation reference | Reference only; not a dependency or foundation. |
| VCV Rack | Inspiration for modular interaction and patch readability | Inspiration only; do not copy its rack-specific workflow as C.A.W.'s overall song-making model. |
| Existing C.A.W. engine, .caw built-ins and code | Reusable algorithms, DSP, MIDI, parameter, graph and synthesis behavior | Audit and migrate useful capabilities into the C++ Library/SDK; preserve behavior where valuable, not the legacy language or architecture. Verify each retained path with tests and audio comparisons. |

The owner's current direction is that C.A.W. itself is free/open source, with optional support/donation bundles of prebuilt FX, instruments, presets, samples and sounds. Core functionality is not paywalled. C.A.W. is Apache-2.0 and uses permissive dependencies only (owner, 2026-11-09). No paid dependency or commercial licence may be assumed. A candidate with obligations that C.A.W. cannot meet is rejected or used only as a reference.

## 8. Relationship to the canonical roadmap

The [roadmap](roadmap.md) owns sequencing and status. This note supplies design detail for:
- CP.1–CP.5: local C++ toolchain, shared component contract, Library and migration of existing code;
- Foundation F1–F6: prepared typed graph, N-channel audio, events, parameters and modulation;
- UI.1–UI.7: code authoring, component visual composition, generated/custom UI and MIDI;
- Stage 2: sends, returns, sidechains, parallel paths, track/bus/master routing and the project visual workspace;
- Stages 5–7 and 9: live MIDI/events, arrangement/recording and plugin/standalone adapters.

Implementation issues remain separate and narrowly scoped. Do not create a competing sequence here. Update implementation status only after code, tests and CI establish the behavior.
