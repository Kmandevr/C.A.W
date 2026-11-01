---
title: Music workflow feature-gap plan
summary: Evidence-based status and build order for extending CAW's piano roll, arrangement, mixer, audio editing, sampling, MIDI and export workflows.
covers: [app/lib/ui/, app/lib/model/, engine/]
updated: 2026-11-01
---

# Music workflow feature-gap plan

This is the detailed implementation-gap companion to the [two-part core development plan and complete feature list](core-and-feature-plan.md) and the [roadmap](roadmap.md). It compares CAW's implemented workflows with useful capabilities found in established music creation and audio-editing software. The purpose is to extend CAW's existing systems, not rebuild them or copy a full conventional DAW. For unconventional, non-AI sound-generation and transformation ideas filtered for low-end hardware, see the separate [lightweight creative audio systems plan](lightweight-creative-audio-systems.md).

## Status key

- **[Fact] Implemented:** current app/engine documentation identifies a working implementation.
- **[Fact] Partial:** a useful foundation exists, but the complete workflow does not.
- **[Proposal] Planned:** a sensible extension, not a claim that code exists.
- **[Deferred]** Deliberately outside the current scope; do not start without revisiting the owner's direction.

Where documentation conflicts, the app and engine implementation are authoritative. The current app reference is [app](app.md), the UI specification is [ui](ui.md), and engine details are in [engine](engine.md).

## Existing foundations — preserve and extend
