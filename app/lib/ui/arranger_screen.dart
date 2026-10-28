// Arranger: project settings (BPM with tap, meter, loop length, key, seed) and the loop stack of layers.
import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/project.dart';
import 'param_control.dart';
import 'theme.dart';
import 'widgets.dart';

class ArrangerScreen extends StatelessWidget {
  const ArrangerScreen({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final p = state.project;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      children: [
        if (state.meters.overloaded > 0) _OverloadBanner(state: state),
        _ProjectSettings(state: state),
        if (state.globalDefs.isNotEmpty) ...[
          const Heading('Project controls'),
          NeonPanel(
            color: Neon.blue,
            child: ValueListenableBuilder<int>(
              valueListenable: state.values,
              builder: (context, _, _) => ParamGroups(
                params: state.globalDefs,
                color: Neon.blue,
                valueOf: state.globalValue,
                onChanged: (p, v) => state.setGlobal(p.name, v),
              ),
            ),
          ),
        ],
        Heading('Layers (${p.layers.length})',
            trailing: TextButton.icon(
              onPressed: p.layers.length >= 64 ? null : state.addLayer,
              icon: const Icon(Icons.add, color: Neon.yellow),
              label: const Text('Add layer'),
            )),
        if (p.layers.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No layers. Add one, then pick a generator for it.', textAlign: TextAlign.center),
          ),
        for (var i = 0; i < p.layers.length; i++) ...[
          _LayerCard(state: state, layer: p.layers[i], index: i),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _OverloadBanner extends StatelessWidget {
  const _OverloadBanner({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: NeonPanel(
          color: Neon.pink,
          child: Row(children: [
            const Icon(Icons.speed, color: Neon.pink),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                  'Out of headroom: the newest layer${state.meters.overloaded > 1 ? 's were' : ' was'} muted to keep audio clean.'),
            ),
            TextButton(onPressed: state.clearOverload, child: const Text('Unmute')),
          ]),
        ),
      );
}

class _ProjectSettings extends StatefulWidget {
  const _ProjectSettings({required this.state});
  final AppState state;

  @override
  State<_ProjectSettings> createState() => _ProjectSettingsState();
}

class _ProjectSettingsState extends State<_ProjectSettings> {
  final List<DateTime> _taps = [];
  late final TextEditingController _seed;

  static const keys = [
    'C major', 'C minor', 'C# minor', 'D major', 'D minor', 'Eb major', 'E minor', 'F major', 'F minor', //
    'F# minor', 'G major', 'G minor', 'A major', 'A minor', 'Bb major', 'B minor', 'None',
  ];

  @override
  void initState() {
    super.initState();
    _seed = TextEditingController(text: widget.state.project.seed.toRadixString(16));
  }

  @override
  void didUpdateWidget(covariant _ProjectSettings old) {
    super.didUpdateWidget(old);
    final hex = widget.state.project.seed.toRadixString(16);
    if (int.tryParse(_seed.text, radix: 16) != widget.state.project.seed) _seed.text = hex;
  }

  @override
  void dispose() {
    _seed.dispose();
    super.dispose();
  }

  void _tap() {
    final now = DateTime.now();
    if (_taps.isNotEmpty && now.difference(_taps.last).inMilliseconds > 2000) _taps.clear();
    _taps.add(now);
    if (_taps.length > 5) _taps.removeAt(0);
    if (_taps.length >= 2) {
      final ms = _taps.last.difference(_taps.first).inMicroseconds / 1000.0 / (_taps.length - 1);
      final bpm = (60000 / ms).clamp(20.0, 400.0);
      widget.state.editProject((p) => p.bpm = double.parse(bpm.toStringAsFixed(1)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final p = s.project;
    final bpmText = p.bpm == p.bpm.roundToDouble() ? p.bpm.toStringAsFixed(0) : p.bpm.toStringAsFixed(1);
    return NeonPanel(
      color: Neon.blue,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton.outlined(
              onPressed: () => s.editProject((p) => p.bpm = (p.bpm - 1).clamp(20, 400).roundToDouble()),
              icon: const Icon(Icons.remove)),
          Expanded(
            child: Column(children: [
              Text(bpmText, style: Neon.code(size: 34, color: Neon.blue).copyWith(fontWeight: FontWeight.w700)),
              const Text('BPM', style: TextStyle(color: Neon.dim, fontSize: 12)),
            ]),
          ),
          IconButton.outlined(
              onPressed: () => s.editProject((p) => p.bpm = (p.bpm + 1).clamp(20, 400).roundToDouble()),
              icon: const Icon(Icons.add)),
          const SizedBox(width: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Neon.blue, minimumSize: const Size(72, 48)),
            onPressed: _tap,
            child: const Text('TAP', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _Labeled(
            'Time',
            DropdownButton<int>(
              value: p.beatsPerBar,
              items: [for (var b = 2; b <= 7; b++) DropdownMenuItem(value: b, child: Text('$b/4'))],
              onChanged: (v) => s.editProject((p) => p.beatsPerBar = v!),
            ),
          ),
          _Labeled(
            'Loop',
            DropdownButton<int>(
              value: p.loopBars,
              items: [
                for (final b in {1, 2, 4, 8, 16, p.loopBars}.toList()..sort())
                  DropdownMenuItem(value: b, child: Text(b == 1 ? '1 bar' : '$b bars')),
              ],
              onChanged: (v) => s.editProject((p) => p.loopBars = v!),
            ),
          ),
          _Labeled(
            'Key',
            DropdownButton<String>(
              value: keys.contains(p.key) ? p.key : 'None',
              items: [for (final k in keys) DropdownMenuItem(value: k, child: Text(k))],
              onChanged: (v) => s.editProject((p) => p.key = v!),
            ),
          ),
          _Labeled(
            'Seed',
            SizedBox(
              width: 92,
              child: TextField(
                controller: _seed,
                style: Neon.code(size: 14),
                decoration: const InputDecoration(prefixText: '0x'),
                onSubmitted: (v) {
                  final n = int.tryParse(v, radix: 16);
                  if (n != null && n >= 0 && n <= 0xFFFFFFFF) s.editProject((p) => p.seed = n);
                },
              ),
            ),
          ),
          Text('${p.loopSeconds.toStringAsFixed(2)} s loop', style: const TextStyle(color: Neon.dim)),
        ]),
        Row(children: [
          const SizedBox(width: 56, child: Text('Master', style: TextStyle(color: Neon.dim))),
          Expanded(
            child: Slider(
              value: p.master,
              activeColor: Neon.blue,
              onChanged: (v) => s.editProject((p) => p.master = v),
            ),
          ),
          SizedBox(width: 120, child: PeakMeter(state: s, read: () => s.meters.peakL > s.meters.peakR ? s.meters.peakL : s.meters.peakR, color: Neon.blue)),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          activeThumbColor: Neon.blue,
          title: const Text('Crossfade loop seams'),
          subtitle: const Text('3 ms blend where a layer restarts', style: TextStyle(color: Neon.dim)),
          value: p.seamCrossfade,
          onChanged: (v) => s.editProject((p) => p.seamCrossfade = v),
        ),
      ]),
    );
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label ', style: const TextStyle(color: Neon.dim)),
        child,
      ]);
}

class _LayerCard extends StatelessWidget {
  const _LayerCard({required this.state, required this.layer, required this.index});
  final AppState state;
  final LayerDoc layer;
  final int index;

  Future<void> _rename(BuildContext context) async {
    final c = TextEditingController(text: layer.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename layer'),
        content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Rename')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) state.editLayer(layer, (l) => l.name = name.trim());
  }

  @override
  Widget build(BuildContext context) {
    final p = state.project;
    final color = Neon.layer(layer.color);
    final generators = p.modules.where((m) => state.isGenerator(m.id)).toList();
    final effects = p.modules.where((m) => state.isEffect(m.id)).toList();
    final patterns = p.modules.where((m) => state.isPattern(m.id)).toList();
    final lengths = lengthChoices(p.stepsPerBar);
    if (!lengths.any((c) => c.$1 == layer.lengthSteps)) lengths.add((layer.lengthSteps, '${layer.lengthSteps} 16ths'));
    final dim = layer.mute || (p.layers.any((l) => l.solo) && !layer.solo);
    return Opacity(
      opacity: dim ? 0.55 : 1,
      child: NeonPanel(
        color: color,
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            GestureDetector(
              onTap: () => state.editLayer(layer, (l) => l.color = (l.color + 1) % Neon.layers.length),
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: Neon.glow(color)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                onTap: () => _rename(context),
                child: Text(layer.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
            ValueListenableBuilder<int>(
              valueListenable: state.tick,
              builder: (context, _, _) {
                final m = index < state.layerMeters.length ? state.layerMeters[index] : null;
                if (m?.overloaded != true) return const SizedBox();
                return const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.speed, color: Neon.pink, size: 20),
                );
              },
            ),
            ToggleChip(label: 'M', tooltip: 'Mute', on: layer.mute, color: Neon.yellow, onTap: () => state.mixLayer(layer, mute: !layer.mute)),
            const SizedBox(width: 6),
            ToggleChip(label: 'S', tooltip: 'Solo', on: layer.solo, color: Neon.blue, onTap: () => state.mixLayer(layer, solo: !layer.solo)),
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'rename':
                    _rename(context);
                  case 'up':
                    state.moveLayer(index, index - 1);
                  case 'down':
                    state.moveLayer(index, index + 2);
                  case 'delete':
                    state.removeLayer(layer);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                if (index > 0) const PopupMenuItem(value: 'up', child: Text('Move up')),
                if (index < p.layers.length - 1) const PopupMenuItem(value: 'down', child: Text('Move down')),
                const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Neon.pink))),
              ],
            ),
          ]),
          ValueListenableBuilder<int>(
            valueListenable: state.tick,
            builder: (context, _, _) {
              final m = index < state.layerMeters.length ? state.layerMeters[index] : null;
              return Padding(
                padding: const EdgeInsets.fromLTRB(0, 4, 4, 6),
                child: Bar(value: state.meters.playing ? (m?.progress ?? 0) : 0, color: color, height: 3),
              );
            },
          ),
          Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DropdownButton<String?>(
              value: generators.any((g) => g.id == layer.generatorId) ? layer.generatorId : null,
              hint: const Text('Pick a generator'),
              items: [for (final g in generators) DropdownMenuItem(value: g.id, child: Text(g.name))],
              onChanged: (v) => state.editLayer(layer, (l) => l.generatorId = v),
            ),
            Tooltip(
              message: 'Notes for the generator to play (make one in Builder: New, then a pattern)',
              child: DropdownButton<String?>(
                value: patterns.any((m) => m.id == layer.patternId) ? layer.patternId : null,
                hint: const Text('No pattern'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('No pattern')),
                  for (final m in patterns)
                    DropdownMenuItem<String?>(
                      value: m.id,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.piano, size: 16, color: Neon.yellow),
                        const SizedBox(width: 6),
                        Text(m.name),
                      ]),
                    ),
                ],
                onChanged: (v) => state.editLayer(layer, (l) => l.patternId = v),
              ),
            ),
            if (layer.patternId == null)
              DropdownButton<int>(
                value: layer.lengthSteps,
                items: [for (final c in lengths) DropdownMenuItem(value: c.$1, child: Text(c.$2))],
                onChanged: (v) => state.editLayer(layer, (l) => l.lengthSteps = v!),
              )
            else
              const Text('Length: the pattern\'s', style: TextStyle(color: Neon.dim, fontSize: 13)),
          ]),
          Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final id in layer.effectIds)
              InputChip(
                label: Text(p.module(id)?.name ?? '?'),
                avatar: const Icon(Icons.tune, size: 16, color: Neon.pink),
                onDeleted: () => state.editLayer(layer, (l) => l.effectIds.remove(id)),
              ),
            if (layer.effectIds.length < 8)
              PopupMenuButton<String>(
                tooltip: 'Add an effect',
                enabled: effects.isNotEmpty,
                onSelected: (id) => state.editLayer(layer, (l) => l.effectIds.add(id)),
                itemBuilder: (_) => [for (final e in effects) PopupMenuItem(value: e.id, child: Text(e.name))],
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Text(effects.isEmpty ? 'No effects yet (make one in Builder)' : '+ effect',
                      style: const TextStyle(color: Neon.pink)),
                ),
              ),
          ]),
          ValueListenableBuilder<int>(
            valueListenable: state.values,
            builder: (context, _, _) => Row(children: [
              const Icon(Icons.volume_up, size: 18, color: Neon.dim),
              Expanded(
                flex: 3,
                child: Slider(value: layer.volume, activeColor: color, onChanged: (v) => state.mixLayer(layer, volume: v)),
              ),
              const Text('L', style: TextStyle(color: Neon.dim, fontSize: 12)),
              Expanded(
                flex: 2,
                child: Slider(
                  value: layer.pan,
                  min: -1,
                  max: 1,
                  activeColor: color,
                  onChanged: (v) => state.mixLayer(layer, pan: v.abs() < 0.04 ? 0 : v),
                ),
              ),
              const Text('R', style: TextStyle(color: Neon.dim, fontSize: 12)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: PeakMeter(
                state: state,
                read: () => index < state.layerMeters.length ? state.layerMeters[index].peak : 0,
                color: color),
          ),
        ]),
      ),
    );
  }
}
