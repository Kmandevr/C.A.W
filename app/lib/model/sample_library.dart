// The sample library: linked folders (app-wide), their on-disk index (incremental, bounded), what each file is, and the browser's filters.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../platform/linked_folders.dart';
import 'atomic_file.dart';
import 'music_key.dart';
import 'sample_meta.dart';
import 'sample_names.dart';

/// Where a value came from, most trusted first. Detected values are estimates and shown as such.
enum ValueSource {
  metadata('m', 'from the file'),
  name('n', 'from the name'),
  detected('d', 'estimated');

  const ValueSource(this.code, this.label);
  final String code, label;
  static ValueSource? byCode(Object? c) => values.where((v) => v.code == c).firstOrNull;
}

/// A folder the user linked (Files › Samples › Link folder…): every project sees it.
class LinkedFolder {
  LinkedFolder({required this.id, required this.name, required this.location});
  final String id;
  String name;

  /// A directory path, or an Android tree URI.
  String location;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'location': location};

  static LinkedFolder? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'], location = j['location'];
    if (id is! String || !RegExp(r'^[A-Za-z0-9_-]{1,40}$').hasMatch(id)) return null;
    if (location is! String || location.isEmpty || location.length > 4096) return null;
    if (location.codeUnits.any((c) => c < 0x20 || c == 0x7f)) return null;
    final n = name is String ? name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim() : '';
    return LinkedFolder(id: id, name: n.isEmpty ? 'Samples' : (n.length > 80 ? n.substring(0, 80) : n), location: location);
  }
}

/// What the library knows about one file.
class SampleEntry {
  SampleEntry({required this.root, required this.rel, this.size = 0, this.modified = 0, this.doc});
  final String root, rel;
  int size, modified;
  String? doc;

  double? bpm;
  ValueSource? bpmFrom;
  MusicalKey? key;
  ValueSource? keyFrom;

  /// 0..1 for a detected key (how clearly it won).
  double? keyConfidence;
  SampleKind? kind;
  ValueSource? kindFrom;
  SampleInstrument? instrument;
  double? seconds;
  bool secondsApprox = false;
  int? rootNote;
  String? title, genre;
  List<String> tags = const [];

  /// Detection already tried (1: tempo, 2: key), so a file is not analysed again until it changes.
  int tried = 0;

  String get name => rel.split('/').last;
  String get baseName => name.replaceFirst(RegExp(r'\.[A-Za-z0-9]{1,5}$'), '');

  /// The folder inside the linked folder ('' at its top).
  String get folder {
    final i = rel.lastIndexOf('/');
    return i < 0 ? '' : rel.substring(0, i);
  }

  String get extension => name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : '';

  ListedFile get listed => ListedFile(rel, size, modified, doc: doc);

  Map<String, dynamic> toJson() => {
        'r': rel, 's': size, 'm': modified, 'd': ?doc,
        if (bpm != null) ...{'b': bpm, 'bs': bpmFrom?.code},
        if (key != null) ...{'k': key!.code, 'ks': keyFrom?.code, if (keyConfidence != null) 'kc': keyConfidence},
        if (kind != null) ...{'t': kind!.name, 'ts': kindFrom?.code},
        'i': ?instrument?.name,
        'sec': ?seconds,
        if (secondsApprox) 'sa': true,
        'rn': ?rootNote,
        'ti': ?title,
        'ge': ?genre,
        if (tags.isNotEmpty) 'g': tags,
        if (tried != 0) 'tr': tried,
      };

  static String? _str(Object? v, int max) {
    if (v is! String || v.isEmpty) return null;
    final s = v.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
    return s.length > max ? s.substring(0, max) : s;
  }

  static double? _num(Object? v, double lo, double hi) => v is num && v.isFinite && v >= lo && v <= hi ? v.toDouble() : null;

