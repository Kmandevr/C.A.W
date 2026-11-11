// Settings › Editing: the piano roll's starting grid, snap, tool and note length, following the playhead, the mouse
// wheel, asking before a track is deleted, and the roll's sizes and touch choices.
import 'package:flutter/material.dart';

import '../../model/settings.dart';
import 'settings_deps.dart';
import 'settings_widgets.dart';

class EditingSettings extends StatelessWidget {
  const EditingSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final s = deps.settings;
    final r = s.roll;
    const d = RollLook();
    String px(double v) => '${v.round()} px';
    String length(double steps) => switch (steps) {
          0 => 'The grid',
          1 => '1/16',
          2 => '1/8',
          4 => '1/4',
          8 => '1/2',
          _ => '1 bar',
        };
    Widget roll(String id, double value, double min, double max, String Function(double) show,
            RollLook Function(RollLook, double) set, double reset, IconData icon) =>
        settingSlider(id, s,
            value: value, min: min, max: max, show: show, icon: icon,
            set: (x, v) => x.roll = set(x.roll, v), reset: reset);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      settingDropdown<int>('editing.grid', s.rollGrid, [for (final g in Settings.rollGrids) (g, '1/$g')],
          (v) => s.update((x) => x.rollGrid = v),
          icon: Icons.grid_on),
      settingSwitch('editing.snap', s.rollSnap, (v) => s.update((x) => x.rollSnap = v), icon: Icons.straighten),
      settingChoice<StartTool>('editing.tool', s.rollTool, [for (final t in StartTool.values) (t, t.label)],
          (v) => s.update((x) => x.rollTool = v),
          icon: Icons.draw_outlined,
          subtitle: s.rollTool == StartTool.draw ? 'A tap on empty grid draws a note' : 'A tap selects; a drag draws a box'),
      settingDropdown<double>('editing.noteLength', s.rollNoteSteps,
          [for (final l in Settings.rollNoteLengths) (l, length(l))], (v) => s.update((x) => x.rollNoteSteps = v),
          icon: Icons.straighten_outlined,
          subtitle: 'A new note\'s length until you change one (the last length then carries on)'),
      settingSwitch('editing.follow', s.followPlayhead, (v) => s.update((x) => x.followPlayhead = v),
          icon: Icons.keyboard_double_arrow_right),
      settingSwitch('editing.wheel', s.wheelZooms, (v) => s.update((x) => x.wheelZooms = v),
          icon: Icons.mouse_outlined,
          subtitle: s.wheelZooms ? 'The wheel zooms the arrangement; Ctrl + wheel scrolls' : 'Ctrl + wheel zooms the arrangement'),
      settingSwitch('editing.confirmDelete', s.confirmDelete, (v) => s.update((x) => x.confirmDelete = v),
          icon: Icons.delete_outline,
          subtitle: s.confirmDelete ? 'Asks first; undo still takes a delete back' : 'Deletes at once; undo takes it back'),
      settingHeading('Piano roll'),
      roll('editing.rowHeight', r.rowHeight, 10, 40, px, (r, v) => r.copyWith(rowHeight: v.roundToDouble()), d.rowHeight,
          Icons.height),
      roll('editing.velocityLane', r.velocityLane, 32, 160, px, (r, v) => r.copyWith(velocityLane: v.roundToDouble()),
          d.velocityLane, Icons.equalizer),
      roll('editing.chanceLane', r.chanceLane, 24, 120, px, (r, v) => r.copyWith(chanceLane: v.roundToDouble()),
          d.chanceLane, Icons.casino_outlined),
      roll('editing.gridLines', r.gridStrength, 0.2, 2, (v) => '${(v * 100).round()}%',
          (r, v) => r.copyWith(gridStrength: (v * 10).round() / 10), d.gridStrength, Icons.grid_4x4),
      roll('editing.grab', r.grab, 6, 40, px, (r, v) => r.copyWith(grab: v.roundToDouble()), d.grab,
          Icons.pan_tool_alt_outlined),
      roll('editing.hold', r.holdMs.toDouble(), 250, 1500, (v) => '${v.round()} ms',
          (r, v) => r.copyWith(holdMs: (v / 50).round() * 50), d.holdMs.toDouble(), Icons.touch_app_outlined),
      settingChoice<KeyLabels>('editing.keyNames', r.keyLabels,
          const [(KeyLabels.none, 'None'), (KeyLabels.octaves, 'C'), (KeyLabels.all, 'All')],
          (v) => s.update((x) => x.roll = x.roll.copyWith(keyLabels: v)),
          icon: Icons.piano),
      settingChoice<EmptyDrag>('editing.emptyDrag', r.emptyDrag,
          const [(EmptyDrag.scroll, 'Scroll'), (EmptyDrag.select, 'Select'), (EmptyDrag.draw, 'Draw')],
          (v) => s.update((x) => x.roll = x.roll.copyWith(emptyDrag: v)),
          icon: Icons.swipe, subtitle: 'With the Draw tool (a tap still draws)'),
      settingChoice<ValueGrid>('editing.valueGrid', r.valueGrid, [for (final g in ValueGrid.values) (g, g.label)],
          (v) => s.update((x) => x.roll = x.roll.copyWith(valueGrid: v)),
          icon: Icons.linear_scale),
      settingSwitch('editing.hearNotes', r.hearNotes, (v) => s.update((x) => x.roll = x.roll.copyWith(hearNotes: v)),
          icon: Icons.hearing),
    ]);
  }
}
