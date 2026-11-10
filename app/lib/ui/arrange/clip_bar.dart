// Arrange's clip bar (docs/reaper-flow.md, gap 1): Split, Glue, Duplicate, Delete, Properties and Select for the
// selected clips, docked at the bottom on a phone and in the toolbar when wide, and the clip Properties sheet.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/arrange_edit.dart';
import '../../model/project.dart';
import '../glass.dart';
import '../theme.dart';
import '../tokens.dart';
import '../widgets.dart';

/// The clip actions. [docked]: the phone's bar over the bottom of the tracks (a glass pill with a count); otherwise
/// a row of buttons for the toolbar.
class ClipBar extends StatelessWidget {
  const ClipBar({super.key, required this.state, required this.selectMode, required this.onSelectMode,
    required this.onProperties, this.docked = false});
  final AppState state;

  /// Select mode (the phone's multi-select): taps add clips and a long-press drag in empty lane space draws a box.
  final bool selectMode;
  final ValueChanged<bool> onSelectMode;
  final VoidCallback onProperties;
  final bool docked;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final chosen = s.selectedClips;
    final step = s.editStep;
    final canSplit = (chosen.isEmpty
            ? s.project.layers.expand((l) => l.clips)
            : chosen.map((c) => c.clip))
        .any((c) => !c.lock && c.startSteps < step && c.startSteps + c.lengthSteps > step);
    final perTrack = <String, int>{};
    for (final c in chosen) {
      if (!c.clip.lock) perTrack[c.layer.id] = (perTrack[c.layer.id] ?? 0) + 1;
    }
    final canGlue = perTrack.values.any((n) => n >= 2);
    Widget button(String key, IconData icon, String tip, VoidCallback? onTap, {Color? color}) => IconButton(
      key: ValueKey('clip-bar-$key'), tooltip: tip, onPressed: onTap, visualDensity: VisualDensity.compact,
      iconSize: 19, color: color, icon: Icon(icon));
    final buttons = <Widget>[
      button('split', Icons.content_cut, 'Split at the playhead (S)', canSplit ? () => s.splitClips() : null),
      button('glue', Icons.join_full, 'Glue into one clip (G)', canGlue ? s.glueSelected : null),
      button('duplicate', Icons.copy_all, 'Duplicate (Ctrl+D)', chosen.isEmpty ? null : s.duplicateSelected),
      button('delete', Icons.delete_outline, 'Delete (Delete)', chosen.any((c) => !c.clip.lock) ? s.deleteSelected : null,
        color: Neon.pink),
      button('properties', Icons.tune, 'Properties (F2)', chosen.isEmpty ? null : onProperties),
      button('select', selectMode ? Icons.checklist : Icons.checklist_rtl,
        selectMode ? 'Select mode on: taps add clips, a long-press drag draws a box' : 'Select several clips',
        () => onSelectMode(!selectMode), color: selectMode ? Neon.blue : null),
    ];
    if (!docked) return Row(key: const ValueKey('clip-bar'), mainAxisSize: MainAxisSize.min, children: buttons);
    final label = chosen.isEmpty ? 'Tap clips' : chosen.length == 1 ? s.clipName(chosen.single.clip) : '${chosen.length} clips';
    return GlassOverlay(key: const ValueKey('clip-bar'), radius: Radii.l,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SizedBox(height: 44, child: Row(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 8),
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 84), child: Text(label, maxLines: 1,
          overflow: TextOverflow.ellipsis, style: const TextStyle(color: Neon.dim, fontSize: 11, fontWeight: FontWeight.w700))),
        ...buttons,
        button('close', Icons.close, 'Deselect', () { onSelectMode(false); s.clearClipSelection(); }),
      ])));
  }
}

/// Opens the Properties sheet for the selected clip (REAPER's item properties, F2): it follows the selection while
/// open, and every value can be typed.
Future<void> showClipProperties(BuildContext context, AppState state) => showGlassSheet<void>(
      context: context, isScrollControlled: true, showDragHandle: true,
      builder: (_) => ClipProperties(state: state));

class ClipProperties extends StatefulWidget {
  const ClipProperties({super.key, required this.state});
  final AppState state;
  @override
  State<ClipProperties> createState() => _ClipPropertiesState();
}

