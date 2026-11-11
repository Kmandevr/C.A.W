// One open C++ effect in the Builder: its files, autosave, the live check, completion, Build, versions and tests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/component_info.dart';
import '../engine/engine.dart';
import '../platform/cpp_build.dart';
import '../platform/cpp_compiler.dart';
import 'app_state.dart';
import 'cpp_starters.dart';
import 'arrange_fx.dart';
import 'cpp_completion.dart';
import 'cpp_component.dart';
import 'cpp_diagnostics.dart';
import 'cpp_versions.dart';
import 'native_trust.dart';
import 'project.dart';

/// What the Builder runs on: the in-app compiler (null on desktop), an app-private work directory for checks and
/// versions, and the desktop build (local CMake) where there is no in-app compiler.
class CppBuilderServices {
  CppBuilderServices({required this.compiler, required this.workDirectory, this.desktopBuild});

  final CppCompiler? compiler;
  final Future<Directory> Function() workDirectory;

  /// Builds [component] into a loadable library with local tools; null result: no tools on this computer.
  final Future<CppBuildResult?> Function(AppState state, CppComponentDoc component)? desktopBuild;

  static CppBuilderServices device() => CppBuilderServices(
        compiler: platformCppCompiler(),
        workDirectory: () async => Directory('${(await getApplicationSupportDirectory()).path}/cpp-builder'),
        desktopBuild: _desktopCMakeBuild,
      );
}

/// The desktop path: `cmake` on PATH and the installed SDK in `CAW_SDK_DIR` (CppComponentBuildService).
Future<CppBuildResult?> _desktopCMakeBuild(AppState state, CppComponentDoc component) async {
  final storage = state.storage;
  final sdk = Platform.environment['CAW_SDK_DIR'];
  if (storage == null || sdk == null || sdk.isEmpty) return null;
  try {
    final probe = await Process.run('cmake', ['--version']);
    if (probe.exitCode != 0) return null;
  } on ProcessException {
    return null;
  }
  return CppComponentBuildService(storage).build(
    project: state.project,
    component: component,
    cmakeExecutable: 'cmake',
    sdkDirectory: sdk,
    parallelJobs: Platform.numberOfProcessors.clamp(1, 8),
  );
}

enum CppBuildPhase { idle, building, built, failed }

/// Where an effect plays: a track's chain (layer) or the master's (layer null), at [index] in the project's list.
class CppEffectUse {
  const CppEffectUse(this.layer, this.index, this.use);
  final LayerDoc? layer;
  final int index;
  final ComponentUseDoc use;
}

final _trustSaves = Expando<Future<void>>('trust saves');

/// Saves the trust store after any save already running (two at once would race on its temporary file).
Future<void> _saveTrust(NativeTrustStore trust) {
  final next = (_trustSaves[trust] ?? Future<void>.value()).then((_) => trust.save()).catchError((Object _) {});
  _trustSaves[trust] = next;
  return next;
}

final _workbenches = Expando<Map<String, CppWorkbench>>('cpp workbenches');
final _services = Expando<CppBuilderServices>('cpp services');

extension CppBuilderState on AppState {
  CppBuilderServices get cppServices => _services[this] ??= CppBuilderServices.device();
  set cppServices(CppBuilderServices s) => _services[this] = s;

  /// The project's C++ component a Build tab names: by its component id, or its entry id.
  CppComponentDoc? cppComponent(String id) =>
      project.cppComponents.where((c) => c.componentId == id).firstOrNull ??
      project.cppComponents.where((c) => c.id == id).firstOrNull;

  /// The open session of a component (by entry id), kept while the app runs so each file's undo survives tab
  /// switches.
  CppWorkbench cppWorkbench(String entryId) =>
      // Per project too: a duplicated or imported project keeps entry ids, and its code is its own.
      (_workbenches[this] ??= {}).putIfAbsent('${project.id}/$entryId', () => CppWorkbench(this, entryId));

  /// Saves every open session's code now (the app going to the background, or quitting).
  Future<void> saveCppWorkbenches() async {
    for (final w in (_workbenches[this] ?? const <String, CppWorkbench>{}).values) {
      await w.save();
    }
  }

