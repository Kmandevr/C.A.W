---
title: Decisions
summary: Dated record of what was chosen and why, newest first.
updated: 2026-11-03
---

# Decisions

## 2026-11-03: Engine shape, formats and trust decisions to avoid later rework

- **One graph runs everything (eventual engine core).** Code (.caw) layers, synth voices, effects, folder buses, sends and master all become nodes of the one typed module graph. The current layer → effects → folder bus → master mixer is migrated into it, not kept as a parallel path. Graph integration stays paused until the owner resumes it; this fixes the target, not the timing.
- **Stage 0 SFZ means full import and mapping.** The first multisample version imports WAV samples (own or third-party), maps zones (key ranges, velocity layers) by hand, plays them in C.A.W and exports WAV + .sfz. This pulls the needed parts of roadmap Stage 3 (audio import) and Stage 4 (sampler zones, WAV/SFZ interchange) into Stage 0.
- **Exports are always bit-identical.** Offline renders and exports produce the same bits on every platform. Live preview may use faster maths (SIMD, threads, reduced quality) only when it is labelled as a preview mode; golden tests cover the export path.
- **Graph integration resumes before roadmap Stage 2.** Finish Stage 0 and Stage 1 on the current engine, then move the mixer into the graph and build sends, sidechain, parallel paths and the master chain there once.
- **Low-end target includes budget phones:** Galaxy A1x-class, 3–4 GB RAM, Android 10+. Voice counts, buffer sizes and benchmark budgets are set for that class.
- **Precision:** graph audio buffers are 32-bit float; 64-bit is used where accuracy needs it (phase/time accumulators, sensitive filter state). The .caw VM keeps its 64-bit JavaScript number semantics, which bytebeat compatibility requires.
- **Latency is adjustable:** a low-latency mode for playing live when timing matters, and a lighter, more stable mode (larger buffers, less CPU) when it doesn't. This is the workload-policy model in [engine-next](engine-next.md) §9.
- **Third-party native code: the user chooses per item.** Each external plugin (CLAP/VST3/AU) or third-party native module runs in one of three modes the user sets: **Isolated** (separate process), **Trusted** (in-process, no isolation, for code the user trusts) or **Blocked**. Shared .caw source stays sandboxed as before. The default mode for code not seen before is an open question in [vision](vision.md#open-owner-decisions).
- **Projects are folders that work like a repository.** A project folder holds the project file and its local assets; assets can also be linked from the global library. "Package build" collects every dependency into the folder so it works on its own. The format must stay compatible with a future **AutoStacc cloud library** (the owner's synced personal asset library). That sync is optional; core work never needs the network.
- **Audio clip timing is chosen per clip.** Clip positions are stored in musical time (beats). Each audio clip is either *musical* (follows tempo changes, time-stretched) or *fixed* (plays at original speed in seconds).
- **Graph is N-channel by design, stereo in practice.** Ports and buses carry a channel-layout field and are not hard-coded to two channels; only mono and stereo are implemented until surround (roadmap Stage 10).
- **Everything in the graph must be plugin-exportable.** Built-in graph nodes may not depend on the app or the OS, so any graph can become a CLAP/VST3 plugin (roadmap Stage 9).
- **Projects set their own render sample rate** (default 48 kHz; 44.1 and 96 kHz selectable). Live playback resamples to the device when they differ; exports always use the project rate.

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
