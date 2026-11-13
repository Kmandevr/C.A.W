# Changelog

What changed in each C.A.W release, newest first. C.A.W is in open alpha: expect rough edges and unexpected issues.
Versions keep the `-alpha.N` suffix until the official release.

## 1.0.2-alpha.1 (2026-11-13)

Benchmark and diagnostics.

### New
- **A full-coverage Benchmark:** about 30 test projects, from an empty project to everything at once. They cover instruments, every effect, folder routing, sends, automation, modulation, many notes starting at once, sample streaming and audio clips.
- **Where the time goes:** the results open on a verdict ("~N tracks · voices · biggest cost") and then a bar per part of the engine: mixing, routing, sends, automation, voices, samples, metering, audio input/output, the parallel mixer, the master chain and your devices. Tap a bar to see its numbers, the projects where it mattered and tips.
- **Plug-in benchmark:** a Benchmark button in the C++ Builder, and your plug-ins listed in Settings › Performance › Benchmark.
  - It checks your own (or Trusted) C++ plug-ins for slowdowns at silence (denormals), cost per voice, how cost grows with block size and sample rate, and the cost of parameter changes.
  - Mark parts of your code with `CAW_PROFILE_SCOPE("name")` to see which part is slow.
  - A plug-in that freezes fails the run instead of hanging the app.
- **What's new:** this changelog, in Settings › About and beta. It's also shown once after each update and used for each GitHub release's notes.
- **Display modes:** in Engine diagnostics, everything your phone reports about its screen, with a Copy button.

### Improved
- **Windows:** the engine is built with Clang. It's 12–17% faster on songs and about 45% faster on heavy Flagship patches.
- **Anonymous telemetry:** it now includes which kind of CPU core the audio ran on, and whether Android's performance hint was on.
- **Frame-rate row:** it says exactly why the screen is capped, if it is: Lightweight, battery saver, Samsung's Standard motion smoothness, or heat.

### Fixed
- **120 Hz screens:** they could be held at 60 Hz. Screens that list 120 Hz only as an alternative rate, such as the Galaxy S22+, now get 120 Hz in Auto.
- **Blocked plug-ins:** a plug-in you Block or stop trusting can no longer be benchmarked.

## 1.0.1-alpha.1 (2026-11-13)

The polish release.

### New
- **Flagship synth, Fold mode:** each oscillator can fold its unison stack per copy (the sound so far, the default) or as a whole stack, a grittier texture that is also about 30% lighter on the CPU.
- **Benchmark:**
  - It measures what the app really does: the parallel mixer, a warm-up, and the first moment after Play reported on its own.
  - Live runs at your playing buffer and at Low latency.
  - A real-time 2-minute heat test with the phone's thermal status.
  - Costs per test project.

### Improved
- **Flagship synth:**
  - About 8% faster with no change to the sound in the default mode.
  - High folded notes stay clean, because they use the higher-quality fold.
  - A faster drive.
- **Every screen fits** on small phones, with large system text, on tablets and on desktop. Nothing sits under the navigation bar any more, and labels are no longer cut off.
- **Parallel mixer:** it falls back to the normal mixer when it would miss more audio deadlines than the normal mixer would.

### Fixed
- **Low latency and recording:** they now use the phone's small audio blocks instead of 40 ms ones, which removes extra delay and dropouts.
- **Switching headphones or Bluetooth while playing:**
  - The device settings are read again.
  - A fixed-size buffer reopens.
  - Recordings stay aligned.
- **The update prompt** could lose its text on small phones.
- **Light themes:** the status and navigation bar icons were invisible.
- **The built-in Privacy Policy** now states the minimum age of 16.
- **The About line** now shows the open alpha notice.
- **Windows:** a small update now keeps the app's start-up arguments.

## 1.0.0-alpha.1 (2026-11-13)

The first open alpha.

### New
- **Startup screen** with the version and the open alpha notice.
- **Updates from GitHub Releases:**
  - Never forced: Update, Not now or Don't ask again.
  - Update now, and installing another version, in Settings.
  - Stable, Beta and Every change channels.
  - Opt-in automatic updates (Off, Patches, Minor, All).
  - Smaller downloads that only fetch what changed.
- **Benchmark** in Settings › Performance: a Quick or Full run of the engine on your device. It stops when the phone gets hot or battery saver is on, and you can share or save the results. Each run is sent as anonymous telemetry when telemetry is on.
- **Music video, round 2:**
  - Export at 24, 30 or 60 fps, with quality presets and draft renders.
  - A tabbed layout.
  - Text and images.
  - Transitions, camera moves and beat presets.
  - Renders that run in the background while you keep working.
- **Anonymous telemetry and feedback**, with a first-run privacy page, My data and Send feedback.
- **Projects:** select mode, folders, project details, and mass delete you can undo.
- **Background playback** on Android, with a notification and a battery setting hint.

### Improved
- **Engine speed:**
  - A parallel mixer for heavy projects.
  - The first moment after Play costs no more than the rest.
  - Many smaller optimisations.
- **Bluetooth audio:** fixed-size blocks at the device, and overloaded layers come back on their own.
- **Frame rate:** up to 240 fps, with Auto and caps (Lightweight 60, Minimal 30).
- **Piano roll:** a cursor and a ruler loop like the arranger's.
- **Gestures:** tap selects, double tap does the quick action, hold opens the menu, and hold-and-move moves.

### Fixed
- **Dropouts:** with the microphone input open, playback no longer waits on the microphone.
- **Music video renders:** they no longer fail with three or more tracks playing.
- **Saves:** fixed races between saves of the same file.