  /// A new effect from the blank pass-through template (or, with [instrument], a new instrument from the blank
  /// polyphonic sine), added to the project; it is the user's own code.
  CppComponentDoc newCppEffect({String? name, bool instrument = false}) {
    final base = instrument ? 'My instrument' : 'My effect';
    var n = name ?? base;
    if (name == null) {
      var k = 1;
      while (project.cppComponents.any((c) => c.name == n)) {
        n = '$base ${++k}';
      }
    }
    final doc = instrument
        ? CppComponentDoc.blankInstrument(id: newId('cpp'), name: n)
        : CppComponentDoc.blankEffect(id: newId('cpp'), name: n);
    editProject((p) => p.cppComponents.add(doc));
    cppWorkbench(doc.id).own = true;
    final trust = nativeComponents?.trust;
    if (trust != null) {
      trust.markAuthored(doc);
      unawaited(_saveTrust(trust));
    }
    return doc;
  }

  /// A copy of a bundled C++ starter (examples/cpp/starters), added to the project under a free name. It ships
  /// with the app like the blank templates, so it is the user's own code from here on.
  CppComponentDoc addCppStarter(CppStarter starter) {
    var n = starter.name;
    var k = 1;
    while (project.cppComponents.any((c) => c.name == n)) {
      n = '${starter.name} ${++k}';
    }
    final doc = starter.copy(id: newId('cpp'), displayName: n);
    editProject((p) => p.cppComponents.add(doc));
    cppWorkbench(doc.id).own = true;
    final trust = nativeComponents?.trust;
    if (trust != null) {
      trust.markAuthored(doc);
      unawaited(_saveTrust(trust));
    }
    return doc;
  }
}

/// The session behind one C++ editor tab. Code lives in [texts] while editing and autosaves into the project
/// component after a pause, without a project undo step (code undo is per file, in the editor). A project undo
/// that restores older code doesn't take the code back: the editor's text is written into the restored project.
class CppWorkbench extends ChangeNotifier {
  CppWorkbench(this.state, this.entryId, {this.saveDelay = const Duration(milliseconds: 800), this.checkDelay = const Duration(seconds: 1)}) {
    final c = state.project.cppComponents.where((c) => c.id == entryId).firstOrNull;
    _project = state.project;
    if (c != null) {
      texts.addAll(c.files);
      componentId = c.componentId;
      final trust = state.nativeComponents?.trust;
      own = trust != null && trust.decide(c.componentId, NativeTrustStore.sourceFingerprint(c)) == NativeComponentTrust.trusted;
    }
    currentFile = fileOrder.firstWhere((f) => f.endsWith('.cpp'), orElse: () => fileOrder.firstOrNull ?? 'src/effect.cpp');
    state.addListener(_onState);
  }

  final AppState state;
  final String entryId;
  Duration saveDelay, checkDelay;
  String componentId = '';

  /// The user's own code (written here, or code from elsewhere they chose to trust and edit): it builds and
  /// loads without asking.
  bool own = false;

  final Map<String, String> texts = {};
  late String currentFile;

  /// Bumped when files change from outside the editor (a version restored): the editor reloads them.
  int revision = 0;

  List<CppDiagnostic> diagnostics = const [];
  bool checking = false;
  /// One line about live checks (no in-app compiler, compiler unavailable); null when they run.
  String? checkNote;

  CppBuildPhase phase = CppBuildPhase.idle;
  String? buildMessage;
  int builds = 0;

  /// The built effect's descriptor while it is loaded (its knobs), null before the first build.
  NativeComponentInfo? info;

  String? _artifact;

  /// The library file of the last build this session, else the one the engine loaded (the Build tools' test and
  /// sample-pack renders load it again); null before a build.
  String? get artifactPath => _artifact ?? state.nativeComponents?.artifactOf(componentId);

  /// The build before the last one, while its library file is a different file that still exists (the testing
  /// suite's "previous build" comparison).
  String? previousArtifactPath;

  /// Sets the last build's library file without building (widget tests of the Build tools).
  @visibleForTesting
  set debugArtifactPath(String path) => _artifact = path;

  Timer? _saveTimer, _checkTimer;
  int _editGeneration = 0;
  bool _dirty = false;
  late ProjectDoc _project;

  /// Code from elsewhere the user hasn't trusted yet: the compiler doesn't read it at all (no check, no completion),
  /// so an include can't show app-private files; Build asks first.
  bool get _untrusted {
    if (own) return false;
    final trust = state.nativeComponents?.trust;
    final c = component;
    if (trust == null || c == null) return false;
    return trust.decide(c.componentId, NativeTrustStore.sourceFingerprint(c)) != NativeComponentTrust.trusted;
  }
  int _workspaces = 0;

