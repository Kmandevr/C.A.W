---
title: Native engine recovery
summary: Short resume guide for continuing the native engine refactor without repeating completed work.
covers: [engine/, app/]
updated: 2026-11-02
---

# Native engine recovery

**Goal:** complete the owner's native engine refactor/integration assignment in Kmandevr/C.A.W; implement, test and integrate rather than produce another plan.

## Current checkpoint

- Branch: feature/native-engine-refactor-integration
- Base: Main at 20fd3da9a37f8936f1c3ff6069878978d064ae37
- Branch created from refactor/native-engine-foundation at 49ba277f91bc9349f70d492c32e5f498d692e9b3 (15 ahead, 0 behind Main at recovery).
- PR: none. CI on this branch: not yet checked.
- Milestone: M0 audit in progress; no engine code changed on this branch yet.

## Read first

1. AGENTS.md, CLAUDE.md, applicable .claude/rules/*.md and skills.
2. docs/engine-progress.md — exact status, evidence and next actions.
3. docs/engine-build-status.md — existing code versus missing integration.
4. docs/engine-next.md — full owner requirements.
5. docs/decisions.md, docs/log.md, docs/roadmap.md.

## Critical recovery facts

The engine already has a worker pool, hardware/workload policy, typed graph validation, prepared stereo graph executor/publication helper, module descriptors/registry, dependency resolver, MIDI 2.0 UMP decoder/queue and partial app job integration. Do not recreate these.

The key gap is that the prepared graph executor/runtime is not wired into the existing Engine/VM mixer. Other major gaps include general runtime routing/sidechains/buses, shared parameters across all module types, live MIDI device/voice integration, native module isolation/lifecycle, and graph-aware app/project integration.

The owner has explicitly reopened full graph/runtime integration despite an older status note saying it was paused. Preserve existing product boundaries and real-time safety.

## Resume protocol

Check current branch, commits, open PRs/issues and CI before editing. Compare actual code against the progress ledger; trust code over stale prose. Continue from the exact next action in docs/engine-progress.md. Never reset/discard changes. Connector-only sessions cannot run local builds: use CI and inspect logs; never report unobserved tests as passing. Update progress, decisions and log at each milestone boundary.