// The sampler's editor (org.caw.sampler) in Raven's one-screen layout: the keyboard map on top (drop a sample and it plays on every key), the zone, sound, slicing and recording sections below, the mod-source strip at the bottom; a phone held upright swipes three panels (Zone, Sound, Tools) under the map.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../model/app_state.dart';
import '../../../model/audio_edit.dart';
import '../../../model/audio_record.dart';
import '../../../model/project.dart';
import '../../../model/project_package.dart';
import '../../../model/sampler.dart';
import '../../../model/sampler_tools.dart';
import '../../frame/sections.dart';
import '../../haptics.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_registry.dart';
import '../device_scope.dart';
import '../flagship/flagship_editor.dart' show DevicePicker;
import '../flagship/flagship_panels.dart';
import '../flagship/flagship_tools.dart' show PanelDots;
import '../kit/controls.dart';
import '../kit/device_style.dart';
import 'sampler_widgets.dart';
import '../../crow.dart';

export 'sampler_widgets.dart';

final Map<String, DeviceEditorEntry> samplerEditors = {
  samplerComponentId: DeviceEditorEntry(
    (_) => [
      DeviceSection('sampler', 'SAMPLER', Icons.piano_outlined, (_) => const SamplerPage(), stripAtBottom: true),
    ],
    family: DeviceFamily.synth,
    inline: (_) => const SamplerSoundPage(),
  ),
};

/// Width from which the editor is one screen; narrower, the map over three panels.
const double samplerWide = 700;

/// The phone's three panels, by name.
const samplerPanels = ['Zone', 'Sound', 'Tools'];

/// Picking files for the sampler, for tests to replace: sample files (absolute paths in app storage) and an SFZ.
class SamplerFiles {
  SamplerFiles._();

  /// Audio files picked and copied into the project (paths of the copies).
  static Future<List<String>> Function(AppState state) pickSamples = _pickSamples;
  static Future<String?> Function() pickSfz = _pickSfz;
  static Future<String?> Function(String name) exportPath = _exportPath;

  static Future<List<String>> _pickSamples(AppState state) async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: audioExtensions);
    final out = <String>[];
    for (final f in files) {
      final a = await state.importAudio(f.name, () => f.readAsByteStream());
      out.add(a.path);
    }
    return out;
  }

  static Future<String?> _pickSfz() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['sfz']);
    return f?.path;
  }

  /// Where an export goes: a folder the user picks (the samples are copied beside the .sfz).
  static Future<String?> _exportPath(String name) async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Export SFZ to…');
    return dir == null ? null : '$dir/$name.sfz';
  }
}

/// The sampler's one page.
class SamplerPage extends StatefulWidget {
  const SamplerPage({super.key});

  @override
  State<SamplerPage> createState() => _SamplerPageState();
}

class _SamplerPageState extends State<SamplerPage> {
  final Set<int> _selected = {};
  final _pages = PageController();
  SamplerState? _working; // a drag's zones before they are saved
  bool _busy = false;
  bool _narrow = false;
  int _panel = 0;
  DropMapping _mapping = DropMapping.auto;
  // Slicing.
  bool _grid = false;
  int _divisions = 16;
  double _sensitivity = 0.5;
  // Recording.
  final _plan = MultisamplePlan();

