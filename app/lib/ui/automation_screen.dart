// Automation editor for the track volume and pan lanes supported by the current native engine.
import 'package:flutter/material.dart';
import '../model/app_state.dart';
import '../model/project.dart';
import 'theme.dart';
import 'widgets.dart';

class AutomationScreen extends StatelessWidget {
  const AutomationScreen({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final tracks = state.project.layers.where((l) => !l.isFolder).toList();
    return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
      const Text('AUTOMATION', style: TextStyle(letterSpacing: 1.5, fontWeight: FontWeight.w900, fontSize: 12)),
      const Text('Song-time curves · shared with Arranger and native engine', style: TextStyle(color: Neon.dim, fontSize: 11)),
      const SizedBox(height: 12),
      if (tracks.isEmpty) const NeonPanel(child: Text('Create a track in Arranger to begin automating its level or pan.')),
      for (final layer in tracks) _TrackAutomation(state: state, layer: layer),
      const SizedBox(height: 12),
      const NeonPanel(color: Neon.blue, child: Text(
        'Current engine boundary: track volume and pan lanes are supported. Plugin parameters, modulation links and processing-graph automation are not yet exposed here.',
        style: TextStyle(color: Neon.dim, fontSize: 12))),
    ]);
  }
}

class _TrackAutomation extends StatelessWidget {
  const _TrackAutomation({required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: NeonPanel(color: Neon.blue, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(layer.name, style: const TextStyle(fontWeight: FontWeight.w800))),
        PopupMenuButton<String>(
          tooltip: 'Add automation lane',
          onSelected: (target) => state.addAutomationLane(layer, target),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'volume', child: Text('Track volume')),
            PopupMenuItem(value: 'pan', child: Text('Track pan')),
          ],
          icon: const Icon(Icons.add, color: Neon.blue),
        ),
      ]),
      if (layer.automation.isEmpty)
        const Text('No automation lanes. Add volume or pan automation.', style: TextStyle(color: Neon.dim, fontSize: 12)),
      for (final lane in layer.automation) _AutomationLane(state: state, layer: layer, lane: lane),
    ])),
  );
}

class _AutomationLane extends StatelessWidget {
  const _AutomationLane({required this.state, required this.layer, required this.lane});
  final AppState state;
  final LayerDoc layer;
  final AutomationLaneDoc lane;

  @override
  Widget build(BuildContext context) {
    final volume = lane.target == 'volume';
    final color = volume ? Neon.green : Neon.blue;
    final maxStep = state.project.maxArrangementSteps.toDouble();
    return Padding(padding: const EdgeInsets.only(top: 12), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(volume ? 'VOLUME' : 'PAN', style: Neon.code(size: 12, color: color))),
          IconButton(tooltip: 'Remove lane', onPressed: () => state.removeAutomationLane(layer, lane), icon: const Icon(Icons.close, size: 18)),
          IconButton(tooltip: 'Add midpoint point', onPressed: lane.points.length >= 128 ? null : () =>
              state.addAutomationPoint(layer, lane, (maxStep / 2).roundToDouble(), volume ? layer.volume : layer.pan),
            icon: const Icon(Icons.add_circle_outline, size: 18)),
        ]),
        _CurveEditor(state: state, layer: layer, lane: lane, maxStep: maxStep, color: color, volume: volume),
        for (var i = 0; i < lane.points.length; i++)
          _PointEditor(state: state, layer: layer, lane: lane, index: i, maxStep: maxStep, color: color, volume: volume),
      ],
    ));
  }
}

class _PointEditor extends StatelessWidget {
  const _PointEditor({required this.state, required this.layer, required this.lane, required this.index,
    required this.maxStep, required this.color, required this.volume});
  final AppState state;
  final LayerDoc layer;
  final AutomationLaneDoc lane;
  final int index;
  final double maxStep;
  final Color color;
  final bool volume;

