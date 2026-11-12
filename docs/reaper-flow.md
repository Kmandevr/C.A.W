---
title: REAPER's flow and C.A.W's
summary: REAPER's path from a new project to a finished render, step by step with sources, beside C.A.W's current flow, the gaps, phone equivalents and a build plan ranked by what makes a song easier to finish.
updated: 2026-11-12
---

# REAPER's flow and C.A.W's

**Owner (2026-11-10):** "look at the flow of REAPER and match that as well", after the arranger was made to work like REAPER's (#172, [decisions](decisions.md)), and: "The goal is to make it really easy to use." So this note takes REAPER's flow where it is simple and direct. Where REAPER is powerful but fiddly (deep dialogs, modifier-heavy gestures, the routing matrix), the plan puts an easy path first, with sensible defaults and one obvious way to do each thing, and keeps REAPER's depth one step behind it.

This is a **plan**, except build steps 1 (clip editing) and 2 (loop range, markers and regions), built 2026-11-10 and described as built in [App](app.md): nothing else below section 2 is built. The arranger's gestures (moving, copying, trimming items, drops below the last track, FX drag and drop) are in [UI design: REAPER reference](ui.md#reaper-reference-the-arranger-copies-it) and are not repeated here.

**Sources.** **[Fact]** unless marked, checked 2026-11-10 in *Up and Running: A REAPER User Guide* v7.85 ([PDF](https://www.reaper.fm/userguide/ReaperUserGuide785c.pdf), "UG", section and printed page; the printed pages match the PDF's page numbers) and the [REAPER Quick Start](https://www.reaper.fm/guides/REAPER%20Quick%20Start.pdf) ("QS", a three-page key sheet with no sections). These are REAPER's defaults on Windows; its keys and mouse modifiers can be changed (UG 15.1, p. 299). C.A.W's side is from [App](app.md) (authoritative for what ships), [UI design](ui.md), [Actions](actions.md) and the [roadmap](roadmap.md), checked against `app/lib/` the same day.

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
| Arm, monitor, record | Record (Ctrl+R) arms the selected track, counts in a bar and starts playback; Stop writes the take as a new pattern clip, with a "Keep take?" toast and Undo (`lib/model/live_midi.dart`). A USB keyboard (Android) or the on-screen keys and pads play the armed or selected track at any time (always-on monitoring). The metronome and count-in are on Record's long-press. Record arm and Input are in the track menu. There is no audio recording or record mode choice ([roadmap](roadmap.md) Stages 5, 7). |
| Loop recording, takes | Each pass of a loop recording is a take of one clip; the take chip (‹ n/N ›) and the clip menu's Takes pick one; Record's long-press sets Overdub or Replace (2026-11-11). No take lanes or comping (roadmap 7.5). |
| Editing clips | A MIDI clip shows its notes as a mini piano roll (2026-11-10 evening; `lib/ui/arrange/clip_preview.dart`). Drag to move (also to another track), Ctrl or a second finger copies with its own notes, both edges trim, Alt-drag shifts the source offset, Ctrl+drag or a double-tap draws an empty clip ([UI design](ui.md#arrangement-workspace)). Ctrl/Shift-click, a right-drag marquee or the phone's Select mode select several, which drag together; a clip bar has Split (S, at the playhead), Glue, Duplicate, Delete and a Properties sheet (name, colour, length, offset, loop, mute, lock) ([App](app.md), Clip editing). The long-press menu also duplicates linked (C.A.W.'s pooled MIDI) and exports as MIDI. No audio clips, so no fades, crossfades, clip gain or stretch markers (roadmap 3.4). |
| MIDI editor | Double-tap a clip: its notes open in the focus view's Clip tab (the piano roll). Draw/Select/Curve/Erase tools, snap magnet with triplets and adaptive grid, velocity and chance lanes, per-note pitch, pressure, timbre and vibrato curves, quantize to the grid (`roll.notes.quantize`), generators (Euclid, humanize, arpeggiate…), MIDI import and export ([UI design](ui.md#editors)). A Quantize… sheet (grid, starts/ends/both, strength, swing, humanize, previewed live, Bypass), step input from the roll's keys or a MIDI keyboard, connect notes and tremolo (2026-11-11, WP-K2). No MIDI CC lanes inside a clip (roadmap 6.3); a clip's .mid export carries its track's automation as CCs. |
| Routing | Folders nest to any depth, indented with guide lines, solo and mute acting on everything inside (2026-11-10 evening); a folder can be a bus (children summed, group volume and pan, its own effects). Sends to buses (level, pre/post, mute), "Send to… › New reverb bus", sidechain keys for the ducker, compressor and gate, a routing view of chips; routing loops refused (2026-11-11, #175). No receives list or routing matrix; effects on a track run in a fixed serial chain. |
| Automation | Track volume and pan lanes, and project lanes for module parameters, globals and native effect and instrument parameters, edited by hand (tap to add points, drag them, sliders, curve previews, their own undo) or written by the transport's Automate button in Touch, Latch, Write or Read (`lib/model/automation_writer.dart`). A track's lanes open under it in Arrange from its envelope button and are edited there in place, drawn live while written (`lib/ui/arrange/track_lanes.dart`, 2026-11-10 evening). Each lane has an arm button (2026-11-11). No per-track mode, no freehand drawing or segment bend in the lanes. |
| Mixer | Upright REAPER-style strips, master first: chain slots, output and a Send button, send knobs, pan, a REAPER-tapered fader, meter, M, S; tap a slot for its parameters or device UI; the master strip shows the master FX chain's slots, and a long-pressed slot drags onto another strip to copy (Alt moves) it (2026-11-11). |
| Markers, regions, grid, tempo | One tempo and meter per project, typed or tapped; adjustable snap with Shift to bypass; long-press-drag makes a time selection; tap sets the edit cursor; 1–0 jump to markers, a region drags with its clips (Alt) or copies them (Ctrl or a second finger), and Markers and regions… lists them (2026-11-11). A drag along the ruler draws a loop range (handles adjust it; ⟳ or R toggles it; off, the song loops at its end); a long press on the ruler adds a named, coloured marker or region that a tap jumps to and a drag moves; Shift+M, Shift+R, Ctrl+] and Ctrl+[ ([App](app.md), Loop range, markers and regions). No tempo map (roadmap 6.2). |
| Actions, keys, layouts | ? opens the action list (search, see keys, run); a key bindings editor (Settings › Key bindings); macros; editable piano-roll toolbar; Vim mode ([Actions](actions.md)). Arrange has few actions (track select, volume, pan, mute, solo, add, delete, move). Docking presets Arrange, Mix and Code; each screen shape saves its own layout ([UI design](ui.md#layout)). |
| Render | Export song: the mix and aligned stems (tracks, buses) over the song, the loop, the selection or each region, a tail (none, seconds, until silent), peak or LUFS normalising, 16/24-bit PCM (TPDF dither at 16) or 32-bit float WAV at 44.1/48/96 kHz, names from a pattern, and a queue that survives restarts. Exporter keeps Quick Export (the loop), free-length, one-shot, wavetable and MIDI exports, profiles and history. No other formats than WAV. |
| Freeze | Not built (roadmap 1.2, 6.4). |
| Media explorer, project bay | Files: a Unity-style browser (tree, grid, inspector; a drawer on a phone), openable beside the tracks in Arrange so items are dragged onto tracks or the FX stack; imported MIDI files are listed with their patterns. No audio files to preview (no audio clips yet) and no "replace everywhere" view. |

## 3. Gaps

**Effort:** S = one app area, days; M = several app areas or a small engine change; L = a new engine capability or a roadmap stage. **Phone (easy path)** is the touch way to do the step, using the existing [gesture vocabulary](ui.md#one-gesture-vocabulary) (tap, long-press for options, drag, a second finger for Ctrl, a resting finger for Shift, double-tap, pinch). REAPER's own advice, "right click everything", becomes "long-press everything".

| Step | REAPER | C.A.W today | Gap | Effort | Phone (easy path) |
|---|---|---|---|---|---|
| Templates | Save/insert project and track templates; default template (1.1) | **Built** (gap 10, 2026-11-11): Save as template, New from template with a default, track templates in the add-track menu, bundled starters | — | — | Project menu › Save as template; track menu › Save as track template; templates appear in New and in the New track zone's long-press |
| Add instrument track | Insert virtual instrument on new track: one step, armed and named (1.2) | Drop an instrument below the last track, or add a track then pick | One "New instrument track" that also arms and selects | S | + in the toolbar opens the instrument browser; the pick makes a named, selected, armed track |
| Arm and record MIDI | Arm, input, monitor, Ctrl+R; keep or delete on stop (1.3) | **Built** (gap 3, 2026-11-10): Record from a USB keyboard or the on-screen keys and pads, metronome, count-in, Keep take? toast | On-screen keys; metronome; count-in; arm per track; keep or discard on stop | M | Record works with no keyboard by opening a bottom keyboard or pads; a metronome toggle and count-in in the transport's long-press; a "Keep take?" toast with Undo instead of a dialog |
| Record audio | Arm, input, monitor, record to items (1.3) | None | Audio input, audio clips, monitoring | L (Stages 3, 5, 7) | Same Record button; the input picked once per track; monitoring on by default with a headphones warning |
| Loop recording, takes | Time selection auto-punch, takes per pass (1.4) | **Built for MIDI** (gap 3): each pass a take, the take chip, Overdub and Replace modes | Audio takes | L (audio) | Loop range drawn on the ruler; each pass adds a take; a take chip on the clip (‹ 2/4 ›) swipes between takes |
| Comping | Slice and dice, comp lanes (1.4) | None | Take lanes and comp | L | A "Takes" view on long-press: lanes stacked, a drag across a lane picks that span (REAPER's comp-area drag) |
| Split | S at the edit cursor (1.5) | **Built:** S or the clip bar's ✂ splits the selected clips (or every clip) at the playhead | — | — | Tap empty lane space (moves the playhead), tap a clip, ✂ in the clip bar |
| Glue | Glue selected items into one (1.5) | **Built:** G or the clip bar's Glue | — | — | Select two or more clips, Glue in the clip bar |
| Multi-select | Marquee (right-drag), Shift/Ctrl click (1.5) | **Built:** Ctrl/Shift-click, right-drag marquee; selected clips drag, copy, duplicate, delete and glue together | — | — | Select mode (the clip bar's ☑, or long-press › Select several): taps add clips, a long-press drag draws a box |
| Item properties | F2: position, length, loop, mute, rate, pitch… (1.5) | **Built:** F2 or the clip bar opens a sheet: name, colour, length, offset, loop, mute, lock | Transpose, linked/independent in the sheet | S | Clip bar › Properties; the sheet follows the selection, lengths typeable as bars.beats.steps |
| Fades, crossfades | Drag handles; shapes on right-click (1.5) | No audio clips | Fades and crossfades on audio clips | M after audio clips | Big corner handles on a selected clip only; long-press a handle for shapes |
| Stretch, stretch markers | Alt+drag edge, Shift+W markers (1.5) | No audio clips | Stretch and markers | L (roadmap 8.1) | Later; a Stretch tool in the selection bar rather than a modifier |
| Pooled vs unique | Ctrl copy unique, pooled by modifier or preference (1.5) | Copies unique; linked copy in the menu | None for behaviour; make the link visible and breakable | S | A link badge on linked clips; long-press › Make unique |
| Open MIDI editor | Double-click opens it (1.6) | Double-tap opens the focus view's Clip tab | Phone: the roll is a part-height panel | S | Double-tap opens the roll; a swipe up on its header makes it full screen (the focus view already raises) |
| Quantize | Dialog: strength, swing, position/length, bypass preview (1.6) | **Built** (2026-11-11): ⋮ › Quantize… sheet: grid, triplets, starts/ends/both, strength, swing, humanize, the notes moving live (heard while playing), Bypass; Ctrl+U stays the quick grid quantize | — | — | ⋮ › Quantize…; Apply is one undo step |
| CC lanes | + lane, pick CC, draw (1.6) | Velocity, chance and per-note expression lanes | Lanes for instrument parameters inside a clip (clip-following automation, roadmap 6.3) | M | A + lane picks any instrument knob; draw with a finger; double-tap a point deletes it |
| Step input | Step size, play keys to enter (1.6) | **Built** (2026-11-11): ⋮ › Step input; the roll's keys or a MIDI keyboard enter a note a grid step long at the cursor and move on; held keys make a chord; Rest and Done in the step bar | The slide-up on-screen keys and pads don't enter steps yet | S | Turn it on, tap the roll's keys |
| Sends | Drag route button to a track; send level and type (1.7) | Built (2026-11-11): Send to… with New reverb/delay bus, send knobs, pre/post and mute | Sends and returns | L (roadmap 2.1) | Track menu › Send to… lists tracks and "New reverb bus" (creates a bus with a reverb and the send in one tap); a send knob on the strip |
| Folders as buses | Folder = submix automatically (1.7) | Folders, opt-in bus | Make a folder a bus by default when it has an effect or is used as a group | S | Keep the bus switch; turn it on automatically when an effect is added to a folder (ask once) |
| Sidechain | Four channels, drag into the plug-in, aux detector (1.7) | Built (2026-11-11): Key: <track> under the header of the ducker, compressor and gate | Sidechain input on effects | L (roadmap 2.2) | On a compressor's editor, a "Listen to" picker lists tracks; no channel counts shown |
| Routing matrix | Alt+R grid (1.7) | A routing view of chips per track (outputs, sends, keys) | A whole-project routing view | M after sends | Desktop and tablets only; phones use the per-track Send to… list |
| Automation write | Envelope button, arm, Read/Touch/Latch/Write (1.8) | **Built** (gap 4, 2026-11-10; lane arm 2026-11-11): the Automate button, Touch by default, an arm per lane | Per-track mode | S | One Automate toggle in the transport (red): while it is on and playing, any knob or fader moved is written in Touch mode, making its lane if needed; long-press the toggle for Latch, Write and Read |
| Automation items | Reusable envelope sections, LFO shapes (1.8) | Points only | Shapes and reusable sections | M | Later: a lane's long-press › Insert shape (ramp, LFO) over the time selection |
| Mixer sends, master FX | Send rotaries, FX drag between strips (1.9) | **Built** (gap 9, 2026-11-11): send knobs, master FX slots, FX drag between strips (copy; Alt moves) | — | — | Master strip gets FX slots like a track; long-press a slot and drag it onto another strip to copy |
| Markers | M, 1–0, ], [, drag, rename (1.10) | **Built:** long-press the ruler › Add marker, Shift+M; tap jumps, drag moves, long-press renames, colours, deletes; Ctrl+] / Ctrl+[; 1–0 (2026-11-11); the Markers and regions list | ‹ › on a phone without keys | S | ‹ › in the transport's long-press (the transport is another branch's work) |
| Regions | Shift+R, ruler drag, move or copy with contents (1.10) | **Built:** long-press the ruler › Add region, Shift+R; named, coloured, dragged, Loop this region; with its clips by Alt-drag, copied by Ctrl-drag, a second finger or Duplicate with clips (2026-11-11) | Render a region | M | A second finger while dragging a region copies it with its clips |
| Loop range | Drag the timeline, R repeat (1.10) | **Built:** drag along the ruler, handles, ⟳ in the Arrange toolbar and R; the engine loops over it and the loop export uses it | — | — | Drag on the ruler; ⟳ toggles |
| Tempo map | Tempo and meter markers, tempo envelope (1.10) | One tempo and meter | Tempo and meter changes | L (roadmap 6.2) | Later: long-press the ruler › Tempo change here |
| Actions list | ?, search, run, assign keys, custom actions (1.11) | Built: list, keys editor, macros | Arrange actions (split, glue, marker, region, record, loop) are missing; no phone entry point | S | A search button in ⋮ More opens the action list on a phone; every new step above is an action |
| Screensets | Saved window layouts (1.11) | Arrange/Mix/Code presets, saved per screen shape | Save and name your own layouts | S | Desktop and tablets; phones keep their fixed sections |
| Render | Source, bounds, normalize, dither, formats, queue (1.12) | Export song: mix and stems, song/loop/selection/region bounds, tail, peak or LUFS normalize, 16-bit dither, a queue that persists (built 2026-11-11) | More formats (FLAC, MP3); selected items, razor areas; results as new tracks | S (formats) | The **Export song** sheet: Source, Range and Tail on top, Format, Loudness and Names in folds; Render queues |
| Freeze | Render/freeze tracks, unfreeze (1.12) | None | Freeze a track to audio | L (needs audio clips and per-track render) | Track menu › Freeze; a snowflake on the header; tap it to unfreeze |
| Media explorer, project bay | Insert at cursor/new track, preview, replace everywhere (1.13) | Files browser with drag onto tracks | Preview of audio (after audio clips); "Used in project" with replace everywhere | S–M | Files gets a Used in project filter; long-press › Replace everywhere |

## 4. Build plan, ranked by "makes a song easier to finish"

Each step lists the easy path first and REAPER's depth behind it. **Owner** marks what needs the owner's direction before it is built (CLAUDE.md: "Before any UI work, ask the owner how it should look"); **Direct** marks what can be built from this note and existing UI patterns. All are **[Proposal]**.

1. **Clip editing basics (M). Built 2026-11-10** ([App](app.md), Clip editing): the clip bar (Split at the playhead, Glue, Duplicate, Delete, Properties, Select), docked at the bottom on a phone and in the toolbar when wide; S splits (owner), next track keeps ↓; Ctrl/Shift-click and a right-drag marquee, Select mode on a phone; several clips drag together; a properties sheet. Splits cut crossing notes at the split and give the right part its own pattern (REAPER, UG 22.9.1 and 13.35). Choices to confirm are in [decisions](decisions.md).
2. **Loop range, markers and regions (M). Built 2026-11-10** ([App](app.md), Loop range, markers and regions): a drag along the ruler draws the loop range with handles (owner), the toolbar's ⟳ and R toggle it, and the engine loops over it (`loop_range`, the loop export's bounds too); a long press on the ruler adds a marker or region (owner), named and coloured, that a tap jumps to and a drag moves; Shift+M, Shift+R, Ctrl+] / Ctrl+[. The phone's ruler is 44 px, markers and regions sharing its lower half. Regions that move or copy their clips, 1–0 jumps and the region list built 2026-11-11. Still to do: region render. Choices to confirm are in [decisions](decisions.md).
3. **The recording flow (M for MIDI). Built 2026-11-10** ([App](app.md), Frame: Record, On-screen keys and pads): Record works with no USB keyboard through a slide-up piano (scrollable octaves, velocity by where a key is struck) or a 4×4 pad grid (General MIDI drums on drum tracks, the key's scale elsewhere), as the owner chose; the engine's built-in click while recording (or always) and a 1-bar count-in, both on Record's long-press; each pass of a loop recording (the loop range or the song) is a take of one clip, the newest playing, picked from the clip menu's Takes; a "Keep take?" toast with Undo. **Record modes and the take chip built 2026-11-11:** Record's long-press picks New clip/takes, Overdub or Replace; a clip with takes shows ‹ n/N ›. Still to do: audio recording (L, roadmap Stages 3, 5 and 7).
4. **Automation writing (M). Built 2026-11-10** ([App](app.md), Frame: Automate): the Automate button in the transport (owner: Touch, button in transport); while it is on and playing, any knob or fader moved is written, its lane made if needed, thinned, one undo step per take; long-press for Latch, Write and Read; Write falls back to Read after a pass (REAPER's option). Volume lanes now reach +12 dB like the faders. The engine gained `caw_engine_release_touches` so a released Touch hears its lane again at once. Per-lane arm built 2026-11-11. Still to do: per-track mode.
5. **Sends and FX buses (L, roadmap 2.1). Built 2026-11-11 (#175)** except receives and a wide-screen matrix. Track menu › Send to… with "New reverb bus" making the bus, its reverb and the send in one tap; a send knob on the strip; pre/post in the send's long-press. Depth: receives and the routing matrix on wide screens. *Owner:* the send knob's look and the routing view (UI.3b). *Direct:* the engine's send nodes in the existing graph (F4).
6. **Render parity (M, plus L for stems). Built 2026-11-11** ([App](app.md), Exporter; [engine](engine.md#song-renders)): the Export song sheet: Source (mix, stems of tracks, buses or both, or both), Range (song, loop, selection, regions), Tail (none, seconds, until silent), Format (44.1/48/96 kHz, 16-bit with TPDF dither, 24-bit, 32-bit float), Loudness (peak or LUFS with a true-peak ceiling), file names from a pattern, and a queue that survives restarts, with progress, cancel and Save all to a folder. The engine renders the mix and every stem in one pass per range, so they line up; the mix equals playback bit for bit. *Owner:* the sheet's look, reviewed in the APK. Still to do: other formats than WAV (FLAC, MP3), selected items and razor areas as sources, adding the results as tracks, and freeze.
7. **Actions everywhere (S).** Every new step becomes an action with a key; the arranger gets REAPER's keys where they don't clash (M marker, Shift+R region, Ctrl+R record, R repeat); a search button in ⋮ More opens the action list on a phone. *Direct*, except key clashes with the owner's WASD keys (*Owner*).
8. **MIDI editor flow (S–M). Quantize sheet and step input built 2026-11-11 (WP-K2).** Double-tap opens the roll, a swipe makes it full screen; lanes for instrument parameters inside a clip (roadmap 6.3, clip-following automation). *Owner:* whether parameter lanes live in the roll or in the arrangement; the looks of the quantize sheet and the step bar (in the APK).
9. **Mixer parity. Built 2026-11-11:** send knobs (#175), master FX slots and FX drag between strips. Master FX slots (roadmap 2.4), send knobs after step 5, long-press-drag of an FX slot to another strip copies it. *Direct* once sends exist; the master chain needs the engine.
10. **Templates (S). Built 2026-11-11:** save a project or tracks as a template, New from template with a default, track templates in the add-track menu, bundled starters.

**Later, in roadmap order:** audio clips with fades and crossfades (Stage 3), tempo map (6.2), freeze (after stems and audio clips), comp lanes (7.5), stretch markers (8.1), automation items, saved layouts on wide screens, a Used in project view in Files.

## Owner questions

Recorded in [vision](vision.md#open-owner-decisions): the phone look of the Export sheet and the send knob. The owner chose S as Split, Touch automation from a transport button, and on-screen keys with pads (2026-11-10); the looks built for them are to confirm ([decisions](decisions.md)).
