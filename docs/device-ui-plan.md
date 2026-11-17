---
title: Device UI plan
summary: The owner's 2026-11-17 direction for every device's UI (collapsible FX chain, Vital-like Flagship, visual-first effects with knobs, the shared QoL kit) and a plan per device; planned for 1.0.6, not built.
updated: 2026-11-17
---

# Device UI plan

**[Proposal]** None of this is built. It ships with the FX batch 1.0.6 (#227, #231). The owner gives a yes on each device's plan before it is built.

## The owner's direction (2026-11-17)
- **FX chain:** each effect is a collapsed row with power, name, a tiny live visual and Mix.
  - Any number can be open at once, with **Collapse all** on top.
  - Every control works in place. No full screen is needed; the full screen only gives more room.
- **Feel:** visual first, controlled mainly by knobs, "to make things less touchy". The visual shows what the device is doing and takes the big, obvious drags (an EQ node, a filter's cutoff). Fine work is on knobs.
- **Flagship:** one cohesive screen, Vital-like. No accordions.
- **Identity:** cohesive, yet each device has its own design and feel, so none is boring. Devices that go together share things.
- **Auto gain** never changes the intent of the work, and it can be turned off.

- **Ready for routing (1.1.0, #233):** every device is built so it can later be a node in the visual routing graph: one parameter and modulation model, no device-specific routing.

## The shared kit (every device)
- **Header:**
  - power, the name in the family's colour, and the preset bar (‹ name ›, a tap to search, ★ favourite);
  - **A/B** (a tap switches, a hold copies A to B);
  - ⋯ for copy and paste settings, randomize (with an amount slider), undo history, auto gain and reset.
- **Knob:** the same everywhere.
  - Drag up or down, and the value shows while dragging.
  - A second finger, or Shift, gives fine moves (a tenth).
  - Double tap resets; hold opens the menu: type a value, Automate (#230), MIDI learn, reset.
  - A modulation ring shows its range live.
- **Footer:** an output meter with a clip light, Mix where the device has one, and Output.
- **Auto gain:** an ear icon in the header.
  - It's a listening aid: it matches the loudness, not the peaks, so you compare by ear and not by level. Its trim shows as a number.
  - It's off by default. **Settings › Audio** has it app-wide, with a per-device switch.
  - It is never applied silently to a render. It plays in a render only when its device's switch is on, as for any setting you choose.
- **Families share a visual language:**

  | Family | Colour | Shared visual |
  |---|---|---|
  | EQ and Filter | blue/mint | a response curve on a log grid |
  | Dynamics | yellow | a transfer curve plus a scrolling gain-reduction trace |
  | Drive and bit | orange | a transfer curve plus a harmonics bar |
  | Space (delay, reverb) | violet | taps, or a decay picture in time |
  | Modulation | cyan | the LFO and voices drawn in motion |
  | Pitch | pink | a keyboard or spectrum shift |

  Within a family the layout repeats; across families each device has its own centrepiece.

## Flagship (Vital as inspiration)
- **Wide** (tablet, desktop, phone landscape): one screen.
  - Top: three oscillator panels side by side. Each has its wavetable in 3D, with drag for frame and warp, and knobs under it for level, pan, unison, detune and pitch.
  - Middle: Filter 1 and 2 with their curves and routing (series or parallel as a switch drawn between them), plus a small FX rack summary.
  - Bottom: the mod sources as tabs: Env 1–3, LFO 1–4, Random, Macros. The open source is drawn big.
  - Drag any source's ⊕ handle onto any knob to modulate it. The knob grows a ring, and dragging the ring sets the amount.
- **Phone portrait:** three swipeable panels.
  - **Oscillators**, **Filters** (filters and FX) and **Modulation** (envelopes, LFOs, the matrix); names chosen by the owner, 2026-11-17.
  - A mod-source strip stays pinned at the bottom of all three, so drag-to-modulate works across panels: drag a source onto the edge to flip panels.
  - A small dot row shows the panel.
- **Matrix:** a compact list on the Modulation panel, not a separate tab.
- **QoL:**
  - the keyboard strip can be shown or hidden, to play while editing;
  - Init and a Random patch with an amount;
  - oscillator copy and paste;
  - a "What's modulating this?" highlight on a hold.

## Effects (after the #227 consolidation)
- **EQ:** the response curve is the screen.
  - A tap on the curve adds a band, and a drag moves it. A pinch, or the knob row under it, sets its Q.
  - The chosen band's knobs (freq, gain, Q, type, dynamic threshold and range, M/S) sit in one row under the curve.
  - Live spectrum, pre and post. A solo-band listen while holding a node.
  - Modes: Bands, Graphic, DJ and Tilt each draw in their own style on the same grid.
- **Filter:** the curve with a big cutoff/resonance puck, and the model picked from a strip of small curve icons. The auto-filter and wah LFO or envelope is drawn moving the puck.
- **Compressor:**
  - the transfer curve, with threshold and knee handles;
  - a scrolling trace of the input, with gain reduction in yellow;
  - mode chips (Down, Up, Expand, Duck), detection chips (RMS, Peak, ISP) and the sidechain source picker;
  - knobs for attack, hold, release, ratio and amount.
- **Limiter:** a big gain-reduction meter, ceiling, release, ISP, and a loudness readout (LUFS).
- **Transient:** the attack/sustain split drawn on the waveform, with two big knobs.
- **Drive:**
  - the transfer curve morphs with drive;
  - a harmonics bar shows the even and odd balance;
  - modes are cards (Tape, Tube, Fold, Clip, Phase), each with its own curve colour;
  - pre and post tone knobs, plus Mix.
- **Drive's amp and pedal modes:** the amp modes show an amp face (tone stack knobs in a row, as on an amp). The pedal modes show a pedal face, with a footswitch for bypass. Both keep Drive's transfer curve as the visual.
- **Convolver Cab mode:** a picker of cabinet cards with the speaker's response curve, mic position (centre to edge) and distance.
- **The effect browser:** purpose chips on top (Guitar, Vocals, Drums, Bass, Mixing, Mastering, Sound design, Lo-fi), then the chain templates of that purpose, then the devices and presets.
- **Drive's Bands mode:**
  - the live spectrum with 1–3 crossover handles;
  - each band a coloured strip under it, holding its drive type (a chip), amount and mix, plus solo, mute and Clean;
  - a tap on a band selects it, and the transfer curve shows that band.
- **Bit distortion:** a staircase waveform view (bits and rate drawn), plus bitwise mode chips.
- **Utility and stereo:** a goniometer and correlation meter; width, balance, Haas, mono-below and channel swap.
- **Chorus and Flanger:** the voices drawn as moving dots in stereo, with modes as chips.
- **Phaser:** the notches drawn sweeping.
- **Tremolo and Pan:** the LFO shape with a stereo puck.
- **Delay:**
  - the taps drawn in time, in ping-pong lanes, that you can drag;
  - modes Digital, Ping-pong and Tape. Tape shows reels whose wow and flutter wobble;
  - a sync and time toggle, plus feedback, filters and ducking.
- **Reverb:** a decay picture (early reflections and tail) with size and decay drawn. The algorithms (Hall, Room, Plate, Spring, Shimmer) are cards. Pre-delay, damping, width and Mix.
- **Pitch and Shift:** the spectrum before and after, a semitone dial with a fine knob, and Shift in Hz.
- **New devices:**
  - Exciter and bass enhancer: harmonics bars.
  - Pitch correction: the note line with snapping.
  - Vocoder: band bars.
  - Analyzer, tuner and loudness meter: meters.
- **Recording tools:**
  - **Noise reduction:** the spectrum with the learned noise floor drawn under it, and **Learn** as a big button. Reduction and smoothing knobs.
  - **Pedal gate:** a big, pedal-like open or closed light, a threshold knob with the input level moving across it, and a decay knob; a scrolling trace shows where it cut.
  - **De-hum:** the harmonics as spikes that dip when removed.
  - **De-click, de-plosive, de-reverb and breath:** before-and-after waveforms.
- **AutoStacc pack:**
  - each pack device has its own "toy-like" centrepiece (bit-shift shows the bit lanes flipping, warp a bending grid, spectral a frozen spectrum you can paint, glitch a slice grid lighting up);
  - each has the AutoStacc badge in the header.

## Open questions (owner)
- Any device above whose centrepiece should be different.
