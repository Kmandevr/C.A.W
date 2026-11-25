# Changelog

What changed in each C.A.W release, newest first. C.A.W is in open alpha: expect rough edges and unexpected issues.
Versions keep the `-alpha.N` suffix until the official release.

## 1.1.3-alpha.3 (2026-11-25)

- **The new instruments, every knob heard:** Starling's Hammer runs from soft felt to hard (about 12 dB brighter), and Soft pedal, Touch, Resonance, Sympathy, Phantom partials and Noise all do what they say in normal playing; the Upright and Felt are their own pianos (the Felt darker and softer, the Upright boxy and shorter-lived), both with the grand's recorded attack processed to match; a key let go under the pedal sounds its damper when the pedal lifts. Curlew's Growl is a real growl and flutter-tongue, its Vibrato is heard at the default, and the sax has a body. Nightingale no longer spikes or buzzes as a note is released, and its vibrato comes in sooner. Woodpecker's Release damps the bars by hand, Attack level adds or removes the mallet's stroke, and the vibraphone's motor is one control.

## 1.1.3-alpha.2 (2026-11-25)

Realistic instruments, part two: tuned percussion.

### New
- **Woodpecker, tuned percussion:** marimba, xylophone, glockenspiel, vibraphone, tubular bells and timpani, each with its real mallet stroke (VCSL, CC0) flowing into a ringing bar, tube or drum measured from the same recordings, in tune at A440. Listen for the stroke handing over to the ring with no dip or bump, the marimba's warm tube (the Resonator knob), the vibraphone's motor shimmer and damper pedal, and a brighter tone as you raise Mallet hardness. 15 presets.

## 1.1.3-alpha.1 (2026-11-24)

Realistic instruments, part one: a piano, bowed strings, winds and a cathedral organ that sound like the real thing.

### New
- **Starling, a grand piano:** modelled strings with a real grand's recorded attack, key and pedal noises (the Salamander Grand Piano by Alexander Holm, CC-BY 3.0), tuned like that piano. Grand, Upright and Felt; 12 presets. Its recordings load only while a track uses it.
- **Nightingale, bowed strings:** violin, viola, cello and double bass. The bow now stays in the sweet spot at any loudness, so notes start cleanly and never jump to the octave; the bow noise is subtle; each instrument has a body measured from real recordings (VSCO 2, CC0). 12 presets.
- **Curlew, winds:** flute, clarinet, saxophone, trumpet, trombone and French horn, without the click that made the flute sound like a piano; brass that holds its notes; bodies measured from real recordings. 12 presets.
- **Bittern, a cathedral pipe organ:** 13 stops from a deep 32' to a sparkling mixture and a trumpet, each rank alive with its own tuning and the chiff of real pipes, a living wind, a tremulant and a swell box on the mod wheel, in a cathedral that rings for seconds (turn Space down for the organ loft). 12 registrations.

### Changed
- The wavetable synth is now called **Kestrel** (it was Raven).
- More devices have new names (search still finds the old ones): the ducker is **Swoop** (was Duck), the transient shaper **Stoop** (was Swoop), pitch correction **Chirp** (was Lark), note echo **Mock** (was Ricochet), the formant filter **Coo** (was Syrinx), the limiter **Hover** (was Canopy), the meters **Spot** (was Lookout), the convolver **Call** (was Hollow), the spectral effect **Molt** (was Iris), multiband dynamics **Puff** (was Pinion) and the trance gate **Blink** (was Strobe).
- The new piano, strings and winds open dry (no room): add Space or your own reverb. The organ opens in its cathedral.
- **Knobs turn with a sideways drag**, so swiping up and down over a device page scrolls it. Hold a knob first for fine moves. Prefer the old up-and-down drag? Settings › Haptics and menus › Knobs turn with.
- While a song plays, the screen runs at 60 Hz to leave the phone's power to the audio.

