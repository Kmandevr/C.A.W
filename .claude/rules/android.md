---
paths:
  - "android/**"
---

# Android app (Kotlin, Compose)

- The UI never touches audio data. It sends control messages (play, stop, swap program, set parameter) through the thin JNI bridge; no per-sample or per-block calls cross JNI.
- Compile and render on worker threads, never the main thread. Long renders show progress and can be cancelled.
- Files: app-private storage for projects; the Storage Access Framework for import and WAV export. Ask only for permissions a feature needs now.
- Playback that continues in the background uses a foreground service with the `mediaPlayback` type.
- No secrets in the APK. GitHub tokens come from the device-flow sign-in and are stored encrypted with the Android Keystore.
- The screen is a phone screen: compact panels, sensible defaults, the symbol key row for code entry, and errors on one line next to the code.
- Start each file with a one-line `//` comment saying what it is for (the repo map reads it).