  Future<void> _removeWorkspace(String path) async {
    try {
      await Directory(path).delete(recursive: true);
    } on FileSystemException {
      // Left for the next run's clean-up.
    }
  }
  bool _disposed = false;

  CppComponentDoc? get component => state.project.cppComponents.where((c) => c.id == entryId).firstOrNull;

  String get name => component?.name ?? 'C++ effect';

  /// The manifest's sources first, then the other files in name order.
  List<String> get fileOrder {
    final sources = _manifest()?.sources ?? const <String>[];
    final rest = texts.keys.where((f) => !sources.contains(f)).toList()..sort();
    return [...sources.where(texts.containsKey), ...rest];
  }

  int get errorCount => diagnostics.where((d) => d.isError).length;
  int get warningCount => diagnostics.length - errorCount;

  CppComponentManifest? _manifest() {
    try {
      return CppComponentManifest.parse(texts['caw-component.json'] ?? '');
    } on FormatException {
      return null;
    }
  }

  void _onState() {
    if (_disposed) return;
    if (!identical(state.project, _project)) {
      final same = state.project.id == _project.id;
      _project = state.project;
      // Another project opened: this session belongs to the old one and leaves the new one alone.
      if (!same) return;
      final c = component;
      if (c == null) return;
      // A project undo or redo replaced the project: the editor's code stays (it has its own undo).
      if (c.files.length != texts.length || c.files.entries.any((e) => texts[e.key] != e.value)) {
        c.files
          ..clear()
          ..addAll(texts);
        unawaited(state.flush());
      }
    }
  }

  void selectFile(String path) {
    if (!texts.containsKey(path) || currentFile == path) return;
    currentFile = path;
    notifyListeners();
  }

