---
title: Native engine recovery
summary: Short resume guide for continuing the native engine refactor without repeating completed work.
covers: [engine/, app/]
updated: 2026-11-02
---

# Native engine recovery

**Goal:** complete the owner's native engine refactor/integration assignment in Kmandevr/C.A.W. Implement and integrate the existing engine; do not create a parallel engine.

## Current checkpoint

- Branch: feature/native-engine-refactor-integration
- Base: Main at 20fd3da9a37f8936f1c3ff6069878978d064ae37
- Code checkpoint: eb465f4a1489d30beb34801e52bc1e7ddc2e7577; progress-ledger update: 44d37d8e32163b9442aeb9113c6eea5f5528545e.
- PR: none. Do not merge/approve or delete branches.
- Engine CI 41401179084: Linux x64, sanitizers, Windows x64 and Linux Arm64 all passed. Docs CI 41401179017 passed. App CI 41401179166: Dart analysis/tests and Windows app passed; Android APK pending at checkpoint.
- Current milestone: M0 audit in progress; first graph compiler/executor scaling slice implemented and tested. See docs/engine-progress.md for commits and exact status.

## Read first

1. AGENTS.md, CLAUDE.md, applicable .claude/rules/*.md and skills.
2. docs/engine-progress.md — exact status, evidence, known limits and next actions.
3. docs/engine-build-status.md — existing code versus missing integration.
4. docs/engine-next.md — full owner requirements.
5. docs/decisions.md, docs/log.md, docs/roadmap.md.

## Critical recovery facts

GraphExecutor/GraphRuntime and ModuleRegistry exist but have no production references from Engine, VM, C API or Flutter. The active engine still processes VM instances through Engine::runChain/runVoices/processChunk with separate chain/import/export/voice/folder-bus logic. GraphExecutor remains stereo audio only, one input/output per node and 8–192 kHz.

The graph compiler no longer has fixed 1024-node/8192-connection caps and accepts host-selected block sizes above 8192; node-index representation remains uint32. Large-graph and large-block tests pass in the Engine CI matrix.

Important remaining caps and loss paths are listed in docs/engine-progress.md. Prioritize 64 layer slots, 32 voices, chain/export/automation limits, arrangement truncation, command/retirement overflow and project-state budgets. Some VM limits are safety budgets; make them explicit/configurable and surface all failures.

The owner explicitly reopened full integration despite an older paused-status note. Preserve product boundaries and real-time safety.

## Resume protocol

Check branch/head/Main ancestry, open PRs/issues and CI before editing. Trust code over stale prose. Continue from the exact next action in docs/engine-progress.md. Never reset/discard changes. Connector-only sessions cannot run local builds: use CI and inspect logs. Update progress, decisions and log at each milestone.
