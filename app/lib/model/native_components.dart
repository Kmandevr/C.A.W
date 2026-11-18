// Gets a project's C++ components ready to play: trust rules, an in-app build (or a cached one), then a load.
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../engine/engine.dart';
import '../platform/cpp_build.dart';
import '../platform/cpp_compiler.dart';
import 'cpp_component.dart';
import 'native_trust.dart';
import 'project.dart';
import 'storage.dart';
import 'atomic_file.dart';

/// Loads a built library into the engine (Engine.loadNativeComponent); a function, so tests can stand in for it.
typedef NativeLoad = Future<NativeComponentLoadResult> Function(
    {required String artifactPath,
    required String expectedComponentId,
    required NativeComponentTrust trust,
    bool reload,
    String? legacyGraceSha256});

/// The pre-load scan of a built library (Engine.scanNativeComponent); a function, so tests can stand in for it.
typedef NativeScan = Future<ComponentScan> Function(String artifactPath,
    {String? expectedComponentId, String? legacyGraceSha256});

/// The manager for this device, or null where the app has no in-app compiler. Its files are app-private.
Future<NativeComponentManager?> deviceNativeComponentManager(Engine engine, ProjectStorage storage) async {
  final compiler = platformCppCompiler();
  if (compiler == null) return null;
  final dir = await getApplicationSupportDirectory();
  final trust = NativeTrustStore(File('${dir.path}/native-trust.json'));
  await trust.load();
  final service = CppComponentBuildService(storage);
  final builder = CppSourceBuilder(compiler);
  final manager = NativeComponentManager(
    trust: trust,
    cacheFile: File('${dir.path}/native-builds.json'),
    build: (project, component) => service.buildInApp(project: project, component: component, builder: builder),
    load: engine.loadNativeComponent,
    scan: engine.scanNativeComponent,
  );
  await manager.migrateLegacyTrust();
  return manager;
}

/// What [NativeComponentManager.prepare] found for each of the project's components.
class NativeComponentsStatus {
  final List<String> loaded = [];                 // component ids now playable
  final List<CppComponentDoc> needsTrust = [];    // from elsewhere and not decided yet: the UI asks Trust / Block
  final List<String> blocked = [];                // the user blocked this code
  final Map<String, CppBuildResult> buildFailed = {};
  final Map<String, String> loadFailed = {};
  final Set<String> graceApplied = {};            // loaded under legacy grace: built before 1.0.7, warn until rebuilt

  bool get ready => needsTrust.isEmpty && buildFailed.isEmpty && loadFailed.isEmpty;
}

/// Builds and loads a project's C++ components, following the owner's trust rules (`NativeTrustStore`). A build
/// is reused while its sources are unchanged (cached by source fingerprint), so opening a project doesn't
/// rebuild everything. A component already loaded from other sources is reloaded (it switches while playing).
class NativeComponentManager {
  NativeComponentManager({required this.trust, required this.build, required this.load, required this.cacheFile, this.scan});

  final NativeTrustStore trust;

  /// The pre-load scan, for the trust sheet; null where there is none (tests).
  final NativeScan? scan;
  /// Builds one of [project]'s components (it saves the project and materializes the sources first).
  final Future<CppBuildResult> Function(ProjectDoc project, CppComponentDoc component) build;
  final NativeLoad load;

  /// App-private JSON: {component id: {source fingerprint: artifact path}}.
  final File cacheFile;
  final Map<String, String> _loadedFingerprint = {};  // component id -> fingerprint of what the engine has
  final Map<String, String> _loadedArtifact = {};     // component id -> the library file the engine loaded
  final Map<String, String> _loadedLibraryKey = {};   // component id -> an imported build's trust key ('library:...')
  final Set<String> _engineHas = {};                  // ids the engine has loaded at some point (the next load reloads)
  Map<String, Map<String, String>>? _cache;

  /// Every component id the engine has loaded, for ProjectDoc.toEngineJson(playableComponents:).
  Set<String> get loaded => _loadedFingerprint.keys.toSet();

