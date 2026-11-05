// Engine Lab: live diagnostics and inspectable relationships from the compiled project.
// Only capabilities returned by the current engine API are presented; unsupported graph operations are not simulated.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../engine/engine.dart';
import '../model/app_state.dart';
import '../model/project.dart';
import 'theme.dart';
import 'widgets.dart';

class EngineLabScreen extends StatelessWidget {
  const EngineLabScreen({super.key, required this.state, required this.onOpenBuilder});
  final AppState state;
  final VoidCallback onOpenBuilder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: state, builder: (context, _) =>
    ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
      ValueListenableBuilder<int>(valueListenable: state.tick, builder: (context, _, _) =>
        NeonPanel(color: Neon.blue, child: Wrap(spacing: 20, runSpacing: 12, children: [
          _Readout('CPU', '${(state.meters.cpu * 100).toStringAsFixed(1)}%'),
          _Readout('PEAK L', '', child: PeakReadout(state: state, read: () => state.meters.peakL,
            style: Neon.code(size: 16, color: Neon.blue))),
          _Readout('PEAK R', '', child: PeakReadout(state: state, read: () => state.meters.peakR,
            style: Neon.code(size: 16, color: Neon.blue))),
          _Readout('STATUS', state.meters.playing ? 'RUNNING' : 'IDLE'),
          _Readout('OVERLOADS', state.meters.overloaded.toString()),
        ]))),
      const SizedBox(height: 14),
      _MasterScope(state: state),
      const SizedBox(height: 14),
      const Text('TRACK SIGNAL PATHS', style: TextStyle(color: Neon.green, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      if (state.project.layers.isEmpty) const NeonPanel(child: Text('No tracks. Add a track in Arranger.')),
      for (var i = 0; i < state.project.layers.length; i++)
        _SignalPath(state: state, layer: state.project.layers[i], index: i, onOpenBuilder: onOpenBuilder),
      const SizedBox(height: 14),
      const Text('COMPILED MODULES', style: TextStyle(color: Neon.blue, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      if (state.project.modules.isEmpty) const NeonPanel(child: Text('No modules. Create a generator or effect in Builder.')),
      for (final module in state.project.modules) _ModuleReport(state: state, module: module, onOpenBuilder: onOpenBuilder),
      const SizedBox(height: 12),
      const NeonPanel(color: Neon.yellow, child: Text(
        'Engine boundary: the current C API exposes project compilation, parameters, track mixing, scopes and meters. Universal typed connections, sample/buffer editing and custom .cawengine execution are not implemented and are not simulated.',
        style: TextStyle(color: Neon.dim, fontSize: 12))),
    ]));
}

class _SignalPath extends StatelessWidget {
  const _SignalPath({required this.state, required this.layer, required this.index, required this.onOpenBuilder});
  final AppState state;
  final LayerDoc layer;
  final int index;
  final VoidCallback onOpenBuilder;

  @override
  Widget build(BuildContext context) {
    final midiIds = <String>{
      if (layer.patternId != null) layer.patternId!,
      ...layer.clips.map((clip) => clip.patternId),
    };
    final parent = state.project.layers.where((item) => item.id == layer.parentId && item.isFolder).firstOrNull;
    final outputLabel = layer.isFolder && !layer.busEnabled
        ? 'GROUP ONLY'
        : parent?.busEnabled == true ? 'BUS · ${parent!.name}' : 'MASTER OUTPUT';
    return Padding(padding: const EdgeInsets.only(bottom: 8),
      child: NeonPanel(color: Neon.green, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(layer.name, style: const TextStyle(fontWeight: FontWeight.w700))),
        Text(layer.mute ? 'MUTED' : layer.solo ? 'SOLO' : 'ACTIVE',
          style: Neon.code(size: 10, color: layer.mute ? Neon.pink : Neon.green)),
      ]),
      if (midiIds.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 6, children: [
          const Text('MIDI', style: TextStyle(color: Neon.yellow, fontSize: 10, fontWeight: FontWeight.w800)),
          for (final id in midiIds)
            ActionChip(
              avatar: const Icon(Icons.piano, size: 13, color: Neon.yellow),
              label: Text(state.project.module(id)?.name ?? 'Missing pattern', style: const TextStyle(fontSize: 11)),
              onPressed: () { state.selectModule(id); onOpenBuilder(); },
              side: const BorderSide(color: Neon.line), backgroundColor: Neon.panelHi),
        ]),
      ],
      const SizedBox(height: 8),
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 6, children: [
        const Text('AUDIO', style: TextStyle(color: Neon.green, fontSize: 10, fontWeight: FontWeight.w800)),
        for (var i = 0; i < layer.chain.length; i++) ...[
          if (i > 0) _SignalPulse(state: state, index: index, color: Neon.green),
          ActionChip(
            label: Text(state.project.module(layer.chain[i])?.name ?? 'Missing module', style: const TextStyle(fontSize: 11)),
            onPressed: () { state.selectLayer(layer); state.selectModule(layer.chain[i]); onOpenBuilder(); },
            side: const BorderSide(color: Neon.line), backgroundColor: Neon.panelHi),
        ],
        if (layer.chain.isEmpty) const Text('No generator or effects assigned', style: TextStyle(color: Neon.dim, fontSize: 12)),
        _SignalPulse(state: state, index: index, color: Neon.green),
        const Icon(Icons.arrow_forward, size: 14, color: Neon.dim),
        Text(outputLabel,
          style: Neon.code(size: 10, color: Neon.blue)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: PeakMeter(key: ValueKey(layer.id), state: state,
          read: () => index < state.layerMeters.length ? state.layerMeters[index].peak : 0.0,
          color: Neon.green)),
        const SizedBox(width: 8),
        SizedBox(width: 64, child: PeakReadout(state: state,
          read: () => index < state.layerMeters.length ? state.layerMeters[index].peak : 0.0,
          style: Neon.code(size: 10, color: Neon.green))),
      ]),
    ])));
  }
}

