// Dart wrapper over the engine: compiles off the UI isolate, in order, and reads meters and scopes for the screens.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'component_info.dart';
import 'execution.dart';

enum ParamKind { number, toggle, choice }

/// Explicit, per-component native-code trust. There is intentionally no implicit Trusted default.
enum NativeComponentTrust {
  blocked(0),
  isolated(1),
  trusted(2);

  const NativeComponentTrust(this.nativeValue);
  final int nativeValue;
}

class NativeComponentLoadResult {
  const NativeComponentLoadResult({
    required this.ok,
    this.componentId = '',
    this.error = '',
    this.errorCode = 0,
  });

  final bool ok;
  final String componentId;
  final String error;
  final int errorCode;

  static NativeComponentLoadResult fromJson(Map<String, dynamic> json) => NativeComponentLoadResult(
        ok: json['ok'] == true,
        componentId: (json['componentId'] as String?) ?? '',
        error: (json['error'] as String?) ?? '',
        errorCode: (json['errorCode'] as num?)?.toInt() ?? 0,
      );
}

class ParamInfo {
  const ParamInfo(
    this.name,
    this.defaultValue,
    this.min,
    this.max, {
    this.step = 0,
    this.kind = ParamKind.number,
    this.choices = const [],
    this.tip = '',
    this.header = '',
    this.doc = '',
    this.global = false,
  });
  final String name;
  final double defaultValue, min, max, step;
  final ParamKind kind;
  final List<String> choices;
  final String tip, header, doc;
  final bool global;

  /// Tooltip text: the short tip, then the longer doc comment.
  String get help => [tip, doc].where((s) => s.isNotEmpty).join('\n');

  static ParamInfo fromJson(Map<String, dynamic> j) => ParamInfo(
        j['name'] as String,
        (j['default'] as num).toDouble(),
        (j['min'] as num).toDouble(),
        (j['max'] as num).toDouble(),
        step: (j['step'] as num?)?.toDouble() ?? 0,
        kind: switch (j['kind']) { 'toggle' => ParamKind.toggle, 'choice' => ParamKind.choice, _ => ParamKind.number },
        choices: ((j['choices'] as List?) ?? const []).cast<String>(),
        tip: (j['tip'] as String?) ?? '',
        header: (j['header'] as String?) ?? '',
        doc: (j['doc'] as String?) ?? '',
        global: j['global'] == true,
      );
}

class ExportInfo {
  const ExportInfo(this.name, this.doc);
  final String name, doc;
}

/// What the engine said about one module after compiling it.
class ModuleInfo {
  const ModuleInfo({
    required this.ok,
    this.error = '',
    this.line = 0,
    this.col = 0,
    this.kind = 'generator',
    this.name = '',
    this.summary = '',
    this.params = const [],
    this.ref = '',
    this.exports = const [],
    this.imports = const [],
    this.warnings = const [],
    this.namespace = '',
    this.functions = const [],
    this.noteCount = 0,
  });
  final bool ok;
  final String error;
  final int line, col;
  /// generator, effect or library.
  final String kind;
  bool get isEffect => kind == 'effect';
  bool get isLibrary => kind == 'library';
  bool get isPattern => kind == 'pattern';
  final String name, summary;
  final List<ParamInfo> params;

  /// The name other modules use to read this module's exports (`ref.export`).
  final String ref;
  final List<ExportInfo> exports;
  final List<String> imports;
  final List<String> warnings;

  /// A library module's namespace and its functions (named `namespace.fn`).
  final String namespace;
  final List<LibraryFn> functions;

  /// A pattern module's number of notes.
  final int noteCount;

