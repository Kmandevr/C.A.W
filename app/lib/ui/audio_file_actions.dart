// Importing audio through the system file picker (Files' ⋯, a track's menu): each WAV, FLAC or MP3 copied into the
// project's storage with a progress dialog, decoded off the UI isolate, then placed as a clip.
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/arrange_edit.dart';
import '../model/audio_clips.dart';
import '../model/audio_edit.dart';
import '../model/project.dart';
import 'haptics.dart';
import 'theme.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

/// One file to bring in: its name, size (0: unknown) and bytes. The picker gives these; tests make their own.
typedef AudioSource = ({String name, int size, Stream<List<int>> Function() read});

/// The system picker, for tests to replace.
class AudioPicker {
  AudioPicker._();
  static Future<List<AudioSource>> Function() pick = _pick;

  static Future<List<AudioSource>> _pick() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: audioExtensions);
    return [
      for (final f in files) (name: f.name, size: f.lengthSync() ?? 0, read: () => f.readAsByteStream()),
    ];
  }
}

/// Asks for audio files and imports them. [layer] given: the clips go on it (or the audio track under it), one after
/// another from [atStep] (else the edit cursor); otherwise each file gets a new audio track, or with [place] false
/// they only join Files. Returns the clips made.
Future<List<AudioClipDoc>> importAudioFiles(BuildContext context, AppState state,
    {LayerDoc? layer, double? atStep, bool place = true}) async {
  final List<AudioSource> picked;
  try {
    picked = await AudioPicker.pick();
  } catch (e) {
    if (context.mounted) _say(context, 'Could not open the file picker: $e');
    return const [];
  }
  if (picked.isEmpty || !context.mounted) return const [];
  return importAudioSources(context, state, picked, layer: layer, atStep: atStep, place: place);
}

/// Imports [sources] with a progress dialog (Cancel stops after the file being copied).
Future<List<AudioClipDoc>> importAudioSources(BuildContext context, AppState state, List<AudioSource> sources,
    {LayerDoc? layer, double? atStep, bool place = true}) async {
  final progress = ValueNotifier<(String, double)>(('', 0));
  var cancelled = false;
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      key: const ValueKey('audio-import-progress'),
      title: const Text('Importing audio'),
      content: ValueListenableBuilder<(String, double)>(valueListenable: progress, builder: (context, p, _) => Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p.$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Neon.dim, fontSize: 12)),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: p.$2 <= 0 ? null : p.$2, color: Neon.green),
        ])),
      actions: [TextButton(onPressed: () { cancelled = true; Navigator.of(context).pop(); }, child: const Text('Cancel'))],
    ),
  );
  final made = <AudioClipDoc>[];
  final failed = <String>[];
  var at = atStep;
  for (final (i, src) in sources.indexed) {
    if (cancelled) break;
    if (!isAudioFileName(src.name)) {
      failed.add('${src.name} (not WAV, FLAC or MP3)');
      continue;
    }
    progress.value = ('${i + 1}/${sources.length} · ${src.name}', 0);
    try {
      final asset = await state.importAudio(src.name, src.read, onProgress: (bytes) {
        if (src.size > 0) progress.value = (progress.value.$1, (bytes / src.size).clamp(0.0, 1.0));
      });
      progress.value = ('${i + 1}/${sources.length} · ${src.name}: decoded', 1);
      if (!place) continue;
      final target = layer ?? state.addAudioTrack(name: asset.name);
      final clip = state.addAudioClip(target, asset, atStep: at ?? (layer == null ? 0 : state.editStep.toDouble()));
      at = clip.endAt(state.project.bpm);
      made.add(clip);
    } catch (e) {
      failed.add('${src.name}: ${e is FormatException ? e.message : e}');
    }
  }
  if (!cancelled && context.mounted) Navigator.of(context).pop();
  await dialog;
  progress.dispose();
  if (!context.mounted) return made;
  if (failed.isEmpty) {
    Haptics.drop();
    final n = sources.length;
    _say(context, cancelled ? 'Import cancelled' : place ? 'Imported $n file${n == 1 ? '' : 's'} as clips'
        : 'Imported $n file${n == 1 ? '' : 's'} into Files › Audio files');
  } else {
    Haptics.error();
    _say(context, 'Not imported: ${failed.join('; ')}');
  }
  return made;
}