class _SignalPulse extends StatelessWidget {
  const _SignalPulse({required this.state, required this.index, required this.color});
  final AppState state;
  final int index;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 24,
    height: 12,
    child: CustomPaint(painter: _SignalPulsePainter(state, index, color)),
  );
}

class _SignalPulsePainter extends CustomPainter {
  _SignalPulsePainter(this.state, this.index, this.color) : super(repaint: state.tick);
  final AppState state;
  final int index;
  final Color color;
  final Paint _line = Paint()..strokeWidth = 1.5;
  final Paint _pulse = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    _line.color = Neon.line;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), _line);
    final peak = index < state.layerMeters.length ? state.layerMeters[index].peak : 0.0;
    if (!state.meters.playing || peak <= 0.001) {
      _pulse.color = color.withValues(alpha: 0.35);
      canvas.drawCircle(Offset(size.width / 2, y), 1.6, _pulse);
      return;
    }
    final phase = (state.tick.value % 18) / 18;
    _pulse.color = color.withValues(alpha: peak.clamp(0.2, 1.0).toDouble());
    canvas.drawCircle(Offset(phase * size.width, y), 2.8, _pulse);
  }

  @override
  bool shouldRepaint(covariant _SignalPulsePainter old) =>
      old.state != state || old.index != index || old.color != color;
}

class _ModuleReport extends StatelessWidget {
  const _ModuleReport({required this.state, required this.module, required this.onOpenBuilder});
  final AppState state;
  final ModuleDoc module;
  final VoidCallback onOpenBuilder;

  @override
  Widget build(BuildContext context) {
    final info = state.info[module.id];
    final color = info == null || !info.ok ? Neon.pink : Neon.blue;
    return Padding(padding: const EdgeInsets.only(bottom: 8),
      child: NeonPanel(color: color, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(module.name, style: const TextStyle(fontWeight: FontWeight.w700))),
          Text(info == null ? 'NOT COMPILED' : info.ok ? info.kind.toUpperCase() : 'ERROR',
            style: Neon.code(size: 10, color: color)),
          IconButton(tooltip: 'Open in Builder', onPressed: () {
            state.selectModule(module.id);
            onOpenBuilder();
          }, icon: const Icon(Icons.open_in_new, size: 18)),
        ]),
        if (info?.summary.isNotEmpty == true) Text(info!.summary, style: const TextStyle(color: Neon.dim, fontSize: 12)),
        if (info?.params.isNotEmpty == true)
          Text('Parameters: ${info!.params.map((p) => p.name).join(', ')}',
            style: Neon.code(size: 11, color: Neon.green)),
        if (info?.error.isNotEmpty == true) Text(info!.error, style: const TextStyle(color: Neon.pink, fontSize: 12)),
        if (info?.imports.isNotEmpty == true) Text('Imports: ${info!.imports.join(', ')}', style: Neon.code(size: 11, color: Neon.dim)),
        if (info?.exports.isNotEmpty == true) Text('Exports: ${info!.exports.map((e) => e.name).join(', ')}', style: Neon.code(size: 11, color: Neon.dim)),
        if (info?.warnings.isNotEmpty == true)
          for (final warning in info!.warnings) Text('Warning: $warning', style: const TextStyle(color: Neon.yellow, fontSize: 11)),
        if (module.edited) const Text('Unrun source edits', style: TextStyle(color: Neon.yellow, fontSize: 11)),
      ])));
  }
}

class _Readout extends StatelessWidget {
  const _Readout(this.label, this.value, {this.child});
  final String label, value;
  final Widget? child;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: Neon.code(size: 10, color: Neon.dim)),
    child ?? Text(value, style: Neon.code(size: 16, color: Neon.blue)),
  ]);
}


/// Reads 512 samples from the native mono master scope only when the meter poller ticks.
class _MasterScope extends StatefulWidget {
  const _MasterScope({required this.state});
  final AppState state;

  @override
  State<_MasterScope> createState() => _MasterScopeState();
}

