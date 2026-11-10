// The Files browser's catalogue: every asset (built-in effects, C++ components and files, .caw modules, patterns), its folder tree, uses and edits.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../engine/component_info.dart';
import '../engine/engine.dart' show NativeComponentTrust;
import '../ui/frame/sections.dart';
import 'app_state.dart';
import 'arrange_fx.dart';
import 'cpp_component.dart';
import 'native_trust.dart';
import 'project.dart';

/// What an asset is. It decides the icon, the type badge, what a drag carries and what double-tap opens.
enum FileAssetType {
  builtinEffect, // part of the engine (org.caw.*): always there, read-only
  cppComponent,  // a project C++ component (an effect)
  cppFile,       // one source file of a project C++ component
  cawEffect,     // a .caw effect module
  cawGenerator,  // a .caw generator or synth
  cawLibrary,    // a .caw library module
  pattern,       // a .caw pattern (MIDI notes)
}

/// The search filters (icons in the toolbar): an asset passes when its group is on, or when none is on.
enum FileAssetFilter { effects, instruments, code, patterns }

extension FileAssetTypeInfo on FileAssetType {
  /// The short badge on the asset's icon.
  String get badge => switch (this) {
        FileAssetType.builtinEffect => 'FX',
        FileAssetType.cppComponent => 'C++',
        FileAssetType.cppFile => 'SRC',
        FileAssetType.cawEffect => 'FX',
        FileAssetType.cawGenerator => 'GEN',
        FileAssetType.cawLibrary => 'LIB',
        FileAssetType.pattern => 'MIDI',
      };

  String get label => switch (this) {
        FileAssetType.builtinEffect => 'Built-in effect',
        FileAssetType.cppComponent => 'C++ effect',
        FileAssetType.cppFile => 'C++ source file',
        FileAssetType.cawEffect => '.caw effect',
        FileAssetType.cawGenerator => '.caw instrument',
        FileAssetType.cawLibrary => '.caw library',
        FileAssetType.pattern => 'Pattern',
      };

  FileAssetFilter get filter => switch (this) {
        FileAssetType.builtinEffect || FileAssetType.cppComponent || FileAssetType.cawEffect => FileAssetFilter.effects,
        FileAssetType.cawGenerator => FileAssetFilter.instruments,
        FileAssetType.cppFile || FileAssetType.cawLibrary => FileAssetFilter.code,
        FileAssetType.pattern => FileAssetFilter.patterns,
      };
}

/// One item in the browser.
class FileAsset {
  FileAsset._(this.key, this.name, this.type, {this.module, this.cpp, this.filePath, this.native});

  /// Unique within the project; also the favourites key (built-ins are app-wide).
  final String key;
  final String name;
  final FileAssetType type;
  final ModuleDoc? module;
  final CppComponentDoc? cpp;
  final String? filePath;        // for a [FileAssetType.cppFile]
  final NativeComponentInfo? native;

  bool get builtin => type == FileAssetType.builtinEffect;

  /// What dragging it (or picking it in the asset picker) carries; null when it can't go on a track.
  AssetDrag? get drag => switch (type) {
        FileAssetType.builtinEffect => native!.role == 'instrument' || native!.role == 'generator'
            ? null
            : AssetDrag(AssetKind.nativeEffect, native!.id, name),
        FileAssetType.cppComponent => cpp!.componentId.isEmpty ? null : AssetDrag(AssetKind.nativeEffect, cpp!.componentId, name),
        FileAssetType.cawEffect || FileAssetType.cawGenerator => AssetDrag(AssetKind.cawModule, module!.id, name),
        FileAssetType.pattern => AssetDrag(AssetKind.pattern, module!.id, name),
        FileAssetType.cppFile || FileAssetType.cawLibrary => null,
      };

  /// The Build tab double-tap opens; null for built-ins (nothing to edit).
  BuildTab? get buildTab => switch (type) {
        FileAssetType.builtinEffect => null,
        FileAssetType.cppComponent || FileAssetType.cppFile => BuildTab(BuildTabKind.cpp, cpp!.componentId),
        _ => BuildTab(BuildTabKind.caw, module!.id),
      };

  /// A .caw module or pattern can be auditioned with Solo preview.
  bool get previewable => module != null && type != FileAssetType.cawLibrary;
}

