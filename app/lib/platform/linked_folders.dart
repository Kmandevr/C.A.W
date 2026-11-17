// Linked sample folders on each platform: a plain directory on Windows and Linux, a granted document tree on Android.
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../model/sample_meta.dart';

/// A folder the user picked.
class PickedFolder {
  const PickedFolder(this.location, this.name);

  /// A directory path, or an Android tree URI (`content://…`).
  final String location;
  final String name;
}

/// One audio file under a linked folder.
class ListedFile {
  const ListedFile(this.rel, this.size, this.modified, {this.doc});

  /// Its path inside the folder, `/` between folders.
  final String rel;
  final int size;

  /// Modified time, milliseconds since the epoch (0: unknown).
  final int modified;

  /// The Android document id (null elsewhere).
  final String? doc;
}

class FolderListing {
  const FolderListing(this.files, {this.truncated = false, this.error});
  final List<ListedFile> files;

  /// The limits stopped the walk before the end (too many files or folders too deep).
  final bool truncated;
  final String? error;
}

/// Limits on one linked folder (untrusted: anything can be in it).
class FolderLimits {
  static const depth = 16;
  static const files = 50000;
  static const nameLength = 255;
}

const _audioExtensions = {'wav', 'wave', 'flac', 'mp3'};

bool _isAudioName(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 && _audioExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// A file or folder name safe to put in a relative path: no separators, `.`/`..`, control characters or hidden
/// (dot) names, at most [FolderLimits.nameLength].
bool safeEntryName(String name) {
  if (name.isEmpty || name.length > FolderLimits.nameLength || name.startsWith('.')) return false;
  if (name.contains('/') || name.contains('\\') || name.contains(':')) return false;
  for (final c in name.codeUnits) {
    if (c < 0x20 || c == 0x7f) return false;
  }
  return true;
}

/// Walks [root] for audio files: no links followed (a link inside the folder is skipped, so nothing outside it is
/// ever reached), at most [FolderLimits.depth] folders deep and [FolderLimits.files] files. Synchronous: run it on
/// a background isolate.
FolderListing listDirectorySync(String root, {int maxDepth = FolderLimits.depth, int maxFiles = FolderLimits.files}) {
  final out = <ListedFile>[];
  var truncated = false;
  final dir = Directory(root);
  if (!dir.existsSync()) return const FolderListing([], error: 'The folder is not there.');
  final queue = Queue<(Directory, String, int)>()..add((dir, '', 0));
  while (queue.isNotEmpty) {
    final (d, prefix, depth) = queue.removeFirst();
    List<FileSystemEntity> entries;
    try {
      entries = d.listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
      final base = e.path.split(Platform.pathSeparator).last;
      final n = base.isEmpty ? name : base;
      if (!safeEntryName(n)) continue;
      if (e is Link) continue;
      if (e is Directory) {
        if (depth + 1 < maxDepth) {
          queue.add((e, '$prefix$n/', depth + 1));
        } else {
          truncated = true;
        }
      } else if (e is File && _isAudioName(n)) {
        if (out.length >= maxFiles) {
          return FolderListing(out, truncated: true);
        }
        try {
          final st = e.statSync();
          if (st.type != FileSystemEntityType.file) continue;
          out.add(ListedFile('$prefix$n', st.size, st.modified.millisecondsSinceEpoch));
        } catch (_) {}
      }
    }
  }
  return FolderListing(out, truncated: truncated);
}

/// Joins a linked folder's directory and a relative path, or null when [rel] is not a plain relative path.
String? joinInside(String root, String rel) {
  if (rel.isEmpty || rel.startsWith('/') || rel.split('/').any((p) => !safeEntryName(p))) return null;
  final sep = Platform.pathSeparator;
  final base = root.endsWith(sep) || root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  return '$base$sep${rel.replaceAll('/', sep)}';
}

/// What the sample library needs from the platform.
abstract class LinkedFolderAccess {
  static LinkedFolderAccess instance = Platform.isAndroid ? AndroidFolderAccess() : DesktopFolderAccess();

  /// The system folder picker; null when cancelled.
  Future<PickedFolder?> pick();

  /// Gives up a folder's grant (unlink).
  Future<void> release(String location);

  /// The audio files under [location], off the UI isolate.
  Future<FolderListing> list(String location);

  /// The metadata of [files] (null where a file can't be read), read off the UI isolate.
  Future<List<SampleMeta?>> readMeta(String location, List<ListedFile> files);

  /// A path the engine and Dart can read [file] by, this run of the app; null when it can't be reached.
  Future<String?> readablePath(String location, ListedFile file);

  /// Whether a file at a [readablePath] stays there across runs (a directory path) or is a session handle.
  bool get stablePaths;

  /// Whether [location] is still reachable (the folder exists, the grant stands).
  Future<bool> reachable(String location);
}

/// Windows and Linux (and macOS): the folder is a directory path.
class DesktopFolderAccess implements LinkedFolderAccess {
  @override
  Future<PickedFolder?> pick() async {
    final path = await FilePicker.getDirectoryPath(dialogTitle: 'Link a sample folder');
    if (path == null || path.isEmpty) return null;
    final name = path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull ?? path;
    return PickedFolder(path, name);
  }

  @override
  Future<void> release(String location) async {}

  @override
  Future<FolderListing> list(String location) => Isolate.run(() => listDirectorySync(location));

  @override
  Future<List<SampleMeta?>> readMeta(String location, List<ListedFile> files) {
    final rels = [for (final f in files) f.rel];
    return Isolate.run(() => [
          for (final rel in rels)
            switch (joinInside(location, rel)) {
              final path? => readSampleMetaFile(path),
              null => null,
            },
        ]);
  }

  @override
  Future<String?> readablePath(String location, ListedFile file) async {
    final path = joinInside(location, file.rel);
    if (path == null) return null;
    try {
      // A link put in its place since the folder was read is not followed.
      if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.file) return null;
    } catch (_) {
      return null;
    }
    return path;
  }

  @override
  bool get stablePaths => true;

  @override
  Future<bool> reachable(String location) => Directory(location).exists();
}

