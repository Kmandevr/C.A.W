// The FX tab: a track's FX chain like REAPER's (its instrument first, then its native C++ effects), built-ins as their
// plugin UIs inline and the rest as knob cards, and a Routing view.
import 'package:flutter/material.dart';

import '../../engine/component_info.dart';
import '../../model/app_state.dart';
import '../../model/arrange_fx.dart';
import '../../model/cpp_workbench.dart';
import '../../model/cpp_component.dart';
import '../../model/mixer_fx.dart';
import '../../model/note_fx.dart';
import '../../model/project.dart';
import '../../model/routing_edit.dart';
import '../../model/device_target.dart';
import '../devices/modulators/modulator_devices.dart' show ModulatorsSection;
import '../devices/device_editor.dart';
import '../devices/device_inline.dart';
import '../cpp/plugin_screen.dart';
import '../files/asset_picker.dart';
import '../frame/sections.dart';
import '../glass.dart';
import '../theme.dart';
import '../volume_fader.dart';
import 'arrange_drag.dart';
import 'track_color.dart';
import 'knob.dart';
import 'long_press_menu.dart';
import 'note_fx_section.dart';

/// Opens the Build tab for a C++ component (nothing without sections: tests).
void openSource(BuildContext context, BuildTab tab) => SectionController.maybeOf(context)?.openBuild(tab);

/// Asks for an effect or an instrument (the same browser, as in REAPER) and puts it on [layer]; an instrument
/// replaces the track's, after asking.
Future<void> addEffectTo(BuildContext context, AppState state, LayerDoc layer) async {
  // The master's chain takes C++ effects only.
  final master = isMasterLayer(layer);
  final pick = await showAssetPicker(context, state, kinds: {AssetKind.nativeEffect}, instruments: !master);
  if (pick != null && context.mounted) await dropOnTrack(context, state, layer, pick);
}

/// The same browser showing only instruments: picks [layer]'s instrument (the track menu's Instrument…, the
/// instrument slot's Add and Replace).
Future<void> pickInstrument(BuildContext context, AppState state, LayerDoc layer) async {
  final pick = await showAssetPicker(context, state, kinds: {AssetKind.nativeEffect},
      title: 'Instrument', effects: false);
  if (pick != null && context.mounted) await dropOnTrack(context, state, layer, pick);
}

