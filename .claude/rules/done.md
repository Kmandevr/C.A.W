---
paths:
  - "engine/**"
  - "app/**"
  - "examples/**"
---

# Definition of done for instruments and devices (owner, 2026-11-25)

Written after 1.1.3-alpha.1 shipped dead knobs, identical piano characters, a synth-like organ and generic pages
(`docs/decisions.md`, 2026-11-25). Nobody needs to restate these. Before every release, ask: "Would the owner,
opening this on the phone, find it, use every control, and hear something believable?" If any part is no, it isn't done.

## Before building
- Never work on something being replaced: check it is the end state.
- Research what makes the real thing recognisable, from primary sources (JASA, Fletcher & Rossing, CCRMA, DAFx,
  UNSW music acoustics): attack, partials and inharmonicity, decay, vibrato, the noises that belong to it and their
  level, the body and the room. Learn what the best products do (Pianoteq, Organteq, Hauptwerk, SWAM, Spitfire,
  Superior Drummer), without copying code.
- Pick the method per part, by the owner's rule: synthesize only the vibrating source; use recordings (CC0/CC-BY,
  about 15 MB in total) for bodies, rooms and every noise or transient.
- Write a short spec with measurable targets (e.g. a principal's chiff 20-60 ms, ranks 1-3 cents apart).

## Measured, not assumed
- Render every preset and note range in a test harness and compare against the spec and a reference recording:
  spectral envelope, attack time, T60 and noise-to-tone ratio, within stated tolerances.
- Automatic red flags, each a failing test:
  - peak far above RMS (stray spikes);
  - variants closer than a spectral-distance threshold (identical characters);
  - a parameter whose min-to-max sweep changes nothing measurable, through the engine's project path (dead knobs);
  - noise events off their note-on, note-off, bow or breath events;
  - pitch jumps or drift that aren't intended.
- Every knob does what its name says, by an amount a listener hears.
- For each instrument, write 3-5 sentences on how it should sound against how the render measures.

## UI is part of the feature
- An instrument is done only with its own page in the Timber-editor layout: a live picture drawn from display data,
  draggable playing positions, knob sections, the mod strip, and three swipe panels on a phone. A generic knob page
  is never done.
- A widget test renders the page at 360x800 and 1280x800, drives every control with the shipped gestures (sideways
  drag, rest-drag, tap) and checks that the engine values change. A gesture change is tested on every control type.
- Send the owner screenshots of every new page with the release.

## Workflow
- Two or three agents in parallel (one researching the next instrument, one building, one writing the measurement
  harness), each briefed fully and checked on partway, not only at the end.
- An `audio-reviewer` reviews every engine diff, and a `code-reviewer` reviews before the PR.
- Run the full local suite before pushing, and push once per complete fix.
- Ship one instrument done right per release, not four half-done ones.
