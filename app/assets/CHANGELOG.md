# Changelog

What changed in each C.A.W release, newest first. C.A.W is in open alpha: expect rough edges and unexpected issues.
Versions keep the `-alpha.N` suffix until the official release.

## 1.0.6-alpha.1 (unreleased)

Choose the real speaker, headphones and microphone on Android, and latency you set stays where you set it.

### New
- **Choose your output and input device on Android:**
  - outputs: the phone speaker, wired headphones, Bluetooth and USB;
  - inputs: the phone's microphones, a headset's and USB.
  - Your choice is remembered and used again when the device reconnects.
  - The line under each drop-down says which device is actually in use.

### Fixed
- **Latency you measure or type** no longer counts the system's latency twice:
  - **Tap along** keeps the figure your taps found, also on Bluetooth headphones whose delay settles after they connect;
  - **the loopback test** splits the round trip correctly, so recordings land where you played;
  - **a typed latency**, for the output or the input, stays what you typed.
<!-- zoom -->

### Improved
- **Latency learns from audio takes too:** when you record audio with the click on, C.A.W finds where your notes start and how far they land from the beat. After a few takes that agree, the latency card suggests a correction. It never changes anything until you tap **Apply**.

## 1.0.5-alpha.2 (2026-11-18)

A hotfix: smoother scrolling, the playhead in time with the sound, a smoother start, and fixes that made the app hard to use.

### Fixed
- **Scrolling in Arrange:**
  - no more hitch every couple of screens;
  - no slowdown near the end of the song.
- **The playhead and meters** move evenly and match what you hear. They no longer step every few seconds or lag a frame behind.
- **Automatic latency** no longer over-estimates on Bluetooth headphones. A saved offset was being counted twice, and the engine counted its whole buffer rather than what was queued. The Latency page now shows the breakdown: system, buffer and your offset.
- **Automation points can be dragged** with a finger, in time and value, instead of the timeline scrolling.
- **The Automation tab** shows and edits the same lanes as the ones under the track, including effect and instrument parameters.
- **Settings:** a long choice such as an audio device's name no longer squeezes its title into one letter per line.
- **The startup animation** runs smoothly. The app now loads in the background and builds only when the animation is done.
- **The loading steps** tick only when their work is done, with real counts ("Loading C++ components 2/5").

