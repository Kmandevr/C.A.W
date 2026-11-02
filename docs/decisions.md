---
title: Decisions
summary: Dated record of what was chosen and why, newest first.
updated: 2026-11-01
---

# Decisions

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
