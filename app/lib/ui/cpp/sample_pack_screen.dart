// The sample-pack maker (#164): pick an instrument, notes, velocities, length, loop and format, render it off the UI isolate with progress and cancel, file the WAVs (and SFZ) under Files › Audio & MIDI › Sample packs, and save the pack as a .zip through the system picker.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../engine/build_tools.dart';
import '../../engine/component_info.dart';
import '../../engine/engine.dart' show NativeComponentTrust;
import '../../model/app_state.dart';
import '../../model/arrange_fx.dart';
import '../../model/sample_packs.dart';
import '../../platform/save_copy.dart';
import '../frame/live_keys.dart' show noteName;
import '../haptics.dart';
import '../theme.dart';
import 'tool_kit.dart';
import '../pointer_input.dart';

/// Opens the maker full screen, with [instrumentId] picked when given.
Future<void> openSamplePackMaker(BuildContext context, AppState state, {String? instrumentId}) =>
    openToolPage(context, SamplePackScreen(state: state, instrumentId: instrumentId));

/// Velocity layers the maker offers (the engine takes any list of 1..127).
const velocityLayers = <int, List<int>>{
  1: [100],
  2: [64, 127],
  4: [32, 64, 96, 127],
  8: [16, 32, 48, 64, 80, 96, 112, 127],
};

/// Hold lengths in seconds.
const holdLengths = <double>[0.25, 0.5, 1, 2, 4, 8];

enum PackNormalize { none, file, pack }

/// The largest grid the maker sends (the engine allows 4096; a phone fills up long before).
const maxPackFiles = 512;

/// The pack's folder name: letters, digits, space and `. _ - # +`; no leading dot; at most 64 characters.
String packFolderName(String name) {
  var n = name.trim().replaceAll(RegExp(r'[^A-Za-z0-9 ._#+-]'), '_').replaceAll(RegExp(r'^\.+'), '');
  if (n.length > 64) n = n.substring(0, 64).trim();
  return n.isEmpty ? 'Pack' : n;
}

/// Saves a finished pack's zip as [name] (the system picker; a test passes a fake). True when saved.
typedef PackZipSaver = Future<bool> Function(File zip, String name);

Future<bool> _saveWithPicker(File zip, String name) =>
    saveCopyOf(zip, name: name, mimeType: 'application/zip', extension: 'zip');

class SamplePackScreen extends StatefulWidget {
  const SamplePackScreen({super.key, required this.state, this.instrumentId, this.backend, this.saveZip, this.onRendered});
  final AppState state;
  final String? instrumentId;

  /// Where renders go (the engine unless a test passes a fake).
  final BuildToolsBackend? backend;

  /// Where Save pack (.zip)… sends the zip (the system picker unless a test passes a fake).
  final PackZipSaver? saveZip;

  /// A pack finished rendering into Files, with the pack's folder name (the plug-in page records it).
  final ValueChanged<String>? onRendered;

  @override
  State<SamplePackScreen> createState() => SamplePackScreenState();
}

class SamplePackScreenState extends State<SamplePackScreen> {
  String? _instrument;
  final _name = TextEditingController();
  bool _nameEdited = false;
  int _from = 36, _to = 84, _step = 12, _layers = 1;
  double _hold = 1;
  bool _loop = false, _sfz = true;
  int _bits = 24;
  PackNormalize _normalize = PackNormalize.none;

  PackRun? _run;
  Timer? _poll;
  double _progress = 0;
  Map<String, dynamic>? _result;
  String? _error;
  Directory? _packDir; // the folder the last finished render filled
  bool _zipping = false;
  String? _zipMessage;

  AppState get s => widget.state;
  BuildToolsBackend get backend => widget.backend ?? BuildToolsBackend.current;

  List<NativeComponentInfo> get _instruments => [...s.nativeInstruments]..sort((a, b) => a.label.compareTo(b.label));

  @override
  void initState() {
    super.initState();
    s.componentCatalog.refreshIfStale();
    _instrument = widget.instrumentId;
    _name.text = _defaultName;
  }

  @override
  void dispose() {
    _poll?.cancel();
    _run?.cancel();
    _name.dispose();
    super.dispose();
  }

  String get _defaultName => _instrument == null ? 'Pack' : packFolderName(s.componentLabel(_instrument!));

