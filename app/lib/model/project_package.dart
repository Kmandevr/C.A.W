// The .caw project file (#159; owner, 2026-11-11): plain project JSON, or a zip package of the project with the
// dependencies the user ticked (audio, samples, C++ builds, presets, the theme), and unpacking one as untrusted input.
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../engine/engine.dart';
import '../ui/theme.dart';
import '../version.dart';
import 'app_state.dart';
import 'arrange_fx.dart';
import 'audio_edit.dart';
import 'native_components.dart';
import 'native_trust.dart';
import 'project.dart';
import 'project_dependencies.dart';
import 'sha256.dart';
import 'user_presets.dart';
import 'zip_archive.dart';

/// The package's manifest format (`manifest.json`).
const packageFormat = 'caw.package';
const packageVersion = 1;

/// The project file's extension, and those import also takes (the old `.cawproj`, a bare `.json`).
const projectExtension = 'caw';
const projectImportExtensions = ['caw', 'cawproj', 'json'];

/// What a package may hold: each kind of file has its own ceiling, and the whole archive one more.
abstract final class PackageLimits {
  static const projectBytes = 64 << 20;
  static const manifestBytes = 4 << 20;
  static const audioBytes = 1 << 30;
  static const binaryBytes = 256 << 20;
  static const themeBytes = 1 << 20;
  static const entries = 20000;
  static const totalBytes = 4 << 30;
  static const zip = ZipLimits(maxEntries: entries, maxEntryBytes: audioBytes, maxTotalBytes: totalBytes);
}

/// This device's ABI as packages name it (`android_arm64`, `windows_x64`...): a build is only offered to the same.
String get deviceAbi => Abi.current().toString();

/// A package path for a file called [name]: plain characters only, no leading dot, at most 96 characters.
String safeArchiveName(String name) {
  var clean = name.replaceAll(RegExp(r'[^A-Za-z0-9 ._()+#-]'), '_').trim();
  while (clean.startsWith('.')) {
    clean = clean.substring(1);
  }
  if (clean.isEmpty) clean = 'file';
  return clean.length > 96 ? clean.substring(clean.length - 96) : clean;
}

/// Reads decoded project JSON (a plain .caw, a package's project.json or an old .cawproj), refusing what isn't one.
ProjectDoc decodeProjectJson(Object? decoded) {
  if (decoded is! Map<String, dynamic> || decoded['caw_app_project'] is! num) {
    throw const FormatException('This is not a C.A.W. project file.');
  }
  final version = (decoded['caw_app_project'] as num).toInt();
  if (version > ProjectDoc.fileVersion) {
    throw FormatException('This project uses a newer format (v$version); this app supports v${ProjectDoc.fileVersion}.');
  }
  return ProjectDoc.fromJson(decoded);
}

// ---------- writing ----------

/// One file to copy into the package, with its manifest entry (the sha256 and size are filled in as it is read).
typedef PackFile = ({String archivePath, String source, Map<String, Object?> entry});

/// Writes the package [out]: `manifest.json`, `project.json` ([projectJson]), [files] read from disk, [extras]
/// already in memory (presets, the theme); [hashOnly] are files listed but not packaged, hashed so Locate… can check
/// a relinked copy. Synchronous: run it with [Isolate.run].
void writeProjectPackage(String out, String projectJson, List<PackFile> files, List<(String, Uint8List, Map<String, Object?>)> extras,
    List<(String, Map<String, Object?>)> hashOnly, List<Map<String, Object?>> listed) {
  final zip = ZipWriter.create(out);
  try {
    final entries = <Map<String, Object?>>[...listed];
    zip.addBytes('project.json', utf8.encode(projectJson));
    for (final f in files) {
      zip.addFile(f.archivePath, f.source);
      entries.add({...f.entry, 'path': f.archivePath, 'packaged': true, 'size': File(f.source).lengthSync(),
          'sha256': sha256OfFileSync(f.source)});
    }
    for (final (path, bytes, entry) in extras) {
      zip.addBytes(path, bytes);
      entries.add({...entry, 'path': path, 'packaged': true, 'size': bytes.length, 'sha256': sha256Hex(bytes)});
    }
    for (final (source, entry) in hashOnly) {
      var sha = '';
      try {
        sha = sha256OfFileSync(source);
      } catch (_) {}
      entries.add({...entry, 'packaged': false, if (sha.isNotEmpty) 'sha256': sha});
    }
    zip.addBytes('manifest.json', utf8.encode(const JsonEncoder.withIndent('  ').convert({
      'format': packageFormat,
      'version': packageVersion,
      'app': appVersion,
      'created': DateTime.now().toUtc().toIso8601String(),
      'project': 'project.json',
      'dependencies': entries,
    })));
    zip.close();
  } catch (_) {
    zip.abandon();
    final f = File(out);
    if (f.existsSync()) f.deleteSync();
    rethrow;
  }
}