class FxStack extends StatefulWidget {
  const FxStack({super.key, required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  @override
  State<FxStack> createState() => _FxStackState();
}

class _FxStackState extends State<FxStack> {
  bool _routing = false;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// The selected card: ('native' | 'instrument', index).
  (String, int)? _selected;

  AppState get s => widget.state;
  LayerDoc get layer => widget.layer;

  /// A bus folder or the master: effects only, no instrument.
  bool get _nativeOnly => layer.isFolder || isMasterLayer(layer);

  @override
  Widget build(BuildContext context) {
    s.componentCatalog.refreshIfStale();
    if (layer.isFolder && !layer.busEnabled) {
      return const Center(child: Padding(padding: EdgeInsets.all(16), child: Text(
        'This folder only groups its tracks. Turn its bus on (Mixer) to give it effects of its own.',
        textAlign: TextAlign.center, style: TextStyle(color: Neon.dim))));
    }
    return DragTarget<AssetDrag>(
      onWillAcceptWithDetails: (d) => d.data.kind != AssetKind.pattern && d.data.kind != AssetKind.midiFile && d.data.kind != AssetKind.audioFile,
      onAcceptWithDetails: (d) => dropOnTrack(context, s, layer, d.data),
      builder: (context, hovering, _) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: hovering.isEmpty ? null : Border.all(color: trackColor(s, layer), width: 1.5)),
        child: ValueListenableBuilder<Map<String, NativeComponentInfo>>(
          valueListenable: s.componentCatalog,
          builder: (context, _, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _toolbar(context),
            Expanded(child: _routing ? _RoutingView(state: s, layer: layer) : _stack(context)),
          ]),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) => SizedBox(height: 40, child: Row(children: [
    const SizedBox(width: 8),
    Text(_routing ? 'ROUTING' : 'FX STACK', style: const TextStyle(
      color: Neon.dim, fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800)),
    const Spacer(),
    if (!isMasterLayer(layer)) IconButton(
      key: const ValueKey('fx-routing-toggle'),
      tooltip: _routing ? 'FX stack' : 'Routing',
      iconSize: 18,
      color: _routing ? Neon.blue : Neon.dim,
      onPressed: () => setState(() => _routing = !_routing),
      icon: Icon(_routing ? Icons.view_agenda_outlined : Icons.account_tree_outlined)),
    IconButton(
      tooltip: 'Add FX or instrument',
      iconSize: 18,
      color: Neon.green,
      onPressed: () => addEffectTo(context, s, layer),
      icon: const Icon(Icons.add_circle_outline)),
  ]));

  Widget _stack(BuildContext context) {
    final glow = trackColor(s, layer);
    // Inline plugin UIs take drags on their heroes and knobs, so the stack also scrolls by its thumb, in a gutter
    // of its own on the right, and by the devices' headers.
    return Scrollbar(controller: _scroll, thumbVisibility: true, interactive: true, thickness: 6,
      radius: const Radius.circular(3), child: ListView(
      key: const ValueKey('fx-stack-list'),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(8, 0, 14, 24), children: [
      // The instrument is the chain's first slot (REAPER: an instrument is FX, usually first in the chain). A bus
      // folder has no instrument: only its effects.
      if (isMasterLayer(layer)) ...[
        const _GroupLabel('MASTER EFFECTS', null, note: 'On the whole mix, before the master level and the safety limiter'),
      ] else if (layer.isFolder) ...[
        const _GroupLabel('BUS EFFECTS', null, note: 'On everything this bus hears: its tracks and the sends to it'),
      ] else if (layer.instrument != null) ...[
        const _GroupLabel('INSTRUMENT · C++', null, note: 'Plays the track\'s notes'),
        _NativeEffectCard(key: ValueKey('fx-instrument-${layer.instrument!.id}'), state: s, layer: layer, index: -1,
          instrument: true, selected: _selected == ('instrument', 0), glow: glow,
          onSelect: () => setState(() => _selected = ('instrument', 0))),
      ] else ...[
        const _GroupLabel('INSTRUMENT', null, note: 'Nothing plays this track\'s notes yet'),
        Align(alignment: Alignment.centerLeft, child: TextButton.icon(
          key: const ValueKey('fx-add-instrument'),
          onPressed: () => pickInstrument(context, s, layer),
          icon: const Icon(Icons.piano, size: 18),
          label: const Text('Instrument'))),
      ],
      const SizedBox(height: 6),
      // Per-note FX (#127): above the track's effects, as they run (each note, then the whole track).
      if (!_nativeOnly && layer.instrument != null && layer.noteComponents.isNotEmpty)
        NoteFxSection(key: const ValueKey('note-fx-section'), state: s, layer: layer),
      if (!_nativeOnly) const _GroupLabel('NATIVE EFFECTS · C++', null, note: 'After the instrument, before volume and pan'),
      if (layer.components.isEmpty) const _GroupLabel('', 'None'),
      if (layer.components.isNotEmpty)
        ReorderableListView(
          key: const ValueKey('fx-native-list'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (from, to) => s.moveNativeEffect(layer, from, to),
          children: [
            for (var i = 0; i < layer.components.length; i++)
              _NativeEffectCard(key: ValueKey('fx-native-$i-${layer.components[i].id}'), state: s, layer: layer,
                index: i, selected: _selected == ('native', i), glow: glow,
                onSelect: () => setState(() => _selected = ('native', i))),
          ],
        ),
      const SizedBox(height: 8),
      Align(alignment: Alignment.centerLeft, child: TextButton.icon(
        onPressed: () => addEffectTo(context, s, layer),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('FX'))),
      // Project modulation (#161): this track's modulators, under its effects (the master's: the project's own).
      ModulatorsSection(state: s, layer: layer),
    ]));
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.title, this.empty, {this.note});
  final String title;
  final String? empty, note;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (title.isNotEmpty) Text(title, style: const TextStyle(
        color: Neon.dim, fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w800)),
      if (note != null) Text(note!, style: const TextStyle(color: Neon.dim, fontSize: 9)),
      if (empty != null) Text(empty!, style: const TextStyle(color: Neon.dim, fontSize: 11)),
    ]),
  );
}