  /// The library file the engine loaded for component [id] (the Build tools test and render it), or null.
  String? artifactOf(String id) => _loadedArtifact[id];

  /// Whether [component]'s code is Trusted now (its current sources; and, for a packaged build the engine loaded for
  /// it, that file too). The plug-in benchmark asks this when it lists a plug-in and again when it starts one, so a
  /// Block or a forgotten choice stops it at once.
  bool benchTrusted(CppComponentDoc component) {
    final id = component.componentId;
    if (id.isEmpty) return false;
    if (trust.decide(id, NativeTrustStore.sourceFingerprint(component)) != NativeComponentTrust.trusted) return false;
    final library = _loadedLibraryKey[id];
    return library == null || trust.decide(id, library) == NativeComponentTrust.trusted;
  }

  // What the engine has of [id] is no longer playable or benchable here (blocked, or the choice forgotten).
  void _forgetLoaded(String id) {
    _loadedFingerprint.remove(id);
    _loadedArtifact.remove(id);
    _loadedLibraryKey.remove(id);
  }

  /// Gets [project]'s components playable. [buildMissing] false loads only builds made already (launch: a build
  /// waits until the app is open); [onProgress] hears how many of the components with an id are done so far.
  Future<NativeComponentsStatus> prepare(ProjectDoc project,
      {bool buildMissing = true, void Function(int done)? onProgress}) async {
    final status = NativeComponentsStatus();
    final cache = await _readCache();
    var done = 0;
    for (final component in project.cppComponents) {
      final id = component.componentId;
      if (id.isEmpty) continue;
      if (done > 0) onProgress?.call(done);
      done++;
      final fingerprint = NativeTrustStore.sourceFingerprint(component);
      final choice = trust.decide(id, fingerprint);
      if (choice == null) {
        _forgetLoaded(id);
        status.needsTrust.add(component);
        continue;
      }
      if (choice == NativeComponentTrust.blocked) {
        _forgetLoaded(id);
        status.blocked.add(id);
        continue;
      }
      if (_loadedFingerprint[id] == fingerprint) {
        status.loaded.add(id);
        continue;
      }
      var artifact = cache[id]?[fingerprint];
      // A build that came in a project package loads only while the user's Trust for exactly that file stands.
      if (artifact != null && isImportedBuild(artifact) && await File(artifact).exists() &&
          trust.decide(id, importedLibraryKey(await NativeTrustStore.libraryFingerprint(artifact))) !=
              NativeComponentTrust.trusted) {
        cache[id]!.remove(fingerprint);
        artifact = null;
      }
      if (artifact == null || !await File(artifact).exists()) {
        if (!buildMissing) continue;
        final result = await build(project, component);
        if (!result.success || result.artifactPath == null) {
          status.buildFailed[id] = result;
          continue;
        }
        artifact = result.artifactPath!;
        (cache[id] ??= {})[fingerprint] = artifact;
        await _writeCache(cache);
      }
      final reload = _engineHas.contains(id);
      // Hashed only when it is needed: a packaged build's trust key, or a component with builds trusted before 1.0.7.
      final sha = isImportedBuild(artifact) || trust.hasLegacy(id) ? await NativeTrustStore.libraryFingerprint(artifact) : null;
      final libraryKey = isImportedBuild(artifact) ? importedLibraryKey(sha!) : null;
      final loaded = await load(artifactPath: artifact, expectedComponentId: id, trust: choice, reload: reload,
          legacyGraceSha256: sha == null ? null : trust.legacyTrusted(id, sha));
      if (loaded.ok) {
        if (loaded.graceApplied) status.graceApplied.add(id);
        _engineHas.add(id);
        _loadedFingerprint[id] = fingerprint;
        _loadedArtifact[id] = artifact;
        if (libraryKey != null) {
          _loadedLibraryKey[id] = libraryKey;
        } else {
          _loadedLibraryKey.remove(id);
        }
        status.loaded.add(id);
      } else {
        status.loadFailed[id] = loaded.error;
      }
    }
    if (done > 0) onProgress?.call(done);
    return status;
  }