// ---------- reading ----------

/// A packaged C++ build unpacked for this device, waiting for the user's Trust or Block.
class ImportedBinary {
  const ImportedBinary(this.componentId, this.name, this.sourceFingerprint, this.path, this.sha256);
  final String componentId, name, sourceFingerprint, path, sha256;
}

/// What an import brought besides the project.
class ProjectImportResult {
  final List<String> presetsAdded = [];
  final List<ImportedBinary> binaries = [];
  final List<String> notes = [];
  CawTheme? theme;
  int filesUnpacked = 0;
}

/// What the unpacking isolate hands back: plain data only.
typedef _Unpacked = ({
  String projectJson,
  List<(String, String, String)> files, // reference in project.json, file written here, sha256
  List<(String, String, String, String, String)> binaries, // component, name, source fingerprint, file, sha256
  List<String> presets,
  String? theme,
  Map<String, String> hashes, // reference -> sha256, for files listed but not packaged
  List<String> notes,
});

String _text(Object? v, int max) => v is String && v.length <= max ? v : '';

/// Opens [path] (any .caw, .cawproj or JSON project) off the UI isolate. A package's files go into [audioDir] and
/// [binaryDir] under names made here (never the archive's own), each checked against its manifest hash.
Future<_Unpacked> _unpack(String path, String audioDir, String binaryDir, String abi) => Isolate.run(() {
  final head = File(path).openSync();
  final List<int> magic;
  try {
    magic = head.readSync(4);
  } finally {
    head.closeSync();
  }
  if (!ZipReader.looksLikeZip(magic)) {
    if (File(path).lengthSync() > PackageLimits.projectBytes) throw const FormatException('The project file is too large.');
    return (projectJson: File(path).readAsStringSync(), files: <(String, String, String)>[],
        binaries: <(String, String, String, String, String)>[], presets: <String>[], theme: null,
        hashes: <String, String>{}, notes: <String>[]);
  }
  final ZipReader zip;
  try {
    zip = ZipReader.open(path, limits: PackageLimits.zip);
  } on ZipException catch (e) {
    throw FormatException('This package can\'t be opened: ${e.message}');
  }
  final written = <String>[];
  try {
    final manifestEntry = zip['manifest.json'], projectEntry = zip['project.json'];
    if (manifestEntry == null || projectEntry == null) throw const FormatException('This is not a C.A.W. package.');
    final manifest = jsonDecode(utf8.decode(zip.readBytes(manifestEntry, maxBytes: PackageLimits.manifestBytes)));
    if (manifest is! Map || manifest['format'] != packageFormat) throw const FormatException('This is not a C.A.W. package.');
    final version = manifest['version'];
    if (version is! int || version < 1 || version > packageVersion) {
      throw FormatException('This package uses a newer format (v$version); this app reads v$packageVersion.');
    }
    final projectJson = utf8.decode(zip.readBytes(projectEntry, maxBytes: PackageLimits.projectBytes));
    final files = <(String, String, String)>[];
    final binaries = <(String, String, String, String, String)>[];
    final presets = <String>[];
    final hashes = <String, String>{};
    final notes = <String>[];
    String? theme;
    final taken = <String>{};
    String freeFile(String dir, String name) {
      Directory(dir).createSync(recursive: true);
      final base = safeArchiveName(name);
      var candidate = '$dir${Platform.pathSeparator}$base';
      for (var n = 2; File(candidate).existsSync() || taken.contains(candidate.toLowerCase()); n++) {
        candidate = '$dir${Platform.pathSeparator}${base.replaceFirst(RegExp(r'(\.[^.]*)?$'), ' $n\$1')}';
      }
      taken.add(candidate.toLowerCase());
      return candidate;
    }

    final list = manifest['dependencies'];
    for (final raw in (list is List ? list : const []).take(PackageLimits.entries)) {
      if (raw is! Map) continue;
      final kind = _text(raw['kind'], 16), name = _text(raw['name'], 256), reference = _text(raw['reference'], 4096);
      final sha = _text(raw['sha256'], 64);
      final archivePath = raw['packaged'] == true ? _text(raw['path'], 240) : '';
      if (archivePath.isEmpty) {
        if (reference.isNotEmpty && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) hashes[reference] = sha;
        continue;
      }
      // A packaged file must sit in its kind's folder and be in the archive; anything else in the zip is ignored.
      final folder = switch (kind) {
        'audio' || 'sample' => 'assets/',
        'binary' => 'components/',
        'preset' => 'presets/',
        'theme' => 'theme.json',
        _ => null,
      };
      final entry = zip[archivePath];
      if (folder == null || !isSafeArchivePath(archivePath) || !archivePath.startsWith(folder) || entry == null) {
        notes.add('Skipped ${name.isEmpty ? archivePath : name} (not where a package keeps it).');
        continue;
      }
      try {
        switch (kind) {
          case 'audio' || 'sample':
            if (reference.isEmpty) continue;
            final out = freeFile(audioDir, name.isEmpty ? archivePath.split('/').last : name.split(RegExp(r'[/\\]')).last);
            zip.extract(entry, out, maxBytes: PackageLimits.audioBytes);
            written.add(out);
            final got = sha256OfFileSync(out);
            if (sha.isNotEmpty && got != sha) {
              File(out).deleteSync();
              written.remove(out);
              notes.add('$name was damaged in the package and was left out.');
              continue;
            }
            files.add((reference, out, got));
          case 'binary':
            final component = _text(raw['component'], 128), fingerprint = _text(raw['source_fingerprint'], 64);
            if (_text(raw['abi'], 64) != abi) {
              notes.add('$name is built for another device (${_text(raw['abi'], 64)}); it builds from source here.');
              continue;
            }
            if (component.isEmpty || fingerprint.isEmpty) continue;
            final ext = archivePath.contains('.') ? archivePath.substring(archivePath.lastIndexOf('.')) : '';
            final bytes = zip.readBytes(entry, maxBytes: PackageLimits.binaryBytes);
            final got = sha256Hex(bytes);
            if (sha.isNotEmpty && got != sha) {
              notes.add('$name was damaged in the package and was left out.');
              continue;
            }
            final out = freeFile(binaryDir, '${safeArchiveName(component)}-${got.substring(0, 12)}$ext');
            File(out).writeAsBytesSync(bytes, flush: true);
            written.add(out);
            binaries.add((component, name, fingerprint, out, got));
          case 'preset':
            presets.add(utf8.decode(zip.readBytes(entry, maxBytes: PresetLimits.fileBytes)));
          case 'theme':
            final j = jsonDecode(utf8.decode(zip.readBytes(entry, maxBytes: PackageLimits.themeBytes)));
            if (j is Map && j['theme'] is String) theme = j['theme'] as String;
        }
      } on ZipException catch (e) {
        notes.add('Skipped ${name.isEmpty ? archivePath : name}: ${e.message}');
      } on FormatException {
        notes.add('Skipped ${name.isEmpty ? archivePath : name}: not readable.');
      }
    }
    return (projectJson: projectJson, files: files, binaries: binaries, presets: presets, theme: theme,
        hashes: hashes, notes: notes);
  } catch (_) {
    for (final w in written) {
      try {
        File(w).deleteSync();
      } catch (_) {}
    }
    rethrow;
  } finally {
    zip.close();
  }
});

