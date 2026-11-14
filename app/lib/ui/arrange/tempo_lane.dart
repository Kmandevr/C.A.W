// Arrange's tempo lane (#207, owner 2026-11-13: REAPER's tempo envelope): a thin lane under the ruler, shown once
// the project has a tempo change. Drag a point up and down, or hold it and move it along; a hold that stays opens its
// menu (stepped or ramped, type the tempo, delete); a tap adds a point (a mouse double-clicks), a double tap deletes.
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/app_state.dart';
import '../../model/arrange_tempo.dart';
import '../../model/project.dart';
import '../../model/tempo_map.dart';
import '../haptics.dart';
import '../pointer_input.dart';
import '../theme.dart';
import '../widgets.dart';
import 'long_press_menu.dart';

/// The tempo lane's height: thin, and still a finger's height for its points (phone first).
double tempoLaneHeight(bool phone) => phone ? 40 : 32;

/// A tempo as text: whole, or with its tenth.
String bpmText(double bpm) => bpm == bpm.roundToDouble() ? bpm.toStringAsFixed(0) : bpm.toStringAsFixed(1);

/// The lane's tempo scale: the map's range with room above and below, at least 20 BPM.
({double lo, double hi}) tempoRange(List<TempoPoint> map) {
  var lo = map.first.bpm, hi = lo;
  for (final p in map) {
    lo = math.min(lo, p.bpm);
    hi = math.max(hi, p.bpm);
  }
  final pad = math.max(5.0, (hi - lo) * 0.2);
  lo = math.max(kMinMapBpm, lo - pad);
  hi = math.min(kMaxMapBpm, hi + pad);
  if (hi - lo < 20) {
    final mid = (hi + lo) / 2;
    lo = math.max(kMinMapBpm, mid - 10);
    hi = lo + 20;
  }
  return (lo: lo, hi: hi);
}

class TempoLane extends StatefulWidget {
  const TempoLane({super.key, required this.state, required this.stepW, required this.width, required this.height});
  final AppState state;
  final double stepW, width, height;

  @override
  State<TempoLane> createState() => _TempoLaneState();
}

class _TempoLaneState extends State<TempoLane> {
  static const _pad = 6.0;
  final _clicks = ClickCounter();
  static const _surface = -1;
  final _hold = HoldToMove();
  int _downPointer = 0;

  /// A drag's running position (the point follows the finger) and the scale it started on (kept while it lasts, so
  /// the point stays under the finger).
  Offset _grab = Offset.zero, _from = Offset.zero;
  ({double lo, double hi})? _frozen;
  int? _dragging;

  AppState get s => widget.state;
  ProjectDoc get p => s.project;
  double get _h => widget.height;

  ({double lo, double hi}) get _range => _frozen ?? tempoRange(p.tempoMap);
  double _y(double bpm) {
    final r = _range;
    return _pad + (1 - (bpm - r.lo) / (r.hi - r.lo)) * (_h - 2 * _pad);
  }

  /// The tempo at height [y]: whole BPM, or tenths with Shift.
  double _bpm(double y) {
    final r = _range;
    final v = r.lo + (1 - (y - _pad) / (_h - 2 * _pad)) * (r.hi - r.lo);
    return HardwareKeyboard.instance.isShiftPressed ? roundBpm(v) : roundBpm(v.roundToDouble());
  }

  /// The beat at [x], on the arrangement's snap grid unless Shift is held.
  double _beat(double x) {
    final raw = math.max(0.0, x / widget.stepW);
    if (HardwareKeyboard.instance.isShiftPressed) return raw.round() / 4;
    final snap = s.arrangementSnapSteps;
    return (raw / snap).round() * snap / 4;
  }

  double _x(double beat) => beat * 4 * widget.stepW;

  @override
  void dispose() {
    _hold.stop();
    super.dispose();
  }

  void _dragStart(int i) {
    final t = p.tempoMap[i];
    _frozen = tempoRange(p.tempoMap);
    _grab = Offset(_x(t.beat), _y(t.bpm));
    s.endUndoStep();
    Haptics.grab();
    setState(() => _dragging = i);
  }

