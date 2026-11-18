---
title: REAPER's flow and C.A.W's
summary: REAPER's path from a new project to a finished render, step by step with sources, beside C.A.W's current flow; the gaps and the build plan are kept privately.
updated: 2026-11-18
---

# REAPER's flow and C.A.W's

**Owner (2026-11-10):** "look at the flow of REAPER and match that as well", after the arranger was made to work like REAPER's (#172, [decisions](decisions.md)), and: "The goal is to make it really easy to use." So this note takes REAPER's flow where it is simple and direct. Where REAPER is powerful but fiddly (deep dialogs, modifier-heavy gestures, the routing matrix), the plan puts an easy path first, with sensible defaults and one obvious way to do each thing, and keeps REAPER's depth one step behind it.

This is a **plan**, except build steps 1 (clip editing) and 2 (loop range, markers and regions), built 2026-11-10 and described as built in [App](app.md): nothing else below section 2 is built. The arranger's gestures (moving, copying, trimming items, drops below the last track, FX drag and drop) are in [UI design: REAPER reference](ui.md#reaper-reference-the-arranger-copies-it) and are not repeated here.

**Sources.** **[Fact]** unless marked, checked 2026-11-10 in *Up and Running: A REAPER User Guide* v7.85 ([PDF](https://www.reaper.fm/userguide/ReaperUserGuide785c.pdf), "UG", section and printed page; the printed pages match the PDF's page numbers) and the [REAPER Quick Start](https://www.reaper.fm/guides/REAPER%20Quick%20Start.pdf) ("QS", a three-page key sheet with no sections). These are REAPER's defaults on Windows; its keys and mouse modifiers can be changed (UG 15.1, p. 299). C.A.W's side is from [App](app.md) (authoritative for what ships), [UI design](ui.md) and [Actions](actions.md), checked against `app/lib/` the same day.

## 1. REAPER's flow, start to finish

### 1.1 New project and templates

1. File › New Project (Ctrl+N); save with Ctrl+S (QS). At startup REAPER opens the last project tabs, a new project or a prompt, as set in Preferences › General (UG 2.1, p. 31).
2. **Project template:** File › Project Templates › Save As Project Template saves tracks, their settings and FX, project settings and the screen layout; File › Project Templates › *name* starts a project from it. Preferences › Project can name one template for every new project (UG 3.13, p. 63).
3. **Track template:** select tracks, Track › Save tracks as track template (optionally with items and envelopes); Track › Insert track from template brings them back with their FX, sends and receives between those tracks (UG 3.11, p. 63).

### 1.2 Tracks and instruments

1. Insert a track with Ctrl+T, Track › Insert new track, or a double-click in the empty track panel; it goes below the selected track, or at the end when the double-click is below the last track (UG 3.4, p. 59). Insert › Multiple tracks adds several (UG 3.6, p. 60).
2. Double-click the name area to name it; recorded files are named after the track (UG 3.4, p. 59).
3. **Instrument:** Insert › Virtual instrument on new track lists the installed instruments; a double-click creates the track "armed and named", with the instrument shown (UG 3.33, p. 73). Dragging an instrument from the FX browser to an empty part of the track panel does the same (UG 3.33, p. 73). Instruments are FX in the track's chain ([UI design](ui.md#reaper-reference-the-arranger-copies-it)).

### 1.3 Arm, monitor and record (audio and MIDI)

1. Record mode: Normal (Options menu) (UG 3.5, p. 59).
2. Click the track's **Record Arm** button (it turns red and shows the Input button); pick the input from the Input menu (UG 3.5, p. 59).
3. **Monitoring** is on by default: Monitor Input is the first item of the arm button's right-click menu (UG 3.5, p. 59).
4. Set the level at the source, aiming at about −10 dB peaks; the track fader sets only playback level (UG 3.5, p. 59).
5. Record with the transport's Record button or Ctrl+R. Stopping with Record or Ctrl+R keeps the new items; stopping with Space or Stop asks which to keep or delete (UG 3.5, p. 60).
6. Tracks can be armed while recording, and disarming one stops just that track (UG 3.5, p. 60). Selecting several tracks and arming one arms them all (UG 3.6, p. 60); *Automatic record arm when track selected* arms a track by selecting it (UG 3.7, p. 61).
7. **Metronome:** Options › Metronome enabled or the toolbar's metronome button; right-click it for metronome and pre-roll settings (UG 3.8, p. 61).
8. **MIDI:** arm, then on the arm button's menu turn on Monitor Input and Record Input, choose Input: MIDI and the device (or the Virtual MIDI Keyboard, Alt+B) and a channel; put a synth in the track's FX; Ctrl+R to record and again to stop (UG 3.31, pp. 71–72).
9. **MIDI record modes:** Record Input (new take, existing events kept), overdub (adds notes in existing items), replace, touch-replace, latch-replace, and output (records what leaves the FX chain) (UG 3.32, p. 73).

### 1.4 Loop recording and takes

1. **Loop recording:** in Preferences › Audio › Loop Recording, add recorded media *On stop* and discard incomplete first or last takes; turn off *Loop points linked to time selection* and turn on *Record mode: Time selection auto-punch*; make a time selection and a loop around it, turn Repeat on and record. Each pass over the loop adds new material (UG 3.35, p. 74).
2. **Overlapping recording** splits existing items and adds takes by default; alternatives are tape mode (trims what was there) and adding lanes (UG 3.17, p. 66; 3.23, p. 68).
3. **Takes:** Ctrl+L shows all takes in lanes; T and Shift+T step through takes; *Explode all takes to new tracks* gives each take its own track (UG 3.20, p. 67; 3.22, p. 68).
4. **Comping, classic:** "slice and dice": split the item where the takes should change (S), then click the take to keep in each slice; Comps › Save as new comp names a combination to recall (UG 8.6, pp. 162–163).
5. **Comping, fixed item lanes (REAPER 7):** up to 256 lanes in a track; *Comp into new empty lane* adds a comp lane, a left drag over a source lane marks a comp area, and the comp copies those segments into new items, leaving the originals untouched (UG 8.12, p. 169; 8.12.3, p. 171).

### 1.5 Editing items

1. **Split:** select the item, put the edit cursor there, press S (QS; UG 7.2, p. 124). Drag the shared edge to move a split (QS).
2. **Glue:** select the items (right-drag marquee), right-click › Glue items; it makes a new item without harming the originals, and glued MIDI items open together in one MIDI editor (UG 7.33, p. 147).
3. **Trim and loop:** drag an item's edge; dragging the right edge past the source loops it (QS). Delete part of an item: select it and a time range, Ctrl+Delete (QS).
4. **Item volume:** drag down from the item's top edge (QS).
5. **Fades:** drag the fade handle at an item's edge; right-click it for shapes; Alt+click deletes a fade and Ctrl+click cycles its shape (UG 7.31, p. 144). Default fade length and shape are in Preferences › Project › Item Fade Defaults (UG 3.18, p. 66).
6. **Crossfades:** with auto-crossfade on (Alt+X or the toolbar), dragging one item over another makes a crossfade; Shift+drag moves it; double-clicking near its top opens the Crossfade Editor (UG 7.32, p. 145; 8.3, p. 162).
7. **Item properties:** F2, right-click › Item Properties, or a double-click on an audio item; the window stays open and follows the selection. It holds position, length, fades, snap offset, timebase, loop source, mute, lock, play all takes, take name, pitch, start in source and playback rate (UG 7.8, p. 134).
8. **Pooled or unique MIDI:** Ctrl+drag copies to a new discrete item; Shift+Ctrl+Alt+drag copies pooled, so edits to one change all; menu copy and paste makes discrete items by default; *Un-pool this item* in the source properties (Ctrl+F2) separates one (UG 13.35, pp. 270–271).
9. **Stretch:** Alt+drag an item edge time-stretches it (QS). **Stretch markers:** Shift+W adds one at the cursor (or a pair at a time selection); drag one to speed up or slow down the audio either side, Shift+Alt drags a pair together, and a vertical drag just beside one ramps the speed (UG 10.7, pp. 196–197).

### 1.6 The MIDI editor

1. Make an empty item: select the track (optionally a time selection) and Insert › New MIDI Item; MIDI items loop by default (UG 13.5, p. 242).
2. **Open:** double-click the MIDI item, Ctrl+Alt+E, or right-click › Open in built-in MIDI editor; by default it opens all selected MIDI items (UG 13.5, p. 242). E opens a smaller in-line editor in the arrange view (UG 13.34, p. 270).
3. **Draw:** drag left to right to draw a note (its length snaps); a double-click inserts a note one grid long, and a double-click on a note deletes it; drag a note's edge for length, its top for velocity, the note itself to move it. The keyboard on the left previews notes (UG 13.15, p. 256).
4. **Quantize:** Edit › Quantize events: which notes, position and/or length, strength, grid (straight, triplet, dotted, swing), with a Bypass switch to compare while tweaking (UG 13.23, p. 261).
5. **CC lanes:** + adds a lane and its drop-down picks the controller (UG 13.9, p. 247); double-click adds a point, a pencil drag draws a sweep, Alt+click deletes (UG 13.10, p. 249). A lane's menu has curve shapes and an LFO generator (UG 13.9, p. 247).
6. **Step input:** turn on step recording, pick a note length, then each key played (or F1–F12) enters a note and moves on a step (UG 13.26, p. 263).

### 1.7 Routing: sends, folders, sidechain, matrix

1. **Sends:** drag from a track's route button onto the destination track; or right-click the route button › Sends or Receives › a track (a new track is offered too). A send has volume, pan, and audio and/or MIDI; the default type is post-fader (UG 2.21, pp. 48–49; QS).
2. **Folders as buses:** make the track above a group a folder (its folder button); the children's direct master send is turned off automatically and they play through the folder, whose volume, mute and FX act on the submix (UG 5.12, p. 99; QS).
   Folders nest to any depth; a track inside a folder made a folder becomes a second-level folder, and an action on a folder acts on its whole contents (UG 5.13.5, p. 102).
3. **Sidechain:** give the receiving track four channels, drag the source track's route button into the compressor's window, and set the compressor's detector to the auxiliary input (UG 17.5, p. 341).
4. **Routing matrix:** Alt+R shows every send, receive and input as a grid of cells; click a cell to route, right-click it for its controls (UG 2.23, p. 49).

### 1.8 Automation

1. **Write:** click the track's envelope button; in the envelopes window make the parameter Visible and Armed and set the mode to Write; play and move the control; then set the mode back to Read or Trim/Read (UG 18.5, pp. 360–361).
2. **Modes:** Trim/Read (envelopes play, controls don't move), Read, Touch (writes while a control is held), Latch (writes from the first touch until stop), Latch Preview (try values, then write them with an action) and Write (overwrites everything armed while playing) (UG 18.8, p. 363). The mode is set from the envelope button's right-click menu, the lane's menu or the track menu (UG 18.8, p. 362); after Write, REAPER can switch itself back to Trim/Read (UG 18.8, p. 363).
3. A preference adds envelopes for any control tweaked in a write mode (UG 18.5, p. 361).
4. **By hand:** V and P show volume and pan envelopes; Shift+click adds a point, Alt+click deletes one, Ctrl+drag draws freehand, Alt+drag bends a segment (QS); a click-drag moves a segment up or down or a point anywhere (UG 18.14, p. 367). Envelopes sit in their own lanes under the track or over its items, shown from the track's Envelopes/Automation button (UG 18.1, p. 359; 18.16, p. 368).
5. **Automation items:** make a time selection, right-click the envelope › Automation items › Insert new automation item; its properties can generate a shape such as an LFO; items can be copied pooled or unpooled (UG 18.40, pp. 380, 382).

### 1.9 The mixer

1. View › Mixer (Ctrl+M); its strips work like the track panel's controls (UG 11.1, p. 205).
2. **FX inserts in the strip:** click an empty slot to add FX; drag to reorder or copy to another track, Alt+drag to move; Shift+click bypasses, Alt+click removes (UG 11.5, p. 209).
3. **Sends in the strip:** each send shows a small rotary for its level; clicking the empty sends area opens the routing window (UG 11.6, p. 210).
4. FX parameters can be shown as controls in the strip (UG 11.5, p. 210).

### 1.10 Markers, regions, grid and tempo

1. **Markers:** M adds a marker at the edit cursor, Shift+M asks for a name; 1–0 jump to markers 1–10, ] and [ to the next and previous; drag to move, Alt+click to remove, Shift+double-click to rename or colour; double-clicking the ruler between two markers selects the span (UG 9.2, p. 176).
2. **Regions:** Shift+R makes one from the time selection, Alt+drag on the ruler draws one; drag moves a region with its contents, Ctrl+drag copies it with them, Alt+drag moves only the region; right-click › Render region (UG 9.8, p. 179).
3. **Loop and time selection:** drag the timeline for a loop, drag empty track space for a time selection, Esc clears; R toggles repeat; Shift+double-click an item sets the time selection to it (QS).
4. **Grid:** the toolbar's magnet (right-click for settings); Alt+S toggles snap, Alt+L opens Snap/Grid Settings, with a swing grid (UG 7.26, p. 141; QS).
5. **Tempo:** type in the transport's BPM, click it to tap tempo; click the tempo display for the time signature (QS; UG 10.8, p. 199). Tempo and time-signature changes are markers inserted by right-clicking the ruler, or points on the master's tempo envelope; the project timebase should be beats (UG 10.8, p. 199; QS).

### 1.11 Actions, shortcuts and layouts

1. **Action list:** ? opens it; type in the filter to search every action, Run one, or select it and Add a key; a key already used asks before it is reassigned (UG 15.2, p. 299; 15.5, p. 302). Search can match synonyms (UG 15.4, p. 302).
2. **Custom actions (macros):** New action, drag or double-click actions into it, reorder, optionally one undo point, then give it a key or put it in a menu (UG 15.15, p. 307). Key maps export and import (UG 15.14, p. 307); menus and toolbars are editable too (UG 15.1, p. 299).
3. **Screensets:** Ctrl+E opens Screensets/Layouts; a window screenset saves which views are open and where, for any project, and loads with a double-click (UG 12.9, p. 229). Track view screensets save track heights and scroll per project (UG 12.8, pp. 228–229).
4. QS's last advice: "Right click everything to find out what it does."

### 1.12 Render, render queue and freeze

1. File › Render (Ctrl+Alt+R) (UG 21.3, p. 413). Choose:
   - **Source:** master mix, selected tracks (stems), master mix + stems, selected tracks via master, region render matrix, selected items, razor areas (UG 21.5, p. 417);
   - **Bounds:** entire project (=START/=END markers if present), time selection, custom range, project regions, or from marker to marker (UG 21.3, p. 414);
   - file name with wildcards, sample rate, channels, speed, resampling; **normalize** (LUFS-I, RMS-I, peak, true peak and others) and brickwall limit, trim or pad silence, fades; **dither**; a second pass for FX tails; primary and secondary formats (WAV, AIFF, FLAC, MP3, OGG Vorbis or Opus, WavPack, video and others); add the results as new tracks; presets; dry run (UG 21.3, pp. 414–415).
2. **Queue:** *Add to render queue* saves the project as it is; File › Open Render Queue renders all or the selected ones (UG 21.9, p. 419).
3. **Freeze:** track menu › Render/freeze tracks (mono, stereo or multichannel) replaces the track's contents with a rendered audio item and takes its FX and receives off; Unfreeze restores them, one level per freeze (UG 6.17, p. 119).

### 1.13 Project bay and media explorer

1. **Media explorer:** browse real folders, shortcuts and databases, search with AND/OR/NOT (UG 4.2, p. 82); insert a file at the cursor on the selected track, at the time selection (stretched or looped to fit), on a new track or into a sample player; double-click or Enter does the default (UG 4.7, p. 87). Files can be dragged in too ([UI design](ui.md#reaper-reference-the-arranger-copies-it)).
2. **Project Media/FX Bay** (View menu): tabs for source media, media items, FX and FX parameters, item groups, take comps and automation items; replace a media file or FX everywhere it is used, select every instance, keep (retain) entries not in the project (UG 12.6, pp. 221–222).

## 2. C.A.W today, the same steps

All **[Fact]** from [App](app.md) unless linked elsewhere.

| Step | What a user does in C.A.W today |
|---|---|
| New project, templates | The app opens the last project (the default project, "mid tempo", on a first run). The project menu (the project name) has New project (the default template, Blank unless chosen), New from template… (bundled starters and saved ones; ☆ sets the default), Save as template…, Duplicate, Open and Delete; the track menu saves a track or folder as a track template, and the + button's long-press inserts one (2026-11-11). |
| Tracks, instruments | + in the Arrange toolbar adds a track; double-tap the New track zone below the last track for an empty one; drop a clip, pattern, MIDI file, instrument or effect there for a track holding it. The instrument is the FX chain's first slot, picked in the FX browser (Instrument… in the track menu, Replace, or drag and drop). Rename is in the track menu. |
| Arm, monitor, record | Record (Ctrl+R) arms the selected track, counts in a bar and starts playback; Stop writes the take as a new pattern clip, with a "Keep take?" toast and Undo (`lib/model/live_midi.dart`). A USB keyboard (Android) or the on-screen keys and pads play the armed or selected track at any time (always-on monitoring). The metronome and count-in are on Record's long-press. Record arm and Input are in the track menu. There is no audio recording or record mode choice. |
| Loop recording, takes | Each pass of a loop recording is a take of one clip; the take chip (‹ n/N ›) and the clip menu's Takes pick one; Record's long-press sets Overdub or Replace (2026-11-11). No take lanes or comping (roadmap 7.5). |
| Editing clips | A MIDI clip shows its notes as a mini piano roll (2026-11-10 evening; `lib/ui/arrange/clip_preview.dart`). Drag to move (also to another track), Ctrl or a second finger copies with its own notes, both edges trim, Alt-drag shifts the source offset, Ctrl+drag or a double-tap draws an empty clip ([UI design](ui.md#arrangement-workspace)). Ctrl/Shift-click, a right-drag marquee or the phone's Select mode select several, which drag together; a clip bar has Split (S, at the playhead), Glue, Duplicate, Delete and a Properties sheet (name, colour, length, offset, loop, mute, lock) ([App](app.md), Clip editing). The long-press menu also duplicates linked (C.A.W.'s pooled MIDI) and exports as MIDI. No audio clips, so no fades, crossfades, clip gain or stretch markers (roadmap 3.4). |
| MIDI editor | Double-tap a clip: its notes open in the focus view's Clip tab (the piano roll). Draw/Select/Curve/Erase tools, snap magnet with triplets and adaptive grid, velocity and chance lanes, per-note pitch, pressure, timbre and vibrato curves, quantize to the grid (`roll.notes.quantize`), generators (Euclid, humanize, arpeggiate…), MIDI import and export ([UI design](ui.md#editors)). A Quantize… sheet (grid, starts/ends/both, strength, swing, humanize, previewed live, Bypass), step input from the roll's keys or a MIDI keyboard, connect notes and tremolo (2026-11-11, WP-K2). No MIDI CC lanes inside a clip (roadmap 6.3); a clip's .mid export carries its track's automation as CCs. |
| Routing | Folders nest to any depth, indented with guide lines, solo and mute acting on everything inside (2026-11-10 evening); a folder can be a bus (children summed, group volume and pan, its own effects). Sends to buses (level, pre/post, mute), "Send to… › New reverb bus", sidechain keys for the ducker, compressor and gate, a routing view of chips; routing loops refused (2026-11-11, #175). No receives list or routing matrix; effects on a track run in a fixed serial chain. |
| Automation | Track volume and pan lanes, and project lanes for module parameters, globals and native effect and instrument parameters, edited by hand (tap to add points, drag them, sliders, curve previews, their own undo) or written by the transport's Automate button in Touch, Latch, Write or Read (`lib/model/automation_writer.dart`). A track's lanes open under it in Arrange from its envelope button and are edited there in place, drawn live while written (`lib/ui/arrange/track_lanes.dart`, 2026-11-10 evening). Each lane has an arm button (2026-11-11). No per-track mode, no freehand drawing or segment bend in the lanes. |
| Mixer | Upright REAPER-style strips, master first: chain slots, output and a Send button, send knobs, pan, a REAPER-tapered fader, meter, M, S; tap a slot for its parameters or device UI; the master strip shows the master FX chain's slots, and a long-pressed slot drags onto another strip to copy (Alt moves) it (2026-11-11). |
| Markers, regions, grid, tempo | One tempo and meter per project, typed or tapped; adjustable snap with Shift to bypass; long-press-drag makes a time selection; tap sets the edit cursor; 1–0 jump to markers, a region drags with its clips (Alt) or copies them (Ctrl or a second finger), and Markers and regions… lists them (2026-11-11). A drag along the ruler draws a loop range (handles adjust it; ⟳ or R toggles it; off, the song loops at its end); a long press on the ruler adds a named, coloured marker or region that a tap jumps to and a drag moves; Shift+M, Shift+R, Ctrl+] and Ctrl+[ ([App](app.md), Loop range, markers and regions). No tempo map (roadmap 6.2). |
| Actions, keys, layouts | ? opens the action list (search, see keys, run); a key bindings editor (Settings › Key bindings); macros; editable piano-roll toolbar; Vim mode ([Actions](actions.md)). Arrange has few actions (track select, volume, pan, mute, solo, add, delete, move). Docking presets Arrange, Mix and Code; each screen shape saves its own layout ([UI design](ui.md#layout)). |
| Render | Export song: the mix and aligned stems (tracks, buses) over the song, the loop, the selection or each region, a tail (none, seconds, until silent), peak or LUFS normalising, 16/24-bit PCM (TPDF dither at 16) or 32-bit float WAV at 44.1/48/96 kHz, names from a pattern, and a queue that survives restarts. Exporter keeps Quick Export (the loop), free-length, one-shot, wavetable and MIDI exports, profiles and history. No other formats than WAV. |
| Freeze | Built 1.0.5 (#209): the track hold menu's Freeze / Unfreeze and Bounce to audio, a clip's Bounce to audio; pre-fader, a snowflake on the header, dimmed devices, "Unfreeze to edit?" ([App](app.md)). |
| Media explorer, project bay | Files: a Unity-style browser (tree, grid, inspector; a drawer on a phone), openable beside the tracks in Arrange so items are dragged onto tracks or the FX stack; imported MIDI files are listed with their patterns. No audio files to preview (no audio clips yet) and no "replace everywhere" view. |

The gaps, the build plan and the owner questions are kept privately.