  AppState get _state => DeviceScope.of(context).target.state;
  LayerDoc? get _layer => DeviceScope.of(context).target.layer;
  SamplerState get _saved => _state.samplerState(_layer!);
  void _save(SamplerState z) => _state.setSamplerState(_layer!, z);

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _say(String t, {bool undo = false}) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(t),
      action: undo ? SnackBarAction(label: 'Undo', onPressed: () => _state.undo()) : null));

  Future<void> _run(String label, Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      Haptics.error();
      _say('$label: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void goTo(int i) {
    if (!_narrow || !_pages.hasClients) return;
    i = i.clamp(0, samplerPanels.length - 1);
    final d = Motion.fade(Motion.standard * 2, Motion.of(context));
    d == Duration.zero ? _pages.jumpToPage(i) : _pages.animateToPage(i, duration: d, curve: Curves.easeOutCubic);
  }

  /// Drop and play: [paths] mapped over the keys by [_mapping] (One key each: from [key] up, beside the zones kept;
  /// otherwise they replace the map), saved as one undo step, so the keyboard plays them at once.
  Future<void> _dropAndPlay(List<String> paths, {int? key}) => _run('Mapping samples', () async {
        if (paths.isEmpty) return;
        final keys = _mapping == DropMapping.keys;
        final r = await _state.mapDroppedSamples(paths, mode: _mapping, startKey: key ?? 36);
        if (!mounted || _layer == null) return;
        final next = keys ? _saved : SamplerState();
        final first = next.zones.length;
        next.zones.addAll(r.zones.take(SamplerState.maxZones - next.zones.length));
        _save(next);
        setState(() => _selected..clear()..addAll([for (var i = first; i < next.zones.length; i++) i]));
        Haptics.drop();
        final known = r.roots.whereType<int>().toList();
        final how = switch (r.mode) {
          DropMapping.root when paths.length == 1 =>
            'on every key, root ${noteName(r.zones.first.root)}${known.isEmpty ? ' (none found: C4)' : ''}',
          DropMapping.root => 'across the keyboard by root',
          DropMapping.spread => 'spread evenly across the keyboard',
          _ => 'one key each from ${noteName(key ?? 36)}',
        };
        _say('${paths.length == 1 ? 'Sample' : '${paths.length} samples'} $how', undo: true);
      });

  Future<void> _addSamples() async {
    final paths = await SamplerFiles.pickSamples(_state);
    if (paths.isNotEmpty) await _dropAndPlay(paths);
  }

  Future<void> _importSfz() => _run('SFZ import', () async {
        final path = await SamplerFiles.pickSfz();
        if (path == null) return;
        final r = await _state.audioIo.sfzImport(path);
        if (!r.ok || r.state == null) throw r.error.isEmpty ? 'the file could not be read' : r.error;
        final zones = SamplerState.fromJson(r.state!);
        // The SFZ's samples are the user's pick: an export may package them (ProjectPackaging.isProjectFile).
        _state.userPickedFiles.addAll(zones.zones.map((x) => x.path));
        _save(zones);
        setState(_selected.clear);
        Haptics.drop();
        _say('Imported ${r.zones} zone${r.zones == 1 ? '' : 's'}'
            '${r.warnings.isEmpty ? '' : ' · left out: ${r.warnings.take(3).join('; ')}${r.warnings.length > 3 ? '…' : ''}'}');
      });

  Future<void> _exportSfz() => _run('SFZ export', () async {
        final path = await SamplerFiles.exportPath(_layer!.name.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '_'));
        if (path == null) return;
        final r = await _state.audioIo.sfzExport(jsonEncode(_saved.toJson()), path, copySamples: true);
        if (!r.ok) throw r.error;
        Haptics.drop();
        _say('Exported ${r.files.length} file${r.files.length == 1 ? '' : 's'} (samples copied beside it)');
      });

  /// The sample slicing reads: the selected zone's, else the first zone's.
  String? _slicePath(SamplerState s) {
    if (s.zones.isEmpty) return null;
    final i = _selected.isEmpty ? 0 : _selected.first;
    return s.zones[i.clamp(0, s.zones.length - 1)].path;
  }

  Future<void> _slice({required bool drums}) => _run('Slicing', () async {
        final path = _slicePath(_saved);
        if (path == null) return;
        final r = await _state.sliceSample(path, grid: _grid, divisions: _divisions, sensitivity: _sensitivity);
        if (!r.ok) throw r.error.isEmpty ? 'no slices found' : r.error;
        if (!mounted) return;
        if (drums) {
          final name = '${path.split(RegExp(r'[/\\]')).last.split('.').first} pads';
          _state.sendSlicesToDrums(path, r.slices, r.frames, name: name, after: _layer);
          Haptics.drop();
          _say('${math.min(r.slices.length, 16)} slices on a new Drums track’s pads', undo: true);
        } else {
          _save(SamplerState(r.zones));
          setState(() => _selected.clear());
          Haptics.drop();
          _say('${r.zones.length} slices from ${noteName(r.zones.first.loKey)} up', undo: true);
        }
      });

  Future<void> _record() async {
    final layer = _layer;
    if (layer == null) return;
    final zones = await showDialog<List<SamplerZone>>(context: context, barrierDismissible: false,
        builder: (_) => MultisampleDialog(state: _state, layer: layer, plan: _plan));
    if (zones == null || zones.isEmpty || !mounted) return;
    _save(SamplerState(zones));
    setState(_selected.clear);
    Haptics.drop();
    _say('${zones.length} recorded zone${zones.length == 1 ? '' : 's'} mapped by root', undo: true);
  }

  @override
  Widget build(BuildContext context) {
    final layer = _layer;
    if (layer == null) return const SizedBox.shrink();
    final s = _working ?? _saved;
    _selected.removeWhere((i) => i >= s.zones.length);
    return LayoutBuilder(builder: (context, box) {
      _narrow = box.maxWidth < samplerWide;
      final accent = DeviceScope.of(context).accent;
      return Column(key: const ValueKey('sampler-page'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _toolbar(s, accent),
        Expanded(child: _narrow ? _phone(s) : _wide(s, box.maxWidth)),
      ]);
    });
  }

  Widget _toolbar(SamplerState s, Color accent) {
    Widget act(String key, IconData icon, String tip, VoidCallback? on, {Color? color}) => IconButton(
        key: ValueKey(key), tooltip: tip, visualDensity: VisualDensity.compact, iconSize: 18,
        icon: Icon(icon, color: on == null ? null : color), onPressed: _busy ? null : on);
    return SizedBox(height: 40, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
      if (_narrow) ...[
        PanelDots(count: samplerPanels.length, index: _panel, color: accent, onPick: goTo),
        const SizedBox(width: 6),
        Flexible(child: Text(samplerPanels[_panel].toUpperCase(), key: const ValueKey('sampler-panel-name'), maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: Neon.text))),
      ] else
        const Flexible(child: Text('Drop samples on the map or the keys: they fit the whole keyboard.', maxLines: 1,
            overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: Neon.dim))),
      const Spacer(),
      if (_busy) const Padding(padding: EdgeInsets.only(right: 6),
          child: CrowLoader(size: 14)),
      if (_selected.length > 1)
        act('sampler-round-robin', Icons.repeat, 'Round robin (${_selected.length})', () {
          _save(_saved..roundRobin(_selected.toList()..sort()));
          Haptics.drop();
          _say('${_selected.length} zones take turns on each hit');
        }),
      if (_selected.isNotEmpty)
        act('sampler-delete', Icons.delete_outline, _selected.length == 1 ? 'Delete zone' : 'Delete ${_selected.length}', () {
          final next = _saved;
          for (final i in _selected.toList()..sort((a, b) => b.compareTo(a))) {
            next.zones.removeAt(i);
          }
          _save(next);
          setState(_selected.clear);
          Haptics.tap();
        }, color: Neon.pink),
      act('sampler-add', Icons.library_add_outlined, 'Add samples', _addSamples),
      act('sampler-import-sfz', Icons.file_open_outlined, 'Import SFZ', _importSfz),
      act('sampler-export-sfz', Icons.file_upload_outlined, 'Export SFZ', s.zones.isEmpty ? null : _exportSfz),
    ])));
  }

  /// The centrepiece: the zone map over the keyboard, one drop target; empty, it says what a drop does.
  Widget _centrepiece(SamplerState s, {required double mapHeight}) {
    final accent = DeviceScope.of(context).accent;
    final state = _state;
    final layer = _layer!;
    String pathOf(AssetDrag d) => state.project.asset(d.id)?.path ?? d.id;
    return FPanel(
      key: const ValueKey('sampler-centrepiece'),
      title: 'KEYBOARD MAP',
      trailing: [
        Text('${s.zones.length} zone${s.zones.length == 1 ? '' : 's'}', style: const TextStyle(fontSize: 10, color: Neon.dim)),
        const SizedBox(width: 6),
        PopupMenuButton<DropMapping>(
          key: const ValueKey('sampler-mapping'),
          tooltip: 'How dropped samples map',
          initialValue: _mapping,
          onSelected: (m) => setState(() => _mapping = m),
          itemBuilder: (_) => [for (final m in DropMapping.values)
            PopupMenuItem(value: m, key: ValueKey('sampler-mapping-${m.name}'), child: Text(dropMappingLabel(m)))],
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), child: Row(mainAxisSize: MainAxisSize.min,
            children: [
              Text(dropMappingLabel(_mapping), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: accent)),
              Icon(Icons.arrow_drop_down, size: 16, color: accent),
            ])),
        ),
      ],
      child: DragTarget<AssetDrag>(
        key: const ValueKey('sampler-drop'),
        onWillAcceptWithDetails: (d) => d.data.kind == AssetKind.audioFile,
        onAcceptWithDetails: (d) => _dropAndPlay([pathOf(d.data)]),
        builder: (context, hovering, _) => AnimatedContainer(
          duration: Motion.fade(Motion.small, Motion.of(context)),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
              border: Border.all(color: hovering.isNotEmpty ? accent : Colors.transparent, width: 2)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Stack(children: [
              ZoneMap(
                key: const ValueKey('sampler-zone-map'),
                zones: s,
                selected: _selected,
                accent: accent,
                height: mapHeight,
                onSelect: (i, {additive = false}) => setState(() {
                  if (i == null) return _selected.clear();
                  if (!additive) _selected.clear();
                  _selected.contains(i) && additive ? _selected.remove(i) : _selected.add(i);
                  Haptics.tap();
                }),
                onDrag: (next) => setState(() => _working = next),
                onDragEnd: () {
                  final w = _working;
                  _working = null;
                  if (w != null) _save(w);
                  Haptics.drop();
                },
              ),
              if (s.zones.isEmpty)
                Positioned.fill(child: IgnorePointer(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.file_download_outlined, color: accent.withValues(alpha: 0.8)),
                  const SizedBox(height: 4),
                  const Text('Drop a sample here: it plays on every key.', key: ValueKey('sampler-empty'),
                      textAlign: TextAlign.center, style: TextStyle(color: Neon.text, fontSize: 12)),
                  const Text('Several map by their notes, or spread evenly.', textAlign: TextAlign.center,
                      style: TextStyle(color: Neon.dim, fontSize: 10)),
                ])))),
            ]),
            const SizedBox(height: 4),
            SamplerKeyboard(
              key: const ValueKey('sampler-keyboard'),
              zones: s,
              accent: accent,
              onNote: (key, on) {
                final id = key + 1000;
                on ? state.previewOn(layer.id, id, key.toDouble(), 0.8) : state.previewOff(id);
              },
              onDropFiles: (key, paths) => _dropAndPlay(paths, key: key),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _zonePanel(SamplerState s) {
    final accent = DeviceScope.of(context).accent;
    final sel = _selected.isEmpty ? null : _selected.first;
    return FPanel(key: const ValueKey('sampler-zone-panel'), title: 'ZONE',
      trailing: [if (sel != null) Text(s.zones[sel].name, style: const TextStyle(fontSize: 10, color: Neon.dim))],
      child: sel == null
          ? const Padding(padding: EdgeInsets.all(12), child: Text('Pick a zone on the map to edit its sample, keys, loop '
              'and stretch.', textAlign: TextAlign.center, style: TextStyle(color: Neon.dim, fontSize: 11)))
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ZoneWaveform(key: ValueKey('sampler-wave-$sel'), state: _state, zone: s.zones[sel], accent: accent,
                  onChanged: (zone) => _save(_saved..zones[sel] = zone)),
              ZoneInspector(key: ValueKey('sampler-zone-$sel'), zone: s.zones[sel], accent: accent,
                  onChanged: (zone) => _save(_saved..zones[sel] = (zone..normalize()))),
            ]));
  }

  List<Widget> _soundPanels(double k) => [
    FPanel(key: const ValueKey('sampler-amp'), title: 'AMP', child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FKnobRow(const ['gain', 'velocity', 'tune', 'transpose', 'polyphony'], size: k),
        FKnobRow(const ['attack', 'decay', 'sustain', 'release'], size: k),
      ])),
    FPanel(key: const ValueKey('sampler-filter'), title: 'FILTER', trailing: const [DeviceChoice('filter')],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FKnobRow(const ['cutoff', 'resonance', 'filter_env', 'filter_key'], size: k),
        FKnobRow(const ['filter_attack', 'filter_decay', 'filter_sustain', 'filter_release'], size: k,
            labels: const {'filter_attack': 'Attack', 'filter_decay': 'Decay', 'filter_sustain': 'Sustain',
              'filter_release': 'Release'}),
      ])),
  ];

  Widget _stepper(String key, String label, String value, VoidCallback down, VoidCallback up) => Row(children: [
    SizedBox(width: 70, child: Text(label, style: const TextStyle(fontSize: 11, color: Neon.dim))),
    IconButton(key: ValueKey('$key-down'), visualDensity: VisualDensity.compact, iconSize: 16, icon: const Icon(Icons.remove),
        onPressed: () => setState(() { Haptics.tick(); down(); })),
    Expanded(child: Center(child: Text(value, style: Neon.code(size: 11, color: Neon.text)))),
    IconButton(key: ValueKey('$key-up'), visualDensity: VisualDensity.compact, iconSize: 16, icon: const Icon(Icons.add),
        onPressed: () => setState(() { Haptics.tick(); up(); })),
  ]);

  Widget _slicePanel(SamplerState s) {
    final path = _slicePath(s);
    return FPanel(key: const ValueKey('sampler-slice'), title: 'SLICE',
      trailing: [if (path != null) Flexible(child: Text(path.split(RegExp(r'[/\\]')).last, maxLines: 1,
          overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Neon.dim)))],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DevicePicker(labels: const ['Transients', 'Grid'], selected: _grid ? 1 : 0, keyPrefix: 'sampler-slice-by',
            onPick: (i) => setState(() => _grid = i == 1)),
        const SizedBox(height: 4),
        AnimatedSwitcher(duration: Motion.fade(Motion.small, Motion.of(context)), child: _grid
            ? KeyedSubtree(key: const ValueKey('grid'), child: _stepper('sampler-divisions', 'Slices', '$_divisions',
                () => _divisions = math.max(1, _divisions ~/ 2 == 0 ? 1 : (_divisions > 8 ? _divisions - 4 : _divisions - 1)),
                () => _divisions = math.min(128, _divisions >= 8 ? _divisions + 4 : _divisions + 1)))
            : Row(key: const ValueKey('transients'), children: [
                const SizedBox(width: 70, child: Text('Sensitivity', style: TextStyle(fontSize: 11, color: Neon.dim))),
                Expanded(child: Slider(key: const ValueKey('sampler-sensitivity'), value: _sensitivity,
                    onChanged: (v) => setState(() => _sensitivity = v))),
              ])),
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 6, children: [
          FilledButton.tonalIcon(key: const ValueKey('sampler-slice-keys'), icon: const Icon(Icons.piano, size: 16),
              label: const Text('To keys'), onPressed: _busy || path == null ? null : () => _slice(drums: false)),
          FilledButton.tonalIcon(key: const ValueKey('sampler-slice-drums'), icon: const Icon(Icons.grid_view, size: 16),
              label: const Text('To Drums pads'), onPressed: _busy || path == null ? null : () => _slice(drums: true)),
        ]),
        if (path == null) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Drop a loop first; its slices '
            'go to keys from C2, or to a Drums track’s pads.', style: TextStyle(fontSize: 10, color: Neon.dim))),
      ]));
  }

  Widget _recordPanel() {
    final p = _plan;
    final n = p.notes.length;
    return FPanel(key: const ValueKey('sampler-record-panel'), title: 'RECORD MULTISAMPLE',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _stepper('sampler-rec-low', 'From', noteName(p.lowKey), () => p.lowKey = math.max(0, p.lowKey - 1),
            () => p.lowKey = math.min(p.highKey, p.lowKey + 1)),
        _stepper('sampler-rec-high', 'To', noteName(p.highKey), () => p.highKey = math.max(p.lowKey, p.highKey - 1),
            () => p.highKey = math.min(127, p.highKey + 1)),
        _stepper('sampler-rec-step', 'Every', '${p.step} st', () => p.step = math.max(1, p.step - 1),
            () => p.step = math.min(12, p.step + 1)),
        _stepper('sampler-rec-layers', 'Velocities', '${p.layers}', () => p.layers = math.max(1, p.layers - 1),
            () => p.layers = math.min(4, p.layers + 1)),
        _stepper('sampler-rec-hold', 'Hold', '${p.noteSeconds.toStringAsFixed(1)} s',
            () => p.noteSeconds = math.max(0.5, p.noteSeconds - 0.5), () => p.noteSeconds = math.min(10, p.noteSeconds + 0.5)),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: Text('$n note${n == 1 ? '' : 's'} · ${p.seconds.round()} s', key: const ValueKey('sampler-rec-summary'),
              style: const TextStyle(fontSize: 11, color: Neon.dim))),
          FilledButton.icon(key: const ValueKey('sampler-record'), icon: const Icon(Icons.fiber_manual_record, size: 16),
              label: const Text('Record'), onPressed: _busy || n == 0 ? null : _record),
        ]),
      ]));
  }

  /// The one screen: the map, then the zone beside the sound, then slicing beside recording. It scrolls when short.
  Widget _wide(SamplerState s, double width) {
    final roomy = width >= 1200;
    final k = roomy ? 40.0 : 34.0;
    const gap = SizedBox(width: 8, height: 8);
    final sound = _soundPanels(k);
    return SingleChildScrollView(key: const ValueKey('sampler-wide'), padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _centrepiece(s, mapHeight: roomy ? 200 : 160),
        gap,
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 6, child: _zonePanel(s)),
          gap,
          Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [sound[0], gap, sound[1]])),
        ]),
        gap,
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _slicePanel(s)),
          gap,
          Expanded(child: _recordPanel()),
        ]),
      ]));
  }

  /// The phone: the map stays on top; under it the three panels swipe sideways.
  Widget _phone(SamplerState s) {
    Widget panel(String key, List<Widget> children) => ListView(key: ValueKey(key),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      children: [for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 8), child: c)]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: _centrepiece(s, mapHeight: 130)),
      Expanded(child: PageView(
        key: const ValueKey('sampler-pages'),
        controller: _pages,
        onPageChanged: (i) {
          Motion.tick();
          setState(() => _panel = i);
        },
        children: [
          panel('sampler-panel-zone', [_zonePanel(s)]),
          panel('sampler-panel-sound', _soundPanels(40)),
          panel('sampler-panel-tools', [_slicePanel(s), _recordPanel()]),
        ],
      )),
    ]);
  }
}

