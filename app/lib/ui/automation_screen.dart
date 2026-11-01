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
          IconButton(tooltip: 'Remove lane', visualDensity: VisualDensity.compact,
            onPressed: () => state.removeAutomationLane(layer, lane), icon: const Icon(Icons.close, size: 18)),
          IconButton(tooltip: 'Add midpoint point', visualDensity: VisualDensity.compact,
            onPressed: lane.points.length >= 128 ? null : () =>
              state.addAutomationPoint(layer, lane, (maxStep / 2).roundToDouble(), volume ? layer.volume : layer.pan),
            icon: const Icon(Icons.add_circle_outline, size: 18)),
        ]),
        SizedBox(height: 72, width: double.infinity,
          child: CustomPaint(painter: _CurvePainter(lane.points, maxStep, color, volume))),
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
    return Row(children: [
      SizedBox(width: 28, child: Text('P' + (index + 1).toString(), style: Neon.code(size: 10, color: color))),
      Expanded(child: Slider(value: point.step.clamp(0.0, maxStep), min: 0, max: maxStep, activeColor: color,
        onChanged: (v) => state.updateAutomationPoint(layer, lane, index, v, point.value))),
      SizedBox(width: 38, child: Text(point.step.toStringAsFixed(0), textAlign: TextAlign.end,
        style: Neon.code(size: 10, color: Neon.dim))),
      Expanded(child: Slider(value: point.value.clamp(volume ? 0.0 : -1.0, 1.0),
        min: volume ? 0 : -1, max: 1, activeColor: color,
        onChanged: (v) => state.updateAutomationPoint(layer, lane, index, point.step, v))),
      SizedBox(width: 42, child: Text(point.value.toStringAsFixed(2), textAlign: TextAlign.end,
        style: Neon.code(size: 10, color: color))),
    ]);
  }
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
      (p.step / maxStep * size.width).clamp(0.0, size.width),
      size.height - ((p.value - (volume ? 0 : -1)) / (volume ? 1 : 2) * size.height).clamp(0.0, size.height));
    final path = Path()..moveTo(map(sorted.first).dx, map(sorted.first).dy);
    for (final p in sorted.skip(1)) { final at = map(p); path.lineTo(at.dx, at.dy); }
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2);
    for (final p in sorted) { canvas.drawCircle(map(p), 4, Paint()..color = color); }
  }

  @override
  bool shouldRepaint(covariant _CurvePainter old) => true;
}