/// What a folder holds. Folders are paths: `fav`, `fx`, `fx/builtin`, `fx/cpp`, `fx/caw`, `code`, `code/cpp`,
/// `code/cpp/<component entry id>`, `code/caw`, `code/caw/<library folder>`, `audio`, `audio/patterns`, `packs`.
enum FilesFolderKind { favourites, effects, builtin, cppEffects, cawEffects, code, cppList, cppComponent, cawModules,
  libraryFolder, audio, patterns, packs }

class FilesFolder {
  const FilesFolder(this.path, this.label, this.kind, [this.children = const []]);
  final String path;
  final String label;
  final FilesFolderKind kind;
  final List<FilesFolder> children;

  /// "New C++ effect" belongs in the effects and C++ folders.
  bool get offersNewCpp => const {FilesFolderKind.effects, FilesFolderKind.cppEffects, FilesFolderKind.code,
    FilesFolderKind.cppList}.contains(kind);

  /// "New .caw module" (and the kind it starts as): effects folders make effects, patterns folders patterns,
  /// code folders a blank generator.
  String? get newCawKind => switch (kind) {
        FilesFolderKind.effects || FilesFolderKind.cawEffects => 'effect',
        FilesFolderKind.code || FilesFolderKind.cawModules || FilesFolderKind.libraryFolder => 'generator',
        FilesFolderKind.audio || FilesFolderKind.patterns => 'pattern',
        _ => null,
      };

  /// The library folder path a new or imported module goes into ('' for none).
  String get libraryPath => kind == FilesFolderKind.libraryFolder ? path.substring('code/caw/'.length) : '';
}

/// Favourites, kept app-wide in `files-favourites.json` next to settings.json (in memory without a folder).
/// Built-ins are keyed by component id; project items by project id and their key.
class FilesFavourites {
  FilesFavourites(this.file);
  final File? file;
  final Set<String> keys = {};
  static const maxKeys = 1024;
  Future<void>? _loading;
  Future<void> _saving = Future.value();

  Future<void> load() => _loading ??= () async {
        try {
          final f = file;
          if (f == null || !await f.exists()) return;
          final j = jsonDecode(await f.readAsString());
          if (j is Map && j['favourites'] is List) {
            keys.addAll((j['favourites'] as List).whereType<String>().where((k) => k.length <= 400).take(maxKeys));
          }
        } catch (_) {
          // An unreadable file starts empty.
        }
      }();

  Future<void> save() {
    final f = file;
    if (f == null) return Future.value();
    final text = jsonEncode({'favourites': keys.toList()});
    return _saving = _saving.catchError((_) {}).then((_) async {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(f.path);
    });
  }
}

final Expando<FilesFavourites> _favourites = Expando('files favourites');
final Expando<List<NativeComponentInfo>> _natives = Expando('native catalogue');

extension FilesCatalog on AppState {
  // ---------- favourites ----------

  FilesFavourites get filesFavourites => _favourites[this] ??= FilesFavourites(
      settings.dir == null ? null : File('${settings.dir!.path}${Platform.pathSeparator}files-favourites.json'));

  String favouriteKey(FileAsset a) => a.builtin ? 'native:${a.native!.id}' : '${project.id}/${a.key}';

  bool isFavourite(FileAsset a) => filesFavourites.keys.contains(favouriteKey(a));

  void setFavourite(FileAsset a, bool on) {
    final f = filesFavourites;
    if (on && f.keys.length >= FilesFavourites.maxKeys) return;
    on ? f.keys.add(favouriteKey(a)) : f.keys.remove(favouriteKey(a));
    unawaited(f.save().catchError((_) {}));
  }

  // ---------- native components (built-ins) ----------

  /// The engine's native components last read (built-ins and loaded project C++ components); empty before.
  List<NativeComponentInfo> get nativeCatalog => _natives[this] ?? const [];

  /// Tests (and screens without an engine) set the list directly.
  set nativeCatalog(List<NativeComponentInfo> list) => _natives[this] = list;

  /// Reads the engine's native components again (off the UI isolate); keeps the last list without an engine.
  Future<List<NativeComponentInfo>> refreshNativeCatalog() async {
    final e = engine;
    if (e == null) return nativeCatalog;
    try {
      final list = await e.nativeComponents();
      _natives[this] = list;
      return list;
    } catch (_) {
      return nativeCatalog;
    }
  }

  NativeComponentInfo? nativeInfo(String componentId) =>
      nativeCatalog.where((c) => c.id == componentId).firstOrNull;

  // ---------- assets ----------