  void _dragBy(int i, Offset delta) {
    if (i >= p.tempoMap.length) return;
    _grab += delta;
    final y = _grab.dy.clamp(0.0, _h).toDouble();
    final before = p.tempoMap[i].bpm;
    s.moveTempoPoint(i, beat: i == 0 ? 0 : _beat(_grab.dx), bpm: _bpm(y));
    if (p.tempoMap[i].bpm != before && p.tempoMap[i].bpm % 10 == 0) Haptics.tick();
  }

  void _dragEnd() {
    s.endUndoStep();
    Haptics.drop();
    setState(() {
      _dragging = null;
      _frozen = null;
    });
  }

  void _tapPoint(int i) {
    // A double tap (a double-click) deletes a point; the first one stays.
    if (_clicks.twice && i > 0) {
      Haptics.tap();
      s.removeTempoPoint(i);
    }
  }

  Future<void> _menu(int i, Offset at) async {
    final map = p.tempoMap;
    if (i >= map.length) return;
    final t = map[i];
    final v = await showLongPressMenu<String>(context, at: at, title: '${bpmText(t.bpm)} BPM',
        style: s.settings.longPressMenu, actions: [
          if (i > 0) MenuAction('step', 'Stepped', Icons.stairs_outlined, checked: !t.ramp, section: 'Change'),
          if (i > 0) MenuAction('ramp', 'Ramped', Icons.trending_up, checked: t.ramp, section: 'Change',
              hint: 'From the point before'),
          const MenuAction('type', 'Set tempo…', Icons.edit_outlined, section: 'Point'),
          if (i > 0) const MenuAction('delete', 'Delete', Icons.delete_outline, danger: true, section: 'Point'),
        ]);
    if (v == null || !mounted) return;
    switch (v) {
      case 'step':
        s.setTempoRamp(i, false);
      case 'ramp':
        s.setTempoRamp(i, true);
      case 'type':
        await typeValue(context, title: 'Tempo (1 to 999 BPM)', initial: bpmText(t.bpm),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            parse: (text) {
              final v = double.tryParse(text.trim().replaceAll(',', '.'));
              return v == null || !v.isFinite ? null : roundBpm(v);
            },
            apply: (v) {
              s.endUndoStep();
              s.moveTempoPoint(i, bpm: v);
              s.endUndoStep();
            });
      case 'delete':
        s.removeTempoPoint(i);
    }
  }

  void _press(int i, LongPressStartDetails d) {
    _hold.start(_downPointer, d.globalPosition,
      begin: (from) {
        if (!mounted) return;
        _from = from;
        _dragStart(i);
      },
      move: (at) {
        if (_dragging != i) return;
        final delta = at - _from;
        _from = at;
        _dragBy(i, delta);
      },
      end: (_) => _dragEnd());
    _menu(i, d.globalPosition);
  }

  @override
  Widget build(BuildContext context) {
    final map = p.tempoMap;
    final range = _range;
    final size = Size(widget.width, _h);
    return SizedBox(key: const ValueKey('arrange-tempo'), width: widget.width, height: _h, child: Stack(
      clipBehavior: Clip.hardEdge, children: [
      Positioned.fill(child: Listener(onPointerDown: (e) => _clicks.down(e, target: _surface), onPointerUp: _clicks.up,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            // A finger's tap adds a point; a mouse double-clicks.
            if (_clicks.mouse && !_clicks.doubleClick) return;
            Haptics.tap();
            s.addTempoPoint(_beat(d.localPosition.dx), bpm: _bpm(d.localPosition.dy));
          },
          child: Semantics(label: 'Tempo lane: tap to add a point, drag a point to change it, hold it for its menu',
            child: RepaintBoundary(child: CustomPaint(size: size,
              painter: _TempoPainter(map, widget.stepW, range.lo, range.hi, _pad, _dragging))))))),
      for (var i = 0; i < map.length; i++)
        Positioned(left: _x(map[i].beat) - 14, top: _y(map[i].bpm) - 14, width: 28, height: 28,
          child: Listener(
            onPointerDown: (e) {
              _downPointer = e.pointer;
              _clicks.down(e, target: i);
            },
            onPointerUp: _clicks.up,
            // A mouse drags a point anywhere between its neighbours (the first only up and down) straight away.
            child: GestureDetector(
              supportedDevices: const {PointerDeviceKind.mouse},
              dragStartBehavior: DragStartBehavior.down,
              onPanStart: (_) => _dragStart(i),
              onPanUpdate: (d) => _dragBy(i, i == 0 ? Offset(0, d.delta.dy) : d.delta),
              onPanEnd: (_) => _dragEnd(),
              // A finger drags it up and down (along one axis, so it wins over the views' scrolling), or holds it and
              // moves it anywhere; a hold that stays opens its menu.
              child: GestureDetector(key: ValueKey('tempo-point-$i'), behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onTap: () => _tapPoint(i),
                onLongPressStart: (d) => _press(i, d),
                onSecondaryTapUp: (d) => _menu(i, d.globalPosition),
                onVerticalDragStart: (_) => _dragStart(i),
                onVerticalDragUpdate: (d) => _dragBy(i, Offset(0, d.delta.dy)),
                onVerticalDragEnd: (_) => _dragEnd(),
                child: MouseRegion(cursor: i == 0 ? SystemMouseCursors.resizeRow : SystemMouseCursors.move,
                  // No tooltip: a finger's hold is the point's menu, not a tooltip's.
                  child: Semantics(label: '${bpmText(map[i].bpm)} BPM${map[i].ramp ? ', ramped' : ''}',
                    child: const SizedBox.expand())))))),
    ]));
  }
}

