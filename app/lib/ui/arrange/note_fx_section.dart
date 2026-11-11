// The FX stack's "Per note" section (#127): a track's effects that run once per note, with the voice-budget chip
// and a dot per slot lit while it holds a note. Look to confirm with the owner (docs/decisions.md).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../engine/engine.dart' show NoteFxStats;
import '../../model/app_state.dart';
import '../../model/arrange_fx.dart';
import '../../model/note_fx.dart';
import '../../model/project.dart';
import '../glass.dart';
import '../theme.dart';
import 'knob.dart';
import 'long_press_menu.dart';

class NoteFxSection extends StatefulWidget {
  const NoteFxSection({super.key, required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  @override
  State<NoteFxSection> createState() => _NoteFxSectionState();
}

class _NoteFxSectionState extends State<NoteFxSection> {
  Timer? _poll;
  NoteFxStats? _stats;

  AppState get s => widget.state;
  LayerDoc get layer => widget.layer;

  @override
  void initState() {
    super.initState();
    // The dots follow the engine's slots, a few times a second (the read never waits).
    _poll = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!mounted || layer.noteComponents.isEmpty) return;
      final next = s.engine?.noteFxStats(layer.id);
      if (next?.activeMask != _stats?.activeMask || next?.overflowing != _stats?.overflowing ||
          next?.budget != _stats?.budget) {
        setState(() => _stats = next);
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _pickVoices(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final at = box == null ? Offset.zero : box.localToGlobal(Offset.zero);
    final v = await showMenu<int>(context: context, position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        for (final n in const [1, 2, 4, 6, 8, 12, 16])
          CheckedPopupMenuItem(value: n, checked: n == layer.noteVoices, child: Text('$n voices')),
      ]);
    if (v != null) s.setNoteVoices(layer, v);
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final budget = stats?.budget ?? layer.noteVoices;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
        child: Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('PER NOTE', style: TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w800)),
            Text('Each note through its own copy, before the instrument\'s own effects',
              style: TextStyle(color: Neon.dim, fontSize: 9)),
          ])),
          Builder(builder: (context) => ActionChip(
            key: const ValueKey('note-fx-voices'),
            visualDensity: VisualDensity.compact,
            avatar: const Icon(Icons.scatter_plot, size: 14, color: Neon.violet),
            label: Text(budget < layer.noteVoices ? '$budget/${layer.noteVoices} voices' : '${layer.noteVoices} voices',
              style: const TextStyle(fontSize: 11)),
            tooltip: budget < layer.noteVoices
                ? 'Eco quality plays $budget notes per note; more share one copy'
                : 'Notes past this share one copy',
            onPressed: () => _pickVoices(context))),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
        child: Row(key: const ValueKey('note-fx-dots'), children: [
          for (var k = 0; k < layer.noteVoices; k++)
            _Dot(lit: ((stats?.activeMask ?? 0) >> k) & 1 == 1, enabled: k < budget, color: Neon.violet),
          const SizedBox(width: 6),
          Tooltip(message: 'Overflow: notes past the budget, sharing one copy',
            child: _Dot(lit: stats?.overflowing ?? false, enabled: true, color: Neon.yellow, square: true)),
        ]),
      ),
      for (var i = 0; i < layer.noteComponents.length; i++)
        _NoteFxCard(key: ValueKey('note-fx-$i-${layer.noteComponents[i].id}'), state: s, layer: layer, index: i),
    ]);
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.lit, required this.enabled, required this.color, this.square = false});
  final bool lit, enabled, square;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8, height: 8, margin: const EdgeInsets.only(right: 4),
    decoration: BoxDecoration(
      shape: square ? BoxShape.rectangle : BoxShape.circle,
      borderRadius: square ? BorderRadius.circular(2) : null,
      color: lit ? color : Colors.transparent,
      border: Border.all(color: enabled ? color.withValues(alpha: 0.7) : Neon.dim.withValues(alpha: 0.35)),
      boxShadow: lit ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 4)] : null));
}

