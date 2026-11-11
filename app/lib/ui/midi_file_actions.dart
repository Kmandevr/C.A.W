// The MIDI file actions behind menus: import a .mid as pattern clips (Files, a track's menu) and export a clip as a
// .mid (a clip's menu), through the system file picker, with a one-line message.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/midi_clips.dart';
import '../model/midi_file.dart';
import '../model/project.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

/// Asks for a .mid file and adds it as pattern clips: on [layer] (else the selected track) when the file holds one
/// part, else on new tracks. The file is read and converted on another isolate.
Future<void> importMidiFile(BuildContext context, AppState state, {LayerDoc? layer}) async {
  try {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['mid', 'midi']);
    if (f == null || !context.mounted) return;
    await _importMidi(context, state, f.name, f.xFile.length, f.xFile.readAsBytes, layer: layer);
  } catch (e) {
    if (context.mounted) _say(context, 'Could not import the MIDI file: $e');
  }
}

/// Adds the .mid at [path] (opened with the app or dropped on its window) as pattern clips, as [importMidiFile]
/// does with a picked one.
Future<void> importMidiFromPath(BuildContext context, AppState state, String path, {LayerDoc? layer}) {
  final f = File(path);
  return _importMidi(context, state, f.uri.pathSegments.last, f.length, f.readAsBytes, layer: layer);
}

Future<void> _importMidi(BuildContext context, AppState state, String fileName, Future<int> Function() length,
    Future<Uint8List> Function() read, {LayerDoc? layer}) async {
  try {
    if (await length() > kMaxMidiFileBytes) throw const MidiFileException('the file is bigger than 16 MB');
    final bytes = await read();
    final adopt = projectHasNoClips(state.project);
    final beats = state.project.beatsPerBar;
    final dot = fileName.lastIndexOf('.');
    final name = (dot > 0 ? fileName.substring(0, dot) : fileName).replaceAll(RegExp(r'[#\r\n]'), ' ').trim();
    final m = await _readOffThread(bytes, beats, adopt, name.isEmpty ? 'MIDI' : name);
    final target = layer ?? state.project.layers.where((l) => l.id == state.selectedLayerId).firstOrNull;
    final message = placeMidiImport(state, m, layer: target, adoptTempo: adopt);
    if (context.mounted) _say(context, message);
  } on FormatException catch (e) {
    if (context.mounted) _say(context, 'Not imported: ${e.message}');
  } catch (e) {
    if (context.mounted) _say(context, 'Could not import the MIDI file: $e');
  }
}

// Top level, so the closure sent to the isolate holds only these values (not the caller's state or context).
Future<MidiImport> _readOffThread(Uint8List bytes, int beats, bool adopt, String name) =>
    Isolate.run(() => midiImport(bytes, beatsPerBar: beats, adoptMeter: adopt, name: name));

/// Asks where to save [clip] as a .mid and writes it (the project's tempo and meter).
Future<void> exportClipAsMidi(BuildContext context, AppState state, ClipDoc clip) async {
  try {
    final bytes = clipToMidi(state.project, clip);
    if (bytes == null) throw const FormatException('the clip\'s pattern is missing or has an error');
    final raw = state.project.module(clip.patternId)?.name ?? 'Clip';
    final base = raw.replaceAll(RegExp(r'[\\/:*?"<>|#\r\n]'), ' ').trim();
    final name = '${base.isEmpty ? 'Clip' : base}.mid';
    final saved = await FilePicker.saveFile(
      fileName: name,
      bytes: bytes,
      mimeType: 'audio/midi',
      type: FileType.custom,
      allowedExtensions: const ['mid'],
    );
    if (context.mounted) _say(context, saved == null ? 'Not exported (picker closed).' : 'Exported $name');
  } on FormatException catch (e) {
    if (context.mounted) _say(context, 'Not exported: ${e.message}');
  } catch (e) {
    if (context.mounted) _say(context, 'Could not export: $e');
  }
}
