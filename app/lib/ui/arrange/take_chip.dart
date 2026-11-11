// The take chip on a loop-recorded clip (docs/reaper-flow.md, gap 3): ‹ 2/4 › steps through its takes, a sideways
// swipe across it does too, and a tap on the count lists them. Audio clips' loop takes use the same chip.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/audio_clips.dart';
import '../../model/audio_edit.dart';
import '../../model/project.dart';
import '../../model/record_modes.dart';
import '../frame/record_tools.dart' show showTakePicker;
import '../haptics.dart';
import 'long_press_menu.dart';

class TakeChip extends StatefulWidget {
  const TakeChip({super.key, required this.state, required this.layer, required ClipDoc this.clip, required this.color})
      : audio = null;

  /// An audio clip's takes (its assets): the same chip, the asset picker on the count.
  const TakeChip.audio({super.key, required this.state, required this.layer, required AudioClipDoc this.audio,
      required this.color})
      : clip = null;
  final AppState state;
  final LayerDoc layer;
  final ClipDoc? clip;
  final AudioClipDoc? audio;
  final Color color;

  @override
  State<TakeChip> createState() => _TakeChipState();
}

class _TakeChipState extends State<TakeChip> {
  double _swipe = 0;

  void _step(int d) {
    Haptics.tick();
    final a = widget.audio;
    a != null ? widget.state.stepAudioTake(widget.layer, a, d) : widget.state.stepTake(widget.layer, widget.clip!, d);
  }

  Future<void> _pick(Offset at) async {
    final a = widget.audio;
    if (a == null) return showTakePicker(context, widget.state, widget.layer, widget.clip!, at);
    final s = widget.state;
    final v = await showLongPressMenu<String>(context, at: at, title: 'Takes', style: s.settings.longPressMenu, actions: [
      for (final (i, id) in a.takes.indexed.toList().reversed)
        MenuAction(id, '${s.project.asset(id)?.name ?? 'Take ${i + 1}'}${i == a.takes.length - 1 ? ' (newest)' : ''}',
            Icons.layers_outlined, checked: a.assetId == id),
    ]);
    if (v != null) s.selectAudioTake(widget.layer, a, a.takes.indexOf(v));
  }

  Widget _arrow(IconData icon, int d, String tip) => Semantics(button: true, label: tip, excludeSemantics: true,
    child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _step(d),
      child: SizedBox(width: 20, height: 22, child: Icon(icon, size: 14, color: widget.color))));

  @override
  Widget build(BuildContext context) {
    final id = widget.audio?.id ?? widget.clip!.id;
    final takes = widget.audio?.takes ?? widget.clip!.takes;
    final i = takes.indexOf(widget.audio?.assetId ?? widget.clip!.patternId);
    return GestureDetector(
      key: ValueKey('take-chip-$id'),
      // A swipe of 24 px steps one take, as the finger goes.
      onHorizontalDragStart: (_) => _swipe = 0,
      onHorizontalDragUpdate: (d) {
        _swipe += d.delta.dx;
        while (_swipe.abs() >= 24) {
          _step(_swipe > 0 ? 1 : -1);
          _swipe -= _swipe.sign * 24;
        }
      },
      child: Container(
        height: 22,
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(11),
          border: Border.all(color: widget.color.withValues(alpha: 0.8))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _arrow(Icons.chevron_left, -1, 'Previous take'),
          GestureDetector(
            onTapUp: (d) => _pick(d.globalPosition),
            child: Text('${i < 0 ? '–' : i + 1}/${takes.length}', key: ValueKey('take-count-$id'),
              style: TextStyle(color: widget.color, fontSize: 10, fontWeight: FontWeight.w800))),
          _arrow(Icons.chevron_right, 1, 'Next take'),
        ]),
      ),
    );
  }
}