  /// Once, on the first start of 1.0.7 or later over an older store: every build the user trusted then (this
  /// device's builds of trusted sources, and packaged builds trusted as files) is recorded by its SHA-256, so it
  /// keeps loading with legacy grace until it is rebuilt (owner, 2026-11-18).
  Future<void> migrateLegacyTrust() async {
    if (!trust.needsLegacyMigration) return;
    final builds = <(String, String)>[];
    for (final MapEntry(key: id, value: map) in (await _readCache()).entries) {
      for (final MapEntry(key: fingerprint, value: path) in map.entries) {
        if (trust.decide(id, fingerprint) != NativeComponentTrust.trusted) continue;
        try {
          final sha = await NativeTrustStore.libraryFingerprint(path);
          if (isImportedBuild(path) && trust.decide(id, importedLibraryKey(sha)) != NativeComponentTrust.trusted) continue;
          builds.add((id, sha));
        } on FileSystemException {
          // Gone: a rebuild follows, under the scan's rules.
        }
      }
    }
    trust.finishLegacyMigration(builds);
    await trust.save();
  }

  /// The pre-load scan of [component]'s build on this device for its current sources, with legacy grace when the
  /// user trusted that exact build before 1.0.7; null when there is no build yet or no scan here.
  Future<ComponentScan?> scanBuild(CppComponentDoc component) async {
    final s = scan;
    final path = await builtArtifact(component);
    if (s == null || path == null) return null;
    final sha = await NativeTrustStore.libraryFingerprint(path);
    return s(path, expectedComponentId: component.componentId,
        legacyGraceSha256: trust.legacyTrusted(component.componentId, sha));
  }

  /// The trust store's key for a built library that came in a package: its own fingerprint, apart from its sources'.
  static String importedLibraryKey(String sha256) => 'library:$sha256';

  /// Whether [path] is a build unpacked from a package (ProjectStorage.nativeImportsDirectory), not one made here.
  static bool isImportedBuild(String path) => path.replaceAll('\\', '/').contains('/native-imports/');

  /// This device's build of [component]'s current sources, if there is one (the export packages it).
  Future<String?> builtArtifact(CppComponentDoc component) async {
    final path = (await _readCache())[component.componentId]?[NativeTrustStore.sourceFingerprint(component)];
    return path != null && await File(path).exists() ? path : null;
  }

  /// A packaged build of [componentId] (for sources with [sourceFingerprint]) the user chose to trust: the choice
  /// is remembered for that file's fingerprint, and the build is used instead of building those sources here.
  Future<void> adoptImportedBuild(String componentId, String sourceFingerprint, String path, String sha256) async {
    trust.remember(componentId, importedLibraryKey(sha256), NativeComponentTrust.trusted);
    await trust.save();
    final cache = await _readCache();
    (cache[componentId] ??= {})[sourceFingerprint] = path;
    await _writeCache(cache);
  }

  Future<Map<String, Map<String, String>>> _readCache() async {
    final known = _cache;
    if (known != null) return known;
    final cache = <String, Map<String, String>>{};
    try {
      final j = jsonDecode(await cacheFile.readAsString());
      if (j is Map) {
        j.forEach((id, builds) {
          if (id is String && builds is Map) {
            cache[id] = {
              for (final e in builds.entries)
                if (e.key is String && e.value is String) e.key as String: e.value as String,
            };
          }
        });
      }
    } on FileSystemException {
      // No builds yet.
    } on FormatException {
      // A damaged cache only costs a rebuild.
    }
    return _cache = cache;
  }

  Future<void> _writeCache(Map<String, Map<String, String>> cache) async {
    // Only builds that still exist (CppSourceBuilder keeps the newest two per component).
    for (final builds in cache.values) {
      builds.removeWhere((_, path) => !File(path).existsSync());
    }
    await cacheFile.parent.create(recursive: true);
    await writeFileAtomically(cacheFile, jsonEncode(cache), flush: false);
  }
}