Future<void> _writeOffThread(String out, String projectJson, List<PackFile> files,
        List<(String, Uint8List, Map<String, Object?>)> extras, List<(String, Map<String, Object?>)> hashOnly,
        List<Map<String, Object?>> listed) =>
    Isolate.run(() => writeProjectPackage(out, projectJson, files, extras, hashOnly, listed));

Future<String> _hashOffThread(String path) => Isolate.run(() => sha256OfFileSync(path));

final Expando<Map<String, String>> _knownHashes = Expando('hashes of files a package listed');

extension ProjectPackaging on AppState {
  /// The sha256 a package recorded for a file it listed but didn't carry, by its reference in the project.
  Map<String, String> get knownFileHashes => _knownHashes[this] ??= {};

  /// The project's dependencies on this device (the export checklist).
  Future<List<ProjectDependency>> projectDependencies() async {
    final manager = nativeComponents;
    final built = <String, String>{};
    if (manager != null) {
      for (final c in project.cppComponents) {
        if (await manager.builtArtifact(c) case final path?) built[c.id] = path;
      }
    }
    var presets = const <UserPreset>[];
    try {
      await userPresets.load();
      presets = userPresets.all;
    } catch (_) {}
    final s = settings;
    final theme = s.isStarter(s.themeName) ? null : s.theme.copyWith(profile: {...s.theme.profile, ...s.captureProfile()});
    return scanProjectDependencies(project, builtBinary: (c) => built[c.id] ?? nativeComponents?.artifactOf(c.componentId),
        presets: presets, theme: theme, isKnownComponent: (id) => componentInfo(id) != null);
  }

