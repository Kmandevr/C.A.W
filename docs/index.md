---
title: C.A.W vault
summary: Vault home: links to every note.
updated: 2026-11-10
---

# C.A.W vault

Project memory for C.A.W. Open this docs/ folder as a vault in Obsidian, or read it on GitHub. A note that documents code lists the paths it describes in its covers: frontmatter; re-check the note when those change.

## Agent entry point

- [Repository agent instructions](../AGENTS.md): portable starting point for non-Claude agents; links to project-wide guidance, area rules and skills. Claude-specific setup is documented in [../.claude/README.md](../.claude/README.md).

## Notes

- [Native engine recovery](engine-recovery.md): short resume protocol, current checkpoint and critical architecture facts for interrupted sessions.
- [Native engine progress](engine-progress.md): milestone ledger with actual implementation status, evidence, commits, CI, blockers and exact next actions.
- [Task 1 UI implementation handoff](task-1-ui-handoff.md): concise current UI implementation pointer and verified workflow gaps; no stale branch/CI snapshot.
- [Roadmap](roadmap.md): the permanent, canonical product roadmap, including ordered stages, current implementation snapshot, future production capabilities, performance gates and scope boundaries.
- [Master development design](CAW_MASTER_DEVELOPMENT_PLAN.md): approved UI and engine design specification; it is not a separate roadmap or a current implementation report.
- [Vision](vision.md): owner-approved product direction, actual platform support, current scope boundaries and open decisions.
- [Architecture](architecture.md): verified technical architecture plus explicitly labelled future design proposals
- [C++ creation platform](cpp-creation-platform.md): owner-approved C++ language direction and proposed Library/SDK, shared component model, code/visual/performance interfaces, real-time boundaries and migration gates
- [Visual creation and signal routing](visual-routing-and-library-integration.md): two visual workspaces, typed project routing, conditional workflows, Faust/Tracktion evaluations and open-source reuse strategy
- [Native engine refactor plan](engine-next.md): owner-approved refactor strategy, DSP/precomputation, hardware acceleration, permissive dependency candidates, migration phases and verification gates.
- [Engine integration contract](engine-integration.md): how projects, add-ons, the app, library and CLI share native capabilities and assets
- [How it works](how-it-works.md): the path from a .caw file to sound and to a WAV, the file that owns each step, and where to change what; start here in a new session
- [Engine reference](engine.md): the built engine: patterns, playback, project file, exports, C API, CLI, tests
- [Modular engine implementation status](engine-build-status.md): evidence-based ledger of built engine components, incomplete integrations and verification
- [Native module SDK](native-module-sdk.md): the versioned C ABI contract and remaining host/loading work
- [App](app.md): factual inventory of the eight current workspaces, engine integration, storage, build and tests
- [Performance](performance.md): how the engine and app are measured for low-end devices, the audit's ranked bottlenecks, fixes with before/after numbers, and next steps
- [Actions, keys and macros](actions.md): draft for review: every command as an action, customisable keys per area, macros, toolbars and the default keymap
- [UI design](ui.md): current editor implementation, phone/desktop interaction design and performance constraints
- [REAPER's flow and C.A.W's](reaper-flow.md): REAPER's path from a new project to a render, step by step with sources, C.A.W's current flow, the gaps with phone equivalents, and a ranked build plan (proposal)
- [UI plan](ui-plan.md): the owner's UI direction (2026-11-04: the arrangement is home, docking panels, Unity-like code, Reaper-like mixer), today's findings, the order of work and open questions; not built yet
- [Core development plan](core-and-feature-plan.md): compatibility pointer to the permanent roadmap; not a separate plan
- [Music workflow implementation gaps](music-workflow-feature-gap-plan.md): factual implemented/partial/missing status, without a competing feature sequence
- [Lightweight creative audio systems](lightweight-creative-audio-systems.md): supporting technical designs for non-AI sound systems in the roadmap
- [Decisions](decisions.md): what was chosen and why
- [Log](log.md): dated history of changes
