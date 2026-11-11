// The take chip on a loop-recorded clip (docs/reaper-flow.md, gap 3): ‹ 2/4 › steps through its takes, a sideways
// swipe across it does too, and a tap on the count lists them.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/project.dart';
import '../../model/record_modes.dart';
import '../frame/record_tools.dart' show showTakePicker;
import '../haptics.dart';

class TakeChip extends StatefulWidget {
  const TakeChip({super.key, required this.state, required this.layer, required this.clip, required this.color});
  final AppState state;
  final LayerDoc layer;
  final ClipDoc clip;
  final Color color;

  @override
  State<TakeChip> createState() => _TakeChipState();
}

class _TakeChipState extends State<TakeChip> {
  double _swipe = 0;

  void _step(int d) {
    Haptics.tick();
    widget.state.stepTake(widget.layer, widget.clip, d);
  }

  Widget _arrow(IconData icon, int d, String tip) => Semantics(button: true, label: tip, excludeSemantics: true,
    child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _step(d),
      child: SizedBox(width: 20, height: 22, child: Icon(icon, size: 14, color: widget.color))));

  @override
  Widget build(BuildContext context) {
    final c = widget.clip;
    final i = c.takes.indexOf(c.patternId);
    return GestureDetector(
      key: ValueKey('take-chip-${c.id}'),
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
            onTapUp: (d) => showTakePicker(context, widget.state, widget.layer, c, d.globalPosition),
            child: Text('${i < 0 ? '–' : i + 1}/${c.takes.length}', key: ValueKey('take-count-${c.id}'),
              style: TextStyle(color: widget.color, fontSize: 10, fontWeight: FontWeight.w800))),
          _arrow(Icons.chevron_right, 1, 'Next take'),
        ]),
      ),
    );
  }
}
