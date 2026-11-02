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
- Current head: `72502e87cc67506479216edb6ff8128520b15031` (29 ahead, 0 behind).
- Starting point: `refactor/native-engine-foundation` at `49ba277f91bc9349f70d492c32e5f498d692e9b3`.
- Issue: #28, open and in progress. PR: none.
- Milestones: M0 verified; M1 in progress.
- CI at current checkpoint: Engine `41401950333` and Docs `41401950277` passed. App `41401179166` passed Dart analysis/tests, Windows app and Android APK; no app code changed after that run.

## Read first

1. `AGENTS.md`, `CLAUDE.md`, applicable `.claude/rules/*.md` and skills.
2. `docs/engine-progress.md` — exact status, evidence, fixed-limit audit and next actions.
3. `docs/engine-build-status.md` — existing code versus missing integration.
4. `docs/engine-next.md` — full owner requirements.
5. `docs/decisions.md`, `docs/log.md`, `docs/roadmap.md`, `docs/how-it-works.md`.

## Critical recovery facts

The graph compiler no longer has the former 1,024-node/8,192-connection caps and has regression tests above those values. The executor no longer has the former 8,192-frame cap. Engine, App and Docs CI are green at the checkpoints above.

The graph executor remains stereo-only with one audio input and output per node, no explicit buffer byte budget, and no integration into active Engine/VM playback. The active path still uses `Engine::setProject`, `processChunk`, `processSlot` and `runChain`. Do not claim graph integration is complete.

Important remaining risks include fixed 64 layer slots, 32 voices, 9 chain modules, parameter/import/export caps, 64-bar arrangement clamp, silent parser truncation, project-state exhaustion that leaves layers silent, a project command queue timeout that can drop installs, retirement overflow that can leak, and slot exhaustion that can skip a layer. See `docs/engine-progress.md` for exact limits and source behavior.

M0 audit is complete; do not repeat the repository-wide investigation without new evidence. The next implementation step is explicit graph resource budgeting, followed by prepared project snapshot publication and safe ownership/retirement, then multi-domain graph execution and Engine/VM integration.

The owner explicitly reopened full graph/runtime integration despite the older pause comment on issue #28. The issue body and current owner comment reflect the current scope.

## Resume protocol

Check branch head, Main ancestry, open PRs/issues and latest CI before editing; this branch may advance between chats. Continue from the exact next action in `docs/engine-progress.md`. Never reset/discard changes. Connector-only sessions cannot run local builds: use GitHub Actions and inspect failed job logs; never report unobserved tests as passing. Update progress, status, log and recovery notes at each milestone boundary.
