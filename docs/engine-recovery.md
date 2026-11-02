---
title: Native engine recovery
summary: Short resume guide for continuing the native engine refactor without repeating completed work.
covers: [engine/, app/]
updated: 2026-11-02
---

# Native engine recovery

**Goal:** complete the owner's native engine refactor/integration assignment in `Kmandevr/C.A.W`. Implement and integrate the existing engine; do not create a parallel engine.

## Current checkpoint

- Branch: `feature/native-engine-refactor-integration`
- Base: `Main` at `20fd3da9a37f8936f1c3ff6069878978d064ae37`
- Current branch tip at this status record: 32 ahead, 0 behind. Native code commit: `07c796f8e745cd44e7be37992747b8263ac27e9a`.
- Starting point: `refactor/native-engine-foundation` at `49ba277f91bc9349f70d492c32e5f498d692e9b3`.
- Issue: #28, open and in progress. PR: none.
- Milestones: M0 verified; M1 in progress.
- Previous baseline CI: App `41401179166` passed Dart analysis/tests, Windows app and Android APK; no app code changed after that run. Docs `41402930329` passed at docs-only checkpoint `1370a43`. Engine `41402930328` passed Linux x64, Linux Arm64 and sanitizers, but Windows remained in Build over 15 minutes; identical code at `eb465f4` had already passed Windows. New graph-budget code commit `07c796f8` is awaiting fresh Engine/Docs CI.

## Read first

1. `AGENTS.md`, `CLAUDE.md`, applicable `.claude/rules/*.md` and skills.
2. `docs/engine-progress.md` — exact status, evidence, fixed-limit audit and next actions.
3. `docs/engine-build-status.md` — existing code versus missing integration.
4. `docs/engine-next.md` — full owner requirements.
5. `docs/decisions.md`, `docs/log.md`, `docs/roadmap.md`, `docs/how-it-works.md`.

## Critical recovery facts

The graph compiler no longer has the former 1,024-node/8,192-connection caps and has regression tests above those values. The executor no longer has the former 8,192-frame cap. The new `GraphResourceBudget` requires explicit working bytes and checks estimated compile/prepared-buffer memory before allocation; optional node/connection caps default to unlimited. Its tests are added but the new code commit still awaits CI.

The graph executor remains stereo-only with one audio input and output per node, and is not integrated into active Engine/VM playback. The new low-level byte budget is not yet derived from hardware or wired through Engine. The active path still uses `Engine::setProject`, `processChunk`, `processSlot` and `runChain`. Do not claim graph integration is complete.

Important remaining risks include fixed 64 layer slots, 32 voices, 9 chain modules, parameter/import/export caps, 64-bar arrangement clamp, silent parser truncation, project-state exhaustion that leaves layers silent, a project command queue timeout that can drop installs, retirement overflow that can leak, and slot exhaustion that can skip a layer. See `docs/engine-progress.md` for exact limits and source behavior.

M0 audit is complete; do not repeat the repository-wide investigation without new evidence. The next implementation step is to verify the new graph budget commit in CI and wire its budget from hardware-aware Engine policy, followed by prepared project snapshot publication and safe ownership/retirement, then multi-domain graph execution and Engine/VM integration.

The owner explicitly reopened full graph/runtime integration despite the older pause comment on issue #28. The issue body and current owner comment reflect the current scope.

## Resume protocol

Check branch head, Main ancestry, open PRs/issues and latest CI before editing; this branch may advance between chats. Continue from the exact next action in `docs/engine-progress.md`. Never reset/discard changes. Connector-only sessions cannot run local builds: use GitHub Actions and inspect failed job logs; never report unobserved tests as passing. Update progress, status, log and recovery notes at each milestone boundary.