  @override
  Widget build(BuildContext context) {
    final point = lane.points[index];
    final stepSlider = Slider(
      value: point.step.clamp(0.0, maxStep).toDouble(),
      min: 0,
      max: maxStep,
      activeColor: color,
      semanticFormatterCallback: (value) => 'Step ${value.round()}',
      onChanged: (value) => state.updateAutomationPoint(layer, lane, index, value, point.value),
    );
    final valueSlider = Slider(
      value: point.value.clamp(volume ? 0.0 : -1.0, 1.0).toDouble(),
      min: volume ? 0 : -1,
      max: 1,
      activeColor: color,
      semanticFormatterCallback: (value) => volume
        ? 'Volume ${(value * 100).round()} percent'
        : 'Pan ${(value * 100).round()} percent',
      onChanged: (value) => state.updateAutomationPoint(layer, lane, index, point.step, value),
    );
    final removeButton = IconButton(
      tooltip: 'Remove automation point',
      onPressed: () => state.removeAutomationPoint(layer, lane, index),
      icon: const Icon(Icons.close, size: 16),
    );

    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 560) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('POINT ${index + 1}', style: Neon.code(size: 10, color: color))),
            Text('Step ${point.step.toStringAsFixed(0)} · ${point.value.toStringAsFixed(2)}',
              style: Neon.code(size: 10, color: Neon.dim)),
            removeButton,
          ]),
          Row(children: [
            const SizedBox(width: 42, child: Text('TIME', style: TextStyle(color: Neon.dim, fontSize: 9))),
            Expanded(child: stepSlider),
          ]),
          Row(children: [
            SizedBox(width: 42, child: Text(volume ? 'LEVEL' : 'PAN',
              style: const TextStyle(color: Neon.dim, fontSize: 9))),
            Expanded(child: valueSlider),
          ]),
        ]);
      }
      return Row(children: [
        SizedBox(width: 28, child: Text('P${index + 1}', style: Neon.code(size: 10, color: color))),
        Expanded(child: stepSlider),
        SizedBox(width: 38, child: Text(point.step.toStringAsFixed(0), textAlign: TextAlign.end,
          style: Neon.code(size: 10, color: Neon.dim))),
        Expanded(child: valueSlider),
        SizedBox(width: 42, child: Text(point.value.toStringAsFixed(2), textAlign: TextAlign.end,
          style: Neon.code(size: 10, color: color))),
        removeButton,
      ]);
    });
  }
}

class _CurveEditor extends StatefulWidget {
  const _CurveEditor({required this.state, required this.layer, required this.lane,
    required this.maxStep, required this.color, required this.volume});
  final AppState state;
  final LayerDoc layer;
  final AutomationLaneDoc lane;
  final double maxStep;
  final Color color;
  final bool volume;

  @override
  State<_CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<_CurveEditor> {
  int? _dragIndex;

  Offset _position(AutomationPointDoc point, Size size) {
    final minimum = widget.volume ? 0.0 : -1.0;
    final fraction = (point.value - minimum) / (widget.volume ? 1.0 : 2.0);
    return Offset(
      (point.step / widget.maxStep * size.width).clamp(0.0, size.width).toDouble(),
      size.height - (fraction * size.height).clamp(0.0, size.height).toDouble(),
    );
  }

  double _stepAt(Offset position, Size size) =>
      (position.dx / size.width * widget.maxStep).clamp(0.0, widget.maxStep).toDouble();

  double _valueAt(Offset position, Size size) {
    final fraction = (1 - position.dy / size.height).clamp(0.0, 1.0).toDouble();
    return widget.volume ? fraction : fraction * 2 - 1;
  }

  int? _nearestPoint(Offset position, Size size) {
    var nearestIndex = -1;
    var nearestDistance = 20.0;
    for (var i = 0; i < widget.lane.points.length; i++) {
      final distance = (_position(widget.lane.points[i], size) - position).distance;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestIndex = i;
      }
    }
    return nearestIndex < 0 ? null : nearestIndex;
  }

  void _addAt(TapUpDetails details, Size size) {
    if (size.width <= 0 || size.height <= 0 || widget.lane.points.length >= 128) return;
    widget.state.addAutomationPoint(widget.layer, widget.lane,
      _stepAt(details.localPosition, size), _valueAt(details.localPosition, size));
  }

  void _startDrag(DragStartDetails details, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    _dragIndex = _nearestPoint(details.localPosition, size);
  }

  void _drag(DragUpdateDetails details, Size size) {
    final index = _dragIndex;
    if (index == null || size.width <= 0 || size.height <= 0) return;
    widget.state.updateAutomationPoint(widget.layer, widget.lane, index,
      _stepAt(details.localPosition, size), _valueAt(details.localPosition, size));
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 72,
    width: double.infinity,
    child: LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => _addAt(details, size),
        onPanStart: (details) => _startDrag(details, size),
        onPanUpdate: (details) => _drag(details, size),
        onPanEnd: (_) => _dragIndex = null,
        onPanCancel: () => _dragIndex = null,
        child: CustomPaint(painter: _CurvePainter(widget.lane.points, widget.maxStep, widget.color, widget.volume)),
      );
    }),
  );
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.points, this.maxStep, this.color, this.volume);
  final List<AutomationPointDoc> points;
  final double maxStep;
  final Color color;
  final bool volume;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = Neon.line..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (points.isEmpty) return;
    final sorted = [...points]..sort((a, b) => a.step.compareTo(b.step));
    Offset map(AutomationPointDoc p) => Offset(
      (p.step / maxStep * size.width).clamp(0.0, size.width).toDouble(),
      size.height - ((p.value - (volume ? 0 : -1)) / (volume ? 1 : 2) * size.height).clamp(0.0, size.height).toDouble());
    final path = Path()..moveTo(map(sorted.first).dx, map(sorted.first).dy);
    for (final p in sorted.skip(1)) { final at = map(p); path.lineTo(at.dx, at.dy); }
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2);
    for (final p in sorted) { canvas.drawCircle(map(p), 4, Paint()..color = color); }
  }

  @override
  bool shouldRepaint(covariant _CurvePainter old) => true;
}
