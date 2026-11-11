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

/// One playback device the audio backend lists ([Engine.audioDevices]).
class AudioDeviceInfo {
  const AudioDeviceInfo(
      {required this.name, this.id = '', this.isDefault = false, this.rates = const [], this.exclusiveRates = const []});
  final String name;

  /// The backend's id ('' where it has none worth keeping): two identical interfaces share a name, not an id.
  final String id;
  final bool isDefault;

  /// Native sample rates in shared and exclusive mode (0: any rate).
  final List<int> rates, exclusiveRates;
}

/// The playback devices, the backend's name and whether it takes an exclusive-mode request (WASAPI, AAudio).
class AudioDeviceList {
  const AudioDeviceList({this.backend = 'none', this.exclusive = false, this.devices = const []});
  final String backend;
  final bool exclusive;
  final List<AudioDeviceInfo> devices;

  static AudioDeviceList fromJson(Map<String, dynamic> j) => AudioDeviceList(
        backend: j['backend'] as String? ?? 'none',
        exclusive: j['exclusive'] == true,
        devices: [
          for (final d in (j['devices'] as List? ?? const []))
            if (d is Map && d['name'] is String)
              AudioDeviceInfo(
                name: d['name'] as String,
                id: d['id'] as String? ?? '',
                isDefault: d['default'] == true,
                rates: [for (final r in (d['rates'] as List? ?? const [])) if (r is num) r.toInt()],
                exclusiveRates: [for (final r in (d['exclusive_rates'] as List? ?? const [])) if (r is num) r.toInt()],
              ),
        ],
      );
}

/// The device as it runs (caw_audio_status). The rate, period and periods are what the device gave, which can differ
/// from what was asked. [exclusive] and [lowLatency] are read from the stream at open on AAudio ([modesReadBack]; a
/// later reroute may change them); on WASAPI [exclusive] is what opened (it refuses rather than share); elsewhere
/// both are what was asked.
class AudioStatus {
  const AudioStatus({
    this.running = false,
    this.backend = '',
    this.device = '',
    this.deviceId = '',
    this.modesReadBack = false,
    this.fallback = false,
    this.fallbackReason = '',
    this.requestedDeviceId = '',
    this.sampleRate = 0,
    this.periodFrames = 0,
    this.periods = 0,
    this.exclusive = false,
    this.lowLatency = false,
    this.requestedDevice = '',
    this.requestedFrames = 0,
    this.exclusiveRequested = false,
  });
  final bool running, exclusive, lowLatency, modesReadBack;
  final String backend, device, deviceId;
  final int sampleRate, periodFrames, periods;

  /// The chosen device, size or exclusive mode did not open, so the system default runs (shared, its own size).
  final bool fallback;
  final String fallbackReason;

  /// What was asked for (caw_audio_configure), running or not.
  final String requestedDevice, requestedDeviceId;
  final int requestedFrames;
  final bool exclusiveRequested;

  /// The output buffer's length in ms (every period queued), the delay a played note adds before the speaker; the
  /// converter and the speaker add a little more.
  double get bufferMs => sampleRate <= 0 ? 0 : periodFrames * (periods <= 0 ? 1 : periods) * 1000 / sampleRate;

  static AudioStatus fromJson(Map<String, dynamic> j) => AudioStatus(
        running: j['running'] == true,
        backend: j['backend'] as String? ?? '',
        device: j['device'] as String? ?? '',
        deviceId: j['device_id'] as String? ?? '',
        modesReadBack: j['modes_read_back'] == true,
        fallback: j['fallback'] == true,
        fallbackReason: j['fallback_reason'] as String? ?? '',
        requestedDeviceId: j['requested_device_id'] as String? ?? '',
        sampleRate: (j['sample_rate'] as num?)?.toInt() ?? 0,
        periodFrames: (j['period_frames'] as num?)?.toInt() ?? 0,
        periods: (j['periods'] as num?)?.toInt() ?? 0,
        exclusive: j['exclusive'] == true,
        lowLatency: j['low_latency'] == true,
        requestedDevice: j['requested_device'] as String? ?? '',
        requestedFrames: (j['requested_frames'] as num?)?.toInt() ?? 0,
        exclusiveRequested: j['exclusive_requested'] == true,
      );
}