  static ModuleInfo fromJson(Map<String, dynamic> j) => ModuleInfo(
        ok: j['ok'] == true,
        error: (j['error'] as String?) ?? '',
        line: (j['line'] as num?)?.toInt() ?? 0,
        col: (j['col'] as num?)?.toInt() ?? 0,
        kind: (j['kind'] as String?) ?? 'generator',
        name: (j['name'] as String?) ?? '',
        summary: (j['summary'] as String?) ?? '',
        params: ((j['params'] as List?) ?? const [])
            .map((p) => ParamInfo.fromJson(p as Map<String, dynamic>))
            .toList(),
        ref: (j['ref'] as String?) ?? '',
        exports: ((j['exports'] as List?) ?? const [])
            .map((e) => ExportInfo((e as Map)['name'] as String, (e['doc'] as String?) ?? ''))
            .toList(),
        imports: ((j['imports'] as List?) ?? const []).cast<String>(),
        warnings: ((j['warnings'] as List?) ?? const []).cast<String>(),
        namespace: (j['namespace'] as String?) ?? '',
        noteCount: (j['notes'] as num?)?.toInt() ?? 0,
        functions: [
          for (final f in (j['functions'] as List?) ?? const [])
            LibraryFn.fromJson(f as Map<String, dynamic>, namespace: (j['namespace'] as String?) ?? ''),
        ],
      );
}

/// One documented function: a built-in, a built-in library's, or one from a project library.
class LibraryFn {
  const LibraryFn({required this.name, this.category = '', this.doc = '', this.example = '', this.args = const []});
  final String name, category, doc, example;
  final List<({String name, String doc, bool optional})> args;

  /// `name(a, b, c?)`, optional arguments marked `?`.
  String get signature => '$name(${[for (final a in args) a.optional ? '${a.name}?' : a.name].join(', ')})';

  /// What to type for a call: the required arguments' names as placeholders.
  String get callText => '$name(${[for (final a in args) if (!a.optional) a.name].join(', ')})';

  /// [namespace] prefixes names that don't have one yet (a project library's own functions).
  static LibraryFn fromJson(Map<String, dynamic> j, {String namespace = ''}) {
    final name = j['name'] as String;
    return LibraryFn(
      name: namespace.isNotEmpty && !name.contains('.') ? '$namespace.$name' : name,
      category: (j['category'] as String?) ?? '',
      doc: (j['doc'] as String?) ?? '',
      example: (j['example'] as String?) ?? '',
      args: [
        for (final a in (j['args'] as List?) ?? const [])
          (name: (a as Map)['name'] as String, doc: (a['doc'] as String?) ?? '', optional: a['optional'] == true),
      ],
    );
  }
}

/// Everything the module language offers, from `caw_library()`: functions and constants (`scale.minor`).
class Library {
  const Library(this.functions, this.constants);
  final List<LibraryFn> functions;
  final List<String> constants;

  static Library? _cached;

  /// Loaded once; the engine's library is fixed for a build.
  static Library get builtIn {
    final c = _cached;
    if (c != null) return c;
    final b = Bindings.instance;
    final r = b.library();
    final j = jsonDecode(r.toDartString()) as Map<String, dynamic>;
    b.free(r);
    return _cached = Library(
      [for (final f in j['functions'] as List) LibraryFn.fromJson(f as Map<String, dynamic>)],
      (j['constants'] as List).cast<String>(),
    );
  }

  /// Adds a project's own library functions, filed under their module's name.
  Library withProject(Iterable<ModuleInfo> modules) {
    final extra = [
      for (final m in modules)
        if (m.isLibrary)
          for (final f in m.functions)
            LibraryFn(
                name: f.name,
                category: m.name.isEmpty ? m.namespace : m.name,
                doc: f.doc,
                example: f.example,
                args: f.args),
    ];
    return extra.isEmpty ? this : Library([...functions, ...extra], constants);
  }

