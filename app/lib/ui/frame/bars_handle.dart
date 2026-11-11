// The top bars' grip: pulled up it hides the status row and Arrange's toolbar, pulled down (or tapped as a slim tab)
// it brings them back. The bars follow the finger, a threshold shows where letting go acts, and a haptic tick marks it.
import 'package:flutter/material.dart';

import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import 'sections.dart';

/// The grip pill under the top bars, or the pull tab while they are hidden (owner, 2026-11-10: "Hide only on a
/// deliberate pull"). Place it at the top centre of the section, over the bars' bottom edge.
class BarsHandle extends StatefulWidget {
  const BarsHandle({super.key, required this.sections, this.reach = 56});
  final SectionController sections;

  /// How far a pull goes from shown to hidden, in logical pixels; letting go past half of it acts.
  final double reach;

  /// The hit area: wider and taller than the pill, so it is easy to catch.
  static const size = Size(76, 22);

  @override
  State<BarsHandle> createState() => _BarsHandleState();
}

class _BarsHandleState extends State<BarsHandle> {
  double _from = 0, _dy = 0;
  bool _past = false;

  SectionController get c => widget.sections;
  bool get _dragging => c.barsPull.value != null;

  void _start(DragStartDetails _) {
    _from = c.barsShown.value ? 0 : 1;
    _dy = 0;
    _past = false;
    c.barsPull.value = _from;
    Haptics.grab();
    setState(() {});
  }

  void _update(DragUpdateDetails d) {
    if (!_dragging) return;
    _dy += d.delta.dy;
    final p = (_from - _dy / widget.reach).clamp(0.0, 1.0);
    c.barsPull.value = p;
    final past = _from == 0 ? p >= 0.5 : p <= 0.5;
    if (past != _past) {
      _past = past;
      // Crossing into "letting go acts" is a threshold; backing out of it is a lighter tick.
      past ? Haptics.threshold() : Haptics.tick();
      setState(() {});
    }
  }

  void _end(DragEndDetails d) {
    if (!_dragging) return;
    final v = d.primaryVelocity ?? 0;
    final wasShown = _from == 0;
    // A flick counts as a pull past the threshold.
    final act = _past || (wasShown ? v < -400 : v > 400);
    c.barsPull.value = null;
    if (act) {
      c.barsShown.value = !wasShown;
      Haptics.drop();
    }
    _past = false;
    setState(() {});
  }

  void _cancel() {
    c.barsPull.value = null;
    _past = false;
    setState(() {});
  }

  void _tapTab() {
    Haptics.tap();
    c.barsShown.value = true;
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: c.barsShown,
        builder: (context, shown, _) {
          final dragging = _dragging;
          final level = Motion.usabilityOf(context); // a grip's feedback stays with motion Off
          final d = Motion.fade(Motion.small, level);
          final color = _past ? Neon.green : dragging ? Neon.text : Neon.dim;
          final label = !dragging
              ? null
              : _past
                  ? (shown ? 'Let go to hide' : 'Let go to show')
                  : (shown ? 'Pull up to hide the bars' : 'Pull down to show the bars');
          final Widget mark = shown
              // The grip: a pill that grows and lights while held, and turns the accent past the threshold.
              ? AnimatedContainer(
                  key: const ValueKey('bars-grip'),
                  duration: d,
                  curve: Curves.easeOut,
                  width: dragging ? 46 : 30,
                  height: dragging ? 5 : 4,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: dragging ? 0.95 : 0.55),
                    borderRadius: BorderRadius.circular(3),
                    boxShadow: _past ? Neon.glow(Neon.green, strength: 0.5) : null,
                  ),
                )
              // Hidden: a slim tab hanging from the top edge, with a chevron.
              : AnimatedContainer(
                  key: const ValueKey('bars-tab'),
                  duration: d,
                  width: dragging ? 52 : 40,
                  height: 14,
                  decoration: BoxDecoration(
                    color: Neon.panel.withValues(alpha: 0.85),
                    border: Border.all(color: color.withValues(alpha: 0.6)),
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(7)),
                    boxShadow: _past ? Neon.glow(Neon.green, strength: 0.4) : null,
                  ),
                  child: Icon(Icons.keyboard_arrow_down, size: 12, color: color),
                );
          return Semantics(
            button: true,
            label: shown ? 'Hide the top bars' : 'Show the top bars',
            onTap: shown ? () => c.barsShown.value = false : _tapTab,
            excludeSemantics: true,
            child: SizedBox.fromSize(
              size: BarsHandle.size,
              child: Stack(clipBehavior: Clip.none, alignment: Alignment.topCenter, children: [
                Positioned.fill(
                  child: GestureDetector(
                    key: const ValueKey('bars-handle'),
                    // Shown, a tap here still reaches the toolbar under it; only a vertical pull is the handle's.
                    behavior: shown ? HitTestBehavior.translucent : HitTestBehavior.opaque,
                    onTap: shown ? null : _tapTab,
                    onVerticalDragStart: _start,
                    onVerticalDragUpdate: _update,
                    onVerticalDragEnd: _end,
                    onVerticalDragCancel: _cancel,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeUpDown,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(padding: EdgeInsets.only(top: shown ? 3 : 0), child: mark),
                      ),
                    ),
                  ),
                ),
                // The threshold, in words, under the grip while it is held.
                if (label != null)
                  Positioned(
                    top: BarsHandle.size.height,
                    child: IgnorePointer(
                      child: Container(
                        key: const ValueKey('bars-hint'),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Neon.panel.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: color.withValues(alpha: 0.5)),
                        ),
                        child: Text(label, maxLines: 1, style: TextStyle(fontSize: 11, color: color)),
                      ),
                    ),
                  ),
              ]),
            ),
          );
        },
      );
}
