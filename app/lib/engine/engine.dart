// Dart wrapper over the engine: compiles off the UI isolate, in order, and reads meters and scopes for the screens.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'execution.dart';

enum ParamKind { number, toggle, choice }

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
  const LayerMeterValue({this.peak = 0, this.progress = 0, this.active = false, this.overloaded = false});
  final double peak, progress;
  final bool active, overloaded;
}

class Template {
  const Template(this.file, this.source);
  final String file, source;
}

enum ExportKind { loop, free, oneShot, wavetable }

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
  static const int auditionIndex = 64;
  static const int masterIndex = -1;

  final Bindings _b;
  final Pointer<Void> _handle;
  Future<void> _queue = Future.value();
  final Pointer<CawMetersStruct> _meters = calloc<CawMetersStruct>();
  final Pointer<CawLayerMeterStruct> _layer = calloc<CawLayerMeterStruct>();
  final Pointer<Float> _scope = calloc<Float>(1024);
  bool _audioOn = false;

  static Engine create() {
    final b = Bindings.instance;
    if (b.apiVersion() != cawApiVersion) {
      throw StateError('engine library is API ${b.apiVersion()}, the app needs $cawApiVersion');
    }
    final h = b.create(sampleRate);
    if (h == nullptr) throw StateError('could not create the engine');
    return Engine._(b, h);
  }

  /// Sends a whole project. Calls run one at a time on a worker isolate, so compiling never blocks the UI.
  Future<Map<String, ModuleInfo>> setProject(String json) {
    final address = _handle.address;
    final done = Completer<Map<String, ModuleInfo>>();
    _queue = _queue.then((_) async {
      try {
        final result = await EngineWorkScheduler.shared.run(
          workload: EngineWorkload.interactiveAudition,
          task: () => _spawnSetProject(address, json),
        );
        final j = jsonDecode(result) as Map<String, dynamic>;
        // Project-level validation failures have no per-module diagnostics. Do not silently
        // turn those into an empty module map: callers would mistake a rejected project for
        // a successful compile with no modules.
        if (j['ok'] == false) {
          final message = (j['error'] as String?) ?? 'engine rejected the project';
          throw FormatException(message);
        }
        final mods = (j['modules'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, ModuleInfo.fromJson(v as Map<String, dynamic>)));
        done.complete(mods);
      } catch (e, st) {
        done.completeError(e, st);
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

  void play() => _b.play(_handle);
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
    _b.layerMeter(_handle, index, _layer);
    final m = _layer.ref;
    return LayerMeterValue(
        peak: m.peak, progress: m.progress, active: m.active != 0, overloaded: m.overloaded != 0);
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
    stopAudio();
    _b.destroy(_handle);
    calloc.free(_meters);
    calloc.free(_layer);
    calloc.free(_scope);
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

  /// Checks source off the UI isolate, scheduled as interactive preview work.
  static Future<ModuleInfo> checkAsync(String source) => EngineWorkScheduler.shared.run(
        workload: EngineWorkload.interactivePreview,
        task: () => Isolate.run(() => _checkOnWorker(source)),
      );

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

/// A running export. Poll [progress] (0..1); [cancel] stops it.
class RenderJob {
  RenderJob._(this._progress, this._cancel, this.result);

  final Pointer<Int32> _progress, _cancel;
  bool _done = false;

  /// Completes with null on success, or the error message.
  final Future<String?> result;

  double get progress => _done ? 1.0 : _progress.value / 1000.0;
  void cancel() {
    if (!_done) _cancel.value = 1;
  }

  static RenderJob start(RenderRequest req) {
    final progress = calloc<Int32>();
    final cancel = calloc<Int32>();
    final pa = progress.address, ca = cancel.address;
    final future = EngineWorkScheduler.shared.run(
      workload: EngineWorkload.offlineRender,
      task: () => _spawnRender(req, pa, ca),
    );
    final job = RenderJob._(progress, cancel, future);
    // The flags stay allocated until the worker is done with them.
    future.whenComplete(() {
      job._done = true;
      calloc.free(progress);
      calloc.free(cancel);
    }).ignore();
    return job;
  }
}

// Isolate entry points are top-level, and each closure is made in its own small function, so it captures only
// plain values (a closure made inside a method would carry that method's other variables to the worker).

Future<String> _spawnSetProject(int address, String json) => Isolate.run(() => _setProjectOnWorker(address, json));

Future<String?> _spawnRender(RenderRequest req, int progress, int cancel) =>
    Isolate.run(() => _renderOnWorker(req, progress, cancel));

ModuleInfo _checkOnWorker(String source) => Engine.check(source);

String _setProjectOnWorker(int address, String json) {
  final b = Bindings.instance;
  final s = json.toNativeUtf8();
  final r = b.setProject(Pointer<Void>.fromAddress(address), s);
  calloc.free(s);
  final text = r.toDartString();
  b.free(r);
  return text;
}

String? _renderOnWorker(RenderRequest req, int progressAddress, int cancelAddress) {
  final b = Bindings.instance;
  final opts = calloc<CawRenderOptionsStruct>();
  final json = req.projectJson.toNativeUtf8();
  final path = req.outPath.toNativeUtf8();
  final target = req.target.toNativeUtf8();
  final param = req.param.toNativeUtf8();
  final err = calloc<Uint8>(512).cast<Utf8>();
  opts.ref
    ..kind = req.kind.index
    ..sampleRate = req.sampleRate
    ..float32 = req.float32 ? 1 : 0
    ..frames = req.frames
    ..seconds = req.seconds
    ..target = target
    ..param = req.param.isEmpty ? nullptr : param;
  final r = b.render(json, opts, path, Pointer<Int32>.fromAddress(progressAddress),
      Pointer<Int32>.fromAddress(cancelAddress), err, 512);
  final msg = r == 0 ? null : err.toDartString();
  for (final p in [json, path, target, param, err]) {
    calloc.free(p);
  }
  calloc.free(opts);
  return msg;
}
