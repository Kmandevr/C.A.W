---
title: Decisions
summary: Dated record of what was chosen and why, newest first.
updated: 2026-11-09
---

# Decisions

## 2026-11-09: A C++ effect behaves like a CLAP plugin in REAPER (owner, #137)

- **Owner decision:** "the code will run like a CLAP does in REAPER": the same behaviour, in C.A.W's own component format; adopting the CLAP format is not part of this work. Effects run in-process for now; Isolated (a separate process) comes later.
- So an effect has, as built (2026-11-09):
  - an FX-chain place;
  - live, smoothed values;
  - automation lanes (a knob move overrides its lane until the next Play);
  - a click-free bypass that stops processing;
  - state saved into the project, read on every save.
- Also built: tails after Stop and latency compensation.
  - Effects with a declared tail ring out until quiet. They reuse the note-preview path, so the 10 ms stop fade dips the tail briefly.
  - The other tracks are delayed to match the most-delayed track, up to 32,768 frames.
- Still to come: a rebuild swapped in while playing, and custom GUIs.
- **Interface rule changed:** `save_state` may now run on the control thread while the instance processes (as in CLAP), so a playing project can be saved. A component that keeps state must make that safe; one without state needs nothing. `caw_component.h` says so.

## 2026-11-09: How writing and using a C++ effect looks (owner, #137)

- **A C++ workspace of its own** (the ninth, docked like the others): a side-drawer file tree, the editor at full width and Build. A new effect always starts from one blank pass-through template.
- **Errors:** red marks on their lines and the first error on one line under the code; a tap lists them all, and a tap on one jumps to it.
- **Trust:** effects the user built on this device are Trusted without a prompt. Effects from elsewhere ask Trust or Block once, remembered per effect and changeable in its settings.
- **A test strip under the editor:** a source (a track, a loop, a sine, noise), Play and the effect's generated knobs. Build swaps the new version in while it plays.
- **Using it:** "+ C++ effect" in a track's or the master's effect chain lists the built effects; a placed effect is a card with knobs generated from its parameters.

## 2026-11-09: The on-device compiler is LLVM 23.1.5 as one library (#137)

- **Dependency:** LLVM, Clang and LLD 23.1.5 (`llvm-project-23.1.5.src.tar.xz`, SHA-256 `fb50b1ea…6a6e`, release checked 2026-11-09), Apache-2.0 with LLVM exception. Built by `.github/workflows/compiler.yml` with AArch64 code generation only; the build is cached per version.
- **Shape:** `engine/compiler/` wraps them as `libcaw_compiler.so` with three C functions (`caw_compiler_run`, `_free`, `_version`). Clang's driver plans each build; its compile steps run through cc1 and its link step through LLD, all in the calling process. So no executable is ever started, which Android forbids for app files. The Android app loads it in the `:compiler` process (§6 of the C++ platform note).
- **Offline data bundle** (`engine/compiler/bundle.sh`): Clang's headers, the NDK r30 sysroot for arm64 at API 26 (headers, `crtbegin_so.o`/`crtend_so.o`, `libc`/`libm`/`libdl`/`liblog` stubs, `libc++_static.a`, `libc++abi.a`), compiler-rt builtins and `libunwind.a`, the C.A.W SDK headers, and licence texts.
  - **[Assumption]** the redistributed NDK parts are permissive: bionic is BSD/Apache, while libc++, libunwind and compiler-rt are Apache-2.0 with LLVM exception. The bundle carries the NDK `NOTICE`, which must be read before the APK ships them.
- Components link the C++ library statically (`-static-libstdc++`), so a built `.so` needs only libc, libm and libdl.

## 2026-11-09: Where the C++ Library lives (#121, architect review)