### Known issues
- The new instruments use the plain knob page until their own pages are designed.
- Curlew: the flute's top C, the trombone's low E and the horn's lowest notes don't sound reliably yet, and the sax can jump to its octave on C#4.

## 1.1.2-alpha.1 (2026-11-24)

Realism: Timber's instruments and Rook's drums are now simulated, the way the real instruments work, mechanical noises and all.

### New
- **Timber, Simulated mode** for every instrument (old projects keep their Classic sound):
  - **Piano:** a simulated felt hammer striking stiff strings, a shared soundboard, sympathetic resonance, the bass notes' pitch glide, and the mechanical noises (hammer thump, keybed, dampers, pedal), subtle by default with a Noise knob. Checked against measurements of a real grand. New pianos open Simulated.
  - **Flute** (jet and breath), **clarinet and sax** (reed and tonguing), **brass** (lips, brightening when loud), **bowed strings** (bow friction), **plucked strings** (fret buzz, slide noise), **mallets and electric piano** (real contact), **organ** (key-contact click).
  - Eco, Normal and High quality.
- **Rook, three kinds of kit:**
  - **Synth:** a whole kit from one seed and a style.
  - **Produced:** EDM-ready kicks in three layers, tune the kit to your key, finishing chains, loudness match.
  - **Acoustic:** a new simulated drum kit: real drum pieces that keep ringing, rimshots, flams, rolls, brushes, snare wires that buzz with the kick, cymbals, a pedal hi-hat, close and overhead mics with bleed. Pads follow General MIDI, Roland V-Drums or Alesis layouts.
  - A **Build a kit** card to make any of them in a few taps.

### Changed
- The new instruments were optimised to fit their CPU budgets.
- **Steadier playback on phones:** C.A.W now lets Android manage the CPU clock and heat instead of fighting it. The output buffer grows by itself after a dropout (Find the smallest stable buffer is on by default).
- **Load never stops playback:** when the phone can't keep up, C.A.W mutes tracks one at a time but always keeps one playing, and a stream the system stops is reopened within a second.
- The smart-freeze suggestion now appears only after real dropouts, never on the CPU figure alone.
- The Benchmark plays every instrument and effect, with each model and variant, under the names the app shows.

### For contributors
- Engine C API 46: `caw_drums_kit_build`, `caw_drums_kit_tool`.
- `caw_audio_status` reports the stream's path (`mmap`, `fast`, `normal`), buffer, burst and capacity; the load stabilizer is off unless `CAW_LOAD_STABILIZER=1`; `caw_audio_set_thermal` no longer acts.

## 1.1.1-alpha.1 (2026-11-20)

Fixes after 1.1.0: smoother playback, a cooler phone, older Flagship sounds back as they were, and new glitch modes in Bits.

### Fixed
- **Spikes while playing, opening menus or with a device open:** device pages no longer redraw the screen nonstop (an open page drew about 120 frames a second even when stopped; now none when stopped, and device animations run at up to 60 frames a second). Device pictures, menus, the loader and the Benchmark screen redraw only what changes.
- **Older Flagship patches with echoes:** 1.1.0 added new filter types, wavetables and warps, so an LFO or envelope on an old patch could reach the new comb and phaser filters. Old patches now play exactly as in 1.0.9; modulation on a new choice still reaches the whole list.
- Lark's "Edit pitch…" button no longer overflows a narrow phone screen.

### Changed
- **Cooler phone:** the playback stabilizer now works only as hard as needed and backs off as the phone warms up.
- **The Benchmark measures real-world performance:** no cool-down pauses, and the numbers shown are the measured ones, heat included.

### New
- **Bits · Bitwise:** new glitch operations beside bit shift: OR, rotate, reverse, freeze, seeded bit flips, and combining with the key track or a delayed copy of itself, with smoothing, a gate and mix so it stays musical.

### For contributors
- Engine C API 45: `caw_audio_set_thermal`.

## 1.1.0-alpha.1 (2026-11-20)

