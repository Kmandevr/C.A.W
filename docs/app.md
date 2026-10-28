---
title: App
summary: The built Flutter app: its three areas, how it talks to the engine, where projects are saved, and how CI builds and signs it.
covers: [app/]
updated: 2026-10-28
---

# App

The Flutter app in `app/`, as built for v1. The engine it drives is described in [engine](engine.md), and v1's scope is in [roadmap](roadmap.md). Everything here is **[Fact]**, checked in the code and by its tests.

## Areas

- **Top bar:**
  - the crow mark
  - the project name, which opens the project menu: rename, new, duplicate, open and delete
  - BPM, beat and CPU readouts
  - Play/Stop (the space bar on desktop)
- **Builder** (`lib/ui/builder_screen.dart`):
  - a row of module chips, and **New** to start from a template
  - a code editor with highlighting and the symbol key row
  - a one-line status: the error (tap it to jump to the spot), "edited, tap Run", or the module's summary
  - a scope and a slider for every `param`
  - **Run** (Ctrl+Enter) sends the code and hot-swaps it. Code that fails keeps the old sound and puts the cursor on the error
  - **Solo preview** plays only this module. An effect is heard through the generator of a layer that uses it, or the project's first generator
- **Arranger** (`lib/ui/arranger_screen.dart`):
  - project settings: BPM with −/+ and tap, time signature 2/4 to 7/4, loop length of 1–16 bars, key, hex seed, master volume and the seam crossfade switch
  - the loop stack, where each layer has a colour, name, generator, length (from 1 beat to 16 bars, or following the project), an effect chain, volume, pan, M/S, a progress bar and a peak meter
  - a banner when the engine muted layers to keep audio clean, with Unmute
- **Exporter** (`lib/ui/exporter_screen.dart`):
  - the four exports from [engine](engine.md#exports), at 44.1 or 48 kHz, 24-bit or 32-bit float
  - progress and cancel while it renders
  - then the system file picker saves the file
- **Layout:** phones get a bottom navigation bar. Screens at least 900 px wide get a side rail, and the Builder shows code and params side by side. Ctrl+1/2/3 switch areas.
- **Key:** stored and shown with the project. In v1 nothing uses it yet; note helpers that follow it are v2.

## How it works

- **Engine access:** `lib/engine/bindings.dart` binds the C API by hand. `lib/engine/engine.dart` wraps it:
  - Project updates and exports run on worker isolates, so compiling never blocks the UI. Updates run one at a time, in order.
  - Meters and scopes are read about 30 times a second by a ticker.
  - Volume, pan, mute, solo and param changes go straight to the engine. Everything else re-sends the project, and the engine applies only what changed.
- **Model:** `lib/model/project.dart` holds the project.
  - Each module keeps its editor text (`source`) and the code last run (`run_source`). The engine only ever gets the code last run, so other edits never compile half-typed code.
  - The app's file format adds colours, the key and per-layer generator and effect fields to the engine's project JSON.
- **Storage:** projects are JSON files in the app's private support folder, under `projects/`. They're written 0.5 s after each change, and right away when the app goes to the background or quits. The app reopens the last project.
- **Audio:** the device opens at start-up (48 kHz stereo, low-latency profile). When the app goes to the background while stopped, it closes the device, and it reopens it on return. Playing on in the background (an Android foreground service) is not in v1.
- **First run:** the app creates "First loop" from the templates. It has Kick, Bass and Hats layers of 1 bar each and a 3-bar Byte lead with Bitcrush over a 4-bar loop at 140 BPM.

## Build

- **Flutter:** 3.47.7, pinned in `.github/workflows/app.yml`.
- **Dependencies, all permissive:**
  - `ffi` 2.2.0 (BSD-3-Clause)
  - `path_provider` 2.1.6 (BSD-3-Clause)
  - `file_picker` 13.1.0 (MIT)
- **Android:** `android/app/build.gradle.kts` builds `engine/CMakeLists.txt` into `libcaw.so` for arm64-v8a and x86_64, with `minSdk` 26.
  - The application id is `com.kmandevr.caw`. It becomes permanent once a release is installed, because updates only install over the same id and key.
- **Windows and Linux:** `windows/CMakeLists.txt` and `linux/CMakeLists.txt` add the engine and bundle `caw.dll` or `libcaw.so` next to the app. The Linux folder is for local testing; it isn't shipped in v1.
- **CI** (`.github/workflows/app.yml`) runs on changes to `app/`, `engine/` or `examples/`, or on demand:
  - `flutter analyze` and `flutter test` against a Linux build of the engine
  - the release APK, as artifact `caw-android-apk`
  - the Windows app folder, as artifact `caw-windows`. Run `caw.exe` from it.
- **Android signing:** the repository secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` give every build the same key, so each APK installs over the last. Without them, CI signs with a throwaway debug key, and each new APK needs the old one uninstalled first.

## Tests

`flutter test`:
- model round-trips and the engine JSON
- highlighting and editor helpers
- an integration test through `dart:ffi`: templates, checks, a project sync and a loop export. It runs when `CAW_LIB` points at a built engine library; CI sets it.
