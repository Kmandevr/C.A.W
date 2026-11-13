// Arrange's section bar (#207, owner 2026-11-13): coloured, named section blocks above the ruler and markers as thin
// flags. Tap jumps, double tap loops a section, hold opens the menu, hold and move moves it with its contents.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/app_state.dart';
import '../../model/arrange_markers.dart';
import '../../model/project.dart';
import '../haptics.dart';
import '../motion.dart';
import '../pointer_input.dart';
import '../theme.dart';
import 'edit_cues.dart';
import 'long_press_menu.dart';
import 'region_list.dart';

/// The step of the bar line nearest [step] (Shift: the step itself), for a section's move.
int snapToBar(ProjectDoc p, double step) {
  if (HardwareKeyboard.instance.isShiftPressed) return math.max(0, step.round());
  final bars = p.bars;
  final beat = math.max(0.0, step / 4);
  final bar = bars.barAt(beat);
  final a = bars.beatOfBar(bar), b = bars.beatOfBar(bar + 1);
  return ((beat - a <= b - beat ? a : b) * 4).round();
}

/// A section's or marker's look as last drawn, kept while it fades out after it goes.
typedef _Shown = ({int start, int? end, String name, int color});

class ArrangeSectionBar extends StatefulWidget {
  const ArrangeSectionBar({super.key, required this.state, required this.stepW, required this.width, required this.height});
  final AppState state;
  final double stepW, width, height;

  @override
  State<ArrangeSectionBar> createState() => _ArrangeSectionBarState();
}

class _ArrangeSectionBarState extends State<ArrangeSectionBar> {
  final _clicks = ClickCounter();
  final _hold = HoldToMove();
  int _downPointer = 0;

  /// What was drawn last build, by id: a section or marker that goes fades out from there.
  final Map<String, _Shown> _shown = {};
  final Set<String> _leaving = {};

  /// The section or marker held and moved: where the finger took it (unsnapped) and where it would land.
  MarkerDoc? _moving;
  double _movingX = 0;
  int _landAt = 0;
  Offset _from = Offset.zero;

  AppState get s => widget.state;
  ProjectDoc get p => s.project;

  @override
  void dispose() {
    _hold.stop();
    super.dispose();
  }

  void _tap(MarkerDoc m) {
    Haptics.tap();
    s.seekTo(m.startSteps.toDouble());
    // A double tap loops the section (owner, 2026-11-13); the first tap's jump has already run.
    if (_clicks.twice && m.isRegion) {
      s.setLoopRange(m.startSteps, m.endSteps!);
      Motion.tick();
    }
  }

  void _press(MarkerDoc m, LongPressStartDetails d) {
    _hold.start(_downPointer, d.globalPosition,
      begin: (from) {
        if (!mounted) return;
        Motion.tick();
        _from = from;
        setState(() {
          _moving = m;
          _movingX = m.startSteps * widget.stepW;
          _landAt = m.startSteps;
        });
      },
      move: (at) {
        final mv = _moving;
        if (mv == null || !mounted) return;
        final x = math.max(0.0, mv.startSteps * widget.stepW + at.dx - _from.dx);
        final land = mv.isRegion ? snapToBar(p, x / widget.stepW) : math.max(0, (x / widget.stepW).round());
        if (land != _landAt) Haptics.tick();
        setState(() {
          _movingX = x;
          _landAt = land;
        });
      },
      end: (cancel) => _drop(cancel: cancel));
    m.isRegion ? sectionMenu(context, s, m, d.globalPosition) : markerMenu(context, s, m, d.globalPosition);
  }

  /// A mouse drags a section or marker without a hold.
  void _mouseStart(MarkerDoc m, DragStartDetails d) => setState(() {
        _from = d.globalPosition;
        _moving = m;
        _movingX = m.startSteps * widget.stepW;
        _landAt = m.startSteps;
      });

  void _drop({bool cancel = false}) {
    final m = _moving, at = _landAt;
    setState(() => _moving = null);
    if (m == null || cancel || at == m.startSteps) return;
    if (m.isRegion) {
      if (s.moveSection(m, at) != null) {
        Haptics.drop();
      } else {
        Haptics.error();  // it would land on another section: it goes back
      }
    } else {
      s.endUndoStep();
      s.moveMarker(m, at);
      s.endUndoStep();
      Haptics.drop();
    }
  }