The effects and instruments suite: new effects, four new and reworked instruments, and a little bird in everything. Every device now has a crow-family name with a plain subtitle (Talon · Compressor, Plume · EQ), and a plain search still finds it ("EQ", "compressor", "autotune").

### New
- **Instruments:**
  - **Timber · Acoustic:** physically modelled piano, electric piano, organ, plucked and bowed strings, mallets and winds, all synthesised (no samples).
  - **Flock · Granular:** a grain cloud over your sample or a built-in tone, drawn as a flock.
  - **Raven · Flagship** gains FM, ring, AM and sync between oscillators, spectral and additive warps, new filters, a fourth LFO and 8 macros.
  - **Magpie · Sampler:** drop a sample and play it across the keys, slice it, stretch it, or record a multisample.
  - **Rook · Drums:** every setting now does something or says what turns it on, with FM, physical and texture layers, per-pad effects, groove (swing, humanize, accent, flam) and 16 new kits.
  - Every instrument uses Raven's one-screen layout.
- **Effects:**
  - the Compressor splits into **Talon** (Down, Up, Dynamics, Bus), **Hatch** (Gate, Expand, Pedal gate) and **Duck** (Duck, Level, Carve);
  - new modes: dynamic, mid/side, Match and linear-phase EQ; Wah; Tape, Reverse and Multi-tap delays; Room, Plate, Spring, Gated and Reverse reverbs; Amp, Pedal and Bands drive; Bitwise; Cab; Harmonizer and Octaver;
  - new effects: **Lark** (pitch correction, plus a pitch editor for a recorded voice: drag each sung note), **Glint** (exciter), **Mimic** (vocoder), **Meters**, **Preen** (denoise, de-hum, de-reverb), **Hush** (de-click, de-plosive, breath), Lo-fi and Phase align;
  - MIDI effects: Hop, Clutch, Perch, Ricochet and Ruffle;
  - the AutoStacc pack: Murmur, Peck, Bend and Iris.
- **Around the effects:**
  - a sidechain filter (high-pass, low-pass and Listen) on every keyed effect;
  - a loudness target on the Limiter;
  - CPU and latency in each device's header;
  - while a track is armed, heavy effects play a near-zero-delay version, and the full one plays back and exports;
  - at least 8 presets per effect, tagged by purpose, with purpose chips, chain templates (guitar, vocal, podcast, drum bus, master) and project templates (guitar recording, podcast, beat, sound design);
  - a "?" field guide in every device, and **Happy accident**, which nudges a sound a small random step (one undo).
- **The look:** bird icons for each family, a crow in empty places and on the loader, a quill for the modulation handle, and themes named Raven, Jackdaw, Magpie and Jay. New projects get generated names (Settings can turn that off), and each project card shows time spent, bars, tracks and the last export. There may also be a few surprises.

### Changed
- **Steadier live playback on phones:** the load stabilizer from 1.0.9 now follows your Buffer mode, not the mode Android grants, so it runs on phones that refuse a low-latency stream (the Galaxy S22+ at its 960–1024-frame buffers). Battery still turns it off.
- **The screen stays on while a Benchmark runs.**
- Themes: Neon becomes Raven and Flat becomes Jackdaw; Dusk and Dawn move to Jackdaw and Jay, Amber to Magpie. Saved settings move over by themselves.

### For contributors
- Engine C API 44 (from 43): MIDI effects (41), the pitch clip editor (42), the sampler's tools (43) and per-slot cost and armed versions (44).

That's the flock for this one.

## 1.0.9-alpha.1 (2026-11-19)

The performance release: steadier live playback on phones, a fairer Benchmark, and cheaper effects.

### Changed
- **Steadier playback on phones that won't speed up the audio core:** some phones (the Galaxy S22+ among them) ignore Android's request to keep the audio core fast, so it dropped to its slowest speed and playback spiked. While something plays, C.A.W now keeps that core busy enough to stay fast. It costs a little more battery while playing, and none while stopped or in the background. The Battery buffer mode turns it off.
- **Cheaper effects, same sound:**
  - the EQ costs up to 70 % less when its settings aren't moving;
  - the Compressor costs about 40 % less;
  - a typical 8-track song does about 5 % less work in total.

  Every render is bit-for-bit the same.