class _MasterScopeState extends State<_MasterScope> {
  static const _fftSize = 512;
  final Float32List _samples = Float32List(_fftSize);
  final Float32List _real = Float32List(_fftSize);
  final Float32List _imaginary = Float32List(_fftSize);
  final Float32List _spectrum = Float32List(_fftSize ~/ 4);
  late final Float32List _window = Float32List.fromList([
    for (var i = 0; i < _fftSize; i++)
      0.5 - 0.5 * math.cos(2 * math.pi * i / (_fftSize - 1)),
  ]);

  void _updateSpectrum() {
    for (var i = 0; i < _fftSize; i++) {
      _real[i] = _samples[i] * _window[i];
      _imaginary[i] = 0;
    }

    // In-place radix-2 FFT. Scratch buffers and the window are retained across meter ticks.
    var j = 0;
    for (var i = 1; i < _fftSize; i++) {
      var bit = _fftSize >> 1;
      while ((j & bit) != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;
      if (i < j) {
        final real = _real[i];
        _real[i] = _real[j];
        _real[j] = real;
        final imaginary = _imaginary[i];
        _imaginary[i] = _imaginary[j];
        _imaginary[j] = imaginary;
      }
    }

    for (var length = 2; length <= _fftSize; length <<= 1) {
      final angle = -2 * math.pi / length;
      final stepReal = math.cos(angle);
      final stepImaginary = math.sin(angle);
      final half = length >> 1;
      for (var start = 0; start < _fftSize; start += length) {
        var weightReal = 1.0;
        var weightImaginary = 0.0;
        for (var offset = 0; offset < half; offset++) {
          final even = start + offset;
          final odd = even + half;
          final oddReal = _real[odd] * weightReal - _imaginary[odd] * weightImaginary;
          final oddImaginary = _real[odd] * weightImaginary + _imaginary[odd] * weightReal;
          _real[odd] = _real[even] - oddReal;
          _imaginary[odd] = _imaginary[even] - oddImaginary;
          _real[even] += oddReal;
          _imaginary[even] += oddImaginary;
          final nextReal = weightReal * stepReal - weightImaginary * stepImaginary;
          weightImaginary = weightReal * stepImaginary + weightImaginary * stepReal;
          weightReal = nextReal;
        }
      }
    }

    // 128 bars cover bins 1..256 (0..24 kHz at the engine's 48 kHz rate).
    for (var bar = 0; bar < _spectrum.length; bar++) {
      final first = 1 + bar * 2;
      final a = math.sqrt(_real[first] * _real[first] + _imaginary[first] * _imaginary[first]);
      final b = math.sqrt(_real[first + 1] * _real[first + 1] + _imaginary[first + 1] * _imaginary[first + 1]);
      _spectrum[bar] = (math.max(a, b) * (4 / _fftSize)).toDouble();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Neon.showScopes) return const SizedBox.shrink();
    return NeonPanel(color: Neon.blue, child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('MASTER SCOPE · MONO SUM', style: TextStyle(color: Neon.blue, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        ValueListenableBuilder<int>(
          valueListenable: widget.state.tick,
          builder: (context, tick, _) {
            widget.state.engine?.scope(Engine.masterIndex, _samples);
            _updateSpectrum();
            return Column(children: [
              SizedBox(height: 92, width: double.infinity,
                child: CustomPaint(painter: _ScopePainter(_samples, tick))),
              const SizedBox(height: 10),
              SizedBox(height: 72, width: double.infinity,
                child: CustomPaint(painter: _SpectrumPainter(_spectrum, tick))),
            ]);
          },
        ),
        const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('SPECTRUM · 0–24 kHz', style: TextStyle(color: Neon.violet, fontWeight: FontWeight.w800, fontSize: 10)),
          Text('512-POINT HANN / FFT', style: TextStyle(color: Neon.dim, fontSize: 9)),
        ]),
      ],
    ));
  }
}

class _SpectrumPainter extends CustomPainter {
  const _SpectrumPainter(this.bins, this.revision);
  final Float32List bins;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = Neon.line..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (bins.isEmpty) return;
    final slot = size.width / bins.length;
    final barPaint = Paint()..color = Neon.violet;
    for (var i = 0; i < bins.length; i++) {
      final magnitude = math.max(bins[i], 1e-6);
      final db = (20 * math.log(magnitude) / math.ln10).clamp(-72.0, 0.0).toDouble();
      final height = ((db + 72) / 72 * size.height).toDouble();
      canvas.drawRect(Rect.fromLTWH(i * slot + slot * 0.15, size.height - height,
        math.max(1.0, slot * 0.7).toDouble(), height), barPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter old) => old.revision != revision;
}

class _ScopePainter extends CustomPainter {
  const _ScopePainter(this.samples, this.revision);
  final Float32List samples;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final grid = Paint()..color = Neon.line..strokeWidth = 1;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), grid);
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    if (samples.isEmpty) return;
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = i / (samples.length - 1) * size.width;
      final y = mid - samples[i].clamp(-1.0, 1.0) * mid * 0.9;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, Paint()
      ..color = Neon.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant _ScopePainter old) => old.revision != revision;
}