// ---------- multisample recording ----------

/// The guided recording: the input opens, the song plays and records the track's input while the dialog prompts
/// each note in turn (its name, its velocity layer and a bar running down its hold); then the take is cut into
/// zones by the engine and the result says what was heard. Pops with the zones (Use) or null.
class MultisampleDialog extends StatefulWidget {
  const MultisampleDialog({super.key, required this.state, required this.layer, required this.plan});
  final AppState state;
  final LayerDoc layer;
  final MultisamplePlan plan;

  @override
  State<MultisampleDialog> createState() => _MultisampleDialogState();
}

enum _RecPhase { ready, recording, cutting, done }

class _MultisampleDialogState extends State<MultisampleDialog> {
  _RecPhase _phase = _RecPhase.ready;
  double _elapsed = 0; // seconds since the take started, counted by the prompt's ticks
  Timer? _timer;
  String _error = '';
  TakeResult? _result;
  late final List<PlannedNote> _notes = widget.plan.notes;

  @override
  void dispose() {
    _timer?.cancel();
    if (_phase == _RecPhase.recording) unawaited(_stopEngine());
    super.dispose();
  }

  Future<void> _stopEngine() async {
    final io = widget.state.audioIo;
    final r = await io.recordStop();
    if (widget.state.transportOn) widget.state.stopPlayback();
    if (!mounted) return;
    final take = r.takes.where((t) => t.layer == widget.layer.id && t.path.isNotEmpty).firstOrNull;
    if (take == null) {
      setState(() {
        _phase = _RecPhase.done;
        _error = r.error.isEmpty ? 'nothing was recorded' : r.error;
      });
      return;
    }
    setState(() => _phase = _RecPhase.cutting);
    final res = await widget.state.takeToZones(take.path, widget.plan);
    if (!mounted) return;
    setState(() {
      _phase = _RecPhase.done;
      _result = res;
      _error = res.error;
    });
  }