/// Android: a document tree the user granted (ACTION_OPEN_DOCUMENT_TREE, a persisted read grant), listed and opened
/// through `LinkedFolders.kt` over `caw/linked_folders`. The engine reads by path, so a file is opened as a
/// descriptor kept open for the session and read as `/proc/self/fd/<n>` (docs/decisions.md).
class AndroidFolderAccess implements LinkedFolderAccess {
  static const channel = MethodChannel('caw/linked_folders');

  /// Descriptors kept open, by tree and document: the most recently used [maxOpen] (a project's files are pinned
  /// and never closed while it may play them).
  static const maxOpen = 512;
  final LinkedHashMap<String, int> _open = LinkedHashMap();
  final Set<String> pinned = {};

  /// Hears a descriptor that was closed, so caches keyed by its path drop it (waveforms, the engine's assets).
  void Function(String path)? onClosed;

  @override
  Future<PickedFolder?> pick() async {
    final r = await channel.invokeMapMethod<String, Object?>('pick');
    final uri = r?['uri'], name = r?['name'];
    if (uri is! String || uri.isEmpty) return null;
    return PickedFolder(uri, name is String && name.isNotEmpty ? name : 'Folder');
  }

  @override
  Future<void> release(String location) => channel.invokeMethod<void>('release', {'uri': location});

  @override
  Future<FolderListing> list(String location) async {
    final r = await channel.invokeMapMethod<String, Object?>('list',
        {'uri': location, 'maxDepth': FolderLimits.depth, 'maxFiles': FolderLimits.files});
    if (r == null) return const FolderListing([], error: 'The folder could not be read.');
    final files = <ListedFile>[];
    for (final f in (r['files'] as List? ?? const [])) {
      if (f is! Map) continue;
      final rel = f['rel'], doc = f['doc'], size = f['size'], modified = f['modified'];
      if (rel is! String || doc is! String || doc.length > 4096) continue;
      if (rel.split('/').any((p) => !safeEntryName(p)) || !_isAudioName(rel)) continue;
      files.add(ListedFile(rel, size is int ? size : 0, modified is int ? modified : 0, doc: doc));
      if (files.length >= FolderLimits.files) break;
    }
    final error = r['error'];
    return FolderListing(files, truncated: r['truncated'] == true, error: error is String ? error : null);
  }

  Future<int?> _openFd(String location, String doc) async {
    final fd = await channel.invokeMethod<int>('open', {'uri': location, 'doc': doc});
    return fd != null && fd >= 0 ? fd : null;
  }

  Future<void> _closeFd(int fd) => channel.invokeMethod<void>('close', {'fd': fd});

  @override
  Future<List<SampleMeta?>> readMeta(String location, List<ListedFile> files) async {
    // Files are opened 64 at a time, their headers read together on a worker isolate, and closed again.
    final out = <SampleMeta?>[];
    for (var at = 0; at < files.length; at += 64) {
      final batch = files.sublist(at, at + 64 > files.length ? files.length : at + 64);
      final fds = <int?>[];
      for (final f in batch) {
        fds.add(f.doc == null ? null : await _openFd(location, f.doc!));
      }
      try {
        final open = [...fds];
        out.addAll(await Isolate.run(() => [for (final fd in open) fd == null ? null : readSampleMetaFile('/proc/self/fd/$fd')]));
      } finally {
        for (final fd in fds) {
          if (fd != null) await _closeFd(fd);
        }
      }
    }
    return out;
  }

  @override
  Future<String?> readablePath(String location, ListedFile file) async {
    final doc = file.doc;
    if (doc == null) return null;
    final key = '$location|$doc';
    final have = _open.remove(key);
    if (have != null) {
      _open[key] = have;
      return '/proc/self/fd/$have';
    }
    final fd = await _openFd(location, doc);
    if (fd == null) return null;
    _open[key] = fd;
    while (_open.length > maxOpen) {
      final victim = _open.keys.firstWhere((k) => !pinned.contains(k), orElse: () => '');
      if (victim.isEmpty) break;
      final old = _open.remove(victim)!;
      await _closeFd(old);
      onClosed?.call('/proc/self/fd/$old');
    }
    return '/proc/self/fd/$fd';
  }

  /// Keeps [file]'s descriptor open while a project uses it.
  void pin(String location, ListedFile file) {
    if (file.doc != null) pinned.add('$location|${file.doc}');
  }

  @override
  bool get stablePaths => false;

  @override
  Future<bool> reachable(String location) async =>
      await channel.invokeMethod<bool>('reachable', {'uri': location}) ?? false;
}