  Future<void> _emptyMenu(Offset global, double x) async {
    final step = snapToBar(p, x / widget.stepW);
    final bars = p.bars;
    final bar = bars.barAt(step / 4);
    final v = await showLongPressMenu<String>(context, at: global, title: 'Bar ${bar + 1}',
        style: s.settings.longPressMenu, actions: const [
          MenuAction('section', 'Add section', Icons.space_bar),
          MenuAction('marker', 'Add marker', Icons.flag_outlined),
          MenuAction('list', 'Markers and sections…', Icons.list),
        ]);
    if (v == null || !mounted) return;
    switch (v) {
      case 'section':
        // Four bars from the bar pressed, in whatever room there is.
        s.addMarker((bars.beatOfBar(bar) * 4).round(), end: (bars.beatOfBar(bar + 4) * 4).round());
      case 'marker':
        s.addMarker((x / widget.stepW).round());
      case 'list':
        await showMarkerList(context, s);
    }
  }

  /// A marker's flag width for [name].
  static double _flagW(String name) => math.max(40.0, math.min(96.0, name.length * 6.5 + 12));

  /// How far a section's name starts in, past the flags of markers at its start (so neither hides the other).
  double _inset(_Shown sec) {
    final w = widget.stepW;
    var inset = 0.0;
    for (final m in p.markers) {
      if (m.isRegion) continue;
      final dx = (m.startSteps - sec.start) * w;
      if (dx >= 0 && dx < 60) inset = math.max(inset, dx + _flagW(m.name));
    }
    return inset;
  }

