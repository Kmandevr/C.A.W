---
title: C.A.W vault
summary: Vault home: links to every note.
updated: 2026-11-18
---

# C.A.W vault

Project memory for C.A.W. Open this docs/ folder as a vault in Obsidian, or read it on GitHub. A note that documents code lists the paths it describes in its covers: frontmatter; re-check the note when those change.

## Agent entry point

- [Repository agent instructions](../AGENTS.md): portable starting point for non-Claude agents; links to project-wide guidance, area rules and skills. Claude-specific setup is documented in [../.claude/README.md](../.claude/README.md).

## Notes

- [Native engine recovery](engine-recovery.md): short resume protocol, current checkpoint and critical architecture facts for interrupted sessions.
- [Native engine progress](engine-progress.md): milestone ledger with actual implementation status, evidence, commits, CI, blockers and exact next actions.
- [Task 1 UI implementation handoff](task-1-ui-handoff.md): concise current UI implementation pointer and verified workflow gaps; no stale branch/CI snapshot.
- [Roadmap](roadmap.md): the work C.A.W has promised and hasn't built yet (VST3 and CLAP hosting, iOS and macOS, Google Play, the AutoStacc store and cloud library); the vision and other plans are private.
- [Architecture](architecture.md): verified technical architecture and engine/app boundaries
- [C++ creation platform](cpp-creation-platform.md): owner-approved C++ language direction, the Library/SDK, shared component model, code editor, real-time boundaries and migration
- [Engine integration contract](engine-integration.md): how projects, add-ons, the app, library and CLI share native capabilities and assets
- [How it works](how-it-works.md): the path from a .caw file to sound and to a WAV, the file that owns each step, and where to change what; start here in a new session
- [Engine reference](engine.md): the built engine: patterns, playback, project file, exports, C API, CLI, tests
- [Modular engine implementation status](engine-build-status.md): evidence-based ledger of built engine components, incomplete integrations and verification
- [Native module SDK](native-module-sdk.md): the versioned C ABI contract and remaining host/loading work
- [App](app.md): factual inventory of the eight current workspaces, engine integration, storage, build and tests
- [Engine performance](engine-performance.md): the CI bench suite (`caw_bench SECONDS 500`, the Bench workflow), its scenarios, the per-target baseline and the speed phases' before/after tables
- [Performance](performance.md): how the engine and app are measured for low-end devices, the audit's ranked bottlenecks and fixes with before/after numbers
- [Actions, keys and macros](actions.md): draft for review: every command as an action, customisable keys per area, macros, toolbars and the default keymap
- [UI design](ui.md): current editor implementation, phone/desktop interaction design and performance constraints
- [REAPER's flow and C.A.W's](reaper-flow.md): REAPER's path from a new project to a render, step by step with sources, and C.A.W's current flow
- [Beta readiness plan](beta-readiness-plan.md): the owner's 2026-11-12 beta direction for the stress test, telemetry, feedback and builds, and the C.A.W-Telemetry contract
- [Companion protocol](companion-protocol.md): how C.A.W talks to its companion app on Android (#239): the message kinds, version, limits, timeouts, caller check and the fallback when it is absent; the main app's side is built, the companion is not
- [Music workflow implementation gaps](music-workflow-feature-gap-plan.md): factual implemented and partial status by area, and the constraints new work keeps
- [Decisions](decisions.md): what was chosen and why
- [Log](log.md): dated history of changes

The roadmap, feature plans, proposals for unbuilt work, owner questions and decisions about unbuilt features are kept in the private Kmandevr/AutoStacc-Hub (docs/caw/).
