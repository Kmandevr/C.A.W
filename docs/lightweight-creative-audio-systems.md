---
title: Lightweight creative audio systems plan
summary: Prioritized, performance-aware research plan for distinctive non-AI sound generation, transformation, exploration and inspection features.
covers: [engine/, app/lib/]
updated: 2026-11-01
---

# Lightweight creative audio systems plan

This is the detailed design companion to the [two-part core development plan and complete feature list](core-and-feature-plan.md). It filters unconventional audio ideas through C.A.W.'s actual architecture and low-end-device requirements. It complements the [music workflow feature-gap plan](music-workflow-feature-gap-plan.md); it does not replace the existing piano-roll, mixer, audio-editing, sampling, MIDI or export work.

**Owner direction:** no AI integration in this work. No model inference, cloud processing, AI sound generation, AI-assisted editing or AI-dependent features. All proposed processing is conventional deterministic DSP, mathematics, algorithms and user-directed exploration.

## 1. Decision rules

A feature belongs in this plan only when it:
