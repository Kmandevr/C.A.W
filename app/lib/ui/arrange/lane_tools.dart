// The automation lanes' tool row (#230): select, pencil, line, shapes and eraser for every lane, drawn glyphs in the
// lanes' style, and the Automate picker (search, grouped by device, recent first) that adds a lane.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/arrange_fx.dart';
import '../../model/automation_edit.dart';
import '../../model/automation_writer.dart' show AutomationTarget;
import '../../model/project.dart';
import '../feedback.dart';
import '../glass.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import 'long_press_menu.dart';

/// What a drag in a lane does.
enum LaneTool {
  /// Today's editing (tap adds, drag moves, double tap deletes, the segment handles), and box selection.
  select('Select'),
  pencil('Pencil'),
  line('Line'),
  shape('Shape'),
  eraser('Eraser');

  const LaneTool(this.label);
  final String label;
}

/// The lanes' tool and the shape tool's shape: one choice for every lane (the tool row under each track's lanes).
typedef LaneToolChoice = ({LaneTool tool, LaneShape shape});

final _tools = Expando<ValueNotifier<LaneToolChoice>>('lane tools');

/// [state]'s lane tool (select by default; not saved).
ValueNotifier<LaneToolChoice> laneToolOf(AppState state) =>
    _tools[state] ??= ValueNotifier((tool: LaneTool.select, shape: LaneShape.sine));

/// The row under a track's open lanes: Automate (the picker) and the tools. Where the headers are narrow (a phone)
/// the tools fold into one button showing the tool in use, which opens them all; the row scrolls sideways when the
/// text is large.
class LaneToolRow extends StatelessWidget {
  const LaneToolRow({super.key, required this.state, required this.layer, required this.height});
  final AppState state;
  final LayerDoc layer;
  final double height;

  @override
  Widget build(BuildContext context) {
    final tools = laneToolOf(state);
    return SizedBox(height: height, child: LayoutBuilder(builder: (context, box) =>
      ValueListenableBuilder<LaneToolChoice>(valueListenable: tools,
      builder: (context, choice, _) => SingleChildScrollView(scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(children: [
          Pressable(child: TextButton.icon(
            key: ValueKey('lane-add-${layer.id}'),
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size(0, height),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap, foregroundColor: Neon.blue),
            onPressed: () => showAutomationPicker(context, state, layer),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Automate', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)))),
          const SizedBox(width: 2),
          if (box.maxWidth < kLaneToolsInline)
            _ToolButton(key: const ValueKey('lane-tool-menu'), tool: choice.tool, shape: choice.shape, on: true,
              size: height, more: true,
              onTap: (at) async {
                Haptics.tap();
                final v = await _pickTool(context, state, at, choice);
                if (v != null) tools.value = v;
              })
          else for (final t in LaneTool.values)
            _ToolButton(key: ValueKey('lane-tool-${t.name}'), tool: t, shape: choice.shape, on: choice.tool == t,
              size: height,
              onTap: (at) async {
                Haptics.tap();
                if (t == LaneTool.shape && choice.tool == LaneTool.shape) {
                  final s = await _pickShape(context, state, at, choice.shape);
                  if (s != null) tools.value = (tool: LaneTool.shape, shape: s);
                  return;
                }
                tools.value = (tool: t, shape: choice.shape);
              },
              onHold: t != LaneTool.shape ? null : (at) async {
                final s = await _pickShape(context, state, at, choice.shape);
                if (s != null) tools.value = (tool: LaneTool.shape, shape: s);
              }),
        ])))));
  }
}

/// The header width from which the tools sit in the row one by one (narrower: one button that opens them).
const double kLaneToolsInline = 236;

/// Every tool and shape in one menu (the narrow row's tool button).
Future<LaneToolChoice?> _pickTool(BuildContext context, AppState state, Offset at, LaneToolChoice now) async {
  final v = await showLongPressMenu<Object>(context, at: at, title: 'Lane tool', style: state.settings.longPressMenu,
      actions: [
        for (final t in LaneTool.values)
          if (t != LaneTool.shape) MenuAction<Object>(t, t.label, _toolIcon(t), checked: now.tool == t, section: 'Tool'),
        for (final s in LaneShape.values)
          MenuAction<Object>(s, s.label, _shapeIcon(s), checked: now.tool == LaneTool.shape && now.shape == s,
              section: 'Shape'),
      ]);
  if (v is LaneTool) return (tool: v, shape: now.shape);
  if (v is LaneShape) return (tool: LaneTool.shape, shape: v);
  return null;
}

IconData _toolIcon(LaneTool t) => switch (t) {
      LaneTool.select => Icons.near_me_outlined,
      LaneTool.pencil => Icons.draw_outlined,
      LaneTool.line => Icons.trending_up,
      LaneTool.shape => Icons.waves,
      LaneTool.eraser => Icons.auto_fix_normal,
    };

Future<LaneShape?> _pickShape(BuildContext context, AppState state, Offset at, LaneShape now) =>
    showLongPressMenu<LaneShape>(context, at: at, title: 'Shape', style: state.settings.longPressMenu, actions: [
      for (final s in LaneShape.values)
        MenuAction(s, s.label, _shapeIcon(s), checked: s == now, section: 'Shape'),
    ]);

IconData _shapeIcon(LaneShape s) => switch (s) {
      LaneShape.sine => Icons.waves,
      LaneShape.triangle => Icons.change_history,
      LaneShape.saw => Icons.signal_cellular_alt,
      LaneShape.square => Icons.crop_square,
      LaneShape.random => Icons.shuffle,
    };

class _ToolButton extends StatelessWidget {
  const _ToolButton({super.key, required this.tool, required this.shape, required this.on, required this.size,
      required this.onTap, this.onHold, this.more = false});
  final LaneTool tool;
  final LaneShape shape;
  final bool on;