### Improved
- **Latency slider:** a dot sweeps to a line and flashes on each click, so you can line the flash up with the sound. With the song stopped, it plays its own click loop.
- **Bluetooth:** **Best quality** explains how the phone and headphones choose their codec and sample rate, and opens Developer options for you.
- **Engine diagnostics** shows the audio clock while playing (the real rate, late callbacks, dropouts and the microphone's stream), with a Copy button.

## 1.0.5-alpha.1 (2026-11-17)

Recording, editing and timing: comping, freeze and bounce, better automation, a sample library, and snappier playback.

### New
- **Comping:** recorded takes open as lanes under the track. Swipe across a lane to use that part, double tap to hear a take, and **Flatten** to turn the comp into ordinary clips. Audio joins get a short crossfade.
- **A take per loop pass:** each pass of a loop recording becomes its own take, MIDI and audio.
- **Record just works:** with nothing armed, Record picks or makes the right track (a MIDI track when a keyboard is connected, otherwise an audio track for the microphone), counts in and records.
- **Freeze and bounce:**
  - **Freeze** a track to save CPU. It shows a snowflake, and editing it asks to unfreeze first.
  - **Bounce to audio** works on a track or a clip selection.
- **Consolidate:** join selected clips into one, from the clip selection's hold menu.
- **Automation:**
  - Lanes can be resized.
  - Draw with Select, Pencil, Line, Shape (sine, triangle, saw, square, random) or Eraser.
  - Curved segments (slow, fast, S-curve, step).
  - Box-select points to move, scale and tilt them, and copy and paste them.
- **Automate from any knob:** hold a knob, fader or slider and choose **Automate**.
- **An easier way to add a lane:** a searchable picker with your recent parameters at the top.
- **Linked sample folders:** link your sample folders once in Files › Samples. Files stay where they are, nothing is copied, and a moved file can be found again.
- **Sample browser:**
  - tap previews; double tap adds the sample where it fits;
  - waveforms with scrubbing;
  - previews in time with the song;
  - auto-play of the next sample;
  - preview through the track's effects.
- **Automatic BPM, key and type** from the file's tags, its name or the audio itself, as filters you can sort by.
- **Latency slider:** hold Record, then **Latency…**, and drag the slider while the song plays until the playback lines up. It's saved for each device.
- **Projects:** the project menu shows your 3 most recent projects and **All projects…**.
- **Startup:** the startup animation plays to its end. Turn that off in Settings › Feel.

### Improved
- **Clips are stored as MIDI,** which is more precise and holds bends up to ±96 semitones. A project saved by 1.0.5 can't be opened by older versions.
- **Playback looks on time:** the playhead, meters and highlights now match what you hear, leaning slightly early rather than late.
- **Automatic latency:**
  - it is remembered per device and re-checked when the device changes;
  - the loopback test runs 5 times and refuses an unreliable result;
  - after a few late or early MIDI takes, it suggests a correction.
- **Bluetooth:**
  - C.A.W asks Android for its low-latency treatment of the audio;
  - the latency screen explains how to get the lowest delay, with a shortcut to Bluetooth settings.
- **The performance hint** that asks Android to keep the CPU fast for audio retries if Android refuses it at first.
- **Benchmark:**
  - a test you leave the app during is run again when you come back;
  - the track test stops cleanly at the engine's limit.

### Fixed
- **Notes started mid-way now play,** including their bends, when playback starts inside them.
- **Bends past an octave:** the old limit is gone.
- **Piano roll:** the shading starts at the clip's real end.
- **Repeats:** a repeat that runs past a clip's end is cut at the end.
- **Piano roll taps:** notes land where you tap, the tools respond every time, and a tap no longer stacks a duplicate note.
- **The CPU meter** no longer spikes when playback starts on Bluetooth.

## 1.0.4-alpha.1 (2026-11-14)

Audio editing: stretching, pitch, the sample editor and slicing.

### New
- **Stretch audio clips:** drag the small notch in an audio clip's top corner to stretch it, from ¼× to 4×. The length and ratio show while you drag. Dragging the edges still trims.
- **Follows tempo:** an audio clip can follow the song's tempo, including tempo changes and ramps. Its own tempo is detected when you import it; type it in or tap **Detect** to change it.
- **Pitch** in semitones and cents, without changing the clip's length.
- **High-quality stretching** with Signalsmith Stretch (MIT-licensed), live while the song plays. Up to 8 clips per track use it at once; any others use the lighter stretcher.
- **Sample editor** at the top of an audio clip's tab. Double tap a clip, or tap an audio file in Files.
  - The waveform has handles for trimming, fades (with a curve shape) and loop points.
  - The tool row has Normalise, Reverse, Gain and Trim (cuts the silence off both ends).
  - Edits never change the original file, and each is one undo step.
- **Slice to MIDI:** set the sensitivity and watch the cut lines move. **Make MIDI track** puts the slices on drum pads (up to 16) or the sampler, with a MIDI clip that plays them at their original times.

### Improved
- **Long songs:** clips far into a long song are drawn in exactly the right place.
- **Tempo changes:** audio clips are drawn at their true width when the tempo changes.
- **Repeatable stretching:** stretched audio sounds the same every time it plays, and on every device.

## 1.0.3-alpha.1 (2026-11-14)

Song timing: tempo changes, time signatures, sections and markers.

### New
- **Tempo lane:** a lane under the ruler for tempo changes, stepped or ramped. Drag a point up or down; hold it for Stepped, Ramped, Set tempo… or Delete. It appears once a song has a tempo change.
- **Time signature changes:** set from the ruler's hold menu, shown as flags in the ruler (3/4, 6/8…). Bar numbers, the grid, the piano roll and the transport's bar.beat follow them.
- **Sections:** coloured, named blocks above the ruler (Intro, Verse, Chorus…). Tap to jump, double tap to loop, hold for Rename, Colour, Copy or Delete, hold and move to move. Moving, copying or deleting a section takes its clips, automation and tempo changes with it, as one undo step.
- **Markers:** named flags in the section bar.
- **Count-in:** counts whole bars of the time signature where playback starts.

### Improved
- **Everything time-based follows tempo changes:** notes, loops, automation, the metronome (it clicks each note of the signature, accenting the first of the bar), tempo-synced delays, choruses and LFOs, audio clips, recording, export and stems.
- **MIDI import and export** carry tempo changes and time signatures. MIDI can't store a ramp, so ramps are written as small steps.
- **Same sound everywhere:** tempo ramps compute identically on Android, Windows and Linux.
- **Old projects** open unchanged, as one tempo and time signature. Their loop regions become sections.

### Known limits
- **Audio clips** are drawn at the song's starting tempo until audio stretching arrives in 1.0.4.

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