- **No stuck notes:** a flood of MIDI controller messages can no longer push out a note-off. Releases have their own reserved room, and repeated controller moves merge.
- **No stutter the first time a plug-in plays:** a plug-in's code is loaded into memory before playback starts.
- **Bigger projects:** routes per track and modulators or links per project now grow with the project. Very heavy modulation shows a CPU warning instead of being refused.
- **Ratchets up to 64 per step** (from 8).
- **Fixed:** an EQ band that changed type or channel while no knob moved could stay silent.
- **A fairer Benchmark:** it warms up first, runs the coolest tests first, pauses to let the phone cool after heavy ones, and records each test's heat, clock speed and spikes. Results are also shown as if the phone ran at full speed, so a warm phone doesn't look like a slower app.

### For contributors
- **The brand and trademark policy** ([TRADEMARKS.md](https://github.com/Kmandevr/C.A.W/blob/Main/TRADEMARKS.md)): the code stays Apache 2.0; the C.A.W and AutoStacc names, logos and brand art belong to AutoStacc.

## 1.0.8-alpha.1 (2026-11-19)

The effects release: fewer, better effects, each with a page you can play like an instrument, and a redesigned Flagship.

### New
- **One effect per job:** the overlapping effects are merged into one effect each, with modes:
  - Compressor (Down, Dynamics, Gate, Shape, Duck)
  - Limiter
  - Transient
  - Drive
  - Bit distortion
  - EQ (Bands, Graphic, DJ, Tilt)
  - Filter
  - Utility/Stereo
  - Chorus/Flanger
  - Phaser
  - Tremolo/Pan
  - Delay
  - Reverb
  - Pitch/Shift

  Pick the mode from the cards at the top of the effect. Old projects open with the matching effect and mode and sound the same.
- **A new page for every merged effect:** the visual shows what the effect is doing and takes the big drags, such as an EQ band, the filter's cutoff, a compressor's threshold or the delay's echoes. Knobs handle the fine work.
- **Duck:** a new Compressor mode that turns one track down when another plays, or levels its own input. It detects by RMS, Peak or true peak (ISP) and has 9 presets, such as "Kick duck bass" and "Voice over music".
- **A tidier FX chain:** each effect folds to one row with its power, name, a live level and Mix. Open as many as you like, or use Collapse all.
- **Every effect's header and footer:**
  - preset arrows, search and ★ favourites;
  - A/B compare (hold to copy A to B);
  - a ⋯ menu: copy and paste settings, randomize with an amount, this effect's undo history, and reset;
  - an output meter with a clip light, plus Mix and Output.
- **Auto gain:** the ear icon matches an effect's loudness to what goes in, so you judge it by ear and not by level. It is off by default and can be switched on per effect (Settings › Sound sets it for new effects). It plays in a render only when you switch it on.
- **Hold any knob** to type a value, automate it, MIDI-learn it, reset it, or **React to…** another track: that track's loudness or notes move the knob.
- **Preset preview:** turn on Preview in the preset browser and tap through presets while your loop plays. Cancel puts everything back.
- **Flagship on one screen:**
  - On a tablet, a desktop or a phone held sideways: the three oscillators, both filters with a series/parallel switch, the effects and the modulation together.
  - On a phone held upright: three panels to swipe, Oscillators, Filters and Modulation.
  - Drag a modulation source onto any knob, across panels too.
  - Init, Random patch with an amount, oscillator copy and paste, a keyboard strip, and What's modulating?

### Changed
- **Projects saved by this version** that use a merged effect, a mode or a rack need 1.0.8 or later to open.
- **Changing an effect's mode** resets the settings that mean something different in the new mode, along with their automation, modulation and MIDI mappings. One undo brings them all back.

## 1.0.7-alpha.1 (2026-11-18)

The safety release: C.A.W now checks every plug-in before it runs and tells you, in plain words, what it can do.

### New
- **A safety check before any plug-in runs:** every native plug-in is scanned before it is loaded, so nothing in it runs until the check is done. It looks for what the plug-in could do: use the internet, read or write files, start other programs, load more code, run background threads and more.
- **Plug-ins declare what they need:** a C.A.W plug-in that does more than make sound must say so, with a reason in plain words. One that does something it didn't declare is blocked, and C.A.W tells you why.
- **See what a plug-in can do before you trust it:** the trust sheet lists each thing the plug-in can do, the risk, and why an honest plug-in might need it. A blocked plug-in can't be trusted by mistake.
- **Needs, on the Plug-in page:** declare what your own plug-in needs (internet, files, threads…) with a reason, and for the internet the sites it talks to. C.A.W writes it into the plug-in for you.

### Changed
- **Plug-ins built before this version** keep working, with a warning, until you rebuild or update them. Rebuild them with their needs declared to clear it.

## 1.0.6-alpha.1 (2026-11-18)

The usability release: smooth zooming, a tidier Settings, choosing your real speaker, headphones and microphone, and latency that stays where you set it.

### New
- **Choose your output and input device on Android:**
  - outputs: the phone speaker, wired headphones, Bluetooth and USB;
  - inputs: the phone's microphones, a headset's and USB.
  - Your choice is remembered and used again when the device reconnects.
  - The line under each drop-down says which device is actually in use.
- **Pause when unplugged:** playback stops when your headphones or Bluetooth disconnect, before the speaker plays (Settings › Sound › Audio devices, on by default).
- **Safety limiter:** a gentle limiter on what you hear protects your ears and speakers. It never touches your exports (Settings › Sound › Quality and buffer, on by default).
- **Mono check:** hear your mix in mono to check what cancels. It is for listening only; exports stay stereo.
- **Keep the screen awake:** Off, while playing or recording, or always (Settings › App › Performance).
- **New-track defaults:** the instrument a new MIDI track plays when you record, track colours (the next one, or one per kind) and names (kind and number, or the instrument's name), plus whether a new audio track hears its input (Off, Auto or On).
- **Record mode in Settings:** Takes, Overdub or Replace, the same choice as Record's long-press.
- **Remember zoom per project:** each project reopens at its zoom and scroll position.
- **Left-handed layout:** the transport and the side rail are mirrored, Play and Record on the left.
- **Find the smallest stable buffer** (Android): a switch for the automatic buffer size, off by default.

### Fixed
- **Latency you measure or type** no longer counts the system's latency twice:
  - **Tap along** keeps the figure your taps found, also on Bluetooth headphones whose delay settles after they connect;
  - **the loopback test** splits the round trip correctly, so recordings land where you played;
  - **a typed latency**, for the output or the input, stays what you typed.
- **Zooming** in Arrange is smooth: text, clip names and the ruler keep their size instead of stretching and then jumping, nothing snaps when you lift your fingers, and the beat under your fingers stays under them. The zoom buttons and the mouse wheel glide too, and grid lines and ruler numbers fade in and out.
- **Editing feels quicker:** selecting or changing a clip or track redraws only what changed.
- **Automate from a device page** on a phone now closes the page and shows you the lane.

### Improved
- **A tidier Settings:** five sections in the order you use them (Sound, Editing, Appearance and feel, Projects and export, App), each a set of glass cards that keep related settings together. Rarer settings sit under each card's **More**; search still finds every setting and opens its card. Each setting now lives in one place: the two recording offsets sit together as **Audio take offset** and **MIDI note offset**, and the Privacy Policy, Terms and Send feedback appear once.
- **Take lanes** can be resized by dragging their edge, like automation lanes.
- **Bounce to audio** is in an audio clip's own menu.
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