  /// Writes the project as a .caw file in a temporary folder and returns it: plain JSON when nothing but the project
  /// itself is ticked, else a package of the project and the [selected] dependencies (keys of [deps]). Every other
  /// dependency is still listed in the manifest (hashed when it is here), so the other side can see what is missing.
  Future<File> writeProjectFile(List<ProjectDependency> deps, Set<String> selected, {Directory? into}) async {
    await flush();
    final dir = into ?? await Directory.systemTemp.createTemp('caw-export');
    final name = safeArchiveName(project.name.isEmpty ? 'Caw_Project' : project.name).replaceAll(' ', '_');
    final out = File('${dir.path}${Platform.pathSeparator}$name.$projectExtension');
    final pack = [for (final d in deps) if (selected.contains(d.key) && d.packageable) d];
    final json = project.toJson();
    if (pack.isEmpty) {
      await out.writeAsString(const JsonEncoder.withIndent('  ').convert(json), flush: true);
      return out;
    }
    // Packaged files get a reference of their own in the copy's project.json, so no device path travels with them.
    final copy = ProjectDoc.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
    final files = <PackFile>[];
    final extras = <(String, Uint8List, Map<String, Object?>)>[];
    final hashOnly = <(String, Map<String, Object?>)>[];
    final listed = <Map<String, Object?>>[];
    final used = <String>{};
    String unique(String path) {
      var p = path;
      for (var n = 2; !used.add(p.toLowerCase()); n++) {
        p = path.replaceFirst(RegExp(r'(\.[^./]*)?$'), ' $n\$1');
      }
      return p;
    }

    for (final d in deps) {
      final entry = <String, Object?>{'kind': d.kind.name, 'name': d.name, 'used_by': d.usedBy, 'size': d.size,
          if (d.componentId != null) 'component': d.componentId};
      final picked = selected.contains(d.key) && d.packageable;
      switch (d.kind) {
        case DependencyKind.audio || DependencyKind.sample:
          final path = d.path!;
          if (!picked) {
            entry['reference'] = path;
            if (d.found) {
              hashOnly.add((path, entry));
            } else {
              listed.add({...entry, 'packaged': false});
            }
            continue;
          }
          final archive = unique('assets/${safeArchiveName(d.name)}');
          final reference = 'package:$archive';
          relinkProjectPath(copy, path, reference);
          files.add((archivePath: archive, source: path, entry: {...entry, 'reference': reference}));
        case DependencyKind.binary:
          if (!picked) continue;
          final c = project.cppComponents.firstWhere((c) => c.componentId == d.componentId);
          final file = d.path!.split(RegExp(r'[/\\]')).last;
          files.add((archivePath: unique('components/${safeArchiveName(c.componentId)}/$deviceAbi/${safeArchiveName(file)}'),
              source: d.path!, entry: {...entry, 'abi': deviceAbi, 'source_fingerprint': NativeTrustStore.sourceFingerprint(c)}));
        case DependencyKind.preset:
          if (!picked) continue;
          final p = userPresets.byId(d.presetId!);
          if (p == null) continue;
          extras.add((unique('presets/${safeArchiveName(p.name)}.cawpreset'), Uint8List.fromList(utf8.encode(p.encode())),
              {...entry, 'preset_kind': p.kind.name}));
        case DependencyKind.theme:
          if (!picked) continue;
          final s = settings;
          final t = s.theme.copyWith(profile: {...s.theme.profile, ...s.captureProfile()});
          extras.add(('theme.json', Uint8List.fromList(utf8.encode(jsonEncode({'name': t.name, 'theme': t.toFile()}))), entry));
        case DependencyKind.plugin:
          listed.add({...entry, 'packaged': false, 'licence': 'unknown: not packaged (redistribution not confirmed)'});
        case DependencyKind.source || DependencyKind.impulse:
          listed.add({...entry, 'packaged': false, 'embedded': true});
      }
    }
    final projectJson = const JsonEncoder.withIndent('  ').convert(copy.toJson());
    final outPath = out.path;
    await _writeOffThread(outPath, projectJson, files, extras, hashOnly, listed);
    return out;
  }