class _ClipPropertiesState extends State<ClipProperties> {
  final _name = TextEditingController();
  String? _shownId;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.state, builder: (context, _) {
    final s = widget.state;
    final placed = s.selectedClips.where((c) => c.clip.id == s.selectedClipId).firstOrNull ?? s.selectedClips.firstOrNull;
    if (placed == null) {
      return const Padding(padding: EdgeInsets.all(24), child: Text('Select a clip', style: TextStyle(color: Neon.dim)));
    }
    final (:layer, :clip) = placed;
    if (_shownId != clip.id) {
      _shownId = clip.id;
      _name.text = clip.name ?? '';
    }
    final bar = s.project.stepsPerBar;
    void set({String? name, int? color, int? length, bool? loop, int? offset, bool? mute, bool? lock}) =>
        s.setClipProperties(layer, clip, name: name, color: color, lengthSteps: length, loop: loop,
          sourceOffsetSteps: offset, mute: mute, lock: lock);
    Widget row(String label, Widget child) => Padding(padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 92, child: Text(label, style: const TextStyle(color: Neon.dim))),
        Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
      ]));
    return SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(key: const ValueKey('clip-properties'), crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min, children: [
        Text('CLIP · ${layer.name}', style: const TextStyle(color: Neon.dim, fontSize: 11, letterSpacing: 1.4,
          fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        row('Name', TextField(key: const ValueKey('clip-prop-name'), controller: _name,
          decoration: InputDecoration(isDense: true, hintText: s.project.module(clip.patternId)?.name ?? 'Pattern'),
          onSubmitted: (v) => set(name: v), onTapOutside: (_) {
            if ((clip.name ?? '') != _name.text.trim()) set(name: _name.text);
          })),
        row('Colour', Wrap(spacing: 6, runSpacing: 6, children: [
          for (var i = -1; i < LayerDoc.trackColors; i++)
            _Swatch(key: ValueKey('clip-prop-color-$i'), color: i < 0 ? null : Neon.layer(i),
              selected: (clip.color ?? -1) == i, onTap: () => set(color: i)),
        ])),
        row('Length', StepsField(key: const ValueKey('clip-prop-length'), value: clip.lengthSteps, min: 1,
          stepsPerBar: bar, onChanged: (v) => set(length: v))),
        row('Start offset', StepsField(key: const ValueKey('clip-prop-offset'), value: clip.sourceOffsetSteps, min: 0,
          stepsPerBar: bar, onChanged: (v) => set(offset: v))),
        row('Loop', Switch(key: const ValueKey('clip-prop-loop'), value: clip.loop, onChanged: (v) => set(loop: v))),
        row('Mute', Switch(key: const ValueKey('clip-prop-mute'), value: clip.mute, onChanged: (v) => set(mute: v))),
        row('Lock', Switch(key: const ValueKey('clip-prop-lock'), value: clip.lock, onChanged: (v) => set(lock: v))),
      ])));
  });
}

class _Swatch extends StatelessWidget {
  const _Swatch({super.key, required this.color, required this.selected, required this.onTap});

  /// Null: the track's colour.
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(button: true, selected: selected,
    label: color == null ? "Track's colour" : 'Colour',
    child: InkWell(onTap: onTap, customBorder: const CircleBorder(), child: Container(width: 28, height: 28,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color?.withValues(alpha: 0.85),
        border: Border.all(color: selected ? Neon.text : Neon.line, width: selected ? 2 : 1)),
      child: color == null ? const Icon(Icons.format_color_reset_outlined, size: 14, color: Neon.dim) : null)));
}

/// A length in sixteenth steps shown as bars.beats.steps (REAPER's measures.beats): − and + move it a beat, a tap
/// types it ("2" is two bars, "1.2" a bar and two beats, "0.0.3" three steps).
class StepsField extends StatelessWidget {
  const StepsField({super.key, required this.value, required this.stepsPerBar, required this.onChanged, this.min = 0});
  final int value, stepsPerBar, min;
  final ValueChanged<int> onChanged;

  static String format(int steps, int stepsPerBar) {
    final bar = math.max(4, stepsPerBar);
    return '${steps ~/ bar}.${steps % bar ~/ 4}.${steps % 4}';
  }

  static int? parse(String text, int stepsPerBar) {
    final parts = text.trim().split(RegExp(r'[.:]'));
    if (parts.isEmpty || parts.length > 3) return null;
    final n = [for (final p in parts) int.tryParse(p.trim())];
    if (n.any((v) => v == null || v < 0)) return null;
    return n[0]! * math.max(4, stepsPerBar).toInt() + (n.length > 1 ? n[1]! * 4 : 0) + (n.length > 2 ? n[2]! : 0);
  }

  @override
  Widget build(BuildContext context) {
    void set(int v) {
      final c = math.max(min, v);
      if (c != value) onChanged(c);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(onPressed: value - 4 >= min ? () => set(value - 4) : null, icon: const Icon(Icons.remove, size: 16),
        tooltip: 'A beat less', visualDensity: VisualDensity.compact),
      TextButton(
        onPressed: () => typeValue(context, title: 'Bars.beats.steps', initial: format(value, stepsPerBar),
          parse: (t) => parse(t, stepsPerBar)?.toDouble(), apply: (v) => set(v.toInt())),
        child: Text(format(value, stepsPerBar), style: Neon.code(size: 13))),
      IconButton(onPressed: () => set(value + 4), icon: const Icon(Icons.add, size: 16),
        tooltip: 'A beat more', visualDensity: VisualDensity.compact),
    ]);
  }
}
