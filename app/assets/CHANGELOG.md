# Changelog

What changed in each C.A.W release, newest first. C.A.W is in open alpha: expect rough edges and unexpected issues.
Versions keep the `-alpha.N` suffix until the official release.

## 1.0.2-alpha.1 (not yet released)

### New
- **Changelog:** this list, in the app (Settings › About and beta › What's new, shown once after an update) and on each GitHub release.

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