  /// Opens the project file at [path] (.caw plain or package, or an old .cawproj) as a new project: a new id
  /// ([importProject]), packaged audio unpacked into its audio folder and relinked, presets added (renamed on a
  /// clash), packaged C++ builds through the trust rules ([askBinaryTrust], once per build's fingerprint; null
  /// leaves it unused). The theme is returned, not applied. [confirm] sees the project before it replaces the open
  /// one (false: nothing changes and null is returned).
  Future<ProjectImportResult?> importProjectFile(String path,
      {Future<bool> Function(ProjectDoc project)? confirm,
      Future<NativeComponentTrust?> Function(ImportedBinary binary)? askBinaryTrust}) async {
    final result = ProjectImportResult();
    final id = newId('p');
    final audioDir = storage?.audioDirectory(id).path ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}caw-audio${Platform.pathSeparator}$id';
    final binaryDir = storage?.nativeImportsDirectory(id).path ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}caw-native-imports${Platform.pathSeparator}$id';
    final unpacked = await _unpack(path, audioDir, binaryDir, deviceAbi);
    Future<void> discard() async {
      for (final (_, file, _) in unpacked.files) {
        try {
          await File(file).delete();
        } catch (_) {}
      }
      for (final b in unpacked.binaries) {
        try {
          await File(b.$4).delete();
        } catch (_) {}
      }
    }

    final ProjectDoc project;
    try {
      project = decodeProjectJson(jsonDecode(unpacked.projectJson));
    } catch (_) {
      await discard();
      rethrow;
    }
    if (confirm != null && !await confirm(project)) {
      await discard();
      return null;
    }
    result.notes.addAll(unpacked.notes);
    // Packaged C++ builds: only for this project's components with the sources they were built from.
    final manager = nativeComponents;
    for (final (component, name, fingerprint, file, sha) in unpacked.binaries) {
      final c = project.cppComponents.where((c) => c.componentId == component).firstOrNull;
      final binary = ImportedBinary(component, name, fingerprint, file, sha);
      var use = false;
      if (c != null && NativeTrustStore.sourceFingerprint(c) == fingerprint && manager != null) {
        final key = NativeComponentManager.importedLibraryKey(sha);
        final choice = manager.trust.decide(component, key) ?? await askBinaryTrust?.call(binary);
        if (choice == NativeComponentTrust.trusted) {
          await manager.adoptImportedBuild(component, fingerprint, file, sha);
          result.binaries.add(binary);
          use = true;
        } else if (choice == NativeComponentTrust.blocked) {
          manager.trust.remember(component, key, NativeComponentTrust.blocked);
          await manager.trust.save();
        }
      } else if (manager == null) {
        result.notes.add('$name was not used: this device doesn\'t load C++ builds.');
      }
      if (!use) {
        try {
          await File(file).delete();
        } catch (_) {}
      }
    }
    for (final text in unpacked.presets) {
      try {
        if (userPresets.importText(text) case final p?) result.presetsAdded.add(p.name);
      } catch (e) {
        result.notes.add('A preset was not added: $e');
      }
    }
    if (unpacked.theme case final text?) {
      try {
        result.theme = CawTheme.parse(text);
      } on FormatException {
        result.notes.add('The packaged theme is not readable.');
      }
    }
    knownFileHashes.addAll(unpacked.hashes);
    await importProject(project, id: id, prepare: (copy) {
      for (final (reference, file, _) in unpacked.files) {
        relinkProjectPath(copy, reference, file);
      }
    });
    result.filesUnpacked = unpacked.files.length;
    return result;
  }

  /// Re-links the missing file [missing] to a copy of [source] in the project's audio folder (Locate… and
  /// Replace…). With [verify] and a hash the package recorded, a different file is refused (FormatException).
  Future<void> relinkMissingFile(ProjectDependency missing, String source, {bool verify = true}) async {
    final from = missing.path;
    if (from == null) return;
    final expected = knownFileHashes[from];
    if (verify && expected != null) {
      final got = await _hashOffThread(source);
      if (got != expected) throw FormatException('${source.split(RegExp(r'[/\\]')).last} is not the file this project used.');
    }
    final dir = audioDirectory;
    await dir.create(recursive: true);
    final base = safeAudioName(source.split(RegExp(r'[/\\]')).last);
    var out = File('${dir.path}${Platform.pathSeparator}$base');
    for (var n = 2; await out.exists(); n++) {
      out = File('${dir.path}${Platform.pathSeparator}${base.replaceFirst(RegExp(r'(\.[^.]*)?$'), ' $n\$1')}');
    }
    final size = await File(source).length();
    if (size > PackageLimits.audioBytes) throw const FormatException('The file is over 1 GB.');
    await File(source).copy(out.path);
    editProject((p) => relinkProjectPath(p, from, out.path));
    knownFileHashes.remove(from);
    await checkMissingFiles();
  }
}