  /// It opens a menu of every tool (a small ▾ beside the picture).
  final bool more;
  final double size;
  final void Function(Offset global) onTap;
  final void Function(Offset global)? onHold;

  @override
  Widget build(BuildContext context) {
    final c = on ? Neon.blue : Neon.dim;
    final tip = more ? 'Lane tool: ${tool == LaneTool.shape ? shape.label : tool.label} (tap for the tools)'
        : tool == LaneTool.shape ? 'Shape: ${shape.label} (tap again or hold to pick)' : tool.label;
    return Tooltip(message: tip, child: Semantics(button: true, selected: on, label: tip, child: Pressable(child:
      GestureDetector(behavior: HitTestBehavior.opaque,
        onTapUp: (d) => onTap(d.globalPosition),
        onLongPressStart: onHold == null ? null : (d) => onHold!(d.globalPosition),
        onSecondaryTapUp: onHold == null ? null : (d) => onHold!(d.globalPosition),
        child: AnimatedContainer(
          duration: Motion.fade(Motion.small, Motion.of(context)),
          width: math.max(28, size - 2) + (more ? 12 : 0), height: size - 6,
          margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 3),
          decoration: BoxDecoration(
            color: on ? Neon.blue.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: on ? Neon.blue.withValues(alpha: 0.7) : Colors.transparent),
            boxShadow: on ? [BoxShadow(color: Neon.blue.withValues(alpha: 0.25), blurRadius: 6)] : null),
          child: more
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(width: math.max(28, size - 2) - 2, height: size - 8, child: CustomPaint(painter: _ToolGlyph(tool, shape, c))),
                  Icon(Icons.arrow_drop_down, size: 12, color: c),
                ])
              : CustomPaint(painter: _ToolGlyph(tool, shape, c)))))));
  }
}

/// Each tool's little picture, in strokes like the lanes' own curves.
class _ToolGlyph extends CustomPainter {
  _ToolGlyph(this.tool, this.shape, this.color);
  final LaneTool tool;
  final LaneShape shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height) * 0.62;
    final o = Offset((size.width - s) / 2, (size.height - s) / 2);
    Offset p(double x, double y) => o + Offset(x * s, y * s);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    switch (tool) {
      case LaneTool.select:
        path
          ..moveTo(p(0.2, 0.1).dx, p(0.2, 0.1).dy)
          ..lineTo(p(0.2, 0.85).dx, p(0.2, 0.85).dy)
          ..lineTo(p(0.4, 0.65).dx, p(0.4, 0.65).dy)
          ..lineTo(p(0.6, 0.95).dx, p(0.6, 0.95).dy)
          ..moveTo(p(0.4, 0.65).dx, p(0.4, 0.65).dy)
          ..lineTo(p(0.72, 0.62).dx, p(0.72, 0.62).dy)
          ..close();
      case LaneTool.pencil:
        path
          ..moveTo(p(0.05, 0.75).dx, p(0.05, 0.75).dy)
          ..cubicTo(p(0.3, 0.2).dx, p(0.3, 0.2).dy, p(0.5, 1.0).dx, p(0.5, 1.0).dy, p(0.95, 0.25).dx, p(0.95, 0.25).dy);
        canvas.drawCircle(p(0.95, 0.25), 1.8, Paint()..color = color);
      case LaneTool.line:
        path
          ..moveTo(p(0.1, 0.85).dx, p(0.1, 0.85).dy)
          ..lineTo(p(0.9, 0.15).dx, p(0.9, 0.15).dy);
        canvas
          ..drawCircle(p(0.1, 0.85), 2, Paint()..color = color)
          ..drawCircle(p(0.9, 0.15), 2, Paint()..color = color);
      case LaneTool.eraser:
        final r = RRect.fromRectAndRadius(Rect.fromPoints(p(0.15, 0.35), p(0.85, 0.75)), Radius.circular(s * 0.08));
        canvas.save();
        canvas.translate(o.dx + s / 2, o.dy + s / 2);
        canvas.rotate(-0.5);
        canvas.translate(-(o.dx + s / 2), -(o.dy + s / 2));
        canvas.drawRRect(r, pen);
        canvas.drawLine(p(0.42, 0.35), p(0.42, 0.75), pen);
        canvas.restore();
      case LaneTool.shape:
        const n = 24;
        for (var i = 0; i <= n; i++) {
          final x = i / n;
          final ph = (x * 2) % 1.0;
          final y = switch (shape) {
            LaneShape.sine => 0.5 - 0.4 * math.sin(2 * math.pi * x * 2),
            LaneShape.triangle => 0.5 - 0.4 * (ph < 0.25 ? 4 * ph : ph < 0.75 ? 2 - 4 * ph : 4 * ph - 4),
            LaneShape.saw => 0.9 - 0.8 * ph,
            LaneShape.square => ph < 0.5 ? 0.15 : 0.85,
            LaneShape.random => const [0.3, 0.8, 0.5, 0.2, 0.65][(x * 4.99).floor()],
          };
          final at = p(x, y);
          if (i == 0) {
            path.moveTo(at.dx, at.dy);
          } else {
            path.lineTo(at.dx, at.dy);
          }
        }
    }
    canvas.drawPath(path, pen);
  }

  @override
  bool shouldRepaint(covariant _ToolGlyph old) => old.tool != tool || old.shape != shape || old.color != color;
}

