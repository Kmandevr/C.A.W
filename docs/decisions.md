---
title: Decisions
summary: Dated record of what was chosen and why, newest first.
updated: 2026-10-28
---

# Decisions

Newest first. A later entry wins over an earlier one on the same topic.

## 2026-10-28: Every platform; Flutter + miniaudio proposed (owner: platforms; Claude: stack, owner to confirm)

- **Targets:** Android, iOS, Windows, macOS and Linux (owner). Android first, on the owner's Galaxy S22+ (Android 16).
- **Replaces the Android-only stack below:** Kotlin + Compose and Oboe are dropped. The portable C++ engine stays, since it was built for this.
- **miniaudio for audio output on every platform:** one public-domain/MIT-0 C library with AAudio, Core Audio, WASAPI and ALSA backends. Oboe stays a fallback for Android if latency tests on the S22+ fall short.
- **Flutter proposed for the UI:** one codebase for all five targets and one `dart:ffi` bridge to the engine. Compose Multiplatform is the runner-up (two bridges, a JVM on desktop). JUCE was rejected for revenue-capped licensing and weak touch text editing, Qt for LGPL on iOS.
- **iOS conflicts with AutoStacc-only selling:** outside the EU and Japan, iOS apps can only be sold through the App Store. Left to the owner.

## 2026-10-28: Sold only through AutoStacc; samples first (owner)

- **Closed and commercial, sold only through AutoStacc**, not the Play Store or other stores. The repository stays private. Permissive dependencies remain the rule, since the app's own source isn't published.
- **Until then it's the owner's sample-making tool for AutoStacc**, so WAV export quality and speed of getting sounds out come first.
- **Default branch:** `main` was pushed at the current commit. Sessions can't change repository settings (the proxy blocks GitHub's write APIs for branches and settings), so the owner switches the default to `main` in GitHub settings.

## 2026-10-28: Repository and agent setup (owner)

- **Setup comes from AutoStacc**, the owner's other repository: `CLAUDE.md` with read-in-layers, the repo map from purpose lines (`.claude/tools/tree.sh`), Graphify for file-level orientation, Serena for symbols, path-scoped rules, skills, read-only review agents, the `change` workflow, the handoff, and GitHub Issues as the only task list. AutoStacc's project-agnostic `tools/`, `hooks/` and `workflows/` are kept identical so they can be refreshed from there (one exception: a `tree.sh` fix for a root with no files of its own, worth porting back).
- **Agents fit this project:** `architect`, `code-reviewer`, `audio-reviewer` (new: real-time safety and DSP) and `security-reviewer` (rewritten for module sandboxing, GitHub auth, Android and CI). AutoStacc's site, SEO and store agents and skills weren't brought over.
- **Docs stay clean and current:** one home per fact, superseded text rewritten where it stands, history only in this note and the [log](log.md). `scripts/docs-test.js` enforces frontmatter, links, named paths, the index and stale notes; CI runs it, and the Stop hook reminds Claude.
- **Note names are lowercase** (`architecture.md`, `roadmap.md`) to match the vault.

## 2026-10-28: Stack and engine direction (Claude, proposed; owner to confirm)

- **Kotlin + Jetpack Compose UI, Oboe for audio I/O, a custom portable C++ engine.** Oboe is the Android low-latency standard (Apache-2.0). A portable core also builds as a Linux CLI, so CI and AI agents can check and render sounds without a phone.
- **User code compiles to bytecode for our own VM** instead of embedding JavaScript or Lua: no garbage-collection pauses on the audio thread, and the sandbox comes from what the language can't do.
- **No NKIDO dependency for Stage 1.** It's MIT and architecturally similar, but small (one main developer) with no confirmed Android build. Re-evaluate with a one-day spike in Stage 2.
- **GitHub App with device-flow sign-in**, limited to repositories the user selects; no secret ships in the app.
- **APKs are built in GitHub Actions**, because the owner works from a phone.
