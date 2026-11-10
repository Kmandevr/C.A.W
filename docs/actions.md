---
title: Actions, keys and macros
summary: Implemented action routing, macros, keymap persistence and configurable toolbars, plus clearly identified UI gaps.
covers: [app/lib/actions/, app/lib/ui/key_router.dart, app/lib/ui/key_bindings.dart, app/lib/ui/pattern_editor.dart, app/lib/ui/touch_quick_actions.dart]
updated: 2026-11-10
---

# Actions, keys and macros

**[Fact, checked 2026-11-01]** The action registry, keymap parser/serializer, per-area key routing, macros, Vim core, configurable piano-roll toolbar and phone Quick Actions strips are implemented (their customise sheets open as glass sheets while Glass is on). The app stores its keymap in a private app file named keys.txt. The action list searches actions, shows their current keys and runs them; it does **not** currently edit key bindings. Keymap files can describe toolbar and long-press menu entries, but there is no in-app general keymap/menu editor. The owner can still revise defaults and open points below. See [decisions](decisions.md) and [App](app.md).

## How it works

- **Everything is an action.** Each command the app can do has an id (`roll.notes.up`), a name and a description. Buttons, menus, keys and macros all run actions, so anything you can tap, you can bind. Reaper works the same way ([Sound on Sound](https://www.soundonsound.com/techniques/automate-anything-reapers-custom-actions)).
- **Areas, like Reaper's sections:** Global, Sounds (Builder), Tracks (Arranger), Pattern editor (roll and grid), Mixer, Engine Lab, Automation, Export, Files and Plugin Builder. A key can do different things in each area. Global keys work everywhere unless the area has its own binding.
- **The action list** (`?`, or Help → Actions):
  - search every action by name, with its keys
  - show the current key bindings for each action; **Edit keys** opens the key bindings editor
  - run the action
  - It also serves as the shortcut overlay the [UI design](ui.md#keyboard-pc) asked for.
- **The key bindings editor** (owner, 2026-11-05; `lib/ui/key_bindings.dart`), from Settings → Key bindings, the action list's **Edit keys**, or the `view.keys` action (no default key):
  - search every action and see its keys; a pencil marks one changed from the default
  - give an action a key by pressing it (each press adds a chord, up to three, so `G G` works; holding a key counts once; Cmd is Ctrl on macOS, as the router reads it) or by typing it (`Ctrl+Shift+K`), for phones. Typed keys are read as the keyboard sends them: `Shift+/` is `?`, and Shift with a plain digit is refused
  - a plain digit first is refused: it is always a count (`3D`)
  - before setting, it says what the key would replace (a key taken in the area moves to this action), clash with (one sequence starting another), or hide (an area key over a global one)
  - remove a key, reset one action (a default key another action has since been given stays with it, and the sheet says so), or **Reset all** (toolbars and long-press menus go back too; macros are kept)
  - it lists actions only: a key bound to a macro in `keys.txt` is not shown there, and Reset all removes that key (the macro itself stays)
  - every change saves `keys.txt`, written as what differs from the defaults (a removed default key is a `-` line)
- **Triggers** (owner chose all four):
  - keys: any combination with Ctrl, Shift and Alt
  - on-screen toolbars you fill with your own actions and macros, so the phone gets one-tap macros without a keyboard
  - long-press menu entries are supported by the keymap data format, but a user-facing menu editor/integration is not currently complete
  - later, MIDI controller notes and CCs, once device support is built ([architecture](architecture.md#variables-and-patterns-proposal))
- **Macros (custom actions):** a named list of actions run in order. Any step can repeat N times. Macros can be recorded from keyboard actions with Alt+Q and then replayed, bound or added to toolbars. The model/parser supports named step lists and repeat counts. There is no in-app step-list macro editor yet; edit the app-private keys.txt file manually for custom macro definitions.
- **Saving** (owner: both):
  - the app keymap, toolbars and macros persist in the app-private keys.txt file and are loaded over the shipped defaults
  - the file format can be edited manually; user-facing keymap import/export and project-carried macros are not implemented
- **Readable files,** so the owner and AI agents can edit them. **[Fact]** The keymap parser/serializer supports this text format; direct in-app editing of all bindings and menus is not yet available:

```
---
kind: keymap
name: My keys
---
# area      keys            action
roll        W               roll.notes.up
roll        Ctrl+W          roll.cursor.up
global      Space           transport.playstop   (play / pause)
global      Shift+Space     transport.stop
roll        Ctrl+Shift+E    macro "Run of four"

macro "Run of four"
  roll.select.copyafter * 3
  roll.notes.up
```

- **Phone without a keyboard:** the Quick Actions strip is available in Sounds, Tracks and Export when Settings → Motion and feel → Quick actions bar is on; it is off by default (owner, 2026-11-04: not very useful yet). The tune control lets you add actions or macros, remove them, reorder them and restore defaults. The piano roll keeps its own dedicated toolbar. Buttons dispatch through the action registry; they do not simulate key presses. Vim remains a physical-keyboard feature.

## Vim-style control

The owner wants the whole app, code editor included, to work like Vim (2026-10-28). It's for whenever a keyboard is connected, on PC or the phone. Touch stays a complete way to use the app on the phone, and nothing requires the Vim style.

- **Modes:**
  - **Normal** (the default): single keys run actions, using the keymap above, with WASD for movement.
  - **Insert:** keys type text, in the code editor, name fields and the command line.
  - **Visual:** movement keys extend the selection: a time × pitch rectangle in the roll, cells in the grid, layers in the Arranger.
  - Esc always returns to Normal, and the mode shows in the status bar.
- **Counts:** a number before a command repeats it. `3E` copies the selection three times after itself, `12W` moves notes up an octave, and `4]` makes a layer four steps longer. That's why the grid sizes moved from 1–4 to Alt+1–4.
- **Command line:** `:` opens it, with completion. Every action is a command by its name (`:quantize`, `:export loop`), and some take values: `:bpm 140`, `:grid 1/16`, `:key A minor`, `:len 4 bars`, `:vel 80%`.
- **Repeat:** `.` repeats the last change. With a count, `5.` repeats it five times.
- **Recording macros:**
  - Alt+Q starts recording into a named slot, and Alt+Q again stops (owner agreed). Vim uses `q`, but Q inserts a note in the owner's scheme.
  - `@` then the slot's name replays it, and `3@a` replays it three times.
  - A recording is saved as an ordinary macro, a list of actions, so it can be edited, bound to a key or put on a toolbar like the others.
- **Code editor:**
  - A setting turns Vim editing on in the code editor (owner: available, but never needed to use the app). It's off by default, so typing on the phone stays normal.
  - With it on, the editor has Normal, Insert and Visual modes and Vim's text commands: `dd`, `yy`, `p`, `cw`, `ciw`, `u`, `/` search, `n`, counts and `.`.
  - **Movement uses WASD here too** (owner): W A S D move the text cursor in Normal mode. **[Proposal]** Word jumps move to Shift+A / Shift+D, and line start and end to Home and End. `i`, `a` and `o` still enter Insert mode. Shift+W / Shift+S move half a screen.
- **Defaults and reset:** C.A.W ships with the keymap below. "Reset to defaults" works per area or for everything.
- **[Assumption]** Where the defaults say "like Reaper", they still need checking against Reaper's current action list. Reaper's own keys couldn't be confirmed from a reliable source on 2026-10-28.

## Default keys

Keys marked † are the owner's own scheme (2026-10-28). The rest are proposals to review. "—" means no default key; the action can still be bound, put on a toolbar or used in a macro.

### Global

| Action | Default keys |
| --- | --- |
| Play / pause (resumes where it paused; the id `transport.playstop` stays, so saved keymaps keep it) | Space |
| Stop: the next play starts from the beginning | Shift+Space |
| Undo / redo (the piano roll's own history inside it, a text field's own text undo while one has focus, such as the code editor; the project's everywhere else) | Ctrl+Z / Ctrl+Shift+Z (also Ctrl+Y) |
| Save now (projects also autosave) | Ctrl+S |
| Action list | ? |
| Show the Code / Arrange / Export panel | Ctrl+1 / Ctrl+2 / Ctrl+3 (already built; the panel is revealed in the dock) |
| Go to Mixer / Engine Lab / Automation | Ctrl+4 / Ctrl+5 / Ctrl+6 |
| Go to Files / Plugin Builder | Ctrl+7 / Ctrl+8 |
| New, open, duplicate, rename, delete project | — / Ctrl+O / — / F2 in the project menu / — |
| Tap tempo | T |
| Tempo up / down 1 BPM (Shift: 0.1) | Ctrl+= / Ctrl+- |
| Master volume up / down | — |
| Unmute layers the engine muted (overload) | — |
| Full screen for the current editor | F11 |
| Focus next / previous panel | Tab / Shift+Tab (focus traversal) |
| Open the long-press menu | Menu key or Shift+F10 |

### Builder (code)

| Action | Default keys |
| --- | --- |
| Run (compile and hot-swap) | Ctrl+Enter (already built) |
| Live auto-update on / off (and its delay, in settings or `:live 400ms`) | Alt+L |
| When swaps land: now, next beat, next bar (`:swap bar`) | — |
| Function library | F1 (already built) |
| Complete the word at the cursor | Ctrl+Space |
| Jump to the error | F8 |
| Solo preview on / off | Alt+P |
| New module from a template | Ctrl+N |
| Next / previous module | Ctrl+Tab / Ctrl+Shift+Tab |
| Rename / delete module | F2 / — |
| A pattern: switch between editor and text | Ctrl+T |

### Pattern editor (piano roll and drum grid)

Patterns have no note or curve-point cap (F7.1, 2026-11-04), so actions work on any size.

Notes:

| Action | Default keys |
| --- | --- |
| Move selected notes later / earlier one grid step | D / A, also → / ← † |
| Move selected notes up / down a semitone | W / S, also ↑ / ↓ † |
| Move the cursor one grid step or one semitone (selects the note it lands on) | Ctrl+W / A / S / D, also Ctrl+arrows † |
| Jump the cursor to the next note in that direction | Ctrl+Shift+W / A / S / D † |
| Insert a note at the cursor (last length used) | Q † |
| Copy the selection to just after it, and select the copy | E † |
| Shorter / longer by one grid step | Shift+A / Shift+D † |
| Invert a chord up / down (a single note: up / down an octave) | Shift+W / Shift+S † (the single-note part is a proposal) |
| Delete selected notes | Delete, Backspace |
| Select all / none | Ctrl+A / Esc |
| Select next / previous note in time | Tab / Shift+Tab |
| Add the note at the cursor to the selection | Ctrl+Shift+Space |
| Copy / cut / paste at the cursor / duplicate | Ctrl+C / Ctrl+X / Ctrl+V / Ctrl+D |
| Split notes at the cursor / join selected notes | Ctrl+E / Ctrl+J (Ableton uses these: [Live 12 manual](https://www.ableton.com/live-manual/12/live-keyboard-shortcuts/)) |
| Quantize selected notes to the grid | Ctrl+U (as in Live) |
| Hear the selected notes | Enter |

Note values and extras:

| Action | Default keys |
| --- | --- |
| Velocity up / down 10% (Shift: 1%); the next drawn note takes it | = / - |
| Probability: cycle 100, 75, 50, 25% | P |
| Ratchet: cycle 1, 2, 3, 4 | R |
| Slide on / off | L |
| Open the note's extras panel | Menu key, Shift+F10, or long-press |

Grid and view:

| Action | Default keys |
| --- | --- |
| Grid resolution 1, 1/2, 1/4, 1/8, 1/16, 1/32, 1/64, 1/128 (the finest the adaptive grid goes) | Alt+1 to Alt+8 (plain digits are counts, see [Vim-style control](#vim-style-control)) |
| Triplets on / off | Alt+0 |
| Snap (magnet) on / off (grid off) | N |
| Adaptive / fixed grid | Alt+F |
| Drag a length without snapping | hold Shift while dragging |
| Tools: draw, select, curve, erase | B, V, C, X |
| Switch piano roll / drum grid | G |
| Zoom in / out / fit the pattern (also Ctrl + wheel; Ctrl + Shift + wheel for the row height) | Ctrl+= / Ctrl+- / F |
| Show velocity lane / extras lanes | Alt+V / Alt+X (Ctrl+1/2/3 always switch areas, owner) |
| Hear notes on / off | ⋮ menu (no default key) |

Generators (buttons; no default keys):

| Action | Default keys |
| --- | --- |
| Euclid, random in key, arpeggiate, humanize, chord stamp | — |
| Legato (stretch each note to the next) | — |
| Reverse selection, invert pitch around the cursor | — |

### Arranger

| Action | Default keys |
| --- | --- |
| Select previous / next layer | W, ↑ / ↓ (S splits since 2026-11-10, owner: as in REAPER) |
| Pan left / right | A / D |
| Volume up / down (1 dB a press, at most 0 dB) | = / - |
| Mute / solo the layer | M / Alt+S |
| Open the layer's menu (generator, pattern, effects, length) | Enter |
| Layer length shorter / longer | [ / ] |
| Add layer / delete layer (Delete removes the selected clips instead while any are selected, as REAPER's Delete removes selected items) | Ctrl+N / Delete |
| Move layer up / down | Ctrl+W / Ctrl+S |
| Change layer colour | — |
| Split clips at the playhead: the selected ones, or every clip under it (REAPER's S) | S |
| Glue the selected clips on each track into one | G |
| Duplicate the selected clips after themselves, with their own notes (REAPER's Ctrl+D; [Assumption] not checked in the guide) | Ctrl+D |
| Delete the selected clips | — (Delete, above) |
| Clip properties (REAPER's F2) | F2 |
| Select several clips (Select mode: taps add, a long-press drag draws a box) | — |
| Loop range on / off (REAPER's R; on with none drawn takes the time selection, else four bars) | R |
| Add a marker at the playhead (REAPER's M is the layer's mute here) | Shift+M |
| Add a region over the time selection, else the loop range (REAPER's Shift+R) | Shift+R |
| Go to the next / previous marker or region (REAPER's ] and [ are the layer's length here) | Ctrl+] / Ctrl+[ |

### Exporter

| Action | Default keys |
| --- | --- |
| Export now | Ctrl+E |
| Next export kind (loop, free, one-shot, wavetable) | K |
| Cancel the export | Esc |

## Remaining UI gaps and owner review

Building the core turned up some clashes in this draft. They're resolved for now as follows, and are for the owner to change:
- **Code editor:** in Vim mode, D moves right and A moves left, which clashes with Vim's `dd` (delete line) and `a` (append). Delete line is `X X` for now, and append has no key yet.
- **Pattern editor:** Ctrl+A / Ctrl+D (select all, duplicate) clash with the owner's Ctrl+WASD cursor keys. The owner's keys win, so select all and duplicate have no default key; the action list or `:` still runs them.
- **Ctrl+S:** saves everywhere except the pattern editor, where it moves the cursor down.
- **Keys the draft didn't give:**
  - Shift+V starts Visual mode (V is the select tool in the roll), and V does in the code editor.
  - `+` and `_` are fine velocity steps.
  - The toolbar's grid button opens a Grid size menu.

- The word-jump and half-screen keys proposed for the code editor's Vim mode.

## Phone toolbar

The piano roll's default toolbar (owner, 2026-10-28; the magnet folded in 2026-11-04) holds:
- the tools: Draw, Select, Curve and Erase
- undo and redo
- the snap magnet with its time grid (`roll.grid.menu`): a tap turns snapping on or off; its ▾ opens a sheet with the time grid, triplets, adaptive and the value grid. Snap, triplets and adaptive are still actions with keys (N, Alt+0, Alt+F) and can be added as their own buttons. A saved toolbar from before, with the grid menu followed by snap, drops those three buttons when it loads
- the notes/text view switch

You can add your own actions and macros, reorder or remove them, and restore the defaults. The Curve tool also shapes the velocity and chance lanes ([app](app.md)).