/// One card of the stack: a drag handle, the title (tap: its source), actions, then the knobs or a notice.
class _FxCard extends StatelessWidget {
  const _FxCard({required this.index, required this.title, required this.color, required this.glow,
    required this.selected, required this.onSelect, required this.onMenu, required this.body,
    this.subtitle, this.onTitle, this.actions = const [], this.dimmed = false, this.titleKey});
  final int index;
  final String title;
  final String? subtitle;
  final Color color, glow;
  final bool selected, dimmed;
  final VoidCallback onSelect;
  final VoidCallback? onTitle;
  final void Function(Offset at) onMenu;
  final List<Widget> actions;
  final Widget body;
  final Key? titleKey;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: GestureDetector(
      onTap: onSelect,
      onLongPressStart: (d) => onMenu(d.globalPosition),
      onSecondaryTapUp: (d) => onMenu(d.globalPosition),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: dimmed ? 0.55 : 1,
        child: DecoratedBox(
          // The selected effect glows in its track's colour, brighter (owner, 2026-11-09).
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? glow : Colors.white.withValues(alpha: 0.08), width: selected ? 1.6 : 1),
            boxShadow: selected ? [BoxShadow(color: glow.withValues(alpha: 0.35), blurRadius: 10)] : null,
          ),
          child: GlassPanel(radius: 10, tint: color, child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 2, 4, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(height: 36, child: Row(children: [
                // A negative index: a card outside the reorderable lists (the track's instrument).
                if (index < 0)
                  const SizedBox(width: 36, height: 36, child: Icon(Icons.piano, size: 18, color: Neon.dim))
                else
                  ReorderableDragStartListener(index: index, child: const Tooltip(message: 'Drag to reorder',
                    child: SizedBox(width: 36, height: 36, child: Icon(Icons.drag_indicator, size: 18, color: Neon.dim)))),
                Container(width: 4, height: 18, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 8),
                Expanded(child: InkWell(
                  key: titleKey,
                  onTap: onTitle,
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                    if (subtitle != null) Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 9, color: Neon.dim)),
                  ]),
                )),
                ...actions,
              ])),
              body,
            ]),
          )),
        ),
      ),
    ),
  );
}

Widget _iconAction({required String tooltip, required IconData icon, required VoidCallback? onPressed, Color? color, Key? key}) =>
    IconButton(key: key, tooltip: tooltip, onPressed: onPressed, iconSize: 18, color: color ?? Neon.dim,
      padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      icon: Icon(icon));

/// A native component's card: one of the track's C++ effects, or (with [instrument]) its C++ instrument.
class _NativeEffectCard extends StatelessWidget {
  const _NativeEffectCard({super.key, required this.state, required this.layer, required this.index,
    required this.selected, required this.glow, required this.onSelect, this.instrument = false});
  final AppState state;
  final LayerDoc layer;
  final int index;
  final bool selected;
  final Color glow;
  final VoidCallback onSelect;
  final bool instrument;

  ComponentUseDoc get _use => instrument ? layer.instrument! : layer.components[index];
  void _bypass(bool on) => instrument ? state.setInstrumentBypass(layer, on) : state.setNativeBypass(layer, index, on);
  void _param(String id, double v) =>
      instrument ? state.setInstrumentParamLive(layer, id, v) : state.setNativeParamLive(layer, index, id, v);
  void _remove() => instrument ? state.setNativeInstrument(layer, null) : state.removeNativeEffect(layer, index);