  Widget _block(String id, _Shown m, MarkerDoc? live, Duration slide) {
    final w = widget.stepW, h = widget.height;
    final moving = live != null && identical(live, _moving);
    final color = Neon.layer(m.color);
    final region = m.end != null;
    final left = moving ? _movingX : m.start * w;
    final width = region ? math.max(16.0, (m.end! - m.start) * w) : _flagW(m.name);
    final body = region
        ? Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: EdgeInsets.only(left: 5 + (moving ? 0 : _inset(m)), right: 5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: moving ? 0.55 : 0.32),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: color.withValues(alpha: 0.9), width: moving ? 1.5 : 1)),
            alignment: Alignment.centerLeft,
            child: Text(m.name, maxLines: 1, overflow: TextOverflow.clip, softWrap: false,
                style: TextStyle(color: Neon.text, fontSize: 11, fontWeight: FontWeight.w700)))
        // A marker: a thin flag, its pole down the bar and its name beside it.
        : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 2, color: color),
            Flexible(child: Container(
              margin: const EdgeInsets.symmetric(vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(color: color.withValues(alpha: moving ? 0.6 : 0.35),
                borderRadius: const BorderRadius.only(topRight: Radius.circular(3), bottomRight: Radius.circular(3))),
              alignment: Alignment.centerLeft,
              child: Text(m.name, maxLines: 1, overflow: TextOverflow.clip, softWrap: false,
                  style: TextStyle(color: Neon.text, fontSize: 9, fontWeight: FontWeight.w700)))),
          ]);
    final l = live;
    // One tree whether it is there or going, so its fade runs on: a section that went only fades.
    final target = IgnorePointer(ignoring: l == null, child: Listener(
      onPointerDown: (e) {
        _downPointer = e.pointer;
        _clicks.down(e, target: id);
      },
      onPointerUp: _clicks.up,
      // A mouse drags it straight away (no hold); a right-click opens the menu.
      child: GestureDetector(
        supportedDevices: const {PointerDeviceKind.mouse},
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: l == null ? null : (d) => _mouseStart(l, d),
        onHorizontalDragUpdate: l == null ? null : (d) {
          final x = math.max(0.0, l.startSteps * w + d.globalPosition.dx - _from.dx);
          setState(() {
            _movingX = x;
            _landAt = l.isRegion ? snapToBar(p, x / w) : math.max(0, (x / w).round());
          });
        },
        onHorizontalDragEnd: (_) => _drop(),
        onHorizontalDragCancel: () => _drop(cancel: true),
        child: GestureDetector(
          key: ValueKey(region ? 'section-$id' : 'marker-$id'),
          behavior: HitTestBehavior.opaque,
          onTap: l == null ? null : () => _tap(l),
          onLongPressStart: l == null ? null : (d) => _press(l, d),
          onSecondaryTapUp: l == null ? null : (d) => region ? sectionMenu(context, s, l, d.globalPosition)
              : markerMenu(context, s, l, d.globalPosition),
          child: Semantics(
            label: region ? 'Section ${m.name}: tap to jump, double-tap to loop, hold for its menu or to move it'
                : 'Marker ${m.name}: tap to jump, hold for its menu or to move it',
            child: MouseRegion(cursor: SystemMouseCursors.grab,
              child: FadeHold<_Shown>(value: l == null ? null : m, builder: (context, _) => body))))),
    ));
    return AnimatedPositioned(key: ValueKey('bar-item-$id'), duration: moving ? Duration.zero : slide,
        curve: EditMotion.nudgeCurve, left: left, top: 0, height: h, width: width, child: target);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.stepW, h = widget.height;
    final live = {for (final m in p.markers) m.id: m};
    // Sections and markers that went fade out where they were (motion Off: at once).
    for (final id in _shown.keys) {
      if (!live.containsKey(id) && _leaving.add(id)) {
        final d = Motion.fade(Motion.standard, Motion.of(context));
        Timer(d + const Duration(milliseconds: 20), () {
          if (!mounted) return;
          setState(() {
            _leaving.remove(id);
            if (!live.containsKey(id)) _shown.remove(id);
          });
        });
      }
    }
    for (final m in live.values) {
      _shown[m.id] = (start: m.startSteps, end: m.endSteps, name: m.name, color: m.color);
      _leaving.remove(m.id);
    }
    final slide = EditMotion.nudge(context, EditMotionKind.clips) ?? Duration.zero;
    // Sections first, so a marker on one stays reachable; the one moving on top.
    final ids = _shown.keys.toList()
      ..sort((a, b) {
        int rank(String id) => identical(live[id], _moving) ? 2 : (_shown[id]!.end != null ? 0 : 1);
        return rank(a).compareTo(rank(b));
      });
    final moving = _moving;
    return SizedBox(key: const ValueKey('arrange-sections'), width: widget.width, height: h, child: Stack(
      clipBehavior: Clip.hardEdge, children: [
      Positioned.fill(child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (d) => _emptyMenu(d.globalPosition, d.localPosition.dx),
        onSecondaryTapUp: (d) => _emptyMenu(d.globalPosition, d.localPosition.dx),
        child: DecoratedBox(decoration: BoxDecoration(color: Neon.panel.withValues(alpha: 0.5),
            border: const Border(bottom: BorderSide(color: Neon.line)))))),
      for (final id in ids) _block(id, _shown[id]!, live[id], slide),
      // Where a held section would land, over the rest: its outline on the bar line, pink where another section is.
      if (moving != null && moving.isRegion)
        Positioned(left: _landAt * w, top: 1, height: h - 2,
          width: math.max(16.0, (moving.endSteps! - moving.startSteps) * w), child: IgnorePointer(child: Builder(
            builder: (context) {
              final ok = s.sectionFits(_landAt, _landAt + moving.endSteps! - moving.startSteps, except: moving);
              final c = ok ? Neon.text : Neon.pink;
              return DecoratedBox(key: const ValueKey('section-landing'), decoration: BoxDecoration(
                color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4),
                border: Border.all(color: c.withValues(alpha: 0.85), width: 1.5)));
            }))),
    ]));
  }
}

/// The hold menu of section [m] (owner, 2026-11-13): rename, colour, copy and delete; copy and delete take its
/// clips, automation and tempo and signature changes.
Future<void> sectionMenu(BuildContext context, AppState s, MarkerDoc m, Offset at) async {
  final v = await showLongPressMenu<String>(context, at: at, title: m.name, style: s.settings.longPressMenu, actions: [
    const MenuAction('rename', 'Rename', Icons.edit_outlined),
    const MenuAction('color', 'Colour', Icons.palette_outlined),
    const MenuAction('copy', 'Copy', Icons.copy_all_outlined, hint: 'With its clips, automation and tempo'),
    const MenuAction('delete', 'Delete', Icons.delete_outline, danger: true),
  ]);
  if (v == null || !context.mounted) return;
  switch (v) {
    case 'rename':
      await renameMarker(context, s, m);
    case 'color':
      s.editMarker(m, color: m.color + 1);
    case 'copy':
      if (s.copySection(m) != null) Haptics.drop();
    case 'delete':
      s.deleteSection(m);
  }
}