/// One per-note effect: its name, bypass, a menu (back to the whole track, remove) and its knobs (every slot).
class _NoteFxCard extends StatelessWidget {
  const _NoteFxCard({super.key, required this.state, required this.layer, required this.index});
  final AppState state;
  final LayerDoc layer;
  final int index;

  @override
  Widget build(BuildContext context) {
    final use = layer.noteComponents[index];
    final info = state.componentInfo(use.id);
    final name = state.componentLabel(use.id);
    final heavy = info?.cpuClass == 'heavy';
    Future<void> menu(Offset at) async {
      final v = await showLongPressMenu<String>(context, at: at, title: name, style: state.settings.longPressMenu,
        actions: [
          MenuAction('bypass', use.bypass ? 'Turn on' : 'Bypass', Icons.power_settings_new, checked: use.bypass),
          const MenuAction('track', 'Run on whole track', Icons.call_merge),
          const MenuAction('remove', 'Remove', Icons.delete_outline, danger: true),
        ]);
      if (v == 'bypass') state.setNoteBypass(layer, index, !use.bypass);
      if (v == 'track') state.runOnTrack(layer, index);
      if (v == 'remove') state.removeNoteEffect(layer, index);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onLongPressStart: (d) => menu(d.globalPosition),
        onSecondaryTapUp: (d) => menu(d.globalPosition),
        child: Opacity(
          opacity: use.bypass ? 0.55 : 1,
          child: GlassPanel(radius: 10, tint: Neon.violet, child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 4, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(height: 36, child: Row(children: [
                const Icon(Icons.scatter_plot, size: 16, color: Neon.violet),
                const SizedBox(width: 8),
                Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                    Text(heavy ? 'Per note · heavy: costs this much per voice' : 'Per note',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 9, color: heavy ? Neon.yellow : Neon.dim)),
                  ])),
                IconButton(key: ValueKey('note-fx-bypass-$index'), tooltip: use.bypass ? 'Turn on $name' : 'Bypass $name',
                  iconSize: 18, color: use.bypass ? Neon.dim : Neon.green,
                  onPressed: () => state.setNoteBypass(layer, index, !use.bypass),
                  icon: const Icon(Icons.power_settings_new)),
                IconButton(key: ValueKey('note-fx-menu-$index'), tooltip: 'More', iconSize: 18, color: Neon.dim,
                  onPressed: () {
                    final box = context.findRenderObject() as RenderBox?;
                    menu(box == null ? Offset.zero : box.localToGlobal(box.size.topRight(Offset.zero)));
                  },
                  icon: const Icon(Icons.more_vert)),
              ])),
              if (info == null)
                const Padding(padding: EdgeInsets.only(left: 4),
                  child: Text('Loading knobs…', style: TextStyle(fontSize: 11, color: Neon.dim)))
              else
                ValueListenableBuilder<int>(
                  valueListenable: state.layerValueTick(layer.id),
                  builder: (context, _, _) => Wrap(spacing: 2, runSpacing: 4, children: [
                    for (final p in info.parameters)
                      if (!p.isChoice)
                        Knob(key: ValueKey('note-knob-${use.id}-${p.id}'), value: use.params[p.id] ?? p.defaultValue,
                          min: p.min, max: p.max, step: p.step, defaultValue: p.defaultValue, label: p.label,
                          exponential: p.exponential, enabled: !use.bypass, color: Neon.violet,
                          valueText: (v) => '${v.toStringAsFixed(p.max - p.min > 20 ? 0 : 2)}${p.unit.isEmpty ? '' : ' ${p.unit}'}',
                          onChanged: (v) => state.setNoteParamLive(layer, index, p.id, v),
                          onChangeEnd: () => state.commitNativeParams(layer)),
                  ]),
                ),
            ]),
          )),
        ),
      ),
    );
  }
}
