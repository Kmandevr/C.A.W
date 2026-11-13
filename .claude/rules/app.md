---
paths:
  - "app/**"
---

# App (Flutter; Android/Windows CI artifacts, other targets unverified)

- The UI never touches audio data. It sends control messages (play, stop, swap program, set parameter) and reads meters through the engine's C API over `dart:ffi`; no per-sample or per-block calls cross it.
- Compile and render off the UI isolate. Long renders show progress and can be cancelled.
- One codebase: platform differences live behind small Dart interfaces with one implementation per platform, never `if (Platform.isX)` scattered through screens.
- Files: app-private storage for projects; the system file picker for import and WAV export. Ask only for permissions a feature needs now.
- Current behavior: when stopped and backgrounded, the app closes the audio device and reopens it on return. While playing or recording, Android runs a `mediaPlayback` foreground service (owner-approved 2026-11-12, `lib/model/background_playback.dart`); it must start while the app is in front. iOS background audio is not implemented; do not document it as if it exists.
- No secrets in any build. GitHub tokens come from the device-flow sign-in and live in the platform's secure storage.
- Phone screens first: compact panels, sensible defaults, the symbol key row for code entry, errors on one line next to the code. Desktop gets keyboard shortcuts on top, not a different app.
- Start each file with a one-line `//` comment saying what it is for (the repo map reads it).
- Every visible state change animates to its new state, in and out, through the theme's motion tokens (`lib/ui/motion.dart`) and respecting Off/Reduced; a drag follows the finger with no lag (owner, 2026-11-11).
