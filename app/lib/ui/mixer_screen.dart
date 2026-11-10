// Mixer: Reaper-style channel strips (chain slots, pan, fader, meter, M and S) and the shared module inspector.
// All edits flow through AppState; this screen does not own a second mix or processing model.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../model/app_state.dart';
import '../model/arrange_fx.dart';
import '../model/project.dart';
import 'param_control.dart';
import 'theme.dart';
import 'volume_fader.dart';
import 'arrange/track_color.dart';
import 'widgets.dart';

/// Below this the strips keep their height and the panel scrolls up and down instead.
const _minStripHeight = 500.0;
const _stripWidth = 100.0;

class MixerScreen extends StatefulWidget {
  const MixerScreen({super.key, required this.state, required this.onOpenBuilder});
  final AppState state;
  final VoidCallback onOpenBuilder;

  @override
  State<MixerScreen> createState() => _MixerScreenState();
}

class _MixerScreenState extends State<MixerScreen> {
  double _inspectorFraction = 0.34;
  final FocusNode _dividerFocusNode = FocusNode(debugLabel: 'Mixer inspector width');

  @override
  void dispose() {
    _dividerFocusNode.dispose();
    super.dispose();
  }

  void _adjustInspector(double delta) {
    setState(() {
      _inspectorFraction = (_inspectorFraction + delta).clamp(0.24, 0.52).toDouble();
    });
  }

  // A chain slot was tapped: its parameters show in the inspector beside the strips, or in a sheet on narrow panels.
  void _openSlot(LayerDoc layer, String id, {required bool wide}) {
    final s = widget.state;
    s.selectLayer(layer); // this selects its instrument, or its first effect
    if (s.selectedModuleId != id) s.selectModule(id);
    if (wide) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Neon.panel,
      builder: (context) => SafeArea(child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: ListenableBuilder(listenable: s,
            builder: (context, _) => _ModuleInspector(state: s, onOpenBuilder: widget.onOpenBuilder)),
        ),
      )),
    );
  }

  Widget _strips(double height, {required bool wide}) {
    final s = widget.state;
    final layers = s.project.layers;
    return SizedBox(height: height, child: ListView(
      key: const ValueKey('mixer-strips'),
      scrollDirection: Axis.horizontal,
      children: [
        _MasterStrip(state: s),
        const SizedBox(width: 8),
        if (layers.isEmpty)
          const SizedBox(width: 180, child: Center(child: Text('Add a track to mix it.',
            style: TextStyle(color: Neon.dim)))),
        for (var i = 0; i < layers.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChannelStrip(state: s, layer: layers[i], index: i, onSlot: (id) => _openSlot(layers[i], id, wide: wide)),
          ),
      ],
    ));
  }

  Widget _divider(double available, double height) => Focus(
    focusNode: _dividerFocusNode,
    onFocusChange: (_) => setState(() {}),
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        _adjustInspector(0.02);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _adjustInspector(-0.02);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Semantics(
      container: true,
      focused: _dividerFocusNode.hasFocus,
      label: 'Mixer inspector width',
      value: '${(_inspectorFraction * 100).round()} percent',
      increasedValue: '${((_inspectorFraction + 0.02).clamp(0.24, 0.52) * 100).round()} percent',
      decreasedValue: '${((_inspectorFraction - 0.02).clamp(0.24, 0.52) * 100).round()} percent',
      onIncrease: () => _adjustInspector(0.02),
      onDecrease: () => _adjustInspector(-0.02),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (details) => _adjustInspector(-details.delta.dx / available),
          child: SizedBox(width: 12, height: height,
            child: Center(child: Container(width: 2, height: 72,
              decoration: BoxDecoration(color: Neon.blue, borderRadius: BorderRadius.circular(2)))),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final wide = constraints.maxWidth >= 1200;
    const pad = 12.0;
    final height = constraints.maxHeight.isFinite
        ? math.max(_minStripHeight, constraints.maxHeight - 2 * pad) : _minStripHeight;
    final s = widget.state;
    return ListView(padding: const EdgeInsets.all(pad), children: [
      if (!wide)
        _strips(height, wide: false)
      else
        LayoutBuilder(builder: (context, inner) {
          final available = inner.maxWidth - 12;
          final inspectorWidth = available * _inspectorFraction;
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: available - inspectorWidth, child: _strips(height, wide: true)),
            _divider(available, height),
            SizedBox(width: inspectorWidth, height: height, child: SingleChildScrollView(
              child: _ModuleInspector(state: s, onOpenBuilder: widget.onOpenBuilder))),
          ]);
        }),
    ]);
  });
}


