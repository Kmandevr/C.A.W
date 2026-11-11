// Mixer: Reaper-style channel strips (chain slots, pan, fader, meter, M and S), the master's FX slots, effects dragged
// between strips, and the shared module inspector.
// All edits flow through AppState; this screen does not own a second mix or processing model.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../model/app_state.dart';
import '../model/arrange_fx.dart';
import '../model/mixer_fx.dart';
import '../model/project.dart';
import '../model/routing_edit.dart';
import 'param_control.dart';
import 'routing_view.dart';
import 'theme.dart';
import 'volume_fader.dart';
import 'arrange/fx_stack.dart' show FxStack, addEffectTo;
import 'arrange/track_color.dart';
import 'devices/device_editor.dart' show openDeviceEditor;
import 'glass.dart';
import 'haptics.dart';
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
      Align(alignment: Alignment.centerRight, child: TextButton.icon(
        key: const ValueKey('mixer-routing'),
        onPressed: () => showRoutingView(context, s),
        icon: const Icon(Icons.account_tree_outlined, size: 16),
        label: const Text('Routing'))),
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
    final master = masterLayerOf(s.project);
    return FxDropTarget(state: s, layer: master, child: SizedBox(width: 120, child: NeonPanel(
      color: Neon.pink,
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
      child: ValueListenableBuilder<int>(
        valueListenable: s.masterValueTick,
        builder: (context, _, _) => Column(children: [
          const SizedBox(height: 28, child: Center(child: Text('MASTER',
            style: TextStyle(color: Neon.pink, fontWeight: FontWeight.w800, fontSize: 12)))),
          // The master's effects (the engine's master chain), like a track's slots: tap one for its UI, long-press
          // and drag it onto a strip to copy it there.
          ValueListenableBuilder<int>(valueListenable: s.layerValueTick(masterLayerId), builder: (context, _, _) =>
            SizedBox(key: const ValueKey('master-fx-slots'), height: 2 * 43, child: master.components.isEmpty
              ? const Center(child: Text('No master FX', style: TextStyle(color: Neon.dim, fontSize: 10)))
              : SingleChildScrollView(child: Column(children: [
                  for (var i = 0; i < master.components.length; i++)
                    FxSlot(key: ValueKey('master-fx-$i'), state: s, layer: master, index: i,
                      onTap: () => openDeviceEditor(context, s, masterLayerOf(s.project), i)),
                ])))),
          SizedBox(height: 36, child: Row(children: [
            Expanded(child: TextButton.icon(key: const ValueKey('master-fx-add'),
              onPressed: () => addEffectTo(context, s, masterLayerOf(s.project)),
              style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: Neon.pink),
              icon: const Icon(Icons.add, size: 16), label: const Text('FX', style: TextStyle(fontSize: 11)))),
            IconButton(key: const ValueKey('master-fx-chain'), tooltip: 'Master FX chain', iconSize: 18,
              color: Neon.pink, padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: () => showMasterFx(context, s), icon: const Icon(Icons.view_agenda_outlined)),
          ])),
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
    )));
  }
}

/// The master's whole chain in a sheet, as a track's FX tab: built-ins with their inline UIs, ⤢ for full screen,
/// drag to reorder, + to add.
Future<void> showMasterFx(BuildContext context, AppState s) => showGlassSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => SafeArea(child: SizedBox(
    height: MediaQuery.sizeOf(context).height * 0.8,
    child: ListenableBuilder(listenable: s,
      builder: (context, _) => FxStack(key: const ValueKey('master-fx-stack'), state: s, layer: masterLayerOf(s.project))),
  )),
);

/// One effect in a strip's slots: tap for its UI; long-press and drag it onto another strip to copy it there (Alt or
/// Shift held while dropping moves it, as REAPER's Alt-drag). [index] is in the chain's C++ effects, or with [caw]
/// in its .caw effects.
class FxSlot extends StatelessWidget {
  const FxSlot({super.key, required this.state, required this.layer, required this.index, required this.onTap,
    this.caw = false, this.selected = false});
  final AppState state;
  final LayerDoc layer;
  final int index;
  final bool caw, selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final use = caw ? null : layer.components[index];
    final name = caw ? state.project.module(layer.effectIds[index])?.name ?? 'Missing module' : state.componentLabel(use!.id);
    final color = caw ? Neon.pink : (isBuiltinComponent(use!.id) ? Neon.blue : Neon.green);
    final bypassed = use?.bypass ?? false;
    final slot = Semantics(button: true, selected: selected, label: '${layer.name} effect $name${bypassed ? ', bypassed' : ''}',
      excludeSemantics: true, child: Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: selected ? color.withValues(alpha: 0.28) : Neon.panelHi,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border(left: BorderSide(color: color, width: 3)),
            ),
            alignment: Alignment.centerLeft,
            child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: bypassed ? Neon.dim : null)),
          ),
        ),
      ),
    ));
    return LongPressDraggable<FxSlotDrag>(
      data: FxSlotDrag(layer.id, caw ? 'caw' : 'native', index),
      onDragStarted: Haptics.grab,
      feedback: Material(color: Colors.transparent, child: Container(
        width: 96, height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(color: Neon.panelHi, borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color), boxShadow: Neon.glow(color, strength: 0.4)),
        child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10)))),
      childWhenDragging: Opacity(opacity: 0.4, child: slot),
      child: slot,
    );
  }
}

