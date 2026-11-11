// The sidechain picker under a device's header (devices with a sidechain input: the ducker, compressor, gate):
// "Key: <track>" to pick what it listens to, and pre or post fader (the ducker's trigger tiles sit right under it).
import 'package:flutter/material.dart';

import '../../model/device_target.dart';
import '../../model/routing_edit.dart';
import '../arrange/long_press_menu.dart';
import '../arrange/track_color.dart';
import '../feedback.dart';
import '../haptics.dart';
import '../theme.dart';

/// One slim row, or nothing when [target]'s device has no sidechain input (or is an instrument).
class SidechainBar extends StatelessWidget {
  const SidechainBar({super.key, required this.target, required this.color});
  final DeviceTarget target;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = target, s = t.state;
    final use = t.use, layer = t.layer, id = t.componentId;
    if (t.isInstrument || use == null || layer == null || id == null || !s.hasSidechain(id)) return const SizedBox.shrink();
    final key = use.key;
    final source = s.layerById(key?.layer);
    final plays = key != null && s.routing.keyPlays(layer, use);
    final ducker = id == 'org.caw.ducker';
    final mode = ducker ? t.value('mode').round().clamp(0, 2) : 0;
    // Tempo needs no key: the picker stays, dimmed, for switching back.
    final needsKey = !ducker || mode != 2;
    return SizedBox(height: 40, child: SingleChildScrollView(
      key: ValueKey('sidechain-bar-${t.slot}'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        Icon(Icons.key, size: 14, color: needsKey ? Neon.yellow : Neon.dim),
        const SizedBox(width: 6),
        _Pill(
          key: ValueKey('sidechain-key-${t.slot}'),
          label: 'Key: ${source?.name ?? (key == null ? 'None' : 'Missing')}',
          color: source == null ? Neon.dim : trackColor(s, source),
          faded: !needsKey || (key != null && !plays),
          tooltip: key != null && !plays ? 'Not playing: that track would hear itself' : 'What this device listens to',
          onTap: (at) => _pickKey(context, at),
        ),
        if (key != null) ...[
          const SizedBox(width: 6),
          _Pill(
            key: ValueKey('sidechain-tap-${t.slot}'),
            label: key.pre ? 'Pre-fader' : 'Post-fader',
            color: Neon.blue,
            faded: !needsKey,
            tooltip: 'Hear the key before or after its fader',
            onTap: (_) {
              Haptics.tap();
              s.setComponentKey(layer, t.slot, key.layer, pre: !key.pre);
            },
          ),
        ],
      ]),
    ));
  }

  Future<void> _pickKey(BuildContext context, Offset at) async {
    final t = target, s = t.state, layer = t.layer;
    if (layer == null) return;
    final current = t.use?.key?.layer;
    final pick = await showLongPressMenu<String>(context, at: at, title: '${t.label} listens to', actions: [
      MenuAction('', 'None', Icons.block, checked: current == null),
      for (final l in s.keySources(layer))
        MenuAction(l.id, l.name, l.isFolder ? Icons.merge_type : Icons.graphic_eq, checked: l.id == current),
    ]);
    if (pick == null) return;
    if (s.setComponentKey(layer, t.slot, pick.isEmpty ? null : pick, pre: t.use?.key?.pre ?? true)) {
      Haptics.drop();
    } else {
      Haptics.error();
    }
  }
}

class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.label, required this.color, required this.onTap, this.tooltip,
    this.faded = false});
  final String label;
  final Color color;
  final void Function(Offset at) onTap;
  final String? tooltip;
  final bool faded;

  @override
  Widget build(BuildContext context) => Tooltip(message: tooltip ?? label, child: Opacity(
    opacity: faded ? 0.5 : 1,
    child: Pressable(glow: color, radius: 14, child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => onTap(d.globalPosition),
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: color.withValues(alpha: 0.1),
          border: Border.all(color: color.withValues(alpha: 0.6))),
        child: Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800,
          color: faded ? Neon.dim : Neon.text)),
      ),
    )),
  ));
}
