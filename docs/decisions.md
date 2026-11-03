---
title: Decisions
summary: Dated record of what was chosen and why, newest first.
updated: 2026-11-03
---

# Decisions

## 2026-11-03: Roadmap order, first release and per-item tables

- **Graph first.** The engine graph and N-channel core (issue #28) is the roadmap's new **Foundation** stage, before the remaining Stage 0 (SFZ, stems) and Stage 1 features, so they are built on the graph once rather than on the old mixer and then migrated. This replaces the same day's decision to pause graph integration until after Stage 1.
- **First release after Stage 7.** Release 1 (signed builds, onboarding/help, docs, licensing, distribution) comes after recording works, on Android and Windows; Stages 8–10 ship as updates. It was previously the last stage.
- **Gaps added to the roadmap:** app-wide undo/redo and crash recovery (Stage 1), project format versions and migration (Foundation, before the project model changes), audio output settings (Stage 5), and onboarding, help and a preset/template browser (Release 1).
- **Layout:** each stage is a table of items with status, where (engine/app), dependencies and what's missing, so progress and gaps are visible per item.

## 2026-11-03: Engine shape, formats and trust decisions to avoid later rework

- **One graph runs everything (eventual engine core).** Code (.caw) layers, synth voices, effects, folder buses, sends and master all become nodes of the one typed module graph. The current layer → effects → folder bus → master mixer is migrated into it, not kept as a parallel path. Timing: first, as the roadmap's Foundation stage (see the next entry).
- **Stage 0 SFZ means full import and mapping.** The first multisample version imports WAV samples (own or third-party), maps zones (key ranges, velocity layers) by hand, plays them in C.A.W and exports WAV + .sfz. This pulls the needed parts of roadmap Stage 3 (audio import) and Stage 4 (sampler zones, WAV/SFZ interchange) into Stage 0.
- **Exports are always bit-identical.** Offline renders and exports produce the same bits on every platform. Live preview may use faster maths (SIMD, threads, reduced quality) only when it is labelled as a preview mode; golden tests cover the export path.
- **Low-end target includes budget phones:** Galaxy A1x-class, 3–4 GB RAM, Android 10+. Voice counts, buffer sizes and benchmark budgets are set for that class.
- **Precision:** graph audio buffers are 32-bit float; 64-bit is used where accuracy needs it (phase/time accumulators, sensitive filter state). The .caw VM keeps its 64-bit JavaScript number semantics, which bytebeat compatibility requires.
- **Latency is adjustable:** a low-latency mode for playing live when timing matters, and a lighter, more stable mode (larger buffers, less CPU) when it doesn't. This is the workload-policy model in [engine-next](engine-next.md) §9.
- **Third-party native code: the user chooses per item.** Each external plugin (CLAP/VST3/AU) or third-party native module runs in one of three modes the user sets: **Isolated** (separate process), **Trusted** (in-process, no isolation, for code the user trusts) or **Blocked**. Shared .caw source stays sandboxed as before. The default mode for code not seen before is an open question in [vision](vision.md#open-owner-decisions).
- **Projects are folders that work like a repository.** A project folder holds the project file and its local assets; assets can also be linked from the global library. "Package build" collects every dependency into the folder so it works on its own. The format must stay compatible with a future **AutoStacc cloud library** (the owner's synced personal asset library). That sync is optional; core work never needs the network.
- **Audio clip timing is chosen per clip.** Clip positions are stored in musical time (beats). Each audio clip is either *musical* (follows tempo changes, time-stretched) or *fixed* (plays at original speed in seconds).
- **Graph is N-channel by design, stereo in practice.** Ports and buses carry a channel-layout field and are not hard-coded to two channels; only mono and stereo are implemented until surround (roadmap Stage 10).
- **Everything in the graph must be plugin-exportable.** Built-in graph nodes may not depend on the app or the OS, so any graph can become a CLAP/VST3 plugin (roadmap Stage 9).
- **Projects set their own render sample rate** (default 48 kHz; 44.1 and 96 kHz selectable). Live playback resamples to the device when they differ; exports always use the project rate.

## 2026-11-03: A separate test route for chat agents

- Owner: GPT works from a chat window with only a GitHub connector, can't run tests itself, and gets stuck re-reviewing when its context grows. It needs a way to run tests without opening pull requests or building the app, plus a workflow that survives a new chat.
- Chosen: `gpt/**` branches run only the Quick check (`.github/workflows/quick-check.yml`, `scripts/agent-run.js`). `run:` lines in the last commit message choose exactly which commands run (a filtered test, a sanitizer run, one build target, a render, ripgrep, Graphify, ctags lookups), so the agent tests what it needs while it builds, much like a terminal. With none, a default set runs (docs guard, Linux build and tests, examples, Dart checks when `app/` changed). Commands are a fixed list run without a shell. The same runner covers ChatGPT's own list of gaps (2026-11-03): git `diff`/`log`/`show`/`blame`; app interaction through widget tests, accessibility guidelines and published `screenshot` PNGs; a RUNNING notice and `INDEX.md` for job tracking; and an environment line in every report so a CI pass is never presented as a hardware result. It publishes a short report file per branch on the `agent-results` branch, because a file is what the connector reads reliably. **[Assumption]** It is not verified that the connector can read Actions logs or trigger `workflow_dispatch`, so the route needs neither.
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