/// How [Engine.configureAudio] left the device: running as chosen (or not running), running on the system default
/// because the choice did not open, or closed because nothing opened.
enum AudioConfigured { ok, fallback, closed }

/// Live engine plus its audio device. One per app.
class Engine {
  Engine._(this._b, this._handle, this.sampleRate);

  /// The rate the engine runs at unless Settings › Audio chose another (it is fixed when the engine is made).
  static const int defaultSampleRate = 48000;
  static const sampleRates = [44100, 48000, 88200, 96000];
  final int sampleRate;
  static const int auditionIndex = -2;  // CAW_SCOPE_AUDITION: the audition's slot moves when the engine grows
  static const int masterIndex = -1;    // CAW_SCOPE_MASTER

  final Bindings _b;
  final Pointer<Void> _handle;
  Future<void> _queue = Future.value();
  Future<void> _audioQueue = Future.value();  // device reopens, in order
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

  static Engine create({int sampleRate = defaultSampleRate}) {
    final b = Bindings.instance;
    if (b.apiVersion() != cawApiVersion) {
      throw StateError('engine library is API ${b.apiVersion()}, the app needs $cawApiVersion');
    }
    final rate = sampleRates.contains(sampleRate) ? sampleRate : defaultSampleRate;
    final h = b.create(rate);
    if (h == nullptr) throw StateError('could not create the engine');
    return Engine._(b, h, rate);
  }

  /// The playback devices, read on a background isolate (opening the backend can take tens of milliseconds).
  static Future<AudioDeviceList> audioDevices() => Isolate.run(() {
        final b = Bindings.instance;
        final r = b.audioDevices();
        if (r == nullptr) return const AudioDeviceList();
        final j = jsonDecode(r.toDartString()) as Map<String, dynamic>;
        b.free(r);
        return AudioDeviceList.fromJson(j);
      });

  /// How the device opens: [deviceId] (the backend's id), else [device] by name (both '': the default), a callback
  /// of [periodFrames] (0: the buffer mode's) and [exclusive] mode where the backend takes it. A running device
  /// reopens, which stops and opens it under the engine's device lock, so it runs on a background isolate, one call
  /// at a time in order. [audioOn] follows the device afterwards.
  Future<AudioConfigured> configureAudio(
      {String deviceId = '', String device = '', int periodFrames = 0, bool exclusive = false}) {
    if (_disposed) return Future.value(AudioConfigured.closed);
    _pendingNativeOps++;
    final done = Completer<AudioConfigured>();
    final address = _handle.address;
    _audioQueue = _audioQueue.then((_) async {
      try {
        final r = await _configureAudioOffThread(address, deviceId, device, periodFrames, exclusive);
        if (!_nativeDestroyed) _audioOn = _deviceRunning();
        done.complete(switch (r) { 0 => AudioConfigured.ok, 2 => AudioConfigured.fallback, _ => AudioConfigured.closed });
      } catch (error, stack) {
        done.completeError(error, stack);
      } finally {
        _pendingNativeOps--;
        if (_destroyRequested && _pendingNativeOps == 0) _destroyNative();
      }
    });
    return done.future;
  }

  /// Whether the native device runs now (a reopen that failed has closed it, whatever was asked).
  bool _deviceRunning() => audioStatus().running;

  /// The device as it runs now.
  AudioStatus audioStatus() {
    final r = _b.audioStatus(_handle);
    if (r == nullptr) return const AudioStatus();
    final j = jsonDecode(r.toDartString()) as Map<String, dynamic>;
    _b.free(r);
    return AudioStatus.fromJson(j);
  }

  /// The metronome's click: [volume] 0..1 and its sound (CAW_CLICK_*: 0 Classic, 1 Wood, 2 Tick).
  void setMetronomeSound(double volume, int sound) => _b.setMetronomeSound(_handle, volume, sound);