/// A strip that takes effects dragged from other strips: it lights while one hovers, and a drop copies it (moves it
/// with Alt or Shift), with a toast that can undo the drop or make it a move.
class FxDropTarget extends StatelessWidget {
  const FxDropTarget({super.key, required this.state, required this.layer, required this.child});
  final AppState state;
  final LayerDoc layer;
  final Widget child;

  @override
  Widget build(BuildContext context) => DragTarget<FxSlotDrag>(
    onWillAcceptWithDetails: (d) => state.canDropFx(d.data, layer),
    onAcceptWithDetails: (d) {
      final keys = HardwareKeyboard.instance;
      final move = keys.isAltPressed || keys.isShiftPressed;
      final from = state.chainLayer(d.data.layerId);
      final name = d.data.native
          ? state.componentLabel(from!.components[d.data.index].id)
          : state.project.module(from!.effectIds[d.data.index])?.name ?? 'effect';
      final toId = layer.id, fromName = from.name;
      state.endUndoStep();
      if (!state.dropFx(d.data, layer, move: move)) return;
      state.endUndoStep();
      Haptics.drop();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(move ? 'Moved $name from $fromName to ${layer.name}' : 'Copied $name to ${layer.name}'),
        action: move ? SnackBarAction(label: 'Undo', onPressed: state.undo) : SnackBarAction(label: 'Move', onPressed: () {
          // The copy goes, and the effect itself moves instead.
          state.undo();
          final to = state.chainLayer(toId);
          if (to != null) state.dropFx(d.data, to, move: true);
          state.endUndoStep();
        }),
      ));
    },
    builder: (context, hover, _) => DecoratedBox(
      key: ValueKey('fx-drop-${layer.id}'),
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
        border: hover.isEmpty ? null : Border.all(color: Neon.green, width: 2)),
      child: child),
  );
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

  /// A C++ instrument heads the slots: tap for its UI (it stays on its track, so it doesn't drag).
  Widget _instrumentSlot(BuildContext context) => Semantics(button: true, label: '${layer.name} instrument $_instrumentName',
    excludeSemantics: true, child: Padding(padding: const EdgeInsets.only(bottom: 3), child: Material(
      color: Neon.panelHi,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () {
          state.selectLayer(layer);
          openDeviceEditor(context, state, layer, -1);
        },
        child: Container(height: 40, padding: const EdgeInsets.symmetric(horizontal: 5), alignment: Alignment.centerLeft,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(4),
            border: const Border(left: BorderSide(color: Neon.green, width: 3))),
          child: Text(_instrumentName ?? '', maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Neon.green)))))));

  Widget _nativeSlot(BuildContext context, int i) => FxSlot(state: state, layer: layer, index: i,
    onTap: () {
      state.selectLayer(layer);
      openDeviceEditor(context, state, layer, i);
    });

  @override
  Widget build(BuildContext context) {
    // Where the sound goes is the nearest bus above (a folder without a bus only groups), so the output menu lists
    // the bus folders; picking one moves the track into it.
    final folders = state.buses.where((item) => item.id != layer.id).toList();
    final routeId = state.outputOf(layer)?.id;
    final tint = trackColor(state, layer);
    return FxDropTarget(state: state, layer: layer, child: SizedBox(width: _stripWidth, child: NeonPanel(
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
                if (layer.busEnabled) SendButton(state: state, layer: layer),
                // A bus's own effects, also draggable to other strips.
                if (layer.busEnabled)
                  Expanded(child: SingleChildScrollView(child: Column(children: [
                    for (var i = 0; i < layer.components.length; i++) _nativeSlot(context, i),
                  ]))),
              ])
            : layer.chain.isEmpty && layer.components.isEmpty
              // A C++ instrument (no .caw chain): its name, else there is none.
              ? Center(child: Text(_instrumentName ?? 'No instrument', maxLines: 2, overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _instrumentName == null ? Neon.dim : Neon.green, fontSize: 10)))
              // A chain is a handful of slots: all built, scrolling inside the strip when there are more than three.
              : SingleChildScrollView(child: Column(children: [
                  if (layer.instrument == null && layer.generatorId != null) _slot(layer.generatorId!, Neon.green)
                  else if (layer.instrument != null) _instrumentSlot(context),
                  // The effects after it: .caw ones, then C++ ones, each draggable onto another strip.
                  for (var i = 0; i < layer.effectIds.length; i++)
                    FxSlot(state: state, layer: layer, index: i, caw: true,
                      selected: state.selectedLayerId == layer.id && state.selectedModuleId == layer.effectIds[i],
                      onTap: () => onSlot(layer.effectIds[i])),
                  for (var i = 0; i < layer.components.length; i++) _nativeSlot(context, i),
                ]))),
          if (!layer.isFolder)
            // Where the track's sound goes: the master or a folder's bus.
            SizedBox(height: 40, child: Row(children: [Expanded(child: Tooltip(message: '${layer.name} output', child: DropdownButton<String?>(
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
            ))), SendButton(state: state, layer: layer)])),
          // Its sends: a knob per bus it feeds (long-press for pre/post, mute, remove), then "Send" for more.
          if (layer.sends.isNotEmpty && (!layer.isFolder || layer.busEnabled))
            Padding(padding: const EdgeInsets.only(top: 2), child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 100),
              child: SingleChildScrollView(child: SendKnobs(state: state, layer: layer, compact: true, size: 26,
                showAdd: false)))),
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
            SizedBox(width: 10, child: TrackMeter(key: ValueKey(layer.id), state: state, index: index,
              stereo: layer.isStereo, color: Neon.green, vertical: true)),
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
    )));
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