  /// One index line, read with limits; null when it is not one.
  static SampleEntry? fromJson(String root, Object? j) {
    if (j is! Map) return null;
    final rel = j['r'];
    if (rel is! String || rel.isEmpty || rel.length > 1024 || rel.split('/').any((p) => !safeEntryName(p))) return null;
    final e = SampleEntry(root: root, rel: rel, size: (_num(j['s'], 0, 1e15) ?? 0).toInt(),
        modified: (_num(j['m'], 0, 1e15) ?? 0).toInt(), doc: _str(j['d'], 4096));
    e.bpm = _num(j['b'], 20, 999);
    e.bpmFrom = e.bpm == null ? null : ValueSource.byCode(j['bs']) ?? ValueSource.name;
    e.key = MusicalKey.fromCode(j['k']);
    e.keyFrom = e.key == null ? null : ValueSource.byCode(j['ks']) ?? ValueSource.name;
    e.keyConfidence = _num(j['kc'], 0, 1);
    e.kind = SampleKind.values.where((k) => k.name == j['t']).firstOrNull;
    e.kindFrom = e.kind == null ? null : ValueSource.byCode(j['ts']) ?? ValueSource.name;
    e.instrument = SampleInstrument.byName(j['i']);
    e.seconds = _num(j['sec'], 0, 3 * 3600);
    e.secondsApprox = j['sa'] == true;
    e.rootNote = _num(j['rn'], 0, 127)?.toInt();
    e.title = _str(j['ti'], 256);
    e.genre = _str(j['ge'], 128);
    final g = j['g'];
    if (g is List) e.tags = [for (final t in g.take(32)) ?_str(t, 40)];
    final tr = j['tr'];
    e.tried = tr is int ? tr & 3 : 0;
    return e;
  }
}

/// How long a sound has to be before its length alone makes it a loop, and short enough to be a one-shot.
const loopFromSeconds = 6.0;
const oneShotBelowSeconds = 2.5;

/// Fills [e] from its file's metadata and its names, most trusted first; one-shot or loop last from the length.
void describeSample(SampleEntry e, SampleMeta? meta) {
  final folders = e.folder.isEmpty ? <String>[] : e.folder.split('/').reversed.toList();
  final names = guessFromPath(e.name, folders);
  final titled = meta?.title == null ? null : guessFromName(meta!.title!, allowBareTempo: false);
  e.bpm = null;
  e.key = null;
  e.kind = null;
  e.bpmFrom = e.keyFrom = e.kindFrom = null;
  e.keyConfidence = null;
  e.tried = 0;
  if (meta?.bpm != null) {
    e.bpm = meta!.bpm;
    e.bpmFrom = ValueSource.metadata;
  } else if (names.bpm != null) {
    e.bpm = names.bpm;
    e.bpmFrom = ValueSource.name;
  }
  if (meta?.key != null) {
    e.key = meta!.key;
    e.keyFrom = ValueSource.metadata;
  } else if (names.key ?? titled?.key case final k?) {
    e.key = k;
    e.keyFrom = ValueSource.name;
  }
  e.instrument = names.instrument ?? titled?.instrument;
  e.seconds = meta?.seconds;
  e.secondsApprox = meta?.secondsApprox ?? false;
  e.rootNote = meta?.rootNote ?? names.rootNote;
  e.title = meta?.title;
  e.genre = meta?.genre;
  if (meta?.kind != null) {
    e.kind = meta!.kind;
    e.kindFrom = ValueSource.metadata;
  } else if (meta?.beats != null && meta!.beats! > 1) {
    e.kind = SampleKind.loop;
    e.kindFrom = ValueSource.metadata;
  } else if (names.kind != null) {
    e.kind = names.kind;
    e.kindFrom = ValueSource.name;
  } else {
    inferKindFromLength(e);
  }
  // A loop's tempo from its acid beats and length, when nothing else gave one.
  if (e.bpm == null && meta?.beats != null && (e.seconds ?? 0) > 0.5) {
    final bpm = meta!.beats! * 60 / e.seconds!;
    if (bpm >= 40 && bpm <= 300) {
      e.bpm = (bpm * 100).roundToDouble() / 100;
      e.bpmFrom = ValueSource.metadata;
    }
  }
  final tags = <String>{...names.tags, ...?titled?.tags};
  for (final k in meta?.keywords ?? const <String>[]) {
    tags.add(k.toLowerCase());
  }
  if (meta?.genre case final g?) tags.add(g.toLowerCase());
  e.tags = tags.take(32).map((t) => t.length > 40 ? t.substring(0, 40) : t).toList();
}

/// One-shot or loop from the length when nothing said: long, or a whole number of beats at a known tempo, is a loop;
/// short is a one-shot. Marked as detected (an estimate).
void inferKindFromLength(SampleEntry e) {
  final s = e.seconds;
  if (s == null || s <= 0) return;
  SampleKind? k;
  if (e.bpm != null && s >= 1) {
    final beats = s * e.bpm! / 60;
    if (beats >= 2 && (beats - beats.round()).abs() < 0.05) k = SampleKind.loop;
  }
  k ??= s >= loopFromSeconds ? SampleKind.loop : s < oneShotBelowSeconds ? SampleKind.oneShot : null;
  if (k != null) {
    e.kind = k;
    e.kindFrom = ValueSource.detected;
  }
}