  /// [seconds] of a 440 Hz test tone at -12 dBFS, playing or not; 0 ends it.
  void testTone(double seconds) => _b.testTone(_handle, seconds);
  bool get testToneSounding => _b.testToneSounding(_handle) != 0;

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

  /// A playing send (API version 9): send [index] of the layer's project `sends` gets [level] (linear), pre or post
  /// fader and mute, ramped; false if there is no such send. Store it in the project too.
  bool setSend(String layerId, int index, double level, {required bool pre, required bool mute}) {
    final l = layerId.toNativeUtf8();
    try {
      return _b.setSend(_handle, l, index, level, pre ? 1 : 0, mute ? 1 : 0) == 1;
    } finally {
      calloc.free(l);
    }
  }

  /// Project modulation (API 19, #161): a running modulator's knob (by its project id), ramped like a component's.
  /// Store it in the project too, so the next update keeps it.
  bool setModulatorParam(String modulatorId, String param, double value) {
    final m = modulatorId.toNativeUtf8(), p = param.toNativeUtf8();
    try {
      return _b.setModulatorParam(_handle, m, p, value) == 1;
    } finally {
      calloc.free(m);
      calloc.free(p);
    }
  }

  bool setModulatorBypass(String modulatorId, bool bypass) {
    final m = modulatorId.toNativeUtf8();
    try {
      return _b.setModulatorBypass(_handle, m, bypass ? 1 : 0) == 1;
    } finally {
      calloc.free(m);
    }
  }

  /// A link's amount while it plays (a ring drag), −1..1 of its target's travel.
  bool setModulationAmount(int linkId, double amount) => _b.setModulationAmount(_handle, linkId, amount) == 1;

  Pointer<Float>? _modOut;

  /// A modulator's outputs (0..1) at the last audio chunk, or null for an unknown one or while the engine is busy.
  /// Cheap and never blocks: a modulator's UI polls it once per frame.
  List<double>? modulatorOutputs(String modulatorId) {
    if (_nativeDestroyed) return null;
    final out = _modOut ??= calloc<Float>(8);
    final m = modulatorId.toNativeUtf8();
    try {
      final n = _b.modulatorOutputs(_handle, m, out, 8);
      return n <= 0 ? null : [for (var i = 0; i < n; i++) out[i]];
    } finally {
      calloc.free(m);
    }
  }

