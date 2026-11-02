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
- Current branch tip at this status record: 44 ahead, 0 behind. Latest documentation commit: `6734c29443317b348572f4faafb72d920b1d85e0`.
- Starting point: `refactor/native-engine-foundation` at `49ba277f91bc9349f70d492c32e5f498d692e9b3`.
- Issue: #28, open and in progress. PR: none.
- Milestones: M0 verified; M1 in progress.
- Graph-budget implementation commit `07c796f8` passed Engine `41403872524` on Linux x64, Linux Arm64, Windows x64 and sanitizers; Docs `41403872717` passed; App `41403872504` passed Dart analysis/tests, Windows app and Android APK. The graph compiler-budget follow-up and subsequent chain-cap removal changes require fresh CI; the last known green run predates those changes. The earlier delayed Windows job at `1370a43` eventually passed all four targets.

## Latest implementation slice

Dynamic signal-chain length is now preserved through project parsing and Engine chain preparation; synth patch parsing also accepts more than eight effects. See the 2026-11-02 entry in docs/log.md and the decision in docs/decisions.md. Do not reintroduce the old chain cap. Fixed export-buffer, layer-slot, voice and automation limits remain.

## Read first

1. `AGENTS.md`, `CLAUDE.md`, applicable `.claude/rules/*.md` and skills.
2. `docs/engine-progress.md` — exact status, evidence, fixed-limit audit and next actions.
3. `docs/engine-build-status.md` — existing code versus missing integration.
4. `docs/engine-next.md` — full owner requirements.
5. `docs/decisions.md`, `docs/log.md`, `docs/roadmap.md`, `docs/how-it-works.md`.

## Critical recovery facts

The graph compiler no longer has the former 1,024-node/8,192-connection caps and has regression tests above those values. The executor no longer has the former 8,192-frame cap. The new `GraphResourceBudget` requires explicit working bytes and checks estimated compile/prepared-buffer memory before allocation; optional node/connection caps default to unlimited. Its compiler and executor budget tests passed CI at checkpoint `1269019`; a follow-up test now directly covers compiler working-set rejection and awaits CI.

The graph executor remains stereo-only with one audio input and output per node, and is not integrated into active Engine/VM playback. The new low-level byte budget is not yet derived from hardware or wired through Engine. The active path still uses `Engine::setProject`, `processChunk`, `processSlot` and `runChain`. Do not claim graph integration is complete.

Important remaining risks include fixed 64 layer slots, 32 voices, 9 chain modules, parameter/import/export caps, 64-bar arrangement clamp, silent parser truncation, project-state exhaustion that leaves layers silent, a project command queue timeout that can drop installs, retirement overflow that can leak, and slot exhaustion that can skip a layer. See `docs/engine-progress.md` for exact limits and source behavior.

M0 audit is complete; do not repeat the repository-wide investigation without new evidence. The latest code slice removes the fixed nine-module/eight-effect chain cap from parsing, Engine preparation and synth patches, with tests for 12 project-chain entries and nine synth effects. It is not yet CI-verified. Next, check CI as soon as a workflow is available, then continue with hardware-aware Engine budgets and transactional prepared-project publication, safe retirement, typed multi-domain graph execution and Engine/VM integration.

The owner explicitly reopened full graph/runtime integration despite the older pause comment on issue #28. The issue body and current owner comment reflect the current scope.

## Resume protocol

Check branch head, Main ancestry, open PRs/issues and latest CI before editing; this branch may advance between chats. Continue from the exact next action in `docs/engine-progress.md`. Never reset/discard changes. Connector-only sessions cannot run local builds: use GitHub Actions and inspect failed job logs; never report unobserved tests as passing. Update progress, status, log and recovery notes at each milestone boundary.
