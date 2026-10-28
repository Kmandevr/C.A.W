---
paths:
  - "app/**"
---

# App (Flutter, every platform)

- The UI never touches audio data. It sends control messages (play, stop, swap program, set parameter) and reads meters through the engine's C API over `dart:ffi`; no per-sample or per-block calls cross it.
- Compile and render off the UI isolate. Long renders show progress and can be cancelled.
- One codebase: platform differences live behind small Dart interfaces with one implementation per platform, never `if (Platform.isX)` scattered through screens.
- Files: app-private storage for projects; the system file picker for import and WAV export. Ask only for permissions a feature needs now.
- Background playback follows each platform's rule (Android foreground service of type `mediaPlayback`, iOS audio background mode).
- No secrets in any build. GitHub tokens come from the device-flow sign-in and live in the platform's secure storage.
- Phone screens first: compact panels, sensible defaults, the symbol key row for code entry, errors on one line next to the code. Desktop gets keyboard shortcuts on top, not a different app.
- Start each file with a one-line `//` comment saying what it is for (the repo map reads it).