  /// Link [linkId]'s target's summed offset (normalized travel) at the last chunk, or null.
  double? modulationOffset(int linkId) {
    if (_nativeDestroyed) return null;
    final out = _modOut ??= calloc<Float>(8);
    return _b.modulationOffset(_handle, linkId, out) == 1 ? out[0] : null;
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

  /// Gives a playing component a new saved state ([bytes] as its save_state writes them, at [version]; the
  /// convolver also takes a WAV file's bytes: its impulse). The engine rebuilds the chain off the UI isolate, in order
  /// with loads and unloads. False when there is no such component or it refused the state.
  Future<bool> setComponentState(String? layerId, int index, Uint8List bytes, int version) {
    if (_disposed) return Future.error(StateError('engine is disposed'));
    _pendingNativeOps++;
    final done = Completer<bool>();
    final engineAddress = _handle.address;
    _queue = _queue.then((_) async {
      try {
        done.complete(await _setComponentStateOffThread(engineAddress, layerId ?? '', index, bytes, version));
      } catch (error, stack) {
        done.completeError(error, stack);
      } finally {
        _pendingNativeOps--;
        if (_destroyRequested && _pendingNativeOps == 0) _destroyNative();
      }
    });
    return done.future;
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

  /// MIDI from a device (caw.h, API 15): MIDI 1.0 [bytes] for [layerId]'s instrument, played at [timeNs] on
  /// [midiClockNs] (0: now), so the engine places each message at the frame it was played. Returns the messages
  /// queued.
  int midiBytes(String layerId, List<int> bytes, int timeNs) {
    if (bytes.isEmpty) return 0;
    final l = layerId.toNativeUtf8();
    final p = calloc<Uint8>(bytes.length);
    p.asTypedList(bytes.length).setAll(0, bytes);
    final n = _b.midiBytes(_handle, l, p, bytes.length, timeNs);
    calloc.free(p);
    calloc.free(l);
    return n;
  }

  /// The same for Universal MIDI Packet [words] (MIDI 1.0 and 2.0 Channel Voice messages play).
  int midiUmp(String layerId, List<int> words, int timeNs) {
    if (words.isEmpty) return 0;
    final l = layerId.toNativeUtf8();
    final p = calloc<Uint32>(words.length);
    p.asTypedList(words.length).setAll(0, words);
    final n = _b.midiUmp(_handle, l, p, words.length, timeNs);
    calloc.free(p);
    calloc.free(l);
    return n;
  }

  /// Ends every device note on [layerId] (null: on every track): a device went away with keys down.
  void midiRelease([String? layerId]) {
    final l = (layerId ?? '').toNativeUtf8();
    _b.midiRelease(_handle, l);
    calloc.free(l);
  }

  /// MPE on or off, the channel and per-note bend ranges (semitones) and a steady-timing delay (ms).
  void setMidiOptions({bool mpe = false, double bendRange = 2, double noteBendRange = 48, double delayMs = 0}) =>
      _b.setMidiOptions(_handle, mpe ? 1 : 0, bendRange, noteBendRange, delayMs);

  /// Device messages dropped (a full queue) since the engine was made.
  int get midiDropped => _b.midiDropped(_handle);

  /// The transport position (samples into the project loop, unwrapped) at [timeNs] on the MIDI clock; -1 stopped.
  int positionAt(int timeNs) => _b.positionAt(_handle, timeNs);

  /// The MIDI clock (monotonic ns; Android's System.nanoTime) that device timestamps are on.
  int get midiClockNs => _b.midiClockNs();

  void play() => _b.play(_handle);

  /// Plays from [step] sixteenth steps into the project loop (fractions allowed); outside it, from 0.
  void playAt(double step) => _b.playAt(_handle, step);

  /// Clicks [beats] beats at the tempo, then plays from [step] (the recording count-in); a stop cancels it.
  void playCountIn(double step, int beats) => _b.playCountIn(_handle, step, beats);

  /// The engine's built-in metronome click on every beat while playing.
  void setMetronome(bool on) => _b.setMetronome(_handle, on ? 1 : 0);

  /// Sound quality (CAW_QUALITY_*: 0 Eco, 1 Normal, 2 High): what the built-ins spend on oversampling, unison
  /// copies, reverb density and display updates.
  void setQuality(int quality) => _b.setQuality(_handle, quality);

  /// The device buffer (CAW_BUFFER_*: 0 Auto, 1 Low latency, 2 Battery) and whether a recording is running (Auto
  /// uses the small buffer only then). A running device reopens when the size changes.
  void setBufferMode(int mode, {required bool recording}) {
    _b.audioSetBufferMode(_handle, mode, recording ? 1 : 0);
    if (_audioOn) _audioOn = _deviceRunning();  // a failed reopen leaves it closed, so the next play opens it again
  }

  /// The device's callback size in frames while it plays (0 when stopped).
  int get bufferFrames => _b.audioBufferFrames(_handle);

  /// An instrument entry ({"id", "params", "preset"}) as the engine plays it (caw_migrate_instrument): a retired
  /// synth becomes Flagship with its preset and knobs mapped ("migrated": true, "lanes": old knob to new), and an
  /// entry naming a preset gets the preset's values under its own. Null when the engine refuses it.
  static Map<String, dynamic>? resolveInstrument(Map<String, dynamic> entry) {
    final b = Bindings.instance;
    final s = jsonEncode(entry).toNativeUtf8();
    final r = b.migrateInstrument(s);
    calloc.free(s);
    if (r == nullptr) return null;
    final j = jsonDecode(r.toDartString()) as Map<String, dynamic>;
    b.free(r);
    return j['ok'] == true ? j : null;
  }

  /// The drums' layout (`caw_drums_info`: layers, sounds, kits, built-in samples, the GM map, the display layout).
  static Map<String, dynamic>? drumsInfo() => _drumsJson((b) => b.drumsInfo());

  /// A random ([current] null) or mutated sound of drum [type] (an index of the info's types, −1: the current
  /// sound's) for pad [pad] 0..63: `{"ok", "type", "pad", "params": {"<pad>_<suffix>": value}}` (`caw_drums_randomize`).
  static Map<String, dynamic>? drumsRandomize(int type, int seed, double amount, int pad, Map<String, dynamic>? current) {
    final s = current == null ? nullptr : jsonEncode(current).toNativeUtf8();
    try {
      return _drumsJson((b) => b.drumsRandomize(type, seed & 0xFFFFFFFF, amount, pad, s));
    } finally {
      if (s != nullptr) calloc.free(s);
    }
  }

  /// One Single-mode Drums track per used pad of Drums entry [entry] (`caw_drums_explode`).
  static Map<String, dynamic>? drumsExplode(Map<String, dynamic> entry) {
    final s = jsonEncode(entry).toNativeUtf8();
    try {
      return _drumsJson((b) => b.drumsExplode(s));
    } finally {
      calloc.free(s);
    }
  }

  static Map<String, dynamic>? _drumsJson(Pointer<Utf8> Function(Bindings b) call) {
    final b = Bindings.instance;
    final r = call(b);
    if (r == nullptr) return null;
    final j = jsonDecode(r.toDartString()) as Map<String, dynamic>;
    b.free(r);
    return j['ok'] == true ? j : null;
  }

  /// Ends every knob touch, so automation lanes rule again without a restart (Touch mode letting go).
  void releaseTouches() => _b.releaseTouches(_handle);

  /// Runs [frames] of audio with no device and returns the left channel: for tests, which play the transport without
  /// a sound card. Never call it while the device is on.
  Float32List pullForTest(int frames) {
    final l = calloc<Float>(frames), r = calloc<Float>(frames);
    try {
      for (var i = 0; i < frames; i += 512) {
        final n = frames - i < 512 ? frames - i : 512;
        _b.process(_handle, l + i, r + i, n);
      }
      return Float32List.fromList(l.asTypedList(frames));
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

  /// Opens the audio device; returns an error message, or null when sound is running (perhaps on the default
  /// device instead of the chosen one: [AudioStatus.fallback]).
  String? startAudio() {
    if (_audioOn && _deviceRunning()) return null;
    final err = calloc<Uint8>(256).cast<Utf8>();
    final r = _b.audioStart(_handle, err, 256);
    final msg = r == 0 ? null : err.toDartString();
    calloc.free(err);
    _audioOn = r == 0;
    return msg;
  }

  /// Closes the device. Always asks the native side (a no-op when closed), so a device reopened behind a stale
  /// [audioOn] still closes.
  void stopAudio() {
    if (_nativeDestroyed) return;
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
    final modOut = _modOut;
    if (modOut != null) calloc.free(modOut);
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

Future<bool> _setComponentStateOffThread(int engineAddress, String layerId, int index, Uint8List bytes, int version) =>
    Isolate.run(() {
      final bindings = Bindings.instance;
      final layer = layerId.toNativeUtf8();
      final data = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
      try {
        data.asTypedList(bytes.length).setAll(0, bytes);
        return bindings.setComponentState(Pointer<Void>.fromAddress(engineAddress), layer, index, data, bytes.length, version) == 1;
      } finally {
        calloc.free(layer);
        calloc.free(data);
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

Future<int> _configureAudioOffThread(int engineAddress, String deviceId, String device, int periodFrames, bool exclusive) =>
    Isolate.run(() {
      final b = Bindings.instance;
      final id = deviceId.toNativeUtf8(), name = device.toNativeUtf8();
      try {
        return b.audioConfigure(Pointer<Void>.fromAddress(engineAddress), id, name, periodFrames, exclusive ? 1 : 0);
      } finally {
        calloc.free(id);
        calloc.free(name);
      }
    });