  @override
  Widget build(BuildContext context) {
    final use = _use;
    final info = state.componentInfo(use.id);
    final cpp = state.cppComponentFor(use.id);
    final builtin = isBuiltinComponent(use.id) || (info?.builtin ?? false);
    final status = state.nativeEffectState(use.id);
    final name = info?.label ?? cpp?.name ?? builtinComponentName(use.id);
    void open() {
      if (cpp != null) openSource(context, BuildTab(BuildTabKind.cpp, use.id));
    }
    Future<void> menu(Offset at) async {
      final v = await showLongPressMenu<String>(context, at: at, title: name,
        style: state.settings.longPressMenu, actions: [
          MenuAction('bypass', use.bypass ? 'Turn on' : 'Bypass', Icons.power_settings_new, checked: use.bypass),
          if (cpp != null) const MenuAction('open', 'Open code', Icons.code),
          if (cpp != null) const MenuAction('plugin', 'Plug-in: build, test, export…', Icons.extension_outlined),
          if (instrument) const MenuAction('replace', 'Replace…', Icons.swap_horiz),
          if (!instrument && index > 0) const MenuAction('up', 'Move up', Icons.arrow_upward),
          if (!instrument && index < layer.components.length - 1) const MenuAction('down', 'Move down', Icons.arrow_downward),
          if (!instrument && !layer.isFolder && !isMasterLayer(layer))
            MenuAction('pernote', 'Run per note', Icons.scatter_plot,
              enabled: state.perNoteBlocker(layer, use.id) == null, hint: state.perNoteBlocker(layer, use.id)),
          if (info != null && info.parameters.isNotEmpty) const MenuAction('reset', 'Reset knobs', Icons.restart_alt),
          const MenuAction('remove', 'Remove', Icons.delete_outline, danger: true),
        ]);
      if (v == 'bypass') _bypass(!use.bypass);
      if (v == 'open' && context.mounted) open();
      if (v == 'plugin' && cpp != null && context.mounted) {
        // The page's Open code (and its errors) go to the component's Build tab.
        await openPluginPage(context, state.cppWorkbench(cpp.id), onOpenCode: (_) => open());
      }
      if (v == 'replace' && context.mounted) await pickInstrument(context, state, layer);
      if (v == 'up') state.moveNativeEffect(layer, index, index - 1);
      if (v == 'down') state.moveNativeEffect(layer, index, index + 1);
      if (v == 'reset' && info != null) {
        for (final p in info.parameters) {
          _param(p.id, p.defaultValue);
        }
        state.commitNativeParams(layer);
      }
      if (v == 'pernote') state.runPerNote(layer, index);
      if (v == 'remove') _remove();
    }
    final failed = status == NativeEffectState.buildFailed || status == NativeEffectState.loadFailed;
    final openKey = ValueKey(instrument ? 'fx-instrument-open' : 'fx-open-$index');
    final bypassKey = ValueKey(instrument ? 'fx-instrument-bypass' : 'fx-bypass-$index');
    final target = DeviceTarget(state, layer.id, instrument ? DeviceTarget.instrumentSlot : index);
    // A built-in with a plugin UI shows it right here (owner, 2026-11-10: "Show the UI right in the FX tab"); ⤢ and
    // the name open it full screen. Third-party and project C++ keep the knob card.
    if (status == NativeEffectState.playing && cpp == null && hasInlineDevice(target)) {
      return DeviceInline(
        key: ValueKey('fx-device-${instrument ? 'instrument' : index}'),
        target: target,
        leading: index < 0
            ? const SizedBox(width: 32, height: 36, child: Icon(Icons.piano, size: 18, color: Neon.dim))
            : ReorderableDragStartListener(index: index, child: const Tooltip(message: 'Drag to reorder',
                child: SizedBox(width: 32, height: 36, child: Icon(Icons.drag_indicator, size: 18, color: Neon.dim)))),
        titleKey: ValueKey(instrument ? 'fx-instrument-title' : 'fx-native-title-$index'),
        onTitle: () => openDeviceEditor(context, state, layer, target.slot),
        onMenu: menu,
        selected: selected,
        glow: glow,
        onSelect: onSelect,
        actions: [
          _iconAction(key: openKey, tooltip: 'Open $name full screen', icon: Icons.open_in_full,
            onPressed: () => openDeviceEditor(context, state, layer, target.slot)),
          _iconAction(key: bypassKey, tooltip: use.bypass ? 'Turn on $name' : 'Bypass $name',
            icon: Icons.power_settings_new, color: use.bypass ? Neon.dim : Neon.green,
            onPressed: () => _bypass(!use.bypass)),
          // Replace… is in the header's long-press menu, leaving room for the preset on a phone.
          _iconAction(tooltip: 'Remove $name', icon: Icons.close, onPressed: _remove),
        ],
      );
    }
    return _FxCard(
      index: index,
      title: name,
      titleKey: ValueKey(instrument ? 'fx-instrument-title' : 'fx-native-title-$index'),
      subtitle: builtin ? 'Built-in' : (cpp != null ? 'Project C++ · tap to open' : use.id),
      color: failed ? Neon.pink : (builtin ? Neon.blue : Neon.green),
      glow: glow,
      selected: selected,
      dimmed: use.bypass || status == NativeEffectState.needsTrust || status == NativeEffectState.blocked,
      onSelect: onSelect,
      onTitle: cpp == null ? () => openDeviceEditor(context, state, layer, instrument ? -1 : index) : open,
      onMenu: menu,
      actions: [
        _iconAction(key: openKey, tooltip: 'Open $name',
          icon: Icons.open_in_full, onPressed: () => openDeviceEditor(context, state, layer, instrument ? -1 : index)),
        if (failed) const Tooltip(message: 'Build failed', child: Padding(padding: EdgeInsets.symmetric(horizontal: 6),
          child: Icon(Icons.error, size: 16, color: Neon.pink))),
        _iconAction(key: bypassKey,
          tooltip: use.bypass ? 'Turn on $name' : 'Bypass $name',
          icon: Icons.power_settings_new, color: use.bypass ? Neon.dim : Neon.green,
          onPressed: () => _bypass(!use.bypass)),
        if (instrument) _iconAction(key: const ValueKey('fx-instrument-replace'), tooltip: 'Replace $name',
          icon: Icons.swap_horiz, onPressed: () => pickInstrument(context, state, layer)),
        _iconAction(tooltip: 'Remove $name', icon: Icons.close, onPressed: _remove),
      ],
      body: _body(context, status, use, info, cpp, open),
    );
  }