  List<int> get notes => [for (var n = _from; n <= _to; n += _step) n];
  List<int> get velocities => velocityLayers[_layers]!;
  int get fileCount => notes.length * velocities.length;

  bool get _builtin => _instrument != null && isBuiltinComponent(_instrument!);
  String? get _library => _instrument == null || _builtin ? null : s.componentLibrary(_instrument!);

  /// Why Render is off, or null when it can run.
  String? get blocked {
    if (_instrument == null) return 'Pick an instrument.';
    if (!_builtin && _library == null) return 'Build this C++ instrument first: the maker renders its last build.';
    if (fileCount > maxPackFiles) return '$fileCount files is more than $maxPackFiles: use fewer notes or layers.';
    if (s.samplePacksRoot == null) return 'There is no project folder to save into.';
    return null;
  }

  /// The engine request (docs/engine.md, "Sample packs") for a pack in [dir].
  Map<String, dynamic> request(String dir, {bool overwrite = false}) {
    final library = _library;
    // The knobs as the first track playing it has them, else the defaults.
    final params = {...?s.project.layers.map((l) => l.instrument).where((u) => u?.id == _instrument).firstOrNull?.params};
    return {
      'instrument': {'id': _instrument, 'library': ?library, if (params.isNotEmpty) 'params': params},
      'output_dir': dir,
      'name': packFolderName(_name.text).replaceAll(' ', '_'),
      'notes': notes,
      'velocities': velocities,
      'hold_seconds': _hold,
      'max_seconds': (_hold + 10).clamp(10, 60),
      'bit_depth': _bits,
      if (_loop) 'loop': {'enabled': true, 'min_seconds': 0.05, 'max_seconds': _hold / 2},
      if (_normalize != PackNormalize.none)
        'normalize': {'mode': 'peak', 'target_db': -1, 'scope': _normalize == PackNormalize.pack ? 'group' : 'file'},
      'sfz': _sfz,
      'max_files': fileCount,
      'overwrite': overwrite,
    };
  }