  FileAsset _moduleAsset(ModuleDoc m) {
    final type = isPattern(m.id)
        ? FileAssetType.pattern
        : isEffect(m.id)
            ? FileAssetType.cawEffect
            : isLibrary(m.id)
                ? FileAssetType.cawLibrary
                : FileAssetType.cawGenerator;
    return FileAsset._('mod:${m.id}', m.name, type, module: m);
  }

  List<FileAsset> get builtinAssets => [
        for (final c in nativeCatalog.where((c) => c.builtin))
          FileAsset._('native:${c.id}', c.label, FileAssetType.builtinEffect, native: c),
      ]..sort(_byName);

  List<FileAsset> get cppAssets => [
        for (final c in project.cppComponents)
          FileAsset._('cpp:${c.id}', c.name, FileAssetType.cppComponent, cpp: c, native: nativeInfo(c.componentId)),
      ]..sort(_byName);

  List<FileAsset> cppFileAssets(CppComponentDoc c) => [
        for (final path in c.files.keys.toList()..sort())
          FileAsset._('file:${c.id}/$path', path, FileAssetType.cppFile, cpp: c, filePath: path),
      ];

  List<FileAsset> get moduleAssets => [for (final m in project.modules) _moduleAsset(m)]..sort(_byName);

  /// Every asset once (search looks through these).
  List<FileAsset> get allAssets => [
        ...builtinAssets,
        ...cppAssets,
        for (final c in project.cppComponents) ...cppFileAssets(c),
        ...moduleAssets,
      ];

  FileAsset? assetByKey(String key) => allAssets.where((a) => a.key == key).firstOrNull;

  // ---------- folders ----------