  Widget _body(BuildContext context, NativeEffectState status, ComponentUseDoc use, NativeComponentInfo? info,
      CppComponentDoc? cpp, VoidCallback open) {
    Widget note(String text, {Color color = Neon.dim, List<Widget> buttons = const []}) => Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 6, 0),
      child: Row(children: [
        Expanded(child: Text(text, style: TextStyle(fontSize: 11, color: color))),
        ...buttons,
      ]),
    );
    switch (status) {
      case NativeEffectState.needsTrust:
        return note('Native code from ‘${state.project.name}’', buttons: [
          if (cpp != null) TextButton(onPressed: () => state.decideNativeTrust(cpp, trust: true), child: const Text('Trust')),
          if (cpp != null) TextButton(onPressed: () => state.decideNativeTrust(cpp, trust: false),
            style: TextButton.styleFrom(foregroundColor: Neon.pink), child: const Text('Block')),
        ]);
      case NativeEffectState.blocked:
        return note('Blocked on this device; the rest of the song plays.', buttons: [
          if (cpp != null) TextButton(onPressed: () => state.decideNativeTrust(cpp, trust: true), child: const Text('Trust')),
        ]);
      case NativeEffectState.buildFailed:
        return note('Build failed', color: Neon.pink, buttons: [
          if (cpp != null) TextButton(onPressed: open, child: const Text('Open code')),
        ]);
      case NativeEffectState.loadFailed:
        return note('Could not load: ${state.nativeStatus?.loadFailed[use.id] ?? ''}', color: Neon.pink, buttons: [
          if (cpp != null) TextButton(onPressed: open, child: const Text('Open code')),
        ]);
      case NativeEffectState.waiting:
        return note(cpp == null ? 'Not part of this project or the engine' : 'Getting ready to play…');
      case NativeEffectState.playing:
        if (info == null) {
          return note(state.engine == null ? 'Knobs appear when the engine runs' : 'Loading knobs…');
        }
        if (info.parameters.isEmpty) return note('No knobs');
        return ValueListenableBuilder<int>(
          valueListenable: state.layerValueTick(layer.id),
          builder: (context, _, _) => Wrap(spacing: 2, runSpacing: 4, children: [
            for (final p in info.parameters)
              if (p.isChoice)
                _ChoiceParam(label: p.label, value: use.params[p.id] ?? p.defaultValue, choices: p.choices, min: p.min,
                  onChanged: (v) { _param(p.id, v); state.commitNativeParams(layer); })
              else
                Knob(key: ValueKey('knob-${use.id}-${p.id}'), value: use.params[p.id] ?? p.defaultValue,
                  min: p.min, max: p.max, step: p.step, defaultValue: p.defaultValue, label: p.label,
                  exponential: p.exponential,
                  enabled: !use.bypass,
                  color: isBuiltinComponent(use.id) ? Neon.blue : Neon.green,
                  valueText: (v) => '${v.toStringAsFixed(p.max - p.min > 20 ? 0 : 2)}${p.unit.isEmpty ? '' : ' ${p.unit}'}',
                  onChanged: (v) => _param(p.id, v),
                  onChangeEnd: () => state.commitNativeParams(layer)),
          ]),
        );
    }
  }
}