  Future<void> _render() async {
    final root = s.samplePacksRoot;
    if (root == null || blocked != null || _run != null) return;
    final folder = packFolderName(_name.text);
    final dir = Directory('${root.path}${Platform.pathSeparator}$folder');
    var overwrite = false;
    if (await dir.exists() && dir.listSync().isNotEmpty) {
      if (!mounted) return;
      final replace = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
        title: Text('Replace "$folder"?'),
        content: const Text('A pack with this name exists. Files with the same names are replaced; others stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Replace')),
        ],
      ));
      if (replace != true) return;
      overwrite = true;
    }
    final trust = _library == null ? NativeComponentTrust.blocked : NativeComponentTrust.trusted;
    final run = backend.pack(request(dir.path, overwrite: overwrite), trust: trust);
    setState(() {
      _run = run;
      _progress = 0;
      _result = null;
      _error = null;
    });
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() => _progress = run.progress);
    });
    final result = await run.result;
    _poll?.cancel();
    _poll = null;
    await s.refreshSamplePacks();
    if (!mounted) return;
    final ok = result['ok'] == true;
    ok ? Haptics.threshold() : Haptics.error();
    if (ok) widget.onRendered?.call(dir.uri.pathSegments.where((p) => p.isNotEmpty).last);
    setState(() {
      _run = null;
      _result = ok ? result : null;
      _packDir = ok ? dir : null;
      _zipMessage = null;
      _error = ok ? null : '${result['error'] ?? 'The render failed.'}';
    });
  }

  /// Zips the finished pack off the UI isolate and hands it to the system's save picker.
  Future<void> _saveZip() async {
    final dir = _packDir;
    if (dir == null || _zipping) return;
    setState(() {
      _zipping = true;
      _zipMessage = null;
    });
    Directory? tmp;
    String message;
    try {
      tmp = await Directory.systemTemp.createTemp('caw-pack-');
      final name = '${dir.uri.pathSegments.where((p) => p.isNotEmpty).last}.zip';
      final zip = File('${tmp.path}${Platform.pathSeparator}$name');
      final count = await zipSamplePack(dir, zip.path);
      final saved = await (widget.saveZip ?? _saveWithPicker)(zip, name);
      saved ? Haptics.threshold() : Haptics.tap();
      message = saved ? 'Saved $name ($count file${count == 1 ? '' : 's'}).' : 'Not saved (picker closed).';
    } catch (e) {
      Haptics.error();
      message = 'Could not save the pack: $e';
    } finally {
      unawaited(tmp?.delete(recursive: true).then((_) {}, onError: (_) {}));
    }
    if (mounted) {
      setState(() {
        _zipping = false;
        _zipMessage = message;
      });
    }
  }

  void _cancel() {
    Haptics.tap();
    _run?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Neon.green;
    final instruments = _instruments;
    if (_instrument != null && !instruments.any((i) => i.id == _instrument)) {
      // A project instrument not built yet (or a stale id) still shows, so the reason can.
      instruments.insert(0, NativeComponentInfo(id: _instrument!, name: s.componentLabel(_instrument!)));
    }
    final why = blocked;
    final running = _run != null;
    final result = _result;
    return ToolPage(
      title: 'Make sample pack',
      subtitle: _instrument == null ? 'Render an instrument to WAV files' : s.componentLabel(_instrument!),
      icon: Icons.library_music_outlined,
      accent: accent,
      bottom: ToolAction(
        label: why == null ? 'Render $fileCount file${fileCount == 1 ? '' : 's'}' : 'Render',
        icon: Icons.graphic_eq,
        color: accent,
        busyLabel: 'Rendering offline…',
        progress: running ? _progress : null,
        onCancel: running ? _cancel : null,
        onPressed: why == null ? _render : null,
      ),
      children: [
        const ToolHeading('Instrument'),
        DropdownButton<String>(
          key: const ValueKey('pack-instrument'),
          isExpanded: true,
          value: _instrument,
          hint: const Text('Pick an instrument'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13, color: accent),
          items: [for (final i in instruments) DropdownMenuItem(value: i.id, child: Text(i.label))],
          onChanged: running ? null : (v) => setState(() {
            _instrument = v;
            if (!_nameEdited) _name.text = _defaultName;
          }),
        ),
        TextField(
          key: const ValueKey('pack-name'),
          controller: _name,
          enabled: !running,
          decoration: const InputDecoration(labelText: 'Pack name', isDense: true),
          onChanged: (_) => setState(() => _nameEdited = true),
        ),
        const ToolHeading('Notes'),
        ToolStepper(label: 'Lowest', value: _from, max: _to, text: noteName, color: accent, keyPrefix: 'pack-from',
          onChanged: (v) => setState(() => _from = v)),
        ToolStepper(label: 'Highest', value: _to, min: _from, text: noteName, color: accent, keyPrefix: 'pack-to',
          onChanged: (v) => setState(() => _to = v)),
        const SizedBox(height: 6),
        ToolSegments<int>(values: const [1, 3, 6, 12], value: _step, color: accent, keyPrefix: 'pack-step',
          labels: (v) => switch (v) { 1 => 'Every key', 3 => 'Minor 3rds', 6 => 'Tritones', _ => 'Octaves' },
          onChanged: (v) => setState(() => _step = v)),
        const ToolHeading('Velocity layers'),
        ToolSegments<int>(values: velocityLayers.keys.toList(), value: _layers, color: accent, keyPrefix: 'pack-layers',
          labels: (v) => v == 1 ? '1 · vel 100' : '$v layers', onChanged: (v) => setState(() => _layers = v)),
        const ToolHeading('Length held'),
        ToolSegments<double>(values: holdLengths, value: _hold, color: accent, keyPrefix: 'pack-hold',
          labels: (v) => v < 1 ? '${(v * 1000).round()} ms' : '${v.round()} s', onChanged: (v) => setState(() => _hold = v)),
        const Padding(padding: EdgeInsets.only(top: 4), child: Text(
          'Each note is held this long, then released until its tail fades below −80 dB (at most 10 s more).',
          style: TextStyle(fontSize: 11, color: Neon.dim))),
        const ToolHeading('Format'),
        ToolSwitch(label: 'Loop points', detail: 'Finds a seamless loop in the held part (smpl chunk and SFZ)',
          value: _loop, color: accent, onChanged: running ? null : (v) => setState(() => _loop = v)),
        ToolSwitch(label: 'SFZ instrument file', detail: 'Maps every WAV to its keys and velocities',
          value: _sfz, color: accent, onChanged: running ? null : (v) => setState(() => _sfz = v)),
        const SizedBox(height: 6),
        ToolSegments<int>(values: const [16, 24, 32], value: _bits, color: accent, keyPrefix: 'pack-bits',
          labels: (v) => v == 32 ? '32-bit float' : '$v-bit', onChanged: (v) => setState(() => _bits = v)),
        const SizedBox(height: 8),
        ToolSegments<PackNormalize>(values: PackNormalize.values, value: _normalize, color: accent, keyPrefix: 'pack-norm',
          labels: (v) => switch (v) {
            PackNormalize.none => 'As played',
            PackNormalize.file => 'Peak · each',
            PackNormalize.pack => 'Peak · pack',
          },
          onChanged: (v) => setState(() => _normalize = v)),
        const SizedBox(height: 10),
        ToolCard(title: 'Round robins', status: ToolStatus.info, child: const Text(
          'Not yet: the engine renders each note the same, bit for bit, every time, so extra takes would be identical.',
          style: TextStyle(fontSize: 12, color: Neon.dim))),
        if (why != null && !running)
          ToolCard(title: 'Can\'t render yet', status: ToolStatus.warn,
            child: Text(why, style: const TextStyle(fontSize: 12, color: Neon.text)))
        else
          ToolCard(key: const ValueKey('pack-summary'), title: '$fileCount file${fileCount == 1 ? '' : 's'}', color: accent,
            child: Text('${notes.length} note${notes.length == 1 ? '' : 's'} (${noteName(_from)} to ${noteName(notes.last)}) × '
              '${velocities.length} velocit${velocities.length == 1 ? 'y' : 'ies'}, saved to Files › Audio & MIDI › '
              'Sample packs › ${packFolderName(_name.text)}.', style: const TextStyle(fontSize: 12, color: Neon.dim))),
        if (_error case final e?)
          ToolCard(key: const ValueKey('pack-error'), title: e.contains('cancel') ? 'Stopped' : 'The render failed',
            status: e.contains('cancel') ? ToolStatus.info : ToolStatus.fail,
            child: Text(e.contains('cancel') ? 'Files finished before you stopped it are kept in the pack; no SFZ was written.' : e,
              style: const TextStyle(fontSize: 12, color: Neon.text))),
        if (result != null)
          _ResultCard(result: result, saving: _zipping, message: _zipMessage, onSave: _packDir == null ? null : _saveZip),
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result, this.onSave, this.saving = false, this.message});
  final Map<String, dynamic> result;
  final VoidCallback? onSave;
  final bool saving;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final files = [for (final f in (result['files'] as List? ?? const [])) if (f is Map) f];
    final warnings = [for (final w in (result['warnings'] as List? ?? const [])) '$w'];
    final sfz = [for (final f in (result['sfz'] as List? ?? const [])) '$f'];
    final loops = files.where((f) => f['loop'] is Map).length;
    return ToolCard(
      key: const ValueKey('pack-result'),
      title: 'Saved ${files.length} file${files.length == 1 ? '' : 's'}',
      status: warnings.any((w) => const {'clipped', 'failed_blocks', 'silent'}.contains(w)) ? ToolStatus.warn : ToolStatus.pass,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (sfz.isNotEmpty) ToolStat('SFZ', sfz.join(', ')),
        if (loops > 0) ToolStat('Looped', '$loops of ${files.length}'),
        if (warnings.isNotEmpty) ToolStat('Warnings', warnings.join(', '), color: Neon.yellow),
        const SizedBox(height: 6),
        for (final f in files.take(8))
          ToolStat('${f['file']}', f['seconds'] is num ? '${(f['seconds'] as num).toStringAsFixed(2)} s' : ''),
        if (files.length > 8) Text('and ${files.length - 8} more', style: const TextStyle(fontSize: 11, color: Neon.dim)),
        const SizedBox(height: 6),
        Text('Find them in Files › Audio & MIDI › Sample packs; ${PointerInput.hold} one to save a copy.',
          style: TextStyle(fontSize: 11, color: Neon.dim)),
        const SizedBox(height: 6),
        Align(alignment: Alignment.centerLeft, child: TextButton.icon(
          key: const ValueKey('pack-save-zip'),
          onPressed: saving ? null : onSave,
          icon: saving
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.file_upload_outlined, size: 16),
          label: Text(saving ? 'Zipping…' : 'Save pack (.zip)…'),
          style: TextButton.styleFrom(foregroundColor: Neon.green),
        )),
        if (message case final m?) Text(m, key: const ValueKey('pack-save-message'),
          style: const TextStyle(fontSize: 11, color: Neon.dim)),
      ]),
    );
  }
}