/// The tempo curve: flat between points, a jump at a stepped point, a straight line into a ramped one (linear in
/// BPM over beats), each point a dot with its tempo.
class _TempoPainter extends CustomPainter {
  _TempoPainter(this.map, this.stepW, this.lo, this.hi, this.pad, this.dragging);
  final List<TempoPoint> map;
  final double stepW, lo, hi, pad;
  final int? dragging;

  @override
  void paint(Canvas canvas, Size size) {
    double x(double beat) => beat * 4 * stepW;
    double y(double bpm) => pad + (1 - (bpm - lo) / (hi - lo)) * (size.height - 2 * pad);
    canvas.drawRect(Offset.zero & size, Paint()..color = Neon.green.withValues(alpha: 0.04));
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), Paint()..color = Neon.line);
    final path = Path()..moveTo(0, y(map.first.bpm));
    for (var i = 1; i < map.length; i++) {
      final a = map[i - 1], b = map[i];
      if (b.ramp) {
        path.lineTo(x(b.beat), y(b.bpm));
      } else {
        path
          ..lineTo(x(b.beat), y(a.bpm))
          ..lineTo(x(b.beat), y(b.bpm));
      }
    }
    path.lineTo(size.width, y(map.last.bpm));
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = Neon.green.withValues(alpha: 0.10));
    canvas.drawPath(path, Paint()
      ..color = Neon.green.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4);
    final label = TextPainter(textDirection: TextDirection.ltr, maxLines: 1);
    for (var i = 0; i < map.length; i++) {
      final t = map[i];
      final c = Offset(x(t.beat), y(t.bpm));
      canvas.drawCircle(c, i == dragging ? 5 : 3.5, Paint()..color = i == dragging ? Neon.text : Neon.green);
      // The tempo beside each point, where the next one leaves room for it.
      final room = (i + 1 < map.length ? x(map[i + 1].beat) : size.width) - c.dx - 8;
      if (room < 24) continue;
      label.text = TextSpan(text: bpmText(t.bpm), style: Neon.code(size: 9, color: Neon.green));
      label.layout(maxWidth: room);
      final above = c.dy - label.height - 2 >= 0;
      label.paint(canvas, Offset(c.dx + 5, above ? c.dy - label.height - 1 : c.dy + 2));
    }
    label.dispose();
  }

  @override
  bool shouldRepaint(covariant _TempoPainter old) =>
      old.map != map || old.stepW != stepW || old.lo != lo || old.hi != hi || old.dragging != dragging;
}

/// The lane's name beside it, in the track headers' column.
class TempoLaneHeader extends StatelessWidget {
  const TempoLaneHeader({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 10),
    child: Align(alignment: Alignment.centerLeft, child: Text('TEMPO', key: const ValueKey('tempo-lane-header'),
        style: TextStyle(color: Neon.green.withValues(alpha: 0.8), fontSize: 10, letterSpacing: 1.3))));
}