  /// Functions and constants that complete [prefix], best first; the part after a dot matches too (`adsr`).
  List<String> complete(String prefix, {int limit = 8, int minLetters = 2}) {
    if (prefix.length < minLetters || prefix.isEmpty) return const [];
    final names = [for (final f in functions) f.name, ...constants];
    final starts = names.where((n) => n.startsWith(prefix) && n != prefix);
    final parts = names.where((n) => !n.startsWith(prefix) && n.contains('.') && n.split('.').last.startsWith(prefix));
    return [...starts, ...parts].take(limit).toList();
  }

  LibraryFn? find(String name) => functions.where((f) => f.name == name).firstOrNull;
}

class EngineMeters {
  const EngineMeters({
    this.cpu = 0,
    this.peakL = 0,
    this.peakR = 0,
    this.playing = false,
    this.overloaded = 0,
    this.position = 0,
    this.loopLength = 1,
  });
  final double cpu, peakL, peakR;
  final bool playing;
  final int overloaded, position, loopLength;
}

class LayerMeterValue {
  const LayerMeterValue(
      {this.peak = 0, this.peakL = 0, this.peakR = 0, this.progress = 0, this.active = false, this.overloaded = false});

  /// Sample peaks since the last read, after volume and pan: [peak] is the louder of the left and right.
  final double peak, peakL, peakR, progress;
  final bool active, overloaded;
}

class Template {
  const Template(this.file, this.source);
  final String file, source;
}

enum ExportKind { loop, free, oneShot, wavetable, midi }

class RenderRequest {
  const RenderRequest({
    required this.projectJson,
    required this.kind,
    required this.outPath,
    this.sampleRate = 48000,
    this.float32 = false,
    this.seconds = 8,
    this.target = '',
    this.param = '',
    this.frames = 64,
  });
  final String projectJson, outPath, target, param;
  final ExportKind kind;
  final int sampleRate, frames;
  final bool float32;
  final double seconds;
}

/// Live engine plus its audio device. One per app.
class Engine {
  Engine._(this._b, this._handle);

  static const int sampleRate = 48000;
  static const int auditionIndex = -2;  // CAW_SCOPE_AUDITION: the audition's slot moves when the engine grows
  static const int masterIndex = -1;    // CAW_SCOPE_MASTER

  final Bindings _b;
  final Pointer<Void> _handle;
  Future<void> _queue = Future.value();
  final Pointer<CawMetersStruct> _meters = calloc<CawMetersStruct>();
  final Pointer<CawLayerMeterStruct> _layer = calloc<CawLayerMeterStruct>();
  final Pointer<Float> _layerSides = calloc<Float>(2);
  final Pointer<Float> _scope = calloc<Float>(1024);
  final Pointer<Float> _display = calloc<Float>(maxDisplayFloats);
  Pointer<Utf8>? _displayLayer;
  String? _displayLayerId;
  bool _audioOn = false;
  bool _disposed = false;
  int _pendingNativeOps = 0;
  bool _destroyRequested = false;
  bool _nativeDestroyed = false;
  List<String> lastProjectWarnings = const [];

  static Engine create() {
    final b = Bindings.instance;
    if (b.apiVersion() != cawApiVersion) {
      throw StateError('engine library is API ${b.apiVersion()}, the app needs $cawApiVersion');
    }
    final h = b.create(sampleRate);
    if (h == nullptr) throw StateError('could not create the engine');
    return Engine._(b, h);
  }