/// "C" or "0" is centre, "30L" or "-30" is 30% left, "30R" or "30" is 30% right; null when it isn't a pan.
double? _parsePan(String text) {
  final t = text.trim().toUpperCase();
  if (t == 'C') return 0;
  final left = t.endsWith('L'), right = t.endsWith('R');
  final v = double.tryParse(left || right ? t.substring(0, t.length - 1).trim() : t);
  if (v == null || !v.isFinite) return null;
  return ((left ? -v.abs() : right ? v.abs() : v) / 100).clamp(-1.0, 1.0).toDouble();
}

String _levelText(double v) => VolumeTaper.label(v);

/// The level as typed: dB without the unit ("-6.0", "-inf").
String _levelInitial(double v) => VolumeTaper.label(v).replaceAll(' dB', '');
String _panText(double v) => v.abs() < .01 ? 'C' : '${(v.abs() * 100).round()}${v < 0 ? 'L' : 'R'}';

/// A value under a control: tap it to type a new one.
class _TypedValue extends StatelessWidget {
  const _TypedValue({super.key, required this.text, required this.tooltip, required this.color, required this.onTap});
  final String text, tooltip;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(message: tooltip, child: InkWell(
    onTap: onTap,
    child: SizedBox(height: 36, child: Center(child: Text(text, style: Neon.code(size: 11, color: color)))),
  ));
}

/// An upright REAPER-like fader in dB ([VolumeFader]): drag up and down, Shift or a resting second finger for fine
/// moves, double-tap for 0 dB.
class _Fader extends StatelessWidget {
  const _Fader({super.key, required this.value, required this.color, required this.label, required this.onChanged,
      this.defaultGain = 1});
  final double value, defaultGain;
  final Color color;
  final String label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) =>
      VolumeFader(value: value, color: color, label: label, onChanged: onChanged, defaultGain: defaultGain);
}

class _MasterStrip extends StatelessWidget {
  const _MasterStrip({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    return SizedBox(width: 120, child: NeonPanel(
      color: Neon.pink,
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
      child: ValueListenableBuilder<int>(
        valueListenable: s.masterValueTick,
        builder: (context, _, _) => Column(children: [
          const SizedBox(height: 28, child: Center(child: Text('MASTER',
            style: TextStyle(color: Neon.pink, fontWeight: FontWeight.w800, fontSize: 12)))),
          Expanded(child: Row(children: [
            Expanded(child: _Fader(key: const ValueKey('fader-master'), value: s.project.master, color: Neon.pink,
              label: 'Master level', onChanged: s.setMaster, defaultGain: 0.7)),
            SizedBox(width: 22, child: PeakMeter(key: const ValueKey('master-meter'), state: s, read: () => s.meters.peakL,
              readRight: () => s.meters.peakR, color: Neon.blue, vertical: true)),
            const SizedBox(width: 4),
          ])),
          PeakReadout(key: const ValueKey('master-peak-l'), state: s, read: () => s.meters.peakL,
            style: Neon.code(size: 10, color: Neon.blue)),
          PeakReadout(key: const ValueKey('master-peak-r'), state: s, read: () => s.meters.peakR,
            style: Neon.code(size: 10, color: Neon.green)),
          _TypedValue(key: const ValueKey('level-master'), text: _levelText(s.project.master),
            tooltip: 'Type master level', color: Neon.pink,
            onTap: () => typeValue(context, title: 'Master level (dB, or -inf)', initial: _levelInitial(s.project.master),
              parse: VolumeTaper.parse, apply: s.setMaster)),
        ]),
      ),
    ));
  }
}

/// One track's or folder's strip, top to bottom: name, chain slots (or the folder's bus switch), route, pan, fader
/// and meter, level and peak, M and S. The Mixer, Arrange's mixer card and the focus view's Mixer tab share it.
class ChannelStrip extends StatelessWidget {
  const ChannelStrip({super.key, required this.state, required this.layer, required this.index, required this.onSlot});
  final AppState state;
  final LayerDoc layer;
  final int index;
  final ValueChanged<String> onSlot;