- **Library kernels are public, header-only SDK code** in `engine/include/caw/library/` (installed with `CAW::SDK`), so built-in components and third-party components use one implementation, compiled into each; only `caw_component.h` crosses a binary boundary. Built-in components are thin wrappers in the engine (to come with #121). The first kernel is the pan law, `caw::lib::constantPowerPan` (`library/stereo.hpp`), which the mixer's track pan now calls.
- **The deterministic maths is public too** (`engine/include/caw/detmath.hpp`; `engine/src/detmath.h` forwards), moved unchanged: every golden render still matches.
- **Every component built against the SDK gets the engine's floating-point flags** (`-ffp-contract=off -fno-fast-math`; MSVC `/fp:precise`; clang-cl `/fp:precise /clang:-ffp-contract=off`, since its precise mode still fuses multiply-adds) as `CAW::SDK` interface options, chosen for the consumer's compiler in the installed `CAWConfig.cmake`, so Library code gives the same bits in components as in the engine.

## 2026-11-09: Mono stays mono until it becomes stereo; packages; narrower doc coverage

- **Owner decision — mono processing (#17):** a mono source or effect is processed once and copied to both channels while its signal is mono. Once the signal has actually become stereo (a stereo source, pan or width upstream), a mono effect processes each channel separately ("dual mono"), from that point on. Mono work therefore costs one channel until something makes it stereo; there is no silent downmix.
- **Owner decision — packages:** a package is one of three things, of any size: a library that adds code functionality, a sample/MIDI pack, or built plugins/effects. So one component library may hold several components; the C interface lists them by index (`caw_get_component_v3(index)`; the version went to 3 for that signature change, so a library built against v2 is refused cleanly rather than called with an argument it ignores).
- **Owner decision — how Claude works:** follow `CLAUDE.md` for the most part, but stretch the rules or make small assumptions where that is best for the app (never a whole change of direction). Hooks and tooling that cause more problems than they solve may be changed to fit their intended use; first one: the Serena search reminder no longer fires on Bash commands (builds, tests, git), only on Read/Grep. Before building anything that needs UI work, ask the owner how it should look.
- **Owner decision — doc coverage:** notes that describe plans or the whole system no longer `covers:` all of `engine/`, so a code change requires re-checking only the notes that describe the changed files.

## 2026-11-09: Claude takes over engine building

- **Owner decision:** Claude builds the engine for now (replacing the 2026-10-31 split where GPT built features and Claude reviewed). GPT's merged work is the baseline where it applies; Claude asks the owner about open questions instead of deciding them.
- **Owner decisions (same day):** GPT is paused on the engine (Claude only). Work order stays #120 → #17 → #121 → #122 (issue #123), with the stable C interface built as part of #120. Claude merges its own engine PRs once CI is green and its independent audio review finds nothing blocking. The stereo-only C interface v1 (`caw_module_sdk.h`) is replaced by a full v2 with no v1 compatibility.

## 2026-11-09: Two visual workspaces and conditional signal/event routing

- **Owner decision — song workflow:** keep the ordinary arrangement, piano roll, clips and conventional mixer workflow for making songs. Visual routing is an additional workspace, not a replacement for arranging or note editing.
- **Owner decision — two visual workspaces:** use one reusable visual framework for two distinct editors: a component workspace to build/edit instruments, effects and processors (C++, Faust and visual DSP composition), and a project/track workspace to edit track controls, effect chains, sends/destinations, buses, sidechains and routing. The latter should let users adjust track parameters and send destinations while viewing the effect chain and routes together.
- **Owner decision — universal conditional routing:** add a native typed signal/event/control routing and workflow capability. Sources include audio analysis, MIDI/events, parameters, modulation, track/clip/region/note/transport state and explicit UI state such as highlight. Rules support conditions, branches and actions that can affect routes, sends, effects and component parameters across tracks. Regional FX/path activation should not require traditional automation lanes.
- **Architecture distinction:** component/DSP graphs, project routing graphs and condition/workflow graphs are separate domain models, connected through shared typed ports, events, parameters and component descriptors. They must not become three incompatible execution engines or a UI-only graph.
- **Safety and behavior:** prepare routes/effects off the audio callback; runtime rules must be bounded, deterministic, observable and safe for live/offline parity. Define cycle/feedback, hysteresis, debounce, retrigger and resource-budget behavior. Preserve channel and per-note identity unless explicitly converted/combined.
- **Owner decision — reuse scope:** evaluate existing open-source projects at every scale, including complete subsystems and applications, not only small libraries. Prefer adoption/adaptation when feature quality, workflow fit, architecture, performance, platforms, maintenance and licence obligations beat a rebuild. LMMS is source reference only; VCV Rack is interaction inspiration, not the target workflow.
- **Owner decision — DSP language:** C++ remains the primary general-purpose language. Faust is approved for evaluation as an optional specialist DSP authoring/compiler backend, preferably generated C++ through the local C++ build pipeline first. Not built (owner, 2026-11-09): an embedded Faust JIT (libfaust/LLVM) and a Pure Data/libpd runtime. Tracktion Engine and JUCE are engineering references only: C.A.W. studies them but copies no code (see the licence decision below).
- **Owner decision — order (2026-11-09):** conditional rules come after the routing basics (sends, sidechains, parallel paths: roadmap 2.1–2.3), still in Stage 2. The first rule to build is a MIDI note on one track (kick) triggering a ducking envelope on another (bass).
- **Owner decision — UI state as a trigger (2026-11-09):** a highlighted/selected track can only change what is heard while working (audition/monitor); it never changes an export.
- **Owner decision — workspaces (2026-11-09):** on the phone the track/routing workspace is both a slide-up panel for the selected track over the arrangement and a full page for the whole project. The component workspace is an ordinary, always-visible workspace for everyone.
- **Owner decision — component binary boundary (2026-11-09):** compiled components talk to the host through a small, versioned C interface, with the SDK's C++ classes on top, so components survive app, compiler and C++ library updates ([C++ creation platform](cpp-creation-platform.md) §2).
- **Owner decision — safe sharing (2026-11-09):** once .caw is removed, visual-graph components made only of built-in nodes are the safe share format; anything containing C++ needs the user's trust choice.
- **Owner decision — iOS (2026-11-09):** iOS ships without C++ authoring/compilation (play, arrange, build visually). The App Store rule behind this is an assumption to verify.
- **Owner decision — nothing external required (2026-11-09):** the app needs no set-up step, PC, charger, network or other connection to work; optional ones may improve things but are never required. The C++ compiler ships inside the one app (no separate edition), with the SDK and C++ standard library; set-up optionally offers Faust libraries and starter instruments/effects ([C++ creation platform](cpp-creation-platform.md) §6).
- **Owner decision — Android compiler process (2026-11-09):** on Android the bundled Clang/LLD run as a native library hosted in a dedicated `:compiler` process, so a compiler crash cannot take down the app or its audio.
- **Owner decision — overrun protection (2026-11-09):** a component that repeatedly misses its audio time budget is bypassed with a warning and can be re-enabled.
- **Owner direction — remote compiling (2026-11-09, future):** besides required on-device offline compiling, allow optional remote compiling through a free service (the user's own GitHub Actions first; research others) or the user's own computer, reachable on the same network or over the internet. Remote-built components go through the trust choice ([C++ creation platform](cpp-creation-platform.md) §6).
- **Owner decision — Faust timing (2026-11-09):** Faust work starts only after on-device C++ building works; it then uses that same local build step. No CI-only Faust path.
- **Licensing direction:** C.A.W. is intended to be free/open source, with optional support/donation bundles of prebuilt FX, instruments, presets, samples and sounds; core capabilities are not paywalled. No paid dependency or commercial licence is assumed. **Owner decision (2026-11-09):** C.A.W. is licensed under Apache-2.0, switched from all-rights-reserved on 2026-11-09 (chosen over MIT for its explicit patent grant and because it grants no use of the C.A.W. name). AutoStacc distributes the free app and the optional support bundles. Dependencies stay permissive: no GPL/AGPL code (so no Tracktion Engine or JUCE code). This keeps the iOS App Store, closed-source SDK components and later relicensing possible. Faust's compiler (LGPL) is a build tool, not shipped code, so generated components remain eligible subject to the audit. Verify exact versions and transitive/architecture-file licences before adoption.
- **Plan ownership:** the canonical [roadmap](roadmap.md) owns sequence and status. Technical detail lives in [visual creation and signal routing](visual-routing-and-library-integration.md), [C++ creation platform](cpp-creation-platform.md) and [architecture](architecture.md). This decision is not an implementation claim.

## 2026-11-08: Native note, voice and channel processing; direct pitch-expression editing

- **Owner decision — one native processing model:** per-note, per-voice and per-channel processing are first-class capabilities across the C++ SDK, component model, instruments, synthesis, effects, routing, automation, mixer and runtime. They are not separate feature islands and must not require users to duplicate signals or build manual workarounds.
- **Preserve identity until an intentional merge:** note identity, voice identity, per-note expression, channel identity/layout and event timing remain available to components that declare they use them. A component may explicitly transform, aggregate or discard a domain, but the engine must not silently lose note expression, collapse channels or reinterpret a layout.
- **Components declare their processing scope:** whole-stream, per-channel, per-voice and per-note processing are explicit capabilities alongside typed audio, event, MIDI, control and modulation ports. Components may support more than one scope. Effects and instruments use the same contract; an effect that needs individual note/voice context receives it through the native processing model rather than a special-case workaround.
- **Native stereo synthesis is required:** instruments can generate genuinely distinct left/right signals, distribute unison voices across the stereo field, and control per-voice phase, detune, gain, pan and modulation. Stereo oscillators, stereo modulation and stereo effects are native Library/SDK building blocks, not mono duplication followed by a widening workaround.
- **Stereo is the ordinary default; channel capacity follows resources:** new tracks default to stereo. The engine supports explicit mono, stereo and arbitrary N-channel layouts, with practical capacity limited by available CPU, memory, device and host budgets rather than an arbitrary fixed product ceiling. Track layouts are independent of physical output count; any required mapping or downmix is explicit at the output boundary.
- **No hidden channel or expression loss:** incompatible layouts require a visible, declared conversion. A stereo or multichannel effect must not silently collapse to mono, and a component that cannot preserve a processing domain must make the merge/conversion explicit.
- **Piano-roll direction — MIDISketch-inspired per-note pitch curves:** pitch slides and bends should primarily be drawn and edited as continuous curves on the note itself, with the curve representing the pitch the engine actually plays. The note remains visible and editable. A separate slide event remains available where it is musically useful, but it is not required for an ordinary glide.
- **Touch editing must be direct and smooth:** users can select the pitch curve/slide they intend to edit without accidentally selecting the underlying note; move, stretch and reshape it with continuous feedback; keep the underlying note visible; and use accessible handles and helpful snapping without abrupt jumps. Visual editing, note preview and playback use the same expression data.
- **Simple by default, deep when requested:** compatible components connect and work with sensible defaults. Ordinary stereo, unison, effects, panning and pitch expression must not require obscure routing, duplicated signals or manual channel plumbing. Advanced channel maps and per-note/per-voice controls remain available without burdening basic workflows.
- **Safety remains mandatory:** richer note/voice/channel processing stays within the resource budget and real-time callback rules; preparation and allocation happen off the audio thread.
- Detailed SDK contracts and tests: [C++ creation platform](cpp-creation-platform.md). Piano-roll interaction and sequencing: [roadmap](roadmap.md#stage-1-pattern-workflow-and-editing-safety), with current UI design in [UI plan](ui-plan.md#piano-roll).

## 2026-11-06: Offline-first C++ prototype and delivery requirements

- **Owner decision — offline operation:** No part of the C.A.W. app may require an internet connection. C++ project editing, dependency resolution for already-installed packages, compilation, linking, component registration/use, project/library management, saving and project packaging must work locally. There is no required cloud compiler, remote build service, GitHub account or GitHub workflow in the user's app experience. GitHub Actions remains repository CI only; its component matrix validates the code and is not the product build path.
- **Owner decision — local toolchain:** C++ components must compile on the user's device. The exact compiler distribution, target-toolchain packaging and Android implementation remain implementation questions to prove with a working prototype; do not substitute a remote build path. Compiler modules and target SDKs should be installed/cached locally and loaded only when needed.
- **Owner decision — optional dependency acquisition:** When internet is available, C.A.W. may proactively detect missing dependencies while the user writes or opens a project and install them in the background before Build. Ship a small core plus commonly used/preinstalled packages and the C.A.W. Library; obtain less common dependencies on demand. Verify package identity/integrity and licensing, pin project versions, retain installed packages for offline use, and never silently replace a version a project relies on.
- **Owner decision — prototype first:** Prioritize a working end-to-end prototype over a comprehensive framework. Prove the smallest useful vertical slice: create/open a C++ project, edit a component, surface inexpensive errors early, compile locally without network access, register/use the result in the engine, and show actionable diagnostics. Add only architecture needed by that slice; plan future compatibility seams without building a full migration system prematurely.
- **Owner decision — build feedback and speed:** Detect syntax/semantic problems and dependency/configuration issues before expensive compilation where practical. Prepare likely dependencies while the user codes; use incremental compilation and caching so unchanged source is not rebuilt unnecessarily. Full compilation and linking remain local.
- **Owner decision — Library integration:** The C.A.W. Library should be the easiest and fastest way to use components in the engine. Built-in, Library and user C++ components share the same registration, descriptor, ports, parameter and lifecycle contracts; users should be able to add or insert a component without manually recreating its integration.
- **Owner decision — project handoff:** Current priority is REAPER-like self-contained project/build packaging, not cloud collaboration. A handoff bundle should carry the project, required source/assets, pinned dependency versions and the required dependency payloads/configuration so the recipient does not have to hunt them down. Future AutoStacc distribution/synchronization is a later direction, not a current priority.
- **Owner decision — real-time safety:** Keep audio callback work bounded and free of allocation, blocking locks/waits, file/network I/O, logging and UI calls. Prepare memory, assets and execution state before activation.
- **Owner decision — trust:** The user explicitly chooses the trust level for each native component (Blocked, Isolated or Trusted). Building or installing a component never silently changes its trust level. A build process is not runtime isolation.
- **Owner decision — resource controls:** Make CPU, memory, audio load, compilation use and other meaningful resource consumption visible. Budgets and performance recommendations should be transparent and configurable; users may override advisory limits and accept the consequences. Do not impose arbitrary hidden ceilings. Retain genuine format, representation and real-time safety requirements.
- **Owner decision — reliability and security:** Provide practical autosave/recovery and protect projects from partial writes, failed builds and unsafe updates. Verify dependency origin/integrity and record licences, but keep safeguards proportionate; do not build an elaborate package-security framework before the prototype needs it.
- **Owner decision — compatibility:** Design component contracts and project/dependency metadata with future versioning in mind, but do not implement a comprehensive compatibility/migration framework yet.
- **Scope:** These are product requirements and sequencing decisions, not claims that the local compiler, dependency manager, project packager, trust host or recovery system is already implemented.

## 2026-11-05: Ordinary C++ and one shared creation platform

- **Owner decision:** C.A.W. uses ordinary, general-purpose C++ as its programming language. It is not a music-only DSL. The user can write anything ordinary C++ permits; the C.A.W. Library/SDK provides reusable building blocks rather than restricting the language.
- **The language, Library/SDK, component model and runtime are distinct.** The SDK is a broad toolbox of useful audio, DSP, synthesis, MIDI, sample/table, math, bit-manipulation, data and general-purpose functions and algorithms. Components expose one shared descriptor and lifecycle to the native runtime.
- **Three interfaces, one source of truth:** a practical C++ code editor; typed visual scripting/composition using built-in and user-created components; and a generated/custom performance UI and mixer surface. These are not separate engines. A C++ component is implemented once and reused in all three.
- **Shared metadata:** component descriptors cover stable identity, role/capabilities, typed audio/event/MIDI/control/modulation/data ports, channel layouts, parameters, assets/tables, lifecycle, state/presets, latency/resource/real-time requirements, UI metadata and plugin capabilities. One parameter definition drives generated controls, automation, modulation, MIDI mapping and host exposure.
- **Generated UI is the default.** A valid component receives usable controls from parameter metadata without hand-authored UI. Fully custom and hybrid interfaces are optional; processing remains independent of UI.
- **Visual graphs use the native runtime.** Built-in Library functions and user C++ components become typed blocks; graphs compile/prepare into the same native execution system. No separate visual interpreter or duplicated DSP implementation.
- **MIDI is shared.** C++ components, visual graphs, on-screen performance controls and device adapters use the same MIDI 1.0/MIDI 2.0 UMP/event model, including note identity and per-note expression.
- **Extensibility without rewrites is permanent.** New algorithms, components, parameter/port types, controls, MIDI capabilities, file formats, hardware backends and plugin targets use defined interfaces, registrations and adapters. Version extension contracts and component state; avoid speculative abstraction and hot-path overhead.
- **Real-time and trust boundaries remain explicit.** C++ is unrestricted in general-purpose code, but audio-callback code must be bounded and avoid allocation, blocking, I/O, logging and UI calls. Native C++ is not sandboxed by the SDK; use explicit Isolated/Trusted/Blocked policy for native code.
- **Plugin/standalone reuse:** components are C.A.W. components first; CLAP, VST3 and standalone support are host adapters around the same processor and metadata, planned after the SDK and authoring interfaces.
- **No backwards compatibility for the old .caw language or pre-release projects (owner).** The current .caw parser/compiler/bytecode VM is transitional. Migrate useful existing capabilities to C++/Library components and verify their workflows first, then remove the old language/VM. The owner is the only user and explicitly waives old-source and pre-release-project compatibility.
- Detailed technical requirements and migration gates: [C++ creation platform](cpp-creation-platform.md). Canonical sequencing remains in [roadmap](roadmap.md).

## 2026-11-04: UI direction, the arrangement is home

- **Owner:** the arrangement is the home screen, where about 90% of a song is built, and looks like a standard DAW. Empty, nestable tracks hold **several instruments** and effects in a chosen order. Automation lanes drop down under a track, each with a parameter dropdown. MIDI clips are made in the arrangement as in Reaper, and the piano roll opens docked below. The code workspace works like Unity's, with a searchable tree of project assets and user-picked device folders. The mixer is the fine-control screen, like Reaper's. Panels dock and move like Unity's **on the phone too**, with drag and drop onto the arrangement. Motion is light and snapping smooth. Clips and track headers glow with their track's level, and this can be switched off. Track colours plus one accent. A track without clips is silent.
- **Piano roll (owner, 2026-11-04):**
  - **Snapping:** one snap switch (with a hold-to-bypass) for notes and every curve. A value grid alongside the time grid.
  - **Stretching notes:** both ends stretch, and a group stretches together. The end follows the finger, and a ghost shows the snapped length.
  - **Curves on a stretched note:** a toggle chooses whether they stretch with the note or keep their timing.
  - **What snaps:** every curve kind, including automation.
  - **Handles:** bend handles with detents, plus optional per-point Bezier handles. Bezier needs engine and format work.
  - **Freehand:** freehand strokes simplified to grid points.
  - **Toolbar:** one context-aware row: tools, the snap magnet with its grids, a middle part that changes with the selection or curve tool, and ⋮. Undo and redo are in the transport bar.
  - **Motion:** smooth, with a tiny overshoot, and distance-aware (logarithmic: longer moves go faster).
  - **Haptics:** on by default, and can be switched off.
  - **Motion setting:** Full, Reduced or Off.
  - **Quick actions bar (owner, 2026-11-04):** off by default, because it isn't very useful yet; a Settings switch turns it on.
  - **Glass (owner, 2026-11-04):** a glassy look. Real frosted blur only on floating surfaces (toolbars, menus, sheets, drag previews, the transport), because blur is costly on a phone when many panels redraw. Docked panels get a cheap glass look with no blur: a translucent tint, a soft top highlight and a thin bright edge. A Glass switch in Settings, on by default; the Lightweight and Minimal profiles turn it off. Then (owner, same day): an ambient background instead of a flat two-tone look, glass track headers and clips, sheets that slide in as frosted glass, and sliders, bars and toggles with a light see-through fill and a solid outline. Later the same day (owner): glass must look good without blur, so a Frosted blur switch turns the blur off and keeps the glass look, and the Lightweight profile keeps glass without blur (only Minimal turns glass off). Thin outlines; slider knobs fake their transparency (opaque, mixed into the panel colour) so the track never shows through. The arrangement gets an adjustable gap between tracks and spacer rows that only separate tracks on screen.
  - **Detail:** [UI plan](ui-plan.md#piano-roll).
- **Arrangement (owner, 2026-11-04):**
  - **Layout:** the same context-aware toolbar row as the roll, with Select, Draw, Split and Erase. Compact track headers that widen to show volume, pan and the chain.
  - **Nesting:** by dragging onto a track, or Group. Any track can be a parent and still play, which needs engine work.
  - **Clips:** Draw makes clips (tap = the last length). The right edge repeats by default, and a handle switches it to extend. Split cuts under the finger.
  - **Selecting:** box, time range and tap on a header.
  - **Ruler:** playhead, loop region, markers, follow.
  - **Zoom and drag:** pinch both ways. Drag and drop adds instruments, effects (always to the track's chain), patterns and new tracks.
  - **Glow:** subtle and adjustable.
  - **Detail:** [UI plan](ui-plan.md#arrangement-home).
- **Piano roll, hearing and drawing (owner, 2026-11-04):**
  - **Hearing (2026-11-05):** a note plays while it is placed, moved, held or bent, through its track's instrument and effects at the track's volume and pan (mute and solo apply), on top of playback too, at the note's velocity. A tapped-in note plays its own length; a held or dragged note sounds until the finger lifts. A pitch change ends the old note before the new one starts; a move in time only doesn't retrigger. A selection plays its opening chord (the notes that start first). While a bend is edited the note follows the pitch at the edited point of the curve. "Hear notes" in ⋮ turns previews off. Claude built the note on/off C API for it (#103).
  - **Drawing:** drawing stays as today, plus the confirmed quality-of-life tweaks.
  - **Extras:** scale highlight, snap to scale and ghost notes.
- **Code workspace (owner, 2026-11-04):**
  - **Tree:** project assets plus picked device folders, showing C.A.W-related files.
  - **Search and files:** search covers names, tags and contents. Files support new, rename, duplicate, trash, drag to move, drag onto the arrangement, favourites and tags.
  - **Tabs and running:** tabs with autosave for project files. Code runs automatically after a pause, plus Run.
  - **Editor:** inline errors, hover docs, find and replace, go to definition, multi-cursor, folding, snippets and format.
  - **Side panels:** Controls, Problems, Scope and Library.
  - **Detail:** [UI plan](ui-plan.md#code-workspace).
- **Startup and engine changes (owner, 2026-11-04):**
  - **Startup:** the app opens straight into the last project's arrangement. New, template and open move to the project menu, replacing the 2026-10-28 startup screen.
  - **Small engine changes:** Claude makes those the UI needs, such as the note on/off call.
  - **Large engine changes:** these wait for GPT: several instruments per track, parent tracks with sound, and Bezier curves.
- **Why:** the owner wants one place to build a song that feels like a real DAW and good to use. The plan, today's findings and the open questions are in [UI plan](ui-plan.md).
- **Consequences:** several instruments per track and silent empty tracks change the engine and project model. The engine part goes to GPT as an issue, and the UI waits for it where it must.

## 2026-11-04: F7 resource budgets (owner, after the caps audit)

- **The app keeps everything the engine keeps.** The app-only caps go (automation points past 128 and project lanes past 256 dropped on load, patterns at 4,096 notes/steps and 16 curve points, notes dropped on paste); any bound that stays is a clear error, never a silent drop. The owner allowed app/ changes for this.
- **The 64-bar arrangement limit is removed** in the engine and the app: length is bounded only by the step representation and the project JSON budget, and nothing is moved or shortened.
- **Layers become dynamic:** the count is bounded by the memory budget, and the mix graph is re-prepared off the audio thread and swapped in when more slots are needed.
- **Safety bounds come from the hardware budget:** module source, nesting, registers, per-module state, queues, workers and MIDI file limits get defaults derived from `EngineResourceBudget`/the hardware profile, overridable by the host within a safety ceiling, and every one fails with a clear message.
- **F7.2 rules (Claude, within the owner's choice):** an out-of-range song position (loop bars, clip, layer length, automation point, audition) is refused with a message naming it, since clamping would move or shorten it; values past the 32-bit step count are pulled inside it only when the app loads a file, as the representation limit. Clip expansion counts toward the project-state budget and is checked, with room for the build's peak, before it is built. Loop and free exports stream to the file so their memory doesn't grow with the song (a free-RAM check would refuse the same export on one try and allow it on the next); a render longer than a WAV file holds is refused before rendering, not cut short. Automation editors reach the song's end, and at least 64 bars, so new points have room.
- **F7.3 plan (Claude, after an architect review):** three steps. A: slot capacity becomes a runtime value (slots held by pointer with a stored index, a capacity-sized mix graph, the order list sent out of line), still 64 layers, with identical sound. B: the Engine grows its slot table and mix graph off the audio thread and swaps them in by command, geometrically, never shrinking, bounded by the graph-working budget with a clear error, and the parser's 64-layer cap goes. C: the app's layer caps go. Done in B, because a grow moves the audition's slot: `scope()` takes ids for the master (-1) and the audition (-2), `CAW_SCOPE_MASTER`/`CAW_SCOPE_AUDITION` in the C API (no backwards compatibility needed, owner 2026-11-03). B's ceiling counts both graphs a grow holds at once.
- **Unfinished work goes to Main (owner, 2026-11-04):** F7.3 part B was merged with the audio review's findings still open, rather than held on a branch. The open items are recorded where the work stands (`engine-build-status.md`) and in #94. From the same date GPT does the remaining engine work (#94, F7.3 part C, F7.4, F8, F10) and Claude plans the UI; the owner said not to build UI yet.
- **Split:** F7.1 app caps; F7.2 the 64-bar limit; F7.3 dynamic layers; F7.4 safety bounds from the budget; the silent engine clamps (render lengths, unison, wavetable frames, splits, take-over) are reported or removed in the step that owns them.

## 2026-11-04: F6 parameter model: resolution order and owner choices

- **Owner choices (2026-11-04):**
  - A manual change while automation exists is a *touch*: the manual value wins until playback restarts, then the lane rules again.
  - Modulation depth is a fraction of the parameter's range on its curve (normalized 0..1), the same for every parameter.
  - A mapped MIDI CC sets the base like a knob, jumping straight to the controller's value. Soft takeover can come later.
  - Native SDK modules keep one value per block, the block's first frame, so the ABI does not change. Built-in and .caw modules get per-frame values when a parameter varies.
- **Resolution order (after an architect review).** Each frame resolves in this order:
  1. Base: automation, unless touched; otherwise the manual or MIDI value, smoothed linearly over `smoothingFrames` (at most 2^20) from the value last resolved, so touching during automation starts from what was playing.
  2. A link without a signal (disconnected, bypassed) is skipped. With no link carrying a signal, the base is only clamped and stepped, so plain values pass bit for bit, as on the Engine's automation path.
  3. Otherwise: normalize, apply the links in ascending link id (never graph or UI order), clamp to 0..1, denormalize, clamp and step.

  Links are `ModulationOp` Add, Multiply, Min, Max or Replace, each blended from the current value toward its target by depth (−1..1), at most 8 per parameter. A NaN or inf sample from a connected source reads 0. Exponential curves use `detLog`/`detExp` and their endpoints are exact. A block with nothing varying is one constant, which keeps stereo playback cheap.
- **F6.2 executor rules (after the audio review).** prepare() starts every parameter at its default, so a rebuild restores kept values with `setInitialParameter` (no ramp, no touch), never through the queue. The command queue (256) refuses when full rather than blocking, so the sender resends the latest value. A touch reset is one epoch step, whatever the graph size. `smoothingFrames` counts frames at the graph's rate; scaling it by sample rate is still open (see the F6.6 rules).
- **F6.4 automation lane rules.** The graph and the Engine read lanes through one function (`automationLaneValue`), so their values are bit-identical, seeks included. Lane points are borrowed and set while audio is stopped; the transport (position, samples per step, playing) is set on the audio thread and advances by each block's frames. A lane plays only while the transport plays and the parameter is untouched. When the lane stops, the parameter holds the last value played, rather than jumping back to the old manual value: the reliable choice, with no click on stop.
- **F6.5 CC mapping rules.** A CC's value (v / 127, or v / 0xFFFFFFFF for MIDI 2.0) is a position on the parameter's curve (denormalized), so a CC sweeps an exponential parameter like its knob does. One CC per parameter keeps the base unambiguous; one CC may drive several parameters. CCs take effect at their own frame (the block is resolved in segments), and come only from the graph's host events, never from other nodes' event outputs. Soft takeover is still later. **Open (owner):** a MIDI 1.0 CC scales as v / 127, so 64 is 0.504, not the exact centre a MIDI 2.0 0x80000000 gives; the MIDI 2.0 min-centre-max upscaling would make the two agree if bipolar parameters need an exact centre.
- **F6.6 Engine rules (after the audio review).** A .caw param's held value is its manual base. A touch is a knob move only (`setParam`/`setGlobal`): a project update that rewrites held values is a restore, never a touch, so the result doesn't depend on whether a module was recompiled. Play ends touches, including knob moves made while stopped, and a rebuilt chain (a code edit) keeps the touches made since the last Play. Non-finite param numbers are a compile error. Held values are stepped like any base, which leaves values already on the grid (every golden render) bit-identical. .caw params have no smoothing, so the Engine can resolve a module more than once per chunk (lanes, the swap shadow). Whether `smoothingFrames` should count time instead of frames stays open until a smoothed parameter reaches the Engine.
- **Split:**
  - F6.1: resolver and descriptor fields (curve, step, smoothing, unit).
  - F6.2: values to processors through the executor.
  - F6.3: modulation links.
  - F6.4: automation lanes.
  - F6.5: MIDI CC mappings.
  - F6.6: the Engine's .caw params and globals move onto the resolver, with golden hashes unchanged.

## 2026-11-04: F5.2 event ports in the graph executor

- **Event format (owner).** A C.A.W event with a stable note id: `{frame, kind, flags, noteId, data[4]}` (28 bytes). `data` carries the raw MIDI 2.0 UMP words, so MIDI 1.0/2.0 convert at the edges without loss. Chosen over raw UMP alone, which cannot tell two overlapping notes of the same pitch apart. The executor never interprets kind, flags, note id or data.
- **Bounded per block.** Each event output and each merging input holds `GraphResourceBudget::maxEventsPerPort` events (default 1024, counted in the working-memory budget). A summing event input merges its sources by frame, ties in connection order, keeps the earliest events and counts the rest (`eventsDropped()`). A processor's output must be in frame order and in range or the block fails, so later nodes never misread it.
- **Host events** go to each node's first unconnected event input, like host audio; dynamic routing stays audio-only.

## 2026-11-04: F5.1 typed ports in the graph executor

- **Port semantics (after an architect review).** Modulation is one float per frame and may sum like a mix bus; control is one value per block, takes one source, reads its port default when unconnected and holds its last value, saturated after each block like routing (NaN reads 0) so a bad value never latches. Only a node's first audio input reads the host input; other audio inputs (sidechains) and modulation read silence when unconnected. No type is ever converted implicitly: a follower or converter is its own node.
- **Typed nodes are checked at prepare.** A processor with more than one audio port or any other port opts in with `usesProcessPorts()`; otherwise `prepare()` fails, so a correct-looking graph never fails on its first block. One-in/one-out audio nodes keep the old call (callgrind: playback +0.05–0.09%).
- **Parameters are not ports.** F6 decides how a port binds to a parameter (base value plus modulation); F5 does not settle it.

## 2026-11-04: F4.4, every track module is a graph node

- **Done now, with float edges (owner).** Asked whether to split tracks into module nodes now or with parallel effects (2.3), the owner chose now, with 32-bit float edges between modules (the F4.2 rule). Each module's output rounds to float, so 9 template and 8 mixer golden hashes were re-recorded. **[Fact, 2026-11-04]** The old engine with only that rounding added renders the new hashes bit for bit, including new effect-chain, seam, pattern and code-swap cases; 24-bit renders differ from before by at most 1 LSB.
- **A track has 32 module nodes.** The mix graph is prepared once, at Engine construction, so each slot gets a fixed set of module nodes; a longer chain is refused with a layer error, never cut short. F7 may replace the number with a budget.
- **Seams and code swaps run as lanes, not extra graph shapes.** Module edges carry three lanes (current chain, seam shadow, replaced chain), and chunks end at each playing track's loop restarts and swap points, so every node runs whole segments and the order of state hand-overs stays as before.

## 2026-11-03: Seeded randomness everywhere, per project and per module

- **Every random source is seeded (owner).** Any randomness in `.caw` modules, built-in nodes and native plugins comes from a seed, so the same project gives the same result every time. **[Fact, 2026-11-03]** `.caw` already works this way for `rand`, `randi`, `hash`, `noise` and pattern note probability, all from the single project seed; there is no per-module seed, and the component C interface v2 (`caw_component.h`, 2026-11-09) passes components no seed and offers no random source yet (a seed would be a host extension).
- **Per-module seeds follow the project unless pinned (owner).** By default a module's seed is derived from the project seed with a per-module offset, so modules differ but all move when the project seed changes. A module can be pinned to its own seed, which then ignores project seed changes.
- **Seeding can be switched off per module or per project (owner).** Off means fresh randomness on each play or export.
- **[Proposal]** When seeding is off, the seed actually used is still recorded (shown and saved with each export), so a take you like can be pinned and reproduced; exports with seeding on stay bit-identical across platforms.
- **Open:** giving native plugins a seed needs a native SDK ABI change, which the owner approves when that step is built (roadmap F10).

## 2026-11-03: Reliability over old-engine compatibility

- **The old engine's sound and behavior carry no weight (owner).** The goal is the most reliable engine possible. There is no need to reproduce how the pre-Foundation engine sounded or worked, and no support for its quirks.
- **Golden hashes guard determinism and regressions, not the old sound.** Same source and settings must still give the same bits on every platform and every run. When an intended engine change alters output, the pull request re-records the hashes and states why, with a measurement; it does not need the owner's approval first. This replaces the earlier rule that every golden-hash change goes to the owner.
- **Unchanged:** exports bit-identical across platforms; a real-time-safe callback; tests never weakened; bug fixes start with a failing test; the owner is asked before native SDK ABI changes and new dependencies.

## 2026-11-03: Merging, and no project compatibility before Release 1

- **Claude may merge (owner).** Claude may merge its own pull requests, including the #28 engine branch into `Main`, when CI is green and nothing breaks. The no-merge rule is for the chat-agent (GPT) route. Flow: each Foundation item reaches `Main` once its CI is green. Until 2026-11-03 that went through `feature/native-engine-refactor-integration`; that branch merged fully into `Main` in PR #73 and was then deleted by the repository's delete-on-merge setting, so Foundation pull requests now target `Main` directly.
- **No backwards compatibility before Release 1 (owner).** The app hasn't shipped and the owner, its only user, has no projects to keep, so older project files need not keep opening. The project file format stays at version 2; real versioning starts at Release 1, once adding features no longer needs core rework. Roadmap F9 (migrations) moves to before Release 1 (R.7), and Foundation changes to the project model need no migration. Changes to the project file are still listed in each pull request.
- **F4 precision: float graph edges, golden hashes re-recorded once (owner).** The live mixer sums tracks, folder buses and the master in 64-bit `double`, while graph audio edges are 32-bit float. Measured on 2026-11-03: rounding each track's output to float where it enters a bus or the master changes 10 of the 12 golden hashes (rounding of about 1e-7, inaudible). The owner chose to keep float edges and re-record those hashes once, in F4.2, where the old mixer is changed to round at exactly the points the graph will. F4.3 (the graph runs playback) reproduces the F4.2 hashes bit-for-bit. Later golden-hash changes follow the 2026-11-03 "reliability over old-engine compatibility" entry above.

## 2026-11-03: Roadmap order, first release and per-item tables

- **Goal restated (owner):** C.A.W. is not trying to be a conventional DAW and needn't work like one, but it must be able to do everything a good DAW can do, because there is no good DAW for mobile. This replaces the older "lightweight DAW in a pinch, no full feature parity" wording in `architecture.md`. The goal is stated in [vision](vision.md).
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

## 2026-11-02: Prepared project snapshots are the project-publication unit

- Build the complete project runtime on a control/worker thread as one owned prepared snapshot: module instances, VM chains, graph topology, routing, buffers, schedules, parameters, automation, event storage and a bounded state-migration plan.
- Publish one pending snapshot atomically and let the audio callback adopt it only at a block boundary. The callback must not allocate, lock, compile, wait for workers or call the UI.
- Keep the active snapshot alive while it is processed; retire superseded snapshots through preallocated/intrusive retirement records and reclaim them only on a control thread. Replacing an unconsumed pending snapshot must be safe and must not leak.
- Treat project replacement as a transaction. Do not send hundreds of independent layer-install commands that can partially apply when the fixed command queue fills. Keep any remaining live-control queue bounded, coalesced where appropriate, and report overflow to the caller.
- Prepare migration metadata off-thread. Apply only bounded, preallocated state-transfer work at safe block boundaries; if a migration cannot fit the configured real-time budget, defer activation or return an actionable error rather than blocking or silently resetting state.
- This is the target M1 architecture; it is a decision, not a claim that the current Engine already implements it. The current command queue can drop installs after its timeout, the retirement pending list can leak on overflow, and slot exhaustion can skip a layer.

## 2026-11-02: Reopen and complete native engine integration

- The owner explicitly authorizes the full native engine refactor and integration, superseding the earlier note that graph-to-Engine integration was paused.
- Start from the verified native-engine-foundation branch history, but integrate into the existing Engine/VM/mixer. Do not create a second engine or stop at interfaces and documentation.
- Keep the permanent engine blueprint, milestone ledger and recovery guide current; one coherent review PR is the delivery target.
- The graph compiler must not impose arbitrary node/connection/block caps. Resource limits must reflect actual memory, hardware and host safety budgets, with explicit errors and no silent content loss.


## 2026-11-02: Adaptive concurrency and batching

- Concurrency and batching are foundational capabilities, selected automatically according to graph dependencies, workload size, deadlines and available hardware.
- Parallelize independent work across graph branches, tracks, voices, channels and offline tasks where it yields a net benefit; batch compatible operations and use SIMD/accelerators when transfer and setup costs justify them.
- Avoid arbitrary thread counts and unconditional parallelism. Use bounded worker pools, adaptive task granularity, serial fast paths and controls against oversubscription.
- Preserve sample accuracy, deterministic semantics where required, audio deadlines and stable fallbacks. The audio callback must not block waiting for workers or accelerators.
- Optimize measured end-to-end performance, including scheduling, synchronization, memory movement, power and worst-case deadline margin—not just throughput or thread utilization.
- Full requirements: [Native engine refactor, Section 17](engine-next.md#17-adaptive-concurrency-batching-and-minimum-overhead-execution).

## 2026-11-02: Universal creative capability and routing

- The engine must make any technically realizable music/audio idea straightforward to create and combine; standard workflows are defaults, not creative limits.
- Use a universal typed multi-domain graph for audio, multichannel streams, sidechains, control/modulation, MIDI 1.0/2.0, notes, per-note expression, transport and timestamped events. Support cross-domain routing and explicit feedback/delay boundaries.
- Sidechain is first-class and can accept any compatible source, including audio, buses, tracks, external inputs, MIDI/events, envelopes and control signals. It must work across channels, processors and buses through the shared routing model.
- Avoid arbitrary fixed caps on project objects or graph complexity. Real constraints are available resources, platform/format requirements and explicit safety budgets. Surface unavoidable limits and never silently truncate.
- Make resource budgets configurable within host safety policy; enforce real-time bounded work, isolation, diagnostics, graceful bypass/recovery and clear failure reporting.
- Keep common workflows simple and fast while providing advanced extension interfaces for unusual processing, routing and execution models.
- Full requirements: [Native engine refactor, Section 16](engine-next.md#16-universal-creative-capability-safe-extensibility-and-unrestricted-composition).

## 2026-11-02: Safe extensibility for unconventional engine behavior

- The standard engine path is the efficient default, not a creative limitation. Developers must be able to build unusual generators, processors, effects, routing, modulation, synthesis and execution behaviors through explicit extension points.
- Provide composable standard interfaces and advanced interfaces where a generic abstraction would constrain a technique or add unnecessary overhead.
- Extensions declare capabilities, channel/event types, latency, resource needs, state and real-time requirements; validate and prepare them before activation.
- Protect the audio thread with bounded work, preallocated resources, defined failure/bypass/recovery behavior and clear isolation boundaries. In-process native extensions are trusted, not sandboxed; sandboxed VM modules remain constrained.
- Version extension APIs and state, preserve project compatibility through migration/capability negotiation, and isolate experimental interfaces from stable core contracts.
- Full requirements and verification are in [Native engine refactor](engine-next.md#16-safe-extensibility-and-deliberate-departures-from-standard-engine-behavior).

## 2026-11-02: Unified parameter, modulation and mathematical processing model

- Manual controls, project automation and internal/hidden modulation must use one shared parameter model across instruments, effects, tracks, buses, native modules and the .caw VM.
- Parameters may be exposed as simple user controls or remain internal; advanced modulation must not clutter ordinary workflows, and every exposed parameter should remain manually controllable.
- Support conventional automation, MIDI/controller input, macros, envelopes, LFOs, note expression, modulation links and sidechain/audio-following sources where available.
- Define explicit, deterministic source-combination, precedence, scaling, clamping and smoothing rules. Evaluate sample-accurately only where required; use block/control-rate processing where it preserves behavior and saves work.
- Mathematical expressions are first-class generators, waveform sources, modulation/control sources and audio effects, with bounded sandboxed execution and the existing .caw VM retained.
- Keep the cheapest correct path: constants stay constant, shared modulation is computed once where possible, and tables/precomputation are used only when worthwhile with a correct fallback.
- Detailed requirements and tests are in [Native engine refactor](engine-next.md#15-unified-parameters-modulation-automation-and-mathematical-modules).

## 2026-11-01: Native engine refactor and efficiency-first architecture

- The next major engine work is a refactor and integration of the existing CAW engine, not a ground-up rewrite or a parallel engine.
- Use proven professional audio-engine foundations and integrate the existing VM, synth, mixer, automation, renderer, typed module/graph and adaptive execution work into one coherent system.
- Avoid unnecessary work and complexity. Use the simplest correct implementation, and introduce additional processing only when requirements justify it.
- Prefer efficient mathematical/procedural DSP for suitable operations; use tables, wavetables, caches and precomputation when repeated work makes them worthwhile and memory permits. Keep the normal calculation path as a safe fallback.
- Detect and use compatible CPU, SIMD, GPU, memory, audio-device, connected-device, power and thermal capabilities when they provide a measured benefit. Keep portable implementations and safe fallbacks; optional hardware must never be required for project correctness.
- Evaluate existing permissively licensed/commercially usable libraries and proven algorithms before writing replacements. No GPL/AGPL, revenue-capped or commercial-only dependency without an explicit owner exception. Review exact versions and transitive licences and record every adopted dependency.
- Keep stereo as the efficient default while making the architecture capable of explicit mono and future multichannel processing.
- Preserve existing projects, modules, sound semantics, deterministic behavior, real-time callback invariants and live/offline render parity.
- The detailed technical plan is [Native engine refactor](engine-next.md). The canonical sequencing is [Roadmap](roadmap.md).

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


## 2026-11-02: Graph compile and preparation require an explicit working-memory budget

- Graph compilation and prepared execution require a non-zero GraphResourceBudget.maxWorkingBytes; the API does not silently choose an arbitrary fixed node or connection cap.
- Optional maxNodes and maxConnections ceilings default to the representational maximum and may be set by host policy when a specific count ceiling is justified.
- Preflight estimates cover internal compiler temporaries and prepared executor buffers; caller-owned graph input and processor instances are excluded. The estimate is a preflight guard, not a replacement for handling allocator failure, which remains a distinct OutOfMemory result.
- The active Engine must eventually derive this budget from the hardware-aware EngineResourceBudget and pass it when preparing the graph. Until that integration exists, the graph API is budget-safe only when callers supply a realistic budget.
- This is implemented in code commit 07c796f8 and passed Engine, App and Docs CI at checkpoint 1269019. Follow-up commit e815b495 adds direct compiler-budget rejection coverage and awaits CI.

## 2026-11-02 — Effect-chain length is resource-governed, not a fixed product cap

Project layers and synth patches may describe dynamically sized module/effect chains. Parsing and engine preparation must preserve every authored chain element; no silent truncation or arbitrary eight-effect ceiling is allowed. Memory and processing costs are handled by explicit host resource budgets and clear preparation errors. This change does not remove unrelated limits such as the current project layer-slot model or export-buffer capacity; those remain separate integration work.


## 2026-11-06: Native C++ effects in playback (updated 2026-11-09)

**Implementation decision:** explicitly loaded stereo C++ effects run in two kinds of project-owned chain: a track's (`components` on a layer) and the master's (`master_components`), each entry an id or `{"id", "params"}`. A track's chain runs after its .caw modules, whose mono output enters as two equal channels, and before volume and pan; what the effects make of it stays stereo, and the pan law then works per side. The master's runs before the safety limiter, which stays last. Components between .caw modules wait for the dual-mono rule (#17). Folder buses take no components yet.

- One type, `ComponentChain`, serves both. It is built and activated on the control thread before anything is sent, so a component that is not loaded, has other ports or names a parameter it lacks refuses the whole update. An update with the same components in the same order keeps the chain, and its running state (a reverb's tail), and only sets values; any other change rebuilds it.
- Native effects without a tail start each play from silence (reset on Stop, and when a silent track sounds again), and a kept chain takes the project's values with the rest at their defaults, so playback matches a fresh render (export). A project runs at most 256 native component instances. Adding, removing or reordering a component still rebuilds the whole chain without a crossfade (follow-up in #137).
- Parameter values ramp through the F6 resolver. `caw_engine_set_component_param` changes one while playing; the app stores it in the project too. Project automation lanes drive component parameters too (`target_type: component`).

- A successful build never loads or authorizes code. The caller must pass an explicit Blocked, Isolated or Trusted value to the Engine C API; Blocked refuses before opening the library, Isolated is rejected until a real separate-process host exists, and Trusted runs in-process.
- Trust is not serialized into the portable project. The project stores component IDs, order and values only; each user/device must make its own trust decision before the component can be used.
- The audio callback uses fixed preallocated stereo stages, performs no host allocation or locking, sanitizes output and publishes/retires master chains through the existing command/retirement path. Component code itself must obey the real-time contract.
- The known scratch and chain-pointer storage is included in Engine budgets. ABI v1 does not report component-private heap/state size; that remains an explicit measurement gap.
- Next (issue #137): the Android-hosted compiler, the per-component trust UI/store and the in-app C++ editor.