  /// Adds a new file (plain text, a header, JSON...) to the component and opens it; false for an unsafe path or
  /// one that exists. It is saved with the rest after a pause.
  bool addFile(String path, [String text = '']) {
    if (!CppComponentDoc.isSafeRelativePath(path) || texts.containsKey(path)) return false;
    texts[path] = text;
    currentFile = path;
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () => unawaited(save()));
    notifyListeners();
    return true;
  }

  /// The editor's text of [path] changed: autosave and a check follow after a pause.
  void edit(String path, String text) {
    if (texts[path] == text) return;
    texts[path] = text;
    _dirty = true;
    _editGeneration++;
    if (phase == CppBuildPhase.built || phase == CppBuildPhase.failed) phase = CppBuildPhase.idle;
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () => unawaited(save()));
    _checkTimer?.cancel();
    _checkTimer = Timer(checkDelay, () => unawaited(check()));
  }

  /// Whether a check is waiting for typing to pause.
  bool get checkScheduled => _checkTimer?.isActive ?? false;

  /// Writes the editor's code into the project component and saves the project (no project undo step).
  Future<void> save() async {
    _saveTimer?.cancel();
    if (state.project.id != _project.id) return; // another project is open now
    final c = component;
    if (c == null || !_dirty) return;
    _dirty = false;
    c.files
      ..clear()
      ..addAll(texts);
    final trust = state.nativeComponents?.trust;
    if (own && trust != null) {
      trust.markAuthored(c);
      unawaited(_saveTrust(trust));
    }
    await state.flush();
  }

  // The check workspace: this component's current code, written fresh for each check or completion.
  // Each request gets its own folder (removed after it), so a check and a completion never rewrite each other's
  // files while the compiler reads them.
  Future<String> _writeWorkspace(String kind) async {
    final root = await state.cppServices.workDirectory();
    final dir = Directory('${root.path}/check/${entryId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}-$kind-${++_workspaces}');
    if (await dir.exists()) await dir.delete(recursive: true);
    for (final e in texts.entries) {
      if (!CppComponentDoc.isSafeRelativePath(e.key)) continue;
      final f = File('${dir.path}/${e.key}');
      await f.parent.create(recursive: true);
      await f.writeAsString(e.value);
    }
    return dir.path;
  }

  Future<({int code, String output})?> _run(CppCompiler compiler, List<String> args, String key) {
    if (compiler is SerialCppCompiler) return compiler.runLatest(args, key: key);
    return compiler.run(args);
  }

  /// A check-only compile of the current code (`-fsyntax-only`): its errors and warnings become [diagnostics].
  /// Without the in-app compiler it does nothing but say so in [checkNote].
  Future<void> check() async {
    _checkTimer?.cancel();
    final compiler = state.cppServices.compiler;
    if (compiler == null) {
      checkNote = 'Live checks need the in-app compiler; Build shows the errors here.';
      notifyListeners();
      return;
    }
    if (_untrusted) {
      checkNote = 'Live checks start once you trust this code (Build asks).';
      notifyListeners();
      return;
    }
    final generation = _editGeneration;
    final manifest = _manifest();
    if (manifest == null) {
      String why;
      try {
        CppComponentManifest.parse(texts['caw-component.json'] ?? '');
        why = '';
      } on FormatException catch (e) {
        why = e.message;
      }
      diagnostics = [CppDiagnostic(file: 'caw-component.json', line: 1, column: 1, severity: CppSeverity.error, message: why)];
      notifyListeners();
      return;
    }
    checking = true;
    notifyListeners();
    try {
      final toolchain = await compiler.toolchainDirectory();
      final dir = await _writeWorkspace('check');
      final ({int code, String output})? result;
      try {
        result = await _run(compiler, CppSourceBuilder.checkArguments(toolchain: toolchain, sourceDirectory: dir, manifest: manifest),
            '$entryId/check');
      } finally {
        unawaited(_removeWorkspace(dir));
      }
      if (result == null || _disposed) return; // a newer check replaced it
      if (generation != _editGeneration) return; // typing went on: the next check has the right positions
      final found = parseClangDiagnostics(result.output, sourceDirectory: dir);
      if (found.isEmpty && result.code < 0) {
        checkNote = result.output.trim().split('\n').first.replaceFirst(RegExp(r'^error:\s*'), '');
      } else {
        checkNote = null;
        diagnostics = found;
      }
    } on StateError catch (e) {
      checkNote = 'Live checks are off: ${e.message}';
    } on FileSystemException catch (e) {
      checkNote = 'Live checks are off: ${e.message}';
    } finally {
      checking = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Clang's completions at [line]:[column] (0-based) of [path]; empty without the compiler, in a file that isn't
  /// a source, or when Clang has nothing (the instant list still shows).
  Future<List<CppCompletion>> clangCompletions(String path, int line, int column, {required String prefix}) async {
    final compiler = state.cppServices.compiler;
    final manifest = _manifest();
    if (compiler == null || manifest == null || !manifest.sources.contains(path) || _untrusted) return const [];
    try {
      final toolchain = await compiler.toolchainDirectory();
      // Clang completes the word starting at the column, counted in UTF-8 bytes from 1: the word's start.
      final lines = (texts[path] ?? '').split('\n');
      final lineText = line < lines.length ? lines[line] : '';
      final start = (column - prefix.length).clamp(0, lineText.length);
      final byteColumn = utf8.encode(lineText.substring(0, start)).length + 1;
      final dir = await _writeWorkspace('complete');
      final ({int code, String output})? result;
      try {
        result = await _run(
            compiler,
            CppSourceBuilder.completionArguments(
                toolchain: toolchain, sourceDirectory: dir, manifest: manifest, source: path, line: line + 1,
                column: byteColumn),
            '$entryId/complete');
      } finally {
        unawaited(_removeWorkspace(dir));
      }
      if (result == null) return const [];
      return parseClangCompletions(result.output, prefix: prefix);
    } on StateError {
      return const [];
    } on FileSystemException {
      return const [];
    }
  }

  /// The built effect's knobs for the instant list: id with range and unit.
  List<CppCompletion> get knobCompletions => [
        for (final p in info?.parameters ?? const <ComponentParameterInfo>[])
          CppCompletion(p.id, detail: '${_num(p.min)}..${_num(p.max)}${p.unit.isEmpty ? '' : ' ${p.unit}'}'),
      ];

  static String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  // ---------- Build ----------

  /// Builds and loads the effect (tracks already using it switch to the new build while playing). Code from
  /// elsewhere that the user hasn't trusted asks first: pass [trustConfirmed] once they have.
  /// Returns false when it needs that confirmation.
  Future<bool> build({bool trustConfirmed = false}) async {
    if (phase == CppBuildPhase.building) return true;
    final c = component;
    if (c == null) return true;
    final manager = state.nativeComponents;
    if (manager != null && !own) {
      if (!trustConfirmed) return false;
      own = true;
    }
    _checkTimer?.cancel();
    _dirty = true;
    await save();
    phase = CppBuildPhase.building;
    buildMessage = null;
    notifyListeners();
    final before = await _descriptor();
    try {
      if (manager != null) {
        manager.trust.markAuthored(c);
        await _saveTrust(manager.trust);
        await state.prepareNativeComponents();
        final status = state.nativeStatus;
        final id = c.componentId;
        if (status != null && status.loaded.contains(id)) {
          _keepArtifact(manager.artifactOf(id));
          await _built(c, before);
        } else if (status?.buildFailed[id] case final CppBuildResult failed) {
          _failed(failed);
        } else {
          phase = CppBuildPhase.failed;
          buildMessage = status?.loadFailed[id] ?? 'The effect was built but not loaded.';
        }
      } else {
        final desktop = state.cppServices.desktopBuild;
        final result = desktop == null ? null : await desktop(state, c);
        if (result == null) {
          phase = CppBuildPhase.failed;
          buildMessage = 'No C++ compiler here: install CMake and set CAW_SDK_DIR to the C.A.W SDK.';
        } else if (!result.success || result.artifactPath == null) {
          _failed(result);
        } else {
          final engine = state.engine;
          final loaded = engine == null
              ? const NativeComponentLoadResult(ok: false, error: 'The sound engine is not running.')
              : await engine.loadNativeComponent(
                  artifactPath: result.artifactPath!,
                  expectedComponentId: c.componentId,
                  trust: NativeComponentTrust.trusted,
                  reload: builds > 0);
          if (loaded.ok) {
            state.editProject((_) {}); // send the project again so tracks pick the effect up
            _keepArtifact(result.artifactPath);
            await _built(c, before);
          } else {
            phase = CppBuildPhase.failed;
            buildMessage = loaded.error;
          }
        }
      }
    } catch (e) {
      phase = CppBuildPhase.failed;
      buildMessage = '$e';
    }
    if (!_disposed) notifyListeners();
    return true;
  }

  void _keepArtifact(String? path) {
    if (path == null) return;
    final old = artifactPath;
    if (old != null && old != path && File(old).existsSync()) previousArtifactPath = old;
    _artifact = path;
  }

  void _failed(CppBuildResult result) {
    phase = CppBuildPhase.failed;
    var found = parseClangDiagnostics(result.output);
    if (found.isEmpty) {
      found = [
        for (final d in result.diagnostics)
          CppDiagnostic(
            file: d.file ?? 'caw-component.json',
            line: d.line ?? 1,
            column: d.column ?? 1,
            severity: d.severity == 'warning' ? CppSeverity.warning : CppSeverity.error,
            message: d.message,
          ),
      ];
    }
    diagnostics = found;
    final errors = found.where((d) => d.isError).length;
    buildMessage = errors == 0 ? 'The build failed.' : 'Build failed: $errors error${errors == 1 ? '' : 's'}.';
  }

  Future<void> _built(CppComponentDoc c, NativeComponentInfo? before) async {
    builds++;
    phase = CppBuildPhase.built;
    // A build has the whole truth: the check's marks give way to the build's warnings (none on success).
    diagnostics = diagnostics.where((d) => !d.isError).toList();
    info = await _descriptor();
    _applyNewDefaults(before, info);
    try {
      final root = await state.cppServices.workDirectory();
      final v = await CppVersionStore(Directory('${root.path}/versions')).add(state.project.id, entryId, texts);
      buildMessage = 'Built · ${v.label}';
    } on FileSystemException {
      buildMessage = 'Built';
    }
  }

  Future<NativeComponentInfo?> _descriptor() async {
    final engine = state.engine;
    if (engine == null) return info;
    try {
      return (await engine.nativeComponents()).where((i) => i.id == componentId).firstOrNull;
    } catch (_) {
      return info;
    }
  }

  /// Editing a knob's declared default moves the knob after the build, unless the user has turned it.
  void _applyNewDefaults(NativeComponentInfo? before, NativeComponentInfo? after) {
    if (after == null) return;
    var changed = false;
    for (final p in after.parameters) {
      final old = before?.parameters.where((o) => o.id == p.id).firstOrNull;
      if (old == null || old.defaultValue == p.defaultValue) continue;
      for (final u in uses) {
        final value = u.use.params[p.id];
        if (value != null && value != old.defaultValue) continue;
        u.use.params[p.id] = p.defaultValue;
        changed = true;
        final index = engineIndex(u);
        if (index != null) state.engine?.setComponentParam(u.layer?.id, index, p.id, p.defaultValue);
      }
    }
    if (changed) unawaited(state.flush());
  }

  // ---------- where it plays ----------

  /// Every place the project uses this effect: tracks in order, then the master.
  List<CppEffectUse> get uses => [
        for (final l in state.project.layers)
          for (var i = 0; i < l.components.length; i++)
            if (l.components[i].id == componentId) CppEffectUse(l, i, l.components[i]),
        for (var i = 0; i < state.project.masterComponents.length; i++)
          if (state.project.masterComponents[i].id == componentId) CppEffectUse(null, i, state.project.masterComponents[i]),
      ];

  /// Whether this component plays notes (an instrument) rather than shaping sound: its descriptor once built, else
  /// its code deriving from `caw::InstrumentProcessor`.
  bool get isInstrument => info?.isInstrument ?? texts.values.any((s) => s.contains('InstrumentProcessor'));

  /// "Try it on a track": an instrument plays [layer] (its notes stay), an effect joins the end of its chain. With no
  /// [layer] (or a folder) a new track named after the component gets it. The track is selected and returned; null
  /// when nothing changed (it is already there). One project undo step.
  LayerDoc? tryOn(LayerDoc? layer) {
    final c = component;
    if (c == null) return null;
    var target = layer;
    if (target == null || target.isFolder) {
      state.addLayer();
      target = state.project.layers.last..name = c.name;
    }
    if (isInstrument) {
      if (target.instrument?.id == componentId) return null;
      state.setNativeInstrument(target, componentId);
    } else {
      if (target.components.any((u) => u.id == componentId)) return null;
      if (state.addNativeEffect(target, componentId) == null) return null;
    }
    state.selectLayer(target);
    return target;
  }

  /// The use's index in the engine's chain, which leaves out components the engine hasn't loaded.
  int? engineIndex(CppEffectUse u) {
    final chain = u.layer?.components ?? state.project.masterComponents;
    final loaded = state.nativeComponents?.loaded;
    if (loaded == null) return u.index;
    if (!loaded.contains(componentId)) return null;
    return chain.take(u.index).where((c) => loaded.contains(c.id)).length;
  }

  /// A knob's value now on the first track using the effect (its set value or the default), null when the
  /// effect isn't built or isn't on a track.
  double? liveValue(String parameterId) {
    final p = info?.parameters.where((p) => p.id == parameterId).firstOrNull;
    final first = uses.firstOrNull;
    if (p == null || first == null) return null;
    return first.use.params[parameterId] ?? p.defaultValue;
  }

  /// Turns a knob on one use: to the audio thread now, into the project on [commit] (the end of a drag).
  void setKnob(CppEffectUse u, String parameterId, double value, {bool commit = false}) {
    final index = engineIndex(u);
    if (index != null) state.engine?.setComponentParam(u.layer?.id, index, parameterId, value);
    u.use.params[parameterId] = value;
    if (commit) {
      state.editProject((_) {});
    } else {
      notifyListeners();
    }
  }

  // ---------- versions ----------

  Future<CppVersionStore> _versions() async => CppVersionStore(Directory('${(await state.cppServices.workDirectory()).path}/versions'));

  Future<List<CppVersion>> versions() async => (await _versions()).list(state.project.id, entryId);

  /// Puts a version's files back (the current code is kept as a version first, so the restore can be undone).
  Future<void> restore(CppVersion v) async {
    final store = await _versions();
    await store.add(state.project.id, entryId, texts);
    texts
      ..clear()
      ..addAll(v.files);
    if (!texts.containsKey(currentFile)) currentFile = fileOrder.firstOrNull ?? currentFile;
    _dirty = true;
    revision++;
    diagnostics = const [];
    phase = CppBuildPhase.idle;
    await save();
    notifyListeners();
    _checkTimer?.cancel();
    _checkTimer = Timer(checkDelay, () => unawaited(check()));
  }

  @override
  void dispose() {
    if (_dirty) unawaited(save());
    _disposed = true;
    _saveTimer?.cancel();
    _checkTimer?.cancel();
    state.removeListener(_onState);
    super.dispose();
  }
}