/// One parameter the picker offers: what it automates, its name and its group (the device).
typedef AutomationChoice = ({AutomationTarget target, String name, String group, bool exists});

/// What [layer] can automate, grouped by device: Track (volume, pan), then its instrument, then each effect.
List<AutomationChoice> automationChoices(AppState state, LayerDoc layer) {
  final out = <AutomationChoice>[];
  void add(AutomationTarget t, String name, String group) =>
      out.add((target: t, name: name, group: group, exists: state.hasLaneFor(layer, t)));
  for (final target in const ['volume', 'pan']) {
    add(AutomationTarget('track', target, layerId: layer.id), target == 'volume' ? 'Volume' : 'Pan', 'Track');
  }
  if (layer.isFolder) return out;
  final instrument = layer.instrument;
  if (instrument != null) {
    final info = state.componentInfo(instrument.id);
    final group = info?.label ?? state.componentLabel(instrument.id);
    for (final p in info?.parameters ?? const []) {
      if (p.automatable) add(AutomationTarget('instrument', p.id, layerId: layer.id), p.name.isEmpty ? p.id : p.name, group);
    }
  }
  for (var i = 0; i < layer.components.length; i++) {
    final info = state.useInfo(layer.components[i]);
    final group = '${info?.label ?? state.componentLabel(layer.components[i].id)} · ${i + 1}';
    for (final p in info?.parameters ?? const []) {
      if (p.automatable) {
        add(AutomationTarget('component', p.id, layerId: layer.id, component: i), p.name.isEmpty ? p.id : p.name, group);
      }
    }
  }
  return out;
}

/// The one way to add a lane (#230): a searchable list grouped by device, the recently automated first. A pick
/// adds the lane armed and flat at its value now (one automation undo step); a lane already there is revealed.
Future<void> showAutomationPicker(BuildContext context, AppState state, LayerDoc layer) async {
  final picked = await showGlassSheet<AutomationTarget>(context: context, isScrollControlled: true,
      builder: (context) => _Picker(state: state, layer: layer));
  if (picked != null) state.addLaneFor(layer, picked);
}

class _Picker extends StatefulWidget {
  const _Picker({required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = automationChoices(widget.state, widget.layer);
    final q = _query.text.trim().toLowerCase();
    bool hit(AutomationChoice c) => q.isEmpty || c.name.toLowerCase().contains(q) || c.group.toLowerCase().contains(q);
    final recentKeys = widget.state.project.recentAutomation;
    final recent = [
      for (final k in recentKeys) ...all.where((c) => c.target.key == k && hit(c)),
    ];
    final shown = [for (final c in all) if (hit(c)) c];
    final rows = <Widget>[];
    Widget tile(AutomationChoice c, {String? prefix}) => ListTile(
      key: ValueKey('auto-pick-${prefix ?? ''}${c.target.key}'),
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(c.exists ? Icons.check : Icons.add, size: 18, color: c.exists ? Neon.green : Neon.blue),
      title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: prefix == null ? null : Text(c.group, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Neon.dim, fontSize: 11)),
      trailing: c.exists ? const Text('Shown', style: TextStyle(color: Neon.dim, fontSize: 11)) : null,
      onTap: () {
        Haptics.tap();
        Navigator.of(context).pop(c.target);
      });
    if (recent.isNotEmpty) {
      rows.add(const _Group('Recent'));
      rows.addAll([for (final c in recent) tile(c, prefix: 'recent-')]);
    }
    String? group;
    for (final c in shown) {
      if (c.group != group) rows.add(_Group(group = c.group));
      rows.add(tile(c));
    }
    if (shown.isEmpty) {
      rows.add(const Padding(padding: EdgeInsets.all(16),
          child: Text('Nothing matches', style: TextStyle(color: Neon.dim))));
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Row(children: [
          Expanded(child: Text('Automate · ${widget.layer.name}', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800))),
        ])),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: TextField(
          key: const ValueKey('auto-pick-search'),
          controller: _query,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Search parameters'))),
        Flexible(child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 8), children: rows)),
      ]));
  }
}

class _Group extends StatelessWidget {
  const _Group(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Text(text.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800)));
}