  /// Sends a whole project. Calls run one at a time on the native worker pool, off the UI isolate.
  Future<Map<String, ModuleInfo>> setProject(String json) {
    if (_disposed) return Future.error(StateError('engine is disposed'));
    final done = Completer<Map<String, ModuleInfo>>();
    _queue = _queue.then((_) async {
      try {
        if (_disposed) throw StateError('engine is disposed');
        final result = await NativeEngineWorkPool.shared
            .submitProject(_handle, json)
            .result;
        if (result == null) throw StateError('native project job returned no result');
        final j = jsonDecode(result) as Map<String, dynamic>;
        lastProjectWarnings = const [];
        final projectError = j['error'] as String?;
        if (projectError != null && projectError.isNotEmpty) throw StateError(projectError);
        final warnings = j['warnings'] as Map<String, dynamic>? ?? const {};
        lastProjectWarnings = ((warnings['project'] as List?) ?? const []).whereType<String>().toList();
        final mods = (j['modules'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, ModuleInfo.fromJson(v as Map<String, dynamic>)));
        done.complete(mods);
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// Loads a built component only after the caller supplies its explicit trust decision.
  /// The blocking library load runs on a background isolate, never on the UI or audio thread.
  ///
  /// With [reload], the artifact is a rebuild of a component already loaded (a new file): every chain using it
  /// switches to the new build while playing, crossfaded, keeping its values and, if the new build takes it, state.
  Future<NativeComponentLoadResult> loadNativeComponent({
    required String artifactPath,
    required String expectedComponentId,
    required NativeComponentTrust trust,
    bool reload = false,
  }) {
    if (_disposed) return Future.error(StateError('engine is disposed'));
    if (Platform.isIOS) {
      return Future.value(NativeComponentLoadResult(
        ok: false,
        componentId: expectedComponentId,
        error: 'Dynamic native components are not supported on iOS.',
        errorCode: -1,
      ));
    }
    _pendingNativeOps++;
    final done = Completer<NativeComponentLoadResult>();
    final engineAddress = _handle.address;
    final trustValue = trust.nativeValue;
    _queue = _queue.then((_) async {
      try {
        final text = await _loadComponentOffThread(engineAddress, artifactPath, expectedComponentId, trustValue, reload);
        done.complete(NativeComponentLoadResult.fromJson(jsonDecode(text) as Map<String, dynamic>));
      } catch (error, stack) {
        done.completeError(error, stack);
      } finally {
        _pendingNativeOps--;
        if (_destroyRequested && _pendingNativeOps == 0) _destroyNative();
      }
    });
    return done.future;
  }

  /// Returns false when the component is not loaded or a live processor still retains its library.
  Future<bool> unloadNativeComponent(String componentId) {
    if (_disposed) return Future.error(StateError('engine is disposed'));
    if (Platform.isIOS) return Future.value(false);
    _pendingNativeOps++;
    final done = Completer<bool>();
    final engineAddress = _handle.address;
    _queue = _queue.then((_) async {
      try {
        final unloaded = await _unloadComponentOffThread(engineAddress, componentId);
        done.complete(unloaded);
      } catch (error, stack) {
        done.completeError(error, stack);
      } finally {
        _pendingNativeOps--;
        if (_destroyRequested && _pendingNativeOps == 0) _destroyNative();
      }
    });
    return done.future;
  }

  /// The descriptors of the loaded native components (ports, parameters with choices and capability
  /// flags, UI controls). Runs off the UI isolate, in order with loads and unloads.
  Future<List<NativeComponentInfo>> nativeComponents() {
    if (_disposed) return Future.error(StateError('engine is disposed'));
    if (Platform.isIOS) return Future.value(const <NativeComponentInfo>[]);
    _pendingNativeOps++;
    final done = Completer<List<NativeComponentInfo>>();
    final engineAddress = _handle.address;
    _queue = _queue.then((_) async {
      try {
        final text = await _componentsOffThread(engineAddress);
        done.complete(NativeComponentInfo.listFromJson(jsonDecode(text) as Map<String, dynamic>));
      } catch (error, stack) {
        done.completeError(error, stack);
      } finally {
        _pendingNativeOps--;
        if (_destroyRequested && _pendingNativeOps == 0) _destroyNative();
      }
    });
    return done.future;
  }

  void setParam(String moduleId, String name, double value) {
    final m = moduleId.toNativeUtf8(), n = name.toNativeUtf8();
    _b.setParam(_handle, m, n, value);
    calloc.free(m);
    calloc.free(n);
  }

  /// A playing native component's parameter: component [index] of the layer's components, or of the
  /// master chain when [layerId] is null. It ramps over the parameter's smoothing; false if there is no
  /// such component or parameter. Store the value in the project too, so the next update keeps it.
  bool setComponentParam(String? layerId, int index, String param, double value) {
    final l = (layerId ?? '').toNativeUtf8(), p = param.toNativeUtf8();
    try {
      return _b.setComponentParam(_handle, l, index, p, value) == 1;
    } finally {
      calloc.free(l);
      calloc.free(p);
    }
  }

  /// Bypasses (or brings back) a playing native component, crossfaded; null [layerId] is the master chain.
  bool setComponentBypass(String? layerId, int index, bool bypass) {
    final l = (layerId ?? '').toNativeUtf8();
    try {
      return _b.setComponentBypass(_handle, l, index, bypass ? 1 : 0) == 1;
    } finally {
      calloc.free(l);
    }
  }

  /// Each playing component's state in a chain (null [layerId]: the master), by chain index, as its save_state
  /// writes it now. Stored in [ComponentUseDoc.state] it makes a reload or an export start from it.
  Map<int, ({String state, int version})> componentStates(String? layerId) {
    final l = (layerId ?? '').toNativeUtf8();
    final r = _b.componentStates(_handle, l);
    calloc.free(l);
    if (r == nullptr) return const {};
    final j = jsonDecode(r.toDartString()) as Map<String, dynamic>;
    _b.free(r);
    return {
      for (final c in (j['components'] as List? ?? const []).cast<Map<String, dynamic>>())
        if (c['ok'] == true) (c['index'] as num).toInt(): (state: c['state'] as String, version: (c['version'] as num).toInt()),
    };
  }

  /// The most floats a component's display block holds (kMaxDisplayFloats in engine/include/caw/display.hpp).
  static const int maxDisplayFloats = 1024;

  /// Live display data (#173): the latest floats component [index] of a layer's chain published for its UI
  /// (null [layerId]: the master chain; [index] CAW_INSTRUMENT_INDEX, 0xFFFFFFFF: the layer's instrument), copied
  /// into [out] (at most its length). Returns the count; 0 when it has none yet or the engine is busy with a
  /// project update (keep the last picture), -1 when there is no such component. Cheap and never blocks: call
  /// it once per frame. The float layout of each built-in is in docs/engine.md ("Display data").
  int componentDisplay(String? layerId, int index, Float32List out) {
    if (_nativeDestroyed) return -1;
    final id = layerId ?? '';
    if (_displayLayerId != id) {  // the layer id stays in native memory while the same device polls
      final old = _displayLayer;
      if (old != null) calloc.free(old);
      _displayLayer = id.toNativeUtf8();
      _displayLayerId = id;
    }
    final max = out.length < maxDisplayFloats ? out.length : maxDisplayFloats;
    if (max == 0) return 0;
    final n = _b.componentDisplay(_handle, _displayLayer!, index, _display, max);
    if (n > 0) out.setRange(0, n, _display.asTypedList(n));
    return n;
  }

  void setGlobal(String name, double value) {
    final n = name.toNativeUtf8();
    _b.setGlobal(_handle, n, value);
    calloc.free(n);
  }

  void setLayerMix(String layerId, double volume, double pan, bool mute, bool solo) {
    final id = layerId.toNativeUtf8();
    _b.setLayerMix(_handle, id, volume, pan, mute ? 1 : 0, solo ? 1 : 0);
    calloc.free(id);
  }

  void setMaster(double volume) => _b.setMaster(_handle, volume);

  /// Note previews: a held note on a layer's instrument, through its effects and mix, playing or stopped. A second
  /// [noteOn] with the same [id] ends the first; [notePitch] glides a held one without a new attack.
  void noteOn(String layerId, int id, double pitch, double velocity) {
    final l = layerId.toNativeUtf8();
    _b.noteOn(_handle, l, id, pitch, velocity);
    calloc.free(l);
  }

  void notePitch(int id, double pitch) => _b.notePitch(_handle, id, pitch);
  void noteOff(int id) => _b.noteOff(_handle, id);
  void notesOff() => _b.notesOff(_handle);

  void play() => _b.play(_handle);

  /// Plays from [step] sixteenth steps into the project loop (fractions allowed); outside it, from 0.
  void playAt(double step) => _b.playAt(_handle, step);

  /// Runs [frames] of audio with no device, discarding it: for tests, which play the transport without a sound card.
  /// Never call it while the device is on.
  void pullForTest(int frames) {
    final l = calloc<Float>(frames), r = calloc<Float>(frames);
    try {
      for (var i = 0; i < frames; i += 512) {
        final n = frames - i < 512 ? frames - i : 512;
        _b.process(_handle, l + i, r + i, n);
      }
    } finally {
      calloc.free(l);
      calloc.free(r);
    }
  }
  void stop() => _b.stop(_handle);
  void clearOverload() => _b.clearOverload(_handle);

  EngineMeters meters() {
    _b.meters(_handle, _meters);
    final m = _meters.ref;
    return EngineMeters(
      cpu: m.cpu,
      peakL: m.peakL,
      peakR: m.peakR,
      playing: m.playing != 0,
      overloaded: m.overloaded,
      position: m.position,
      loopLength: m.loopLength <= 0 ? 1 : m.loopLength,
    );
  }

  LayerMeterValue layerMeter(int index) {
    _layerSides[0] = 0;
    _layerSides[1] = 0;
    _b.layerMeterStereo(_handle, index, _layer, _layerSides, _layerSides + 1);
    final m = _layer.ref;
    return LayerMeterValue(
        peak: m.peak,
        peakL: _layerSides[0],
        peakR: _layerSides[1],
        progress: m.progress,
        active: m.active != 0,
        overloaded: m.overloaded != 0);
  }

  /// Copies the latest samples of a layer (project index), the audition or the master into [out].
  void scope(int index, Float32List out) {
    final n = out.length > 1024 ? 1024 : out.length;
    _b.scope(_handle, index, _scope, n);
    out.setRange(0, n, _scope.asTypedList(n));
  }

  /// Opens the audio device; returns an error message, or null when sound is running.
  String? startAudio() {
    if (_audioOn) return null;
    final err = calloc<Uint8>(256).cast<Utf8>();
    final r = _b.audioStart(_handle, err, 256);
    final msg = r == 0 ? null : err.toDartString();
    calloc.free(err);
    _audioOn = r == 0;
    return msg;
  }

  void stopAudio() {
    if (!_audioOn) return;
    _b.audioStop(_handle);
    _audioOn = false;
  }

  bool get audioOn => _audioOn;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stopAudio();
    _destroyRequested = true;
    if (_pendingNativeOps == 0) _destroyNative();
  }

  void _destroyNative() {
    if (_nativeDestroyed) return;
    _nativeDestroyed = true;
    _b.destroy(_handle);
    calloc.free(_meters);
    calloc.free(_layer);
    calloc.free(_layerSides);
    calloc.free(_scope);
    calloc.free(_display);
    final displayLayer = _displayLayer;
    if (displayLayer != null) calloc.free(displayLayer);
  }

  static List<Template> templates() {
    final b = Bindings.instance;
    return [
      for (var i = 0; i < b.templateCount(); i++)
        Template(b.templateFile(i).toDartString(), b.templateSource(i).toDartString()),
    ];
  }

  static ModuleInfo check(String source) {
    final b = Bindings.instance;
    final s = source.toNativeUtf8();
    final r = b.check(s);
    calloc.free(s);
    final text = r.toDartString();
    b.free(r);
    return ModuleInfo.fromJson(jsonDecode(text) as Map<String, dynamic>);
  }

  /// Checks source on the native bounded pool as interactive preview work.
  static Future<ModuleInfo> checkAsync(String source) async {
    final result = await NativeEngineWorkPool.shared.submitCheck(source).result;
    if (result == null) throw StateError('native module check returned no result');
    return ModuleInfo.fromJson(jsonDecode(result) as Map<String, dynamic>);
  }

  /// Turns a MIDI file (.mid or MIDI 2.0 Clip) into pattern module text; throws a [FormatException] if it can't.
  static String patternFromMidi(Uint8List bytes) {
    final b = Bindings.instance;
    final data = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    final r = b.patternFromMidi(data, bytes.length);
    calloc.free(data);
    final j = jsonDecode(r.toDartString()) as Map<String, dynamic>;
    b.free(r);
    if (j['ok'] != true) throw FormatException((j['error'] as String?) ?? 'not a MIDI file');
    return j['pattern'] as String;
  }

  /// Writes pattern module text to [path] as a .mid ([clip] false) or a MIDI 2.0 Clip File; returns an error or null.
  static String? exportPattern(String source, String path, {double bpm = 120, int beatsPerBar = 4, bool clip = false}) {
    final b = Bindings.instance;
    final src = source.toNativeUtf8(), out = path.toNativeUtf8();
    final err = calloc<Uint8>(512).cast<Utf8>();
    final rc = b.patternExport(src, bpm, beatsPerBar, clip ? 1 : 0, out, err, 512);
    final msg = rc == 0 ? null : err.toDartString();
    calloc.free(src);
    calloc.free(out);
    calloc.free(err);
    return msg;
  }
}

/// A running export. Poll [progress] (0..1); [cancel] stops the native job.
class RenderJob {
  RenderJob._(this._job) : result = _job.result;

  final NativeEngineJob _job;
  final Future<String?> result;

  double get progress => _job.progress;
  void cancel() => _job.cancel();

  static RenderJob start(RenderRequest req) {
    final job = NativeEngineWorkPool.shared.submitRender(
      projectJson: req.projectJson,
      kind: req.kind.index,
      outPath: req.outPath,
      sampleRate: req.sampleRate,
      float32: req.float32,
      seconds: req.seconds,
      frames: req.frames,
      target: req.target,
      param: req.param,
    );
    return RenderJob._(job);
  }
}

// Isolate.run sends its closure's whole captured context to the new isolate. These top-level
// helpers keep that context to sendable values only (the Engine method's Completer is not).
Future<String> _loadComponentOffThread(int engineAddress, String artifactPath, String componentId, int trust, bool reload) =>
    Isolate.run(() {
      final bindings = Bindings.instance;
      final engine = Pointer<Void>.fromAddress(engineAddress);
      final path = artifactPath.toNativeUtf8();
      final id = componentId.toNativeUtf8();
      try {
        final result = (reload ? bindings.reloadComponent : bindings.loadComponent)(engine, path, id, trust);
        if (result == nullptr) throw StateError('native component loader returned no result');
        try {
          return result.toDartString();
        } finally {
          bindings.free(result);
        }
      } finally {
        calloc.free(path);
        calloc.free(id);
      }
    });

Future<bool> _unloadComponentOffThread(int engineAddress, String componentId) => Isolate.run(() {
      final bindings = Bindings.instance;
      final engine = Pointer<Void>.fromAddress(engineAddress);
      final id = componentId.toNativeUtf8();
      try {
        return bindings.unloadComponent(engine, id) == 1;
      } finally {
        calloc.free(id);
      }
    });

Future<String> _componentsOffThread(int engineAddress) => Isolate.run(() {
      final bindings = Bindings.instance;
      final result = bindings.components(Pointer<Void>.fromAddress(engineAddress));
      if (result == nullptr) throw StateError('native component listing returned no result');
      try {
        return result.toDartString();
      } finally {
        bindings.free(result);
      }
    });
