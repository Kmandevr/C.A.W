---
title: Decisions
summary: Dated record of what was chosen and why, newest first.
updated: 2026-11-03
---

# Decisions

## 2026-11-03: A separate test route for chat agents

- Owner: GPT works from a chat window with only a GitHub connector, can't run tests itself, and gets stuck re-reviewing when its context grows. It needs a way to run tests without opening pull requests or building the app, plus a workflow that survives a new chat.
- Chosen: `gpt/**` branches run only the Quick check (`.github/workflows/quick-check.yml`; Linux build and tests, docs guard, Dart checks when `app/` changed). It publishes a short report file per branch on the `agent-results` branch, because a file is what the connector reads reliably. **[Assumption]** It is not verified that the connector can read Actions logs or trigger `workflow_dispatch`, so the route needs neither.
- Full Engine, App and Docs CI is skipped on `gpt/**` pushes and runs on the pull request, which is still the merge gate. The report's write token sits in a separate job that never runs branch code.
- Start-of-chat context is generated, not remembered: `START.md` on `agent-results` bundles `AGENTS.md`, `CLAUDE.md`, `docs/vision.md` and every area rule, rebuilt from `Main` when any of them changes. A start prompt in the ChatGPT project's instructions (text in `AGENTS.md`) makes each chat fetch it first and confirm what it read, since ChatGPT has no hooks.
- The loop and stop rules live in `AGENTS.md` ("Chat-agent route"): a progress comment on the issue replaces chat memory, each file is reviewed at most once per chat, two failed fixes means stop and report, and a long chat hands off to a new one.

## 2026-11-03: Agent navigation tools are the default path

- Owner: Graphify and Serena (with the repo map) are how agents find and read code by default; plain Read, Grep and shell `cat`/`sed`/`grep` are for what those tools already named.
- Enforced by tooling rather than wording: the session-start hook prints the navigation order and how to load Serena's deferred tools, and Serena's `remind` hook now watches Bash and Serena calls as well as Read/Grep (`.claude/README.md`).

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
