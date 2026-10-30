---
title: How it works
summary: The path a sound takes from a .caw file to the speaker and to a WAV, the file that owns each step, and where to make each kind of change.
covers: [engine/src/compile.h, engine/src/vm.h, engine/src/engine.h, engine/src/capi.cpp, engine/src/builtins.cpp, app/lib/engine/engine.dart, app/lib/model/app_state.dart]
updated: 2026-10-30
---

# How it works

The map for an agent new to the repo. It shows how the parts connect; the details live in [engine](engine.md) (language, playback, C API), [app](app.md) (screens) and [agent guide](agent-guide.md) (writing modules). Every source file starts with a one-line comment saying what it is for, and `.claude/tools/tree.sh <dir>` lists them. The app's areas are called Sounds, Tracks and Export on screen, and `builder`, `arranger` and `exporter` in code (`app/lib/ui/builder_screen.dart`, `arranger_screen.dart`, `exporter_screen.dart`).

## From a keystroke to sound

1. **Text.** A module is plain `.caw` text: a header, then code ([engine](engine.md#module-files-caw)). In the app it is `ModuleDoc.source` (`app/lib/model/project.dart`). The piano roll edits pattern text through `app/lib/model/pattern_doc.dart`, so a pattern is still text.
2. **Edit to project JSON.** `AppState.editSource` (`app/lib/model/app_state.dart`) stores the text. On Run, or auto-update after a pause, the text becomes the module's `run_source`. `_syncNow` turns the whole project into the engine's project JSON (`Project.toEngineJson`) and sends it.
3. **Off the UI thread.** `Engine.setProject` (`app/lib/engine/engine.dart`) runs on a worker isolate, one call at a time, through the hand-written FFI bindings in `app/lib/engine/bindings.dart`.
4. **C API.** `caw_engine_set_project` (`engine/src/capi.cpp`) hands the JSON to `Engine::setProjectJson` (`engine/src/engine.h`). `engine/include/caw.h` is the only door into the engine, for the app, the CLI's tests and any future plugin.
5. **Parse and diff.** `parseProject` (`engine/src/project.cpp`) clamps every value. The engine compares the new project with the running one and only compiles the modules whose code changed.
6. **Compile.** A synth patch (`kind: synth`) is first translated to ordinary code by `translateSynth` (`engine/src/synth.cpp`): one generator for the voice and effect modules for its `fx` lines, which the engine runs after the voices as hidden modules (`ModuleState::expand`). `compileModule` (`engine/src/compile.cpp`) reads the header, lexes and parses in one pass, and emits register bytecode (`Program`, `engine/src/program.h`), folding constants with the same operator code the VM uses (`engine/src/ops.h`). Pattern modules go to `parsePattern` (`engine/src/pattern.cpp`) instead. Errors come back as one line with a position, and the old program keeps playing.
7. **Hand-over.** The compiled program reaches the audio thread through the lock-free queue in `engine/src/spsc.h`. Retired programs come back the same way to be freed off the audio thread.
8. **Audio callback.** miniaudio (`engine/platform/audio_miniaudio.cpp`) calls `Engine::process`. For each layer in dependency order, the generator's `Instance::process` (`engine/src/vm.cpp`) runs every op over a whole block, then the effects run on its output. Pattern layers run the generator once per voice, with `note`, `gate` and the rest set per note. Then the mix, pan, the DC blocker and the limiter.
9. **Built-ins.** Every function a module calls is a row in `kBuiltins` (`engine/src/builtins.cpp`): its code, its state size and its docs. Library modules in `engine/lib/*.caw` are written in the module language and compiled in.
10. **Back to the screen.** The app reads meters and scopes through `caw_engine_meters`, `caw_engine_layer_meter` and `caw_engine_scope`, polled by `app/lib/model/poller.dart` only while something can change.

`AppState` also owns transport timing. Tap Tempo keeps up to five increasing tap timestamps, starts a new measurement after a pause longer than two seconds, averages the intervals and clamps the resulting project tempo to 20–400 BPM. The project update then follows the normal sync and save path.

## Export

`caw_render` (`engine/src/render.cpp`) drives the same `Engine` offline, so a file matches what was heard bit for bit, and writes it with `engine/src/wav.cpp`. The app runs it on a worker isolate with progress and cancel (the Export area). The CLI (`engine/cli/main.cpp`) uses the same calls.

## Where to change what

| To change | Edit | Then |
| --- | --- | --- |
| Add or change a built-in function | `engine/src/builtins.cpp` (and `builtins.h` for a new kind) | `caw docs` to regenerate [library](library.md) and [agent guide](agent-guide.md); `caw_tests` |
| The synth's patch lines and the code they become | `engine/src/synth.cpp` | [synth](synth.md); `synth_test.cpp`; `caw check --code` |
| Add a built-in wavetable shape | `engine/src/tables.cpp` (and its `table.*` name in `builtins.cpp`) | `caw docs`; `synth_test.cpp` |
| Add a library function in the language | `engine/lib/*.caw` with `///` docs | `caw docs`; `caw_tests` |
| Language syntax (statements, params, operators) | `engine/src/compile.cpp`, `ops.h` for operators | [engine](engine.md) language section; `language_test.cpp` or `variables_test.cpp` |
| Pattern text format | `engine/src/pattern.cpp` and the app's `app/lib/model/pattern_doc.dart`, which must agree | `pattern_test.cpp`, `app/test/pattern_doc_test.dart` |
| Playback, mixing, voices, hot swap | `engine/src/engine.cpp` (real-time rules: `.claude/rules/engine.md`) | `engine_test.cpp`; ask `audio-reviewer` |
| A new C API call | `engine/include/caw.h`, `engine/src/capi.cpp`, `app/lib/engine/bindings.dart`, `app/lib/engine/engine.dart` | [engine](engine.md#c-api-engineincludecawh) |
| Something the app keeps (projects, settings) | `app/lib/model/` | [app](app.md) |
| A screen | `app/lib/ui/<screen>.dart`; a new command also gets an action in `app/lib/actions/catalogue.dart` | [app](app.md), [actions](actions.md) |
| A starter module | `examples/*.caw` | `caw_tests --update-golden` only for an intended sound change |

## Checks

- Engine: build with CMake and run `caw_tests` ([engine](engine.md#tests)); `caw check FILE.caw` and `caw render` check a module without listening.
- App: `flutter analyze` and `flutter test` in `app/`; `CAW_LIB=<built libcaw.so>` adds the tests that need the engine.
- Docs: `node scripts/docs-test.js`.