  /// The tree: Favourites, Effects & instruments, Code, Audio & MIDI (Packs only when the app has any: none yet).
  List<FilesFolder> get filesTree {
    final libFolders = project.libraryFolders.toList()..sort();
    List<FilesFolder> libChildren(String parent) => [
          for (final f in libFolders)
            if ((parent.isEmpty ? !f.contains('/') : f.startsWith('$parent/') && !f.substring(parent.length + 1).contains('/')))
              FilesFolder('code/caw/$f', f.split('/').last, FilesFolderKind.libraryFolder, libChildren(f)),
        ];
    return [
      const FilesFolder('fav', 'Favourites', FilesFolderKind.favourites),
      const FilesFolder('fx', 'Effects & instruments', FilesFolderKind.effects, [
        FilesFolder('fx/builtin', 'Built-in', FilesFolderKind.builtin),
        FilesFolder('fx/cpp', 'My C++ effects', FilesFolderKind.cppEffects),
        FilesFolder('fx/caw', '.caw modules', FilesFolderKind.cawEffects),
      ]),
      FilesFolder('code', 'Code', FilesFolderKind.code, [
        FilesFolder('code/cpp', 'C++ components', FilesFolderKind.cppList, [
          for (final c in [...project.cppComponents]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())))
            FilesFolder('code/cpp/${c.id}', c.name, FilesFolderKind.cppComponent),
        ]),
        FilesFolder('code/caw', '.caw modules', FilesFolderKind.cawModules, libChildren('')),
      ]),
      const FilesFolder('audio', 'Audio & MIDI', FilesFolderKind.audio, [
        FilesFolder('audio/patterns', 'Patterns', FilesFolderKind.patterns),
      ]),
    ];
  }

  /// The folder at [path] with its ancestors (root first), or empty when it no longer exists.
  List<FilesFolder> folderTrail(String path) {
    List<FilesFolder>? walk(List<FilesFolder> level, List<FilesFolder> trail) {
      for (final f in level) {
        if (f.path == path) return [...trail, f];
        if (path.startsWith('${f.path}/')) {
          final found = walk(f.children, [...trail, f]);
          if (found != null) return found;
        }
      }
      return null;
    }

    return walk(filesTree, const []) ?? const [];
  }

  FilesFolder? folderAt(String path) => folderTrail(path).lastOrNull;

  /// The assets directly in [folder] (its subfolders are [FilesFolder.children]).
  List<FileAsset> folderAssets(FilesFolder folder) => switch (folder.kind) {
        FilesFolderKind.favourites => allAssets.where(isFavourite).toList(),
        FilesFolderKind.builtin => builtinAssets,
        FilesFolderKind.cppEffects => cppAssets,
        FilesFolderKind.cawEffects => moduleAssets
            .where((a) => a.type == FileAssetType.cawEffect || a.type == FileAssetType.cawGenerator)
            .toList(),
        FilesFolderKind.cppComponent => () {
            final c = project.cppComponents.where((c) => 'code/cpp/${c.id}' == folder.path).firstOrNull;
            return c == null ? <FileAsset>[] : cppFileAssets(c);
          }(),
        FilesFolderKind.cawModules =>
          moduleAssets.where((a) => a.module!.folderPath.isEmpty || !project.libraryFolders.contains(a.module!.folderPath)).toList(),
        FilesFolderKind.libraryFolder => moduleAssets.where((a) => a.module!.folderPath == folder.libraryPath).toList(),
        FilesFolderKind.patterns => moduleAssets.where((a) => a.type == FileAssetType.pattern).toList(),
        _ => const <FileAsset>[],
      };

  /// Every asset whose name, type or tags match [query], narrowed by [filters] (none on: all pass).
  List<FileAsset> searchAssets(String query, Set<FileAssetFilter> filters) {
    final q = query.trim().toLowerCase();
    return allAssets.where((a) => passes(a, filters) && (q.isEmpty || _matches(a, q))).toList();
  }

  bool passes(FileAsset a, Set<FileAssetFilter> filters) => filters.isEmpty || filters.contains(a.type.filter);

  bool _matches(FileAsset a, String q) =>
      a.name.toLowerCase().contains(q) ||
      a.type.label.toLowerCase().contains(q) ||
      (a.native?.id.toLowerCase().contains(q) ?? false) ||
      (a.module?.tags.any((t) => t.toLowerCase().contains(q)) ?? false);

  // ---------- uses ----------

  /// The tracks (by name; "Master" for the master chain) that use [a].
  List<String> usesOf(FileAsset a) {
    final out = <String>[];
    final componentId = a.native?.id ?? a.cpp?.componentId;
    if (a.type == FileAssetType.builtinEffect || a.type == FileAssetType.cppComponent) {
      if (componentId == null || componentId.isEmpty) return out;
      for (final l in project.layers) {
        if (l.components.any((c) => c.id == componentId)) out.add(l.name);
      }
      if (project.masterComponents.any((c) => c.id == componentId)) out.add('Master');
    } else if (a.module != null) {
      final id = a.module!.id;
      for (final l in project.layers) {
        if (l.generatorId == id || l.effectIds.contains(id) || l.patternId == id || l.clips.any((c) => c.patternId == id)) {
          out.add(l.name);
        }
      }
    }
    return out;
  }

  /// Build state of a project C++ component: null when it is loaded and playing, else a short reason.
  String? cppStatus(CppComponentDoc c) {
    final s = nativeStatus;
    final id = c.componentId;
    if (s != null && s.loaded.contains(id)) return null;
    if (nativeCatalog.any((n) => n.id == id)) return null;
    if (s != null && s.needsTrust.any((x) => x.componentId == id)) return 'Needs trust';
    if (s != null && s.blocked.contains(id)) return 'Blocked';
    if (s != null && s.buildFailed.containsKey(id)) return 'Build failed';
    if (s != null && s.loadFailed.containsKey(id)) return 'Load failed';
    return 'Not built';
  }

  // ---------- edits ----------

  String _freeName(String base, Iterable<String> taken) {
    final names = taken.toSet();
    if (!names.contains(base)) return base;
    var n = 2;
    while (names.contains('$base $n')) {
      n++;
    }
    return '$base $n';
  }

  /// Adds a blank pass-through C++ effect to the project, or with [instrument] a blank instrument (the user's own
  /// code: trusted on this device).
  CppComponentDoc addBlankCppEffect({String base = 'New effect', bool instrument = false}) {
    final name = _freeName(base, project.cppComponents.map((c) => c.name));
    final doc = instrument
        ? CppComponentDoc.blankInstrument(id: newId('cpp'), name: name)
        : CppComponentDoc.blankEffect(id: newId('cpp'), name: name);
    editProject((p) => p.cppComponents.add(doc));
    _markAuthored(doc);
    return doc;
  }

  void _markAuthored(CppComponentDoc doc) {
    final trust = nativeComponents?.trust;
    if (trust == null) return;
    trust.markAuthored(doc);
    unawaited(trust.save().catchError((_) {}));
  }

  void renameAsset(FileAsset a, String name) {
    final next = name.trim();
    if (next.isEmpty) return;
    switch (a.type) {
      case FileAssetType.builtinEffect:
        return;
      case FileAssetType.cppComponent:
        editProject((_) => a.cpp!.name = next);
      case FileAssetType.cppFile:
        final c = a.cpp!;
        final from = a.filePath!;
        if (next == from || !CppComponentDoc.isSafeRelativePath(next) || c.files.containsKey(next)) return;
        editProject((_) {
          final text = c.files.remove(from) ?? '';
          c.files[next] = text;
        });
      default:
        renameModule(a.module!.id, next);
    }
  }

  /// True when [name] is free and safe for a file of [c].
  bool canNameFile(CppComponentDoc c, String name) => CppComponentDoc.isSafeRelativePath(name) && !c.files.containsKey(name);

  /// Copies [a] under a free name; returns the copy's key (null for built-ins).
  String? duplicateAsset(FileAsset a) {
    switch (a.type) {
      case FileAssetType.builtinEffect:
        return null;
      case FileAssetType.cppComponent:
        final src = a.cpp!;
        final name = _freeName('${src.name} copy', project.cppComponents.map((c) => c.name));
        final shape = CppComponentDoc.blankEffect(id: newId('cpp'), name: name);
        final old = src.componentId;
        final copy = CppComponentDoc(
          id: shape.id,
          name: name,
          componentId: shape.componentId,
          files: {
            // Only the quoted id (the manifest's and the descriptor's), so a short id can't change other code.
            for (final e in src.files.entries)
              e.key: old.isEmpty ? e.value : e.value.replaceAll('"$old"', '"${shape.componentId}"'),
          },
          dependencies: {...src.dependencies},
        );
        editProject((p) => p.cppComponents.add(copy));
        // A copy is the user's own code only when the original already was trusted: duplicating code from elsewhere
        // must not get round its Trust / Block question (security review, 2026-11-10).
        final trust = nativeComponents?.trust;
        if (trust != null &&
            trust.decide(src.componentId, NativeTrustStore.sourceFingerprint(src)) == NativeComponentTrust.trusted) {
          _markAuthored(copy);
        }
        return 'cpp:${copy.id}';
      case FileAssetType.cppFile:
        final c = a.cpp!;
        final path = a.filePath!;
        final dot = path.lastIndexOf('.');
        final stem = dot > path.lastIndexOf('/') && dot > 0 ? path.substring(0, dot) : path;
        final ext = stem == path ? '' : path.substring(dot);
        var n = 2;
        var next = '${stem}_copy$ext';
        while (c.files.containsKey(next)) {
          next = '${stem}_copy${n++}$ext';
        }
        editProject((_) => c.files[next] = c.files[path] ?? '');
        return 'file:${c.id}/$next';
      default:
        final m = a.module!;
        final copy = ModuleDoc(
          id: newId('m'),
          name: _freeName('${m.name} copy', project.modules.map((x) => x.name)),
          source: m.source,
          runSource: m.runSource,
          params: {...m.params},
          folderPath: m.folderPath,
          tags: [...m.tags],
        );
        final kind = blankKinds[m.id];
        if (kind != null) blankKinds[copy.id] = kind;
        if (info[m.id] != null) info[copy.id] = info[m.id]!;
        editProject((p) => p.modules.insert(p.modules.indexOf(m) + 1, copy));
        return 'mod:${copy.id}';
    }
  }

  /// Deletes [a] and removes it from every track using it. Built-ins can't be deleted.
  void deleteAsset(FileAsset a) {
    switch (a.type) {
      case FileAssetType.builtinEffect:
        return;
      case FileAssetType.cppComponent:
        final id = a.cpp!.componentId;
        editProject((p) {
          p.cppComponents.remove(a.cpp);
          if (id.isNotEmpty && !p.cppComponents.any((c) => c.componentId == id)) {
            for (final l in p.layers) {
              final before = List.of(l.components);
              l.components.removeWhere((c) => c.id == id);
              followComponentLanes(p, l.id, before);
            }
            final before = List.of(p.masterComponents);
            p.masterComponents.removeWhere((c) => c.id == id);
            followComponentLanes(p, null, before);
          }
        });
      case FileAssetType.cppFile:
        editProject((_) => a.cpp!.files.remove(a.filePath));
      default:
        deleteModule(a.module!.id);
    }
    if (filesFavourites.keys.remove(favouriteKey(a))) unawaited(filesFavourites.save().catchError((_) {}));
  }

  /// Whether a Build tab still has something to edit (for SectionController.pruneBuild).
  bool buildTabExists(BuildTab tab) => tab.kind == BuildTabKind.cpp
      ? project.cppComponents.any((c) => c.componentId == tab.id)
      : project.module(tab.id) != null;
}

int _byName(FileAsset a, FileAsset b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