  String? get _instrumentName {
    final id = layer.instrument?.id;
    return id == null ? null : state.componentLabel(id);
  }

  Widget _slot(String id, Color color) {
    final selected = state.selectedLayerId == layer.id && state.selectedModuleId == id;
    final name = state.project.module(id)?.name ?? 'Missing module';
    final role = id == layer.generatorId ? 'instrument' : 'effect';
    return Semantics(button: true, selected: selected, label: '${layer.name} $role $name', excludeSemantics: true,
      child: Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: selected ? color.withValues(alpha: 0.28) : Neon.panelHi,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => onSlot(id),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border(left: BorderSide(color: color, width: 3)),
            ),
            alignment: Alignment.centerLeft,
            child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10)),
          ),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final folders = state.project.layers.where((item) => item.isFolder && item.id != layer.id).toList();
    final routeId = folders.any((folder) => folder.id == layer.parentId) ? layer.parentId : null;
    final tint = trackColor(state, layer);
    return SizedBox(width: _stripWidth, child: NeonPanel(
      color: state.selectedLayerId == layer.id ? Neon.blue : tint,
      padding: const EdgeInsets.fromLTRB(5, 6, 5, 6),
      child: ValueListenableBuilder<int>(
        valueListenable: state.layerValueTick(layer.id),
        builder: (context, _, _) => Column(children: [
          InkWell(
            onTap: () => state.selectLayer(layer),
            child: Container(
              height: 32,
              decoration: BoxDecoration(border: Border(top: BorderSide(color: tint, width: 3))),
              alignment: Alignment.center,
              child: Text(layer.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11)),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(height: 3 * 43, child: layer.isFolder
            ? Column(children: [
                const Text('GROUP BUS', style: TextStyle(color: Neon.dim, fontSize: 10)),
                Switch.adaptive(value: layer.busEnabled, onChanged: (v) => state.setFolderBus(layer, v)),
              ])
            : layer.chain.isEmpty
              // A C++ instrument (no .caw chain): its name, else there is none.
              ? Center(child: Text(_instrumentName ?? 'No instrument', maxLines: 2, overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _instrumentName == null ? Neon.dim : Neon.green, fontSize: 10)))
              // A chain is a handful of slots: all built, scrolling inside the strip when there are more than three.
              : SingleChildScrollView(child: Column(children: [
                  for (final id in layer.chain)
                    _slot(id, id == layer.generatorId ? Neon.green : Neon.pink),
                ]))),
          if (!layer.isFolder)
            // Where the track's sound goes: the master or a folder's bus.
            SizedBox(height: 40, child: Tooltip(message: '${layer.name} output', child: DropdownButton<String?>(
              value: routeId,
              isExpanded: true,
              isDense: true,
              underline: const SizedBox.shrink(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Master')),
                for (final folder in folders)
                  DropdownMenuItem<String?>(value: folder.id, child: Text(folder.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (id) { state.moveLayerIntoFolder(layer, id); },
            ))),
          SizedBox(height: 40, child: ResetOnDoubleTap(onReset: () => state.mixLayer(layer, pan: 0), child: Slider(
            key: ValueKey('pan-${layer.id}'),
            value: layer.pan.clamp(-1.0, 1.0).toDouble(), min: -1, max: 1, activeColor: Neon.blue,
            semanticFormatterCallback: (v) => v.abs() < .01 ? '${layer.name} pan centre'
              : '${layer.name} pan ${(v.abs() * 100).round()}% ${v < 0 ? 'left' : 'right'}',
            onChanged: (v) => state.mixLayer(layer, pan: v),
          ))),
          _TypedValue(key: ValueKey('pan-value-${layer.id}'), text: _panText(layer.pan), tooltip: 'Type ${layer.name} pan',
            color: Neon.blue, onTap: () => typeValue(context, title: 'Pan (C, 30L, 30R or -30)',
              initial: _panText(layer.pan), parse: _parsePan, apply: (v) => state.mixLayer(layer, pan: v))),
          Expanded(child: Row(children: [
            Expanded(child: _Fader(key: ValueKey('fader-${layer.id}'), value: layer.volume, color: Neon.green,
              label: '${layer.name} level', onChanged: (v) => state.mixLayer(layer, volume: v))),
            SizedBox(width: 10, child: PeakMeter(key: ValueKey(layer.id), state: state,
              read: () => index < state.layerMeters.length ? state.layerMeters[index].peak : 0.0,
              color: Neon.green, vertical: true)),
            const SizedBox(width: 4),
          ])),
          PeakReadout(state: state, read: () => index < state.layerMeters.length ? state.layerMeters[index].peak : 0.0,
            style: Neon.code(size: 10, color: Neon.dim)),
          _TypedValue(key: ValueKey('level-${layer.id}'), text: _levelText(layer.volume), tooltip: 'Type ${layer.name} level',
            color: Neon.green, onTap: () => typeValue(context, title: 'Level (dB, or -inf)',
              initial: _levelInitial(layer.volume), parse: VolumeTaper.parse,
              apply: (v) => state.mixLayer(layer, volume: v))),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            ToggleChip(label: 'M', size: 40, tooltip: layer.mute ? 'Unmute ${layer.name}' : 'Mute ${layer.name}', on: layer.mute, color: Neon.yellow,
              onTap: () => state.mixLayer(layer, mute: !layer.mute)),
            const SizedBox(width: 6),
            ToggleChip(label: 'S', size: 40, tooltip: layer.solo ? 'Unsolo ${layer.name}' : 'Solo ${layer.name}', on: layer.solo, color: Neon.blue,
              onTap: () => state.mixLayer(layer, solo: !layer.solo)),
          ]),
        ]),
      ),
    ));
  }
}

