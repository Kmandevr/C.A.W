// Engine Lab: live diagnostics and inspectable relationships from the compiled project.
// Only capabilities returned by the current engine API are presented; unsupported graph operations are not simulated.
import 'package:flutter/material.dart';
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
      const Text('ENGINE LAB', style: TextStyle(letterSpacing: 1.5, fontWeight: FontWeight.w900, fontSize: 12)),
      const Text('Live engine telemetry · compiled module graph', style: TextStyle(color: Neon.dim, fontSize: 11)),
      const SizedBox(height: 12),
      ValueListenableBuilder<int>(valueListenable: state.tick, builder: (context, _, _) =>
        NeonPanel(color: Neon.blue, child: Wrap(spacing: 20, runSpacing: 12, children: [
          _Readout('CPU', '${(state.meters.cpu * 100).toStringAsFixed(1)}%'),
          _Readout('PEAK L', state.meters.peakL.toStringAsFixed(3)),
          _Readout('PEAK R', state.meters.peakR.toStringAsFixed(3)),
          _Readout('STATUS', state.meters.playing ? 'RUNNING' : 'IDLE'),
          _Readout('OVERLOADS', state.meters.overloaded.toString()),
        ]))),
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
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 8),
    child: NeonPanel(color: Neon.green, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(layer.name, style: const TextStyle(fontWeight: FontWeight.w700))),
        Text(layer.mute ? 'MUTED' : layer.solo ? 'SOLO' : 'ACTIVE',
          style: Neon.code(size: 10, color: layer.mute ? Neon.pink : Neon.green)),
      ]),
      const SizedBox(height: 8),
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 6, children: [
        for (var i = 0; i < layer.chain.length; i++) ...[
          if (i > 0) const Icon(Icons.arrow_forward, size: 14, color: Neon.dim),
          ActionChip(
            label: Text(state.project.module(layer.chain[i])?.name ?? 'Missing module', style: const TextStyle(fontSize: 11)),
            onPressed: () { state.selectModule(layer.chain[i]); onOpenBuilder(); },
            side: const BorderSide(color: Neon.line), backgroundColor: Neon.panelHi),
        ],
        if (layer.chain.isEmpty) const Text('No generator or effects assigned', style: TextStyle(color: Neon.dim, fontSize: 12)),
      ]),
      const SizedBox(height: 8),
      ValueListenableBuilder<int>(valueListenable: state.tick, builder: (context, _, _) {
        final peak = index < state.layerMeters.length ? state.layerMeters[index].peak : 0.0;
        return Row(children: [
          Expanded(child: Bar(value: peak, color: Neon.green, height: 5)),
          const SizedBox(width: 8),
          Text(peak.toStringAsFixed(3), style: Neon.code(size: 10, color: Neon.green)),
        ]);
      }),
    ])));

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
  const _Readout(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: Neon.code(size: 10, color: Neon.dim)),
    Text(value, style: Neon.code(size: 16, color: Neon.blue)),
  ]);
}