/// Limits on the index of one folder and on the library.
class LibraryLimits {
  static const folders = 64;
  static const indexBytes = 64 << 20;
  static const entries = FolderLimits.files;
}

/// A folder's index on disk: `sample-index/<id>.json` beside settings.json, compact JSON.
class SampleIndexStore {
  SampleIndexStore(this.dir);
  final Directory? dir;

  File? _file(String id) => dir == null ? null : File('${dir!.path}${Platform.pathSeparator}$id.json');

  /// The saved entries (empty when there is none, it is too big or it doesn't read). Off the UI isolate.
  Future<List<SampleEntry>> load(String id) async {
    final f = _file(id);
    if (f == null) return [];
    final path = f.path;
    return Isolate.run(() => readIndexFileSync(path, id));
  }

  Future<void> save(String id, List<SampleEntry> entries) async {
    final f = _file(id);
    if (f == null) return;
    await f.parent.create(recursive: true);
    final text = jsonEncode({'version': 1, 'root': id, 'entries': [for (final e in entries.take(LibraryLimits.entries)) e.toJson()]});
    await writeFileAtomically(f, text);
  }

  Future<void> delete(String id) async {
    final f = _file(id);
    try {
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// Reads an index file with its limits (8 bytes past [LibraryLimits.indexBytes] and it is ignored).
List<SampleEntry> readIndexFileSync(String path, String id) {
  try {
    final f = File(path);
    if (!f.existsSync() || f.lengthSync() > LibraryLimits.indexBytes) return [];
    final j = jsonDecode(f.readAsStringSync());
    if (j is! Map || j['version'] != 1 || j['root'] != id) return [];
    final list = j['entries'];
    if (list is! List) return [];
    return [for (final raw in list.take(LibraryLimits.entries)) ?SampleEntry.fromJson(id, raw)];
  } catch (_) {
    return [];
  }
}

/// The incremental part of a refresh: entries for [listed], reusing [previous] where a file's size and modified
/// time are unchanged; [changed] are the files whose metadata must be read again.
({List<SampleEntry> entries, List<SampleEntry> changed}) mergeListing(
    String root, List<ListedFile> listed, List<SampleEntry> previous) {
  final old = {for (final e in previous) e.rel: e};
  final entries = <SampleEntry>[];
  final changed = <SampleEntry>[];
  for (final f in listed.take(LibraryLimits.entries)) {
    final was = old[f.rel];
    if (was != null && was.size == f.size && was.modified == f.modified) {
      was.doc = f.doc ?? was.doc;
      entries.add(was);
    } else {
      final e = SampleEntry(root: root, rel: f.rel, size: f.size, modified: f.modified, doc: f.doc);
      entries.add(e);
      changed.add(e);
    }
  }
  return (entries: entries, changed: changed);
}

// ---------- filters ----------

/// How a key filter matches.
enum KeyMatch { exact, relative, compatible }

enum SampleSort { name, bpm, key, length, folder, recent }

/// The browser's filters. Every one left empty passes everything.
class SampleQuery {
  String text = '';
  double? bpmMin, bpmMax;

  /// Also pass tempos at half or double the range (a 70 BPM loop for a 140 BPM song).
  bool halfDouble = false;
  final Set<MusicalKey> keys = {};
  KeyMatch keyMatch = KeyMatch.exact;
  final Set<SampleKind> kinds = {};
  final Set<SampleInstrument> instruments = {};
  double? minSeconds, maxSeconds;

  /// A folder inside the linked folder ('' or null: all).
  String? folder;
  final Set<String> tags = {};

  /// Off: values that were only estimated don't pass a BPM or key filter.
  bool estimates = true;
  SampleSort sort = SampleSort.name;
  bool descending = false;

  bool get active =>
      text.trim().isNotEmpty || bpmMin != null || bpmMax != null || keys.isNotEmpty || kinds.isNotEmpty ||
      instruments.isNotEmpty || minSeconds != null || maxSeconds != null || (folder?.isNotEmpty ?? false) || tags.isNotEmpty;

  void clear() {
    text = '';
    bpmMin = bpmMax = minSeconds = maxSeconds = null;
    keys.clear();
    kinds.clear();
    instruments.clear();
    folder = null;
    tags.clear();
  }

  Set<MusicalKey> get _keySet => switch (keyMatch) {
        KeyMatch.exact => keys,
        KeyMatch.relative => {for (final k in keys) ...[k, k.relative]},
        KeyMatch.compatible => {for (final k in keys) ...k.compatible},
      };

  bool _bpmIn(double bpm) {
    bool inRange(double v) => (bpmMin == null || v >= bpmMin! - 0.005) && (bpmMax == null || v <= bpmMax! + 0.005);
    return inRange(bpm) || halfDouble && (inRange(bpm * 2) || inRange(bpm / 2));
  }

  bool passes(SampleEntry e) {
    if (bpmMin != null || bpmMax != null) {
      if (e.bpm == null || !estimates && e.bpmFrom == ValueSource.detected || !_bpmIn(e.bpm!)) return false;
    }
    if (keys.isNotEmpty) {
      if (e.key == null || !estimates && e.keyFrom == ValueSource.detected || !_keySet.contains(e.key)) return false;
    }
    if (kinds.isNotEmpty && !kinds.contains(e.kind)) return false;
    if (instruments.isNotEmpty && !instruments.contains(e.instrument)) return false;
    if (minSeconds != null && (e.seconds == null || e.seconds! < minSeconds!)) return false;
    if (maxSeconds != null && (e.seconds == null || e.seconds! > maxSeconds!)) return false;
    final f = folder;
    if (f != null && f.isNotEmpty && e.folder != f && !e.folder.startsWith('$f/')) return false;
    if (tags.isNotEmpty && !tags.every(e.tags.contains)) return false;
    final words = text.trim().toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isNotEmpty) {
      final hay = [e.rel, e.title ?? '', e.genre ?? '', ...e.tags, e.instrument?.label ?? '', e.key?.short ?? '']
          .join(' ')
          .toLowerCase();
      if (!words.every(hay.contains)) return false;
    }
    return true;
  }

  int _compare(SampleEntry a, SampleEntry b) {
    // Unknown values sort last either way.
    int nulls(num? x, num? y) => x == null ? (y == null ? 0 : (descending ? -1 : 1)) : y == null ? (descending ? 1 : -1) : x.compareTo(y);
    final c = switch (sort) {
      SampleSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      SampleSort.bpm => nulls(a.bpm, b.bpm),
      SampleSort.key => nulls(a.key == null ? null : (a.key!.minor ? 12 : 0) + a.key!.tonic,
          b.key == null ? null : (b.key!.minor ? 12 : 0) + b.key!.tonic),
      SampleSort.length => nulls(a.seconds, b.seconds),
      SampleSort.folder => a.folder.toLowerCase().compareTo(b.folder.toLowerCase()),
      SampleSort.recent => b.modified.compareTo(a.modified),
    };
    if (c != 0) return descending ? -c : c;
    return a.rel.toLowerCase().compareTo(b.rel.toLowerCase());
  }

  List<SampleEntry> apply(Iterable<SampleEntry> all) => all.where(passes).toList()..sort(_compare);
}

/// The values each filter can take in [entries] (the chips offer only what is there).
({Set<MusicalKey> keys, Set<SampleInstrument> instruments, Set<String> tags, List<String> folders, double? minBpm, double? maxBpm})
    filterChoices(Iterable<SampleEntry> entries) {
  final keys = <MusicalKey>{}, instruments = <SampleInstrument>{}, tags = <String, int>{}, folders = <String>{};
  double? lo, hi;
  for (final e in entries) {
    if (e.key != null) keys.add(e.key!);
    if (e.instrument != null) instruments.add(e.instrument!);
    for (final t in e.tags) {
      tags[t] = (tags[t] ?? 0) + 1;
    }
    if (e.folder.isNotEmpty) folders.add(e.folder);
    if (e.bpm != null) {
      lo = lo == null ? e.bpm : math.min(lo, e.bpm!);
      hi = hi == null ? e.bpm : math.max(hi, e.bpm!);
    }
  }
  final topTags = (tags.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(40).map((e) => e.key).toSet();
  return (keys: keys, instruments: instruments, tags: topTags, folders: folders.toList()..sort(), minBpm: lo, maxBpm: hi);
}

// ---------- the library ----------

/// How far a folder's refresh has got.
class IndexProgress {
  const IndexProgress({this.listing = false, this.done = 0, this.total = 0, this.error, this.truncated = false});
  final bool listing, truncated;
  final int done, total;
  final String? error;
  bool get running => listing || done < total;
}

/// Linked folders and their indexes, app-wide (in `sample-folders.json` and `sample-index/` beside settings.json).
class SampleLibrary extends ChangeNotifier {
  SampleLibrary({Directory? settingsDir, LinkedFolderAccess? access})
      : _dir = settingsDir,
        access = access ?? LinkedFolderAccess.instance,
        indexes = SampleIndexStore(settingsDir == null ? null : Directory('${settingsDir.path}${Platform.pathSeparator}sample-index'));
  final Directory? _dir;
  final LinkedFolderAccess access;
  final SampleIndexStore indexes;

  final List<LinkedFolder> folders = [];

  /// Bumped when the folder list changes (Files' tree listens to this, not to every indexing step).
  final ValueNotifier<int> foldersTick = ValueNotifier(0);
  final Map<String, List<SampleEntry>> _entries = {};
  final Map<String, IndexProgress> progress = {};
  final Map<String, bool> _reachable = {};
  Future<void>? _loading;

  /// Detection of tempo and key from the audio (C API 32/33), set by the app; null: nothing is estimated.
  Future<void> Function(SampleLibrary library, LinkedFolder folder, List<SampleEntry> entries)? analyse;

  File? get _foldersFile => _dir == null ? null : File('${_dir.path}${Platform.pathSeparator}sample-folders.json');

  List<SampleEntry> entries(String folderId) => _entries[folderId] ?? const [];
  Iterable<SampleEntry> get allEntries => folders.expand((f) => entries(f.id));
  LinkedFolder? folder(String id) => folders.where((f) => f.id == id).firstOrNull;
  bool reachable(String id) => _reachable[id] ?? true;

  /// Reads the folder list and each index, then refreshes every folder in the background (on open).
  Future<void> load({bool refresh = true}) => _loading ??= () async {
        final f = _foldersFile;
        if (f != null) {
          try {
            if (await f.exists() && await f.length() <= 1 << 20) {
              final j = jsonDecode(await f.readAsString());
              final list = j is Map ? j['folders'] : null;
              if (list is List) {
                for (final raw in list.take(LibraryLimits.folders)) {
                  final lf = LinkedFolder.fromJson(raw);
                  if (lf != null && folder(lf.id) == null) folders.add(lf);
                }
              }
            }
          } catch (_) {}
        }
        for (final lf in folders) {
          _entries[lf.id] = await indexes.load(lf.id);
        }
        foldersTick.value++;
        notifyListeners();
        if (refresh) {
          for (final lf in [...folders]) {
            unawaited(this.refresh(lf.id));
          }
        }
      }();

  Future<void> _saveFolders() async {
    final f = _foldersFile;
    if (f == null) return;
    await f.parent.create(recursive: true);
    await writeFileAtomically(f, jsonEncode({'version': 1, 'folders': [for (final lf in folders) lf.toJson()]}));
  }

  static String _newId() {
    final r = math.Random.secure();
    return 'lf${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${r.nextInt(1 << 30).toRadixString(36)}';
  }

  /// Link folder…: the system picker, then the new folder is indexed. Null when cancelled; an error text when it
  /// can't be linked (already linked, too many folders).
  Future<(LinkedFolder?, String?)> linkPicked() async {
    final picked = await access.pick();
    if (picked == null) return (null, null);
    return link(picked.location, picked.name);
  }

  Future<(LinkedFolder?, String?)> link(String location, String name, {String? id}) async {
    await load(refresh: false);
    if (folders.any((f) => f.location == location)) return (null, 'That folder is linked already.');
    if (folders.length >= LibraryLimits.folders) return (null, 'At most ${LibraryLimits.folders} folders can be linked.');
    final lf = LinkedFolder(id: id ?? _newId(), name: name, location: location);
    folders.add(lf);
    _entries[lf.id] = [];
    await _saveFolders();
    foldersTick.value++;
    notifyListeners();
    unawaited(refresh(lf.id));
    return (lf, null);
  }

  /// Unlinks a folder: its index goes, nothing in it is touched. Projects that use its files show them missing.
  Future<void> unlink(String id) async {
    final lf = folder(id);
    if (lf == null) return;
    folders.remove(lf);
    _entries.remove(id);
    progress.remove(id);
    await _saveFolders();
    await indexes.delete(id);
    try {
      await access.release(lf.location);
    } catch (_) {}
    foldersTick.value++;
    notifyListeners();
  }

  /// Points a linked folder somewhere else (Find it's relink): the same id, so every project's links follow.
  Future<void> relocate(String id, String location, String name) async {
    final lf = folder(id);
    if (lf == null) return;
    final old = lf.location;
    lf.location = location;
    lf.name = name;
    _entries[id] = [];
    await _saveFolders();
    if (old != location) {
      try {
        await access.release(old);
      } catch (_) {}
    }
    foldersTick.value++;
    notifyListeners();
    await refresh(id);
  }

  final Map<String, Future<void>> _refreshing = {};

  /// Pull-to-refresh and open: lists the folder again, reads the metadata of new and changed files only (by size
  /// and modified time), in batches, then saves the index. Everything heavy runs off the UI isolate.
  Future<void> refresh(String id) => _refreshing[id] ??= _refresh(id).whenComplete(() {
        _refreshing.remove(id);  // a block: returning the removed future would make it wait for itself
      });

  Future<void> _refresh(String id) async {
    final lf = folder(id);
    if (lf == null) return;
    progress[id] = const IndexProgress(listing: true);
    notifyListeners();
    final ok = await access.reachable(lf.location).catchError((_) => false);
    _reachable[id] = ok;
    if (!ok) {
      progress[id] = const IndexProgress(error: 'The folder can\'t be reached: Find it, or unlink it.');
      notifyListeners();
      return;
    }
    FolderListing listing;
    try {
      listing = await access.list(lf.location);
    } catch (e) {
      progress[id] = IndexProgress(error: 'The folder could not be read ($e).');
      notifyListeners();
      return;
    }
    final merged = mergeListing(id, listing.files, entries(id));
    if (folder(id) == null) return;
    _entries[id] = merged.entries;
    var done = 0;
    progress[id] = IndexProgress(total: merged.changed.length, truncated: listing.truncated, error: listing.error);
    notifyListeners();
    const batch = 200;
    for (var at = 0; at < merged.changed.length; at += batch) {
      final part = merged.changed.sublist(at, math.min(at + batch, merged.changed.length));
      List<SampleMeta?> metas;
      try {
        metas = await access.readMeta(lf.location, [for (final e in part) e.listed]);
      } catch (_) {
        metas = List.filled(part.length, null);
      }
      for (var i = 0; i < part.length; i++) {
        describeSample(part[i], i < metas.length ? metas[i] : null);
      }
      done += part.length;
      progress[id] = IndexProgress(done: done, total: merged.changed.length, truncated: listing.truncated, error: listing.error);
      notifyListeners();
    }
    await indexes.save(id, merged.entries).catchError((_) {});
    progress[id] = IndexProgress(truncated: listing.truncated, error: listing.error);
    notifyListeners();
    if (analyse != null) {
      try {
        await analyse!(this, lf, merged.entries);
        await indexes.save(id, merged.entries).catchError((_) {});
      } catch (_) {}
    }
  }

  /// Tests: [folder] with [entries] in place of what a refresh would read, without touching disk.
  @visibleForTesting
  void debugSet(LinkedFolder folder, List<SampleEntry> entries) {
    _loading ??= Future.value();
    if (this.folder(folder.id) == null) folders.add(folder);
    _entries[folder.id] = entries;
    foldersTick.value++;
    notifyListeners();
  }

  /// Tells the browser an entry changed (a value was detected).
  void changed() => notifyListeners();

  /// Saves the index after values were detected (the preview found a tempo or key).
  Future<void> saveIndex(String id) => indexes.save(id, entries(id)).catchError((_) {});

  /// The entry at [rel] in folder [id], if indexed.
  SampleEntry? entry(String id, String rel) => entries(id).where((e) => e.rel == rel).firstOrNull;

  /// Which linked folder and relative path [path] (a directory path) is in, or null.
  (LinkedFolder, String)? locate(String path) {
    final norm = path.replaceAll('\\', '/');
    for (final lf in folders) {
      if (lf.location.startsWith('content://')) continue;
      var root = lf.location.replaceAll('\\', '/');
      if (!root.endsWith('/')) root = '$root/';
      final fold = Platform.isWindows;
      final p = fold ? norm.toLowerCase() : norm, r = fold ? root.toLowerCase() : root;
      if (p.startsWith(r)) {
        final rel = norm.substring(root.length);
        if (rel.split('/').every(safeEntryName)) return (lf, rel);
      }
    }
    return null;
  }

  /// A readable path for [e] this session (Android: an open document handle), or null.
  Future<String?> pathOf(SampleEntry e) async {
    final lf = folder(e.root);
    if (lf == null) return null;
    return access.readablePath(lf.location, e.listed);
  }
}
