// The drums' sample picker: a pad's Sample layer from the built-in pack, a WAV in Files (rendered sample packs), or a WAV picked from the device and kept in app storage.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../model/device_target.dart';
import '../../../model/drums.dart';
import '../../../model/project.dart';
import '../../../model/sample_packs.dart';
import '../../feedback.dart';
import '../../glass.dart';
import '../../theme.dart';
import '../kit/feel.dart';
import 'drums_pads.dart';

/// Picks a WAV from the device and copies it into the app's storage (a `content://` file has no path the engine
/// can open), giving the copy's path; null when cancelled. Tests replace it.
class DrumSampleImport {
  DrumSampleImport._();

  static Future<String?> Function() pick = _pickAndKeep;

  static Future<String?> _pickAndKeep() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['wav', 'wave']);
    if (f == null) return null;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}drum_samples');
    await dir.create(recursive: true);
    final name = f.name.replaceAll(RegExp(r'[^A-Za-z0-9 ._-]'), '_');
    var out = File('${dir.path}${Platform.pathSeparator}$name');
    for (var n = 2; await out.exists(); n++) {
      out = File('${dir.path}${Platform.pathSeparator}${name.replaceFirst(RegExp(r'(\.[^.]*)?$'), ' $n\$1')}');
    }
    await out.writeAsBytes(await f.xFile.readAsBytes(), flush: true);
    return out.path;
  }
}

/// The built-in pack's names: the engine's list, else the library's sounds by their preset names.
List<String> drumBuiltinSamples(DeviceTarget t) =>
    DrumsApi.current.builtinSamples() ??
    [for (final p in t.info?.presets ?? const []) if (!p.name.startsWith('Kit:')) p.name];

/// A sheet to load pad [pad]'s sample: Built-in, Files or Device, and Remove.
Future<void> showDrumSamplePicker(BuildContext context, DeviceTarget t, int pad) => showGlassSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => FractionallySizedBox(heightFactor: 0.7, child: _SamplePicker(t: t, pad: pad)),
);

class _SamplePicker extends StatefulWidget {
  const _SamplePicker({required this.t, required this.pad});
  final DeviceTarget t;
  final int pad;

  @override
  State<_SamplePicker> createState() => _SamplePickerState();
}

class _SamplePickerState extends State<_SamplePicker> {
  int _source = 0;

  void _load(ComponentSampleDoc s) {
    DeviceFeel.tap();
    setPadSample(widget.t, drumsLayout(widget.t), widget.pad, s);
    Navigator.of(context).maybePop();
    drumsToast(context, '${padLabel(widget.pad)} plays ${s.label}');
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final current = padSample(t, widget.pad);
    final packs = t.state.samplePacks;
    final builtin = drumBuiltinSamples(t);
    Widget tile(String key, String title, String? subtitle, IconData icon, VoidCallback onTap, {bool on = false}) =>
        ListTile(
          key: ValueKey(key),
          dense: true,
          leading: Icon(icon, size: 18, color: on ? Neon.green : Neon.blue),
          title: Text(title, style: TextStyle(fontSize: 13, color: on ? Neon.green : Neon.text)),
          subtitle: subtitle == null ? null : Text(subtitle, style: const TextStyle(fontSize: 10, color: Neon.dim)),
          onTap: onTap,
        );
    final List<Widget> list = switch (_source) {
      0 => [
          for (final name in builtin)
            tile('drum-sample-builtin-$name', name, null, Icons.music_note,
              () => _load(ComponentSampleDoc(widget.pad, builtin: name)), on: current?.builtin == name),
        ],
      1 => packs.every((p) => p.files.isEmpty)
          ? [const Padding(padding: EdgeInsets.all(16), child: Text(
              'No WAVs in Files yet. Render a sample pack (Build tools › Samples), or pick one from the device.',
              style: TextStyle(color: Neon.dim)))]
          : [
              for (final p in packs)
                for (final f in p.files)
                  tile('drum-sample-file-${f.file}', f.file, p.name, Icons.audio_file_outlined,
                    () => _load(ComponentSampleDoc(widget.pad, path: f.path)), on: current?.path == f.path),
            ],
      _ => [
          Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Pick a WAV from your phone or computer. C.A.W. keeps a copy with the app, so the project opens '
                'with it later. Mono, up to 30 seconds.', style: TextStyle(color: Neon.dim, fontSize: 12)),
            const SizedBox(height: 12),
            Pressable(child: FilledButton.icon(
              key: const ValueKey('drum-sample-pick'),
              onPressed: () async {
                final path = await DrumSampleImport.pick();
                if (path != null && context.mounted) _load(ComponentSampleDoc(widget.pad, path: path));
              },
              icon: const Icon(Icons.folder_open),
              label: const Text('Pick a WAV…'))),
          ])),
        ],
    };
    return Column(key: const ValueKey('drum-sample-picker'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 4, 8, 4), child: Row(children: [
        Expanded(child: Text('SAMPLE · ${padLabel(widget.pad)}', style: const TextStyle(fontSize: 12, letterSpacing: 1.4,
          fontWeight: FontWeight.w800, color: Neon.text))),
        if (current != null) TextButton.icon(
          key: const ValueKey('drum-sample-remove'),
          onPressed: () {
            DeviceFeel.tap();
            writePad(t, drumsLayout(t), widget.pad, const {'smp_on': 0}, setSample: true);
            Navigator.of(context).maybePop();
          },
          icon: const Icon(Icons.close, size: 16),
          label: Text('Remove ${current.label}', overflow: TextOverflow.ellipsis)),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 0, label: Text('Built-in'), icon: Icon(Icons.auto_awesome, size: 16)),
          ButtonSegment(value: 1, label: Text('Files'), icon: Icon(Icons.folder_outlined, size: 16)),
          ButtonSegment(value: 2, label: Text('Device'), icon: Icon(Icons.smartphone, size: 16)),
        ],
        selected: {_source},
        showSelectedIcon: false,
        onSelectionChanged: (v) {
          DeviceFeel.tap();
          setState(() => _source = v.first);
        },
      )),
      const SizedBox(height: 6),
      Expanded(child: ListView(key: const ValueKey('drum-sample-list'), children: list)),
    ]);
  }
}