class _ModuleInspector extends StatelessWidget {
  const _ModuleInspector({required this.state, required this.onOpenBuilder});
  final AppState state;
  final VoidCallback onOpenBuilder;

  @override
  Widget build(BuildContext context) {
    final layer = state.project.layers.where((l) => l.id == state.selectedLayerId).firstOrNull;
    final id = state.project.module(state.selectedModuleId) != null
      ? state.selectedModuleId : layer?.generatorId ?? layer?.effectIds.firstOrNull;
    final module = state.project.module(id);
    final info = id == null ? null : state.info[id];
    return NeonPanel(color: Neon.blue, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('MODULE INSPECTOR', style: TextStyle(color: Neon.blue, fontWeight: FontWeight.w800))),
        TextButton.icon(onPressed: module == null ? null : onOpenBuilder,
          icon: const Icon(Icons.open_in_new, size: 16), label: const Text('Open in Builder')),
      ]),
      if (module == null)
        const Text('Tap a chain slot to inspect its parameters.')
      else ...[
        Text(module.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        Text(info?.summary.isNotEmpty == true ? info!.summary : state.kindOf(module.id),
          style: const TextStyle(color: Neon.dim)),
        const SizedBox(height: 8),
        if (info == null || !info.ok)
          Text(info?.error ?? 'Module has not compiled. Run it in Builder to expose engine parameters.',
            style: const TextStyle(color: Neon.pink))
        else if (info.params.isEmpty)
          const Text('This module exposes no parameters.', style: TextStyle(color: Neon.dim))
        else
          ValueListenableBuilder<int>(valueListenable: state.moduleValueTick(module.id), builder: (context, _, _) => ParamGroups(
            params: info.params, valueOf: (p) => module.params[p.name] ?? p.defaultValue,
            color: state.isEffect(module.id) ? Neon.pink : Neon.green,
            onChanged: (p, v) => state.setParam(module.id, p.name, v))),
        if (module.edited)
          const Padding(padding: EdgeInsets.only(top: 8), child: Text(
            'Source has unrun edits. Run in Builder before expecting them in playback.',
            style: TextStyle(color: Neon.yellow, fontSize: 12))),
      ],
    ]));
  }
}
