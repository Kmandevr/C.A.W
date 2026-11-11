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

/// Loads a built library into the engine (Engine.loadNativeComponent); a function, so tests can stand in for it.
typedef NativeLoad = Future<NativeComponentLoadResult> Function(
    {required String artifactPath, required String expectedComponentId, required NativeComponentTrust trust, bool reload});

/// The manager for this device, or null where the app has no in-app compiler. Its files are app-private.
Future<NativeComponentManager?> deviceNativeComponentManager(Engine engine, ProjectStorage storage) async {
  final compiler = platformCppCompiler();
  if (compiler == null) return null;
  final dir = await getApplicationSupportDirectory();
  final trust = NativeTrustStore(File('${dir.path}/native-trust.json'));
  await trust.load();
  final service = CppComponentBuildService(storage);
  final builder = CppSourceBuilder(compiler);
  return NativeComponentManager(
    trust: trust,
    cacheFile: File('${dir.path}/native-builds.json'),
    build: (project, component) => service.buildInApp(project: project, component: component, builder: builder),
    load: engine.loadNativeComponent,
  );
}

/// What [NativeComponentManager.prepare] found for each of the project's components.
class NativeComponentsStatus {
  final List<String> loaded = [];                 // component ids now playable
  final List<CppComponentDoc> needsTrust = [];    // from elsewhere and not decided yet: the UI asks Trust / Block
  final List<String> blocked = [];                // the user blocked this code
  final Map<String, CppBuildResult> buildFailed = {};
  final Map<String, String> loadFailed = {};

  bool get ready => needsTrust.isEmpty && buildFailed.isEmpty && loadFailed.isEmpty;
}

/// Builds and loads a project's C++ components, following the owner's trust rules (`NativeTrustStore`). A build
/// is reused while its sources are unchanged (cached by source fingerprint), so opening a project doesn't
/// rebuild everything. A component already loaded from other sources is reloaded (it switches while playing).
class NativeComponentManager {
  NativeComponentManager({required this.trust, required this.build, required this.load, required this.cacheFile});

  final NativeTrustStore trust;
  /// Builds one of [project]'s components (it saves the project and materializes the sources first).
  final Future<CppBuildResult> Function(ProjectDoc project, CppComponentDoc component) build;
  final NativeLoad load;

  /// App-private JSON: {component id: {source fingerprint: artifact path}}.
  final File cacheFile;
  final Map<String, String> _loadedFingerprint = {};  // component id -> fingerprint of what the engine has
  final Map<String, String> _loadedArtifact = {};     // component id -> the library file the engine loaded
  Map<String, Map<String, String>>? _cache;

  /// Every component id the engine has loaded, for ProjectDoc.toEngineJson(playableComponents:).
  Set<String> get loaded => _loadedFingerprint.keys.toSet();

  /// The library file the engine loaded for component [id] (the Build tools test and render it), or null.
  String? artifactOf(String id) => _loadedArtifact[id];

  Future<NativeComponentsStatus> prepare(ProjectDoc project) async {
    final status = NativeComponentsStatus();
    final cache = await _readCache();
    for (final component in project.cppComponents) {
      final id = component.componentId;
      if (id.isEmpty) continue;
      final fingerprint = NativeTrustStore.sourceFingerprint(component);
      final choice = trust.decide(id, fingerprint);
      if (choice == null) {
        status.needsTrust.add(component);
        continue;
      }
      if (choice == NativeComponentTrust.blocked) {
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
        final result = await build(project, component);
        if (!result.success || result.artifactPath == null) {
          status.buildFailed[id] = result;
          continue;
        }
        artifact = result.artifactPath!;
        (cache[id] ??= {})[fingerprint] = artifact;
        await _writeCache(cache);
      }
      final reload = _loadedFingerprint.containsKey(id);
      final loaded = await load(artifactPath: artifact, expectedComponentId: id, trust: choice, reload: reload);
      if (loaded.ok) {
        _loadedFingerprint[id] = fingerprint;
        _loadedArtifact[id] = artifact;
        status.loaded.add(id);
      } else {
        status.loadFailed[id] = loaded.error;
      }
    }
    return status;
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
    final tmp = File('${cacheFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(cache));
    await tmp.rename(cacheFile.path);
  }
}