  Future<void> _start() async {
    final io = widget.state.audioIo;
    final rec = AudioRecorder.current;
    if (rec != null) {
      if (!rec.inputOpen && !await rec.openInput(force: true)) {
        setState(() => _error = 'the input did not open');
        return;
      }
    } else {
      await io.configureInput(enabled: true);
    }
    final dir = widget.state.recordingsDirectory;
    await dir.create(recursive: true);
    final r = await io.recordStart({
      'dir': dir.path,
      'bpm': widget.state.project.bpm,
      'tracks': [{'layer': widget.layer.id, 'channel': 0, 'channels': 1}],
    });
    if (!mounted) return;
    if (!r.ok) {
      setState(() => _error = r.error.isEmpty ? 'recording did not start' : r.error);
      return;
    }
    if (!widget.state.transportOn) widget.state.togglePlay();
    _elapsed = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      _elapsed += 0.05;
      if (_elapsed >= widget.plan.seconds) {
        _finish();
      } else {
        setState(() {});
      }
    });
    setState(() => _phase = _RecPhase.recording);
  }

  void _finish() {
    if (_phase != _RecPhase.recording) return;
    _timer?.cancel();
    _phase = _RecPhase.cutting;
    setState(() {});
    unawaited(_stopEngine());
  }

  /// The note asked for now (null: getting ready or between notes) and how far through its hold.
  (PlannedNote?, double, int) _now() {
    final t = _elapsed;
    for (final (i, n) in _notes.indexed) {
      if (t >= n.start && t < n.end) return (n, (t - n.start) / (n.end - n.start), i);
      if (t < n.start) return (null, 0, i);
    }
    return (null, 1, _notes.length);
  }

  @override
  Widget build(BuildContext context) {
    final accent = DeviceScope.maybeOf(context)?.accent ?? Neon.green;
    final (note, through, index) = _now();
    final layers = widget.plan.layers;
    Widget body;
    switch (_phase) {
      case _RecPhase.ready:
        body = Text('Connect the instrument to the input. When you start, the song plays and each note to play shows here '
            'in turn: ${_notes.length} notes from ${noteName(widget.plan.lowKey)} to ${noteName(widget.plan.highKey)}, '
            'held ${widget.plan.noteSeconds.toStringAsFixed(1)} s each.', style: const TextStyle(fontSize: 12));
      case _RecPhase.recording:
        final next = index < _notes.length ? _notes[index] : null;
        final show = note ?? next;
        final layer = show == null ? 0 : (_notes.indexOf(show) % layers);
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          Text(note != null ? 'PLAY' : 'NEXT', style: const TextStyle(fontSize: 11, letterSpacing: 1.4, color: Neon.dim)),
          AnimatedSwitcher(duration: Motion.fade(Motion.small, Motion.of(context)), child: Text(
              show == null ? '—' : noteName(show.key), key: ValueKey('rec-prompt-${show?.key}-$layer'),
              style: TextStyle(fontSize: 44, fontWeight: FontWeight.w800, color: note != null ? accent : Neon.text))),
          if (layers > 1 && show != null)
            Text(['soft', 'medium', 'loud', 'hardest'][(layer * 4 ~/ layers).clamp(0, 3)],
                style: const TextStyle(fontSize: 12, color: Neon.dim)),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: note == null ? 0 : 1 - through, color: accent),
          const SizedBox(height: 6),
          Text('Note ${math.min(index + 1, _notes.length)} of ${_notes.length}', style: const TextStyle(fontSize: 11, color: Neon.dim)),
        ]);
      case _RecPhase.cutting:
        body = const Row(children: [
          CrowLoader(size: 16),
          SizedBox(width: 10),
          Text('Finding each note in the take…'),
        ]);
      case _RecPhase.done:
        final r = _result;
        final missing = r == null ? 0 : r.found.where((f) => !f).length;
        final off = r == null ? 0 : [for (var i = 0; i < r.found.length; i++) r.found[i] && !r.inTune[i]].where((x) => x).length;
        body = Text(_error.isNotEmpty ? 'Recording failed: $_error' : '${r!.zones.length} zones made'
            '${missing > 0 ? ' · $missing note${missing == 1 ? '' : 's'} not heard' : ''}'
            '${off > 0 ? ' · $off not at the note asked for' : ''}.', key: const ValueKey('rec-result'));
    }
    return AlertDialog(
      key: const ValueKey('sampler-record-dialog'),
      title: const Text('Record multisample'),
      content: SizedBox(width: 320, child: AnimatedSwitcher(duration: Motion.fade(Motion.small, Motion.of(context)),
          child: KeyedSubtree(key: ValueKey(_phase), child: body))),
      actions: [
        if (_phase != _RecPhase.cutting)
          TextButton(key: const ValueKey('rec-cancel'), onPressed: () {
            if (_phase == _RecPhase.recording) {
              _finish();
            } else {
              Navigator.pop(context);
            }
          }, child: Text(_phase == _RecPhase.recording ? 'Stop' : 'Close')),
        if (_phase == _RecPhase.ready)
          FilledButton(key: const ValueKey('rec-start'), onPressed: _start, child: const Text('Start')),
        if (_phase == _RecPhase.done && (_result?.zones.isNotEmpty ?? false))
          FilledButton(key: const ValueKey('rec-use'), onPressed: () => Navigator.pop(context, _result!.zones),
              child: const Text('Use these zones')),
      ],
    );
  }
}

