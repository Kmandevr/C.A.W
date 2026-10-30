---
title: Actions, keys and macros
summary: Every command as an action, customisable keys per area, macros and toolbars, and the full action catalogue with default keys.
covers: [app/lib/actions/, app/lib/ui/key_router.dart]
updated: 2026-10-29
---

# Actions, keys and macros

**[Fact]** Built (2026-10-28): the action catalogue, keymaps, macros and Vim core (`app/lib/actions/`) and the key router that runs them in the app ([app](app.md)). Still a draft for the owner to change; editing keys in the action list isn't built yet. The roll's toolbar can be customised (2026-10-29). The owner asked for Reaper-style customisation (2026-10-28). Their choices are in [decisions](decisions.md), and the screens are in [UI design](ui.md).

## How it works

- **Everything is an action.** Each command the app can do has an id (`roll.notes.up`), a name and a description. Buttons, menus, keys and macros all run actions, so anything you can tap, you can bind. Reaper works the same way ([Sound on Sound](https://www.soundonsound.com/techniques/automate-anything-reapers-custom-actions)).
- **Areas, like Reaper's sections:** Global, Builder, Pattern editor (roll and grid), Arranger and Exporter. A key can do different things in each area. Global keys work everywhere unless the area has its own binding.
- **The action list** (`?`, or Help → Actions):
  - search every action by name, with its keys
  - add or remove keys, with a warning when a key is already taken in that area
  - run the action
  - It also serves as the shortcut overlay the [UI design](ui.md#keyboard-pc) asked for.
- **Triggers** (owner chose all four):
  - keys: any combination with Ctrl, Shift and Alt
  - on-screen toolbars you fill with your own actions and macros, so the phone gets one-tap macros without a keyboard
  - entries in the long-press (right-click) menu
  - later, MIDI controller notes and CCs, once device support is built ([architecture](architecture.md#variables-and-patterns-proposal))
- **Macros (custom actions):** a named list of actions run in order. Any step can repeat N times (owner: chains plus repeat, no scripting for now). A macro is itself an action, so it can have keys, toolbar buttons and menu entries. You build one in a list on the phone: add a step, pick an action, set the repeat count, reorder.
- **Saving** (owner: both):
  - one app keymap with your keys, toolbars and macros, exportable and importable as a file, and later synced through GitHub
  - a project can also carry its own macros, which travel with it
- **Readable files,** so the owner and AI agents can edit them. **[Proposal]** The format:

```
---
kind: keymap
name: My keys
---
# area      keys            action
roll        W               roll.notes.up
roll        Ctrl+W          roll.cursor.up
global      Space           transport.playstop
roll        Ctrl+Shift+E    macro "Run of four"

macro "Run of four"
  roll.select.copyafter * 3
  roll.notes.up
```

- **Phone without a keyboard:** the default toolbar holds the most-used actions, and you swap in your own.

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
| Play / stop | Space |
| Undo / redo | Ctrl+Z / Ctrl+Shift+Z (also Ctrl+Y) |
| Save now (projects also autosave) | Ctrl+S |
| Action list | ? |
| Go to Sounds / Tracks / Export (the Builder, Arranger and Exporter areas) | Ctrl+1 / Ctrl+2 / Ctrl+3 (already built) |
| New, open, duplicate, rename, delete project | — / Ctrl+O / — / F2 in the project menu / — |
| Tap tempo | T (updates the project BPM from repeated taps) |
| Tempo up / down 1 BPM (Shift: 0.1) | Ctrl+= / Ctrl+- |
| Master volume up / down | — |
| Unmute layers the engine muted (overload) | — |
| Full screen for the current editor | F11 |
| Focus next / previous panel | Tab / Shift+Tab (already planned in the UI design) |
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
| Velocity up / down 10% (Shift: 1%) | = / - |
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
| Zoom in / out / fit the pattern | Ctrl+= / Ctrl+- / F |
| Show velocity lane / extras lanes | Alt+V / Alt+X (Ctrl+1/2/3 always switch areas, owner) |

Generators (buttons; no default keys):

| Action | Default keys |
| --- | --- |
| Euclid, random in key, arpeggiate, humanize, chord stamp | — |
| Legato (stretch each note to the next) | — |
| Reverse selection, invert pitch around the cursor | — |

### Arranger

| Action | Default keys |
| --- | --- |
| Select previous / next layer | W / S, ↑ / ↓ |
| Pan left / right | A / D |
| Volume up / down | = / - |
| Mute / solo the layer | M / Alt+S |
| Open the layer's menu (generator, pattern, effects, length) | Enter |
| Layer length shorter / longer | [ / ] |
| Add layer / delete layer | Ctrl+N / Delete |
| Move layer up / down | Ctrl+W / Ctrl+S |
| Change layer colour | — |

### Exporter

| Action | Default keys |
| --- | --- |
| Export now | Ctrl+E |
| Next export kind (loop, free, one-shot, wavetable) | K |
| Cancel the export | Esc |

## Open points for the owner

Building the core turned up some clashes in this draft. They're resolved for now as follows, and are for the owner to change:
- **Code editor:** in Vim mode, D moves right and A moves left, which clashes with Vim's `dd` (delete line) and `a` (append). Delete line is `X X` for now, and append has no key yet.
- **Pattern editor:** Ctrl+A / Ctrl+D (select all, duplicate) clash with the owner's Ctrl+WASD cursor keys. The owner's keys win, so select all and duplicate have no default key; the action list or `:` still runs them.
- **Ctrl+S:** saves everywhere except the pattern editor, where it moves the cursor down.
- **Keys the draft didn't give:**
  - Shift+V starts Visual mode (V is the select tool in the roll), and V does in the code editor.
  - `+` and `_` are fine velocity steps.
  - The toolbar's grid button opens a Grid size menu.

- Is Space for play/stop right on the phone with a keyboard, too?
- The word-jump and half-screen keys proposed for the code editor's Vim mode.

## Phone toolbar

The piano roll's default toolbar (owner, 2026-10-28) holds:
- the tools: Draw, Select, Curve and Erase
- undo and redo
- grid size and the snap magnet
- triplets, the fixed grid and the drum grid switch, which the built roll already showed (Claude, 2026-10-29)

You can add your own actions and macros, reorder them or remove any of these (⋮ → Customise toolbar), and go back to the default. The Curve tool shapes the velocity and chance lanes ([app](app.md)).