/// A choice or toggle parameter: a small dropdown with its name above.
class _ChoiceParam extends StatelessWidget {
  const _ChoiceParam({required this.label, required this.value, required this.choices, required this.min,
    required this.onChanged});
  final String label;
  final double value, min;
  final List<String> choices;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    if (choices.isEmpty) return const SizedBox.shrink();
    final i = (value - min).round().clamp(0, choices.length - 1);
    return SizedBox(width: 96, height: 62, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      DropdownButton<int>(
        value: i,
        isDense: true,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        style: const TextStyle(fontSize: 11, color: Neon.text),
        items: [for (var k = 0; k < choices.length; k++) DropdownMenuItem(value: k, child: Text(choices[k],
          maxLines: 1, overflow: TextOverflow.ellipsis))],
        onChanged: (k) { if (k != null) onChanged(min + k); },
      ),
      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9, color: Neon.dim)),
    ]));
  }
}

/// The same chain left to right: instrument, native effects, volume and pan, the output. Read-only
/// for now; the free routing canvas comes with the engine's routing model (`docs/decisions.md`).
class _RoutingView extends StatelessWidget {
  const _RoutingView({required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  @override
  Widget build(BuildContext context) {
    final out = state.outputOf(layer);
    final nodes = <(String, String, Color, bool)>[
      if (layer.instrument case final inst?)
        (state.componentInfo(inst.id)?.label ?? state.cppComponentFor(inst.id)?.name ?? builtinComponentName(inst.id),
          inst.bypass ? 'Bypassed' : (state.componentPlayable(inst.id) ? 'C++ instrument' : 'Not loaded'),
          isBuiltinComponent(inst.id) ? Neon.blue : Neon.green, inst.bypass || !state.componentPlayable(inst.id))
      else
        ('No instrument', 'Instrument', Neon.green, false),
      for (final c in layer.components)
        (state.componentInfo(c.id)?.label ?? state.cppComponentFor(c.id)?.name ?? builtinComponentName(c.id),
          c.bypass ? 'Bypassed' : (state.componentPlayable(c.id) ? 'C++' : 'Not loaded'),
          isBuiltinComponent(c.id) ? Neon.blue : Neon.green, c.bypass || !state.componentPlayable(c.id)),
      ('Volume · Pan', '${(layer.volume * 100).round()}%', Neon.yellow, false),
      (out?.name ?? 'Master', 'Output', Neon.pink, false),
      for (final send in layer.sends)
        (state.layerById(send.to)?.name ?? 'Missing bus', 'Send · ${VolumeTaper.label(send.level)}${send.pre ? ' · pre' : ''}',
          Neon.violet, send.mute),
    ];
    return SingleChildScrollView(
      key: const ValueKey('fx-routing'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < nodes.length; i++) ...[
          if (i > 0) const Padding(padding: EdgeInsets.only(top: 18),
            child: Icon(Icons.arrow_forward, size: 16, color: Neon.dim)),
          Opacity(opacity: nodes[i].$4 ? 0.5 : 1, child: Container(
            width: 104,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: nodes[i].$3.withValues(alpha: 0.12),
              border: Border.all(color: nodes[i].$3.withValues(alpha: 0.8))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(nodes[i].$1, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              Text(nodes[i].$2, style: TextStyle(fontSize: 9, color: nodes[i].$3)),
            ]),
          )),
        ],
      ]),
    );
  }
}
