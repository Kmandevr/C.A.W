// The project's sample packs (#164): the folders the sample-pack maker renders into, read back from each pack's manifest for Files, and a pack zipped whole to save outside the app.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'app_state.dart';
import 'cpp_workbench.dart';
import 'arrange_fx.dart';
import 'zip_archive.dart';

/// One WAV of a pack, as its manifest describes it.
class SampleFileInfo {
  const SampleFileInfo({required this.file, required this.path, this.noteName = '', this.velocity = 0,
    this.seconds = 0, this.looped = false});
  final String file, path, noteName;
  final int velocity;
  final double seconds;
  final bool looped;
}

/// A rendered pack: its folder, its WAVs and SFZ files.
class SamplePackInfo {
  const SamplePackInfo({required this.name, required this.directory, this.instrument = '', this.files = const [],
    this.sfz = const []});
  final String name, instrument;
  final Directory directory;
  final List<SampleFileInfo> files;
  final List<String> sfz;

  /// Reads [dir]'s manifest (`NAME.json`); a folder without one (a cancelled render) lists its WAVs alone.
  static SamplePackInfo? read(Directory dir) {
    final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final sep = Platform.pathSeparator;
    Map<String, dynamic>? manifest;
    try {
      final j = jsonDecode(File('${dir.path}$sep$name.json').readAsStringSync());
      if (j is Map<String, dynamic> && j['files'] is List) manifest = j;
    } catch (_) {}
    if (manifest != null) {
      return SamplePackInfo(
        name: name,
        directory: dir,
        instrument: '${(manifest['instrument'] as Map?)?['id'] ?? ''}',
        files: [
          for (final f in manifest['files'] as List)
            if (f is Map && f['file'] is String && File('${dir.path}$sep${f['file']}').existsSync())
              SampleFileInfo(
                file: f['file'] as String,
                path: '${dir.path}$sep${f['file']}',
                noteName: '${f['note_name'] ?? ''}',
                velocity: (f['velocity'] as num?)?.toInt() ?? 0,
                seconds: (f['seconds'] as num?)?.toDouble() ?? 0,
                looped: f['loop'] is Map),
        ],
        sfz: [for (final s in (manifest['sfz'] as List? ?? const [])) '$s'],
      );
    }
    final wavs = dir.existsSync()
        ? [for (final f in dir.listSync()) if (f is File && f.path.toLowerCase().endsWith('.wav')) f.path]
        : <String>[];
    if (wavs.isEmpty) return null;
    wavs.sort();
    return SamplePackInfo(name: name, directory: dir, files: [
      for (final p in wavs) SampleFileInfo(file: p.substring(p.lastIndexOf(sep) + 1), path: p),
    ]);
  }
}

/// Zips the pack in [pack] into a new file at [zipPath], off the UI isolate: its WAVs, SFZ files and manifest under one
/// top folder named after the pack (sub-folders, half-written `.part` files and names a zip can't hold safely are left
/// out). Returns how many files went in; a failure deletes the partial zip and throws.
Future<int> zipSamplePack(Directory pack, String zipPath) {
  final dir = pack.path;
  return Isolate.run(() => _zipPack(dir, zipPath));
}

int _zipPack(String dir, String zipPath) {
  final pack = Directory(dir);
  final top = pack.uri.pathSegments.where((s) => s.isNotEmpty).last;
  final files = [
    for (final f in pack.listSync(followLinks: false))
      if (f is File && !f.path.endsWith('.part')) f,
  ]..sort((a, b) => a.path.compareTo(b.path));
  final w = ZipWriter.create(zipPath);
  var n = 0;
  try {
    for (final f in files) {
      final name = '$top/${f.uri.pathSegments.last}';
      if (!isSafeArchivePath(name)) continue;
      w.addFile(name, f.path);
      n++;
    }
    w.close();
  } catch (_) {
    w.abandon();
    try {
      File(zipPath).deleteSync();
    } catch (_) {}
    rethrow;
  }
  return n;
}

final _packs = Expando<List<SamplePackInfo>>('sample packs');
final _root = Expando<Directory>('sample packs root');
final _ticks = Expando<ValueNotifier<int>>('sample packs tick');

/// A WAV deleted in Files' select mode is renamed with this until its Undo is no longer offered.
const deletedSampleSuffix = '.deleted';

/// The set-aside WAVs whose Undo is still offered (kept by [SamplePacks.refreshSamplePacks]).
final Set<String> setAsideSamples = {};

extension SamplePacks on AppState {
  /// The folder this project's packs live in (null without storage, unless a test set one).
  Directory? get samplePacksRoot => _root[this] ?? storage?.samplePacksDirectory(project.id);
  @visibleForTesting
  set samplePacksRoot(Directory dir) => _root[this] = dir;

  /// The packs last read by [refreshSamplePacks], by name.
  List<SamplePackInfo> get samplePacks => _packs[this] ?? const [];

  /// Ticks when [samplePacks] changes (Files redraws on it).
  ValueNotifier<int> get samplePacksTick => _ticks[this] ??= ValueNotifier(0);

  /// Reads the packs again from disk.
  Future<List<SamplePackInfo>> refreshSamplePacks() async {
    final root = samplePacksRoot;
    final list = <SamplePackInfo>[];
    if (root != null && await root.exists()) {
      for (final d in root.listSync().whereType<Directory>()) {
        // A WAV set aside by a delete whose Undo is no longer offered (the app closed meanwhile) goes now.
        for (final f in d.listSync().whereType<File>()) {
          if (f.path.endsWith(deletedSampleSuffix) && !setAsideSamples.contains(f.path)) {
            try {
              f.deleteSync();
            } catch (_) {}
          }
        }
        final p = SamplePackInfo.read(d);
        if (p != null) list.add(p);
      }
    }
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _packs[this] = list;
    samplePacksTick.value++;
    return list;
  }

  /// Deletes one WAV of a pack (and the pack's folder once no WAV is left).
  Future<void> deleteSampleFile(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
    final dir = f.parent;
    if (await dir.exists() && !dir.listSync().any((e) => e.path.toLowerCase().endsWith('.wav'))) {
      await dir.delete(recursive: true);
    }
    await refreshSamplePacks();
  }

  /// The library file a non-built-in component loads from (its last build), or null for a built-in or one not built.
  String? componentLibrary(String componentId) {
    final doc = cppComponentFor(componentId);
    if (doc == null) return nativeComponents?.artifactOf(componentId);
    return cppWorkbench(doc.id).artifactPath;
  }
}