// ---------- the track card's inline controls ----------

class SamplerSoundPage extends StatelessWidget {
  const SamplerSoundPage({super.key});

  @override
  Widget build(BuildContext context) {
    final inline = DeviceScope.isInline(context);
    final size = inline ? 40.0 : 50.0;
    Widget head(String t) => Padding(padding: const EdgeInsets.fromLTRB(4, 10, 4, 2),
        child: Text(t, style: const TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800)));
    final body = Column(key: const ValueKey('sampler-sound'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      head('LEVEL'),
      KnobRow(const ['gain', 'velocity', 'tune', 'transpose', 'polyphony'], size: size),
      head('ENVELOPE'),
      KnobRow(const ['attack', 'decay', 'sustain', 'release'], size: size),
      head('FILTER'),
      const DeviceChoice('filter'),
      KnobRow(const ['cutoff', 'resonance', 'filter_env', 'filter_key'], size: size),
      if (!inline) KnobRow(const ['filter_attack', 'filter_decay', 'filter_sustain', 'filter_release'], size: size,
          labels: const {'filter_attack': 'Attack', 'filter_decay': 'Decay', 'filter_sustain': 'Sustain',
            'filter_release': 'Release'}),
    ]);
    return inline ? body : ListView(padding: const EdgeInsets.fromLTRB(8, 4, 8, 32), children: [body]);
  }
}
