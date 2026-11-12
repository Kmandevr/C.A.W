// The flagship's Import wavetable… action: a WAV file into its User table (the instrument's component state).
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../model/app_state.dart';
import '../../../model/arrange_fx.dart';
import '../../../model/flagship_shapes.dart';
import '../../../model/project.dart';
import '../../haptics.dart';
import '../../theme.dart';
import '../device_scope.dart';
import '../kit/feel.dart';
import '../../panel_motion.dart';

/// The largest WAV file the flagship imports (kMaxWtWavBytes in engine/src/builtin_flagship.cpp).
const maxWavetableBytes = 8 * 1024 * 1024;

/// Picks a WAV file for the User table: its bytes, or null when cancelled (tests replace it). A file over
/// [maxWavetableBytes] is refused before it is read.
Future<Uint8List?> Function() pickWavetableWav = defaultPickWavetableWav;

/// The system file picker, for WAV files.
Future<Uint8List?> defaultPickWavetableWav() async {
  final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['wav']);
  if (file == null) return null;
  if (await file.xFile.length() > maxWavetableBytes) throw const FormatException('That file is over 8 MB.');
  return file.xFile.readAsBytes();
}

/// Asks how to cut the file into frames: 0 for 2048-sample frames (a single-cycle table export, the usual
/// wavetable WAV), 1..256 for that many equal frames, null when cancelled (tests replace it).
Future<int?> Function(BuildContext context) pickWavetableSplit = defaultPickWavetableSplit;

Future<int?> defaultPickWavetableSplit(BuildContext context) => showDialog<int>(
      context: context, animationStyle: dialogAnimation(context),
      builder: (context) => const _SplitDialog(),
    );

class _SplitDialog extends StatefulWidget {
  const _SplitDialog();

  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  bool _byCount = false;
  final _count = TextEditingController(text: '8');

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  int? get _frames {
    final n = int.tryParse(_count.text.trim());
    return n != null && n >= 1 && n <= UserWavetable.maxFrames ? n : null;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Import wavetable'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('2048-sample frames: single-cycle tables, as wavetable synths export them.',
              style: TextStyle(fontSize: 12, color: Neon.dim)),
          SwitchListTile(
            key: const ValueKey('wt-split-count'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _byCount,
            onChanged: (v) => setState(() => _byCount = v),
            title: const Text('Cut into equal frames instead'),
          ),
          if (_byCount)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: TextField(
              key: const ValueKey('wt-split-frames'),
              controller: _count,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Frames (1–${UserWavetable.maxFrames})',
                  errorText: _frames == null ? 'A whole number from 1 to ${UserWavetable.maxFrames}' : null),
              onChanged: (_) => setState(() {}),
            )),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('wt-split-ok'),
            onPressed: _byCount && _frames == null ? null : () => Navigator.pop(context, _byCount ? _frames : 0),
            child: const Text('Import'),
          ),
        ],
      );
}

/// Gives [layer]'s flagship [bytes] as its User table (the import form, [wavetableImport]): the engine checks the
/// file (untrusted), rebuilds the instrument with it off the UI thread, and the project keeps what the engine saved
/// ("CWT1", base64), so a reload, an export and the drawing start from it. False, and nothing kept, when there is
/// no engine, the track's instrument is not a playing flagship (or changed meanwhile), or the engine refused it.
Future<bool> importFlagshipWavetable(AppState s, LayerDoc layer, Uint8List bytes) async {
  final e = s.engine;
  final use = layer.instrument;
  if (e == null || use == null || use.id != _flagshipId || !s.componentPlayable(use.id)) return false;
  if (!await e.setComponentState(layer.id, ProjectDoc.instrumentIndex, bytes, 1)) return false;
  final saved = e.componentStates(layer.id)[ProjectDoc.instrumentIndex];
  if (saved == null || saved.state.isEmpty || layer.instrument?.id != _flagshipId) return false;
  s.endUndoStep();
  s.editLayer(layer, (l) {
    l.instrument!.state = saved.state;
    l.instrument!.stateVersion = saved.version;
  });
  s.endUndoStep();
  return true;
}

const _flagshipId = 'org.caw.synth.flagship';

/// Import wavetable…: a WAV file into the instrument's User table, and this oscillator plays it.
class ImportWavetableButton extends StatefulWidget {
  const ImportWavetableButton({super.key, required this.prefix});

  /// The oscillator's parameter prefix (`osc1_`): its table moves to User once the import is taken.
  final String prefix;

  @override
  State<ImportWavetableButton> createState() => _ImportWavetableButtonState();
}

class _ImportWavetableButtonState extends State<ImportWavetableButton> {
  bool _busy = false;

  void _say(String text, {bool error = false}) {
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(text, style: TextStyle(color: error ? Neon.pink : null)),
        duration: const Duration(seconds: 4)));
  }

  Future<void> _import() async {
    DeviceFeel.tap();
    final t = DeviceScope.of(context).target;
    final layer = t.layer;
    if (layer == null || !t.isInstrument) return;
    setState(() => _busy = true);
    try {
      final bytes = await pickWavetableWav();
      if (bytes == null || !mounted) return;
      final split = await pickWavetableSplit(context);
      if (split == null || !mounted) return;
      final ok = await importFlagshipWavetable(t.state, layer, wavetableImport(bytes, split));
      if (!mounted) return;
      if (ok) {
        t.set('${widget.prefix}table', userTableIndex.toDouble());
        final frames = userWavetableFrames(layer.instrument?.state);
        _say('Wavetable imported${frames == null ? '' : ': $frames frame${frames == 1 ? '' : 's'}'}');
      } else {
        Haptics.error();
        _say('Not imported: the flagship takes a PCM or float WAV of up to 256 frames.', error: true);
      }
    } on FormatException catch (e) {
      Haptics.error();
      if (mounted) _say('Not imported: ${e.message}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: ValueKey('flagship-import-${widget.prefix}'),
          style: TextButton.styleFrom(foregroundColor: DeviceScope.of(context).accent),
          onPressed: _busy ? null : _import,
          icon: _busy
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.file_open, size: 16),
          label: const Text('Import wavetable…', style: TextStyle(fontSize: 12)),
        ),
      );
}

/// How many frames the saved User table in [state] (base64) has, or null.
int? userWavetableFrames(String? state) {
  if (state == null || state.isEmpty) return null;
  try {
    final b = base64Decode(state);
    return UserWavetable.parse(b)?.frames.length;
  } on FormatException {
    return null;
  }
}
