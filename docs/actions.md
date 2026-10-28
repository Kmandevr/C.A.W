---
title: Actions, keys and macros
summary: Draft for the owner's review - every command as an action, customisable keys per area, macros and toolbars, and the full action catalogue with default keys.
updated: 2026-10-28
---

# Actions, keys and macros

**[Proposal]** A draft for the owner to review and change; nothing here is built. The owner asked for Reaper-style customisation (2026-10-28). Their choices are in [decisions](decisions.md), and the screens are in [UI design](ui.md).

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
| Go to Builder / Arranger / Exporter | Ctrl+1 / Ctrl+2 / Ctrl+3 (already built) |
| New, open, duplicate, rename, delete project | — / Ctrl+O / — / F2 in the project menu / — |
| Tap tempo | T |
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
| Move the cursor (selects the note it lands on) | Ctrl+W / A / S / D, also Ctrl+arrows † |
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
| Grid 1/4, 1/8, 1/16, 1/32 | 1, 2, 3, 4 |
| Triplets on / off | 0 |
| Snap (magnet) on / off | N |
| Tools: draw, select, curve, erase | B, V, C, X |
| Switch piano roll / drum grid | G |
| Zoom in / out / fit the pattern | Ctrl+= / Ctrl+- / F |
| Show velocity lane / extras lanes | Ctrl+1 / Ctrl+2 (in the editor these replace the area switch; Ctrl+Alt+1–3 still switch areas) |

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

- Ctrl+W A S D in the roll: move one grid step or one note, or jump to the next note in that direction? Both were mentioned.
- Is Space for play/stop right on the phone with a keyboard, too?
- Which actions belong on the phone's default toolbar?
