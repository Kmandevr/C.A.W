// The Build tools' engine calls: the component testing suite (caw_component_test) and the sample-pack maker (caw_sample_pack_render), each on its own isolate.
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'engine.dart' show NativeComponentTrust;

/// A sample-pack render in progress, as the screens see it.
abstract class PackRun {
  /// 0..1.
  double get progress;
  void cancel();

  /// The result JSON (always with `ok` and `error`).
  Future<Map<String, dynamic>> get result;
}

/// Where the Build tools' screens send their work: the engine, or a fake in widget tests.
abstract class BuildToolsBackend {
  static BuildToolsBackend current = const EngineBuildTools();

  Future<Map<String, dynamic>> test(Map<String, dynamic> request, {required NativeComponentTrust trust, String? outputDir});
  PackRun pack(Map<String, dynamic> request, {required NativeComponentTrust trust});
}

/// The engine's own testing suite and sample-pack maker.
class EngineBuildTools implements BuildToolsBackend {
  const EngineBuildTools();

  @override
  Future<Map<String, dynamic>> test(Map<String, dynamic> request, {required NativeComponentTrust trust, String? outputDir}) =>
      runComponentTest(request, trust: trust, outputDir: outputDir);

  @override
  PackRun pack(Map<String, dynamic> request, {required NativeComponentTrust trust}) =>
      SamplePackJob.start(request, trust: trust);
}

/// Runs one testing-suite request (docs/engine.md, "Component testing") on a new isolate and returns the result
/// JSON (always with `ok` and `error`). [trust] is the user's choice for a library the request names (a request
/// must not name one). [outputDir] is where `write_wav` files go (null: none).
Future<Map<String, dynamic>> runComponentTest(Map<String, dynamic> request,
    {NativeComponentTrust trust = NativeComponentTrust.blocked, String? outputDir}) async {
  final json = jsonEncode(request);
  final level = trust.nativeValue;
  final text = await Isolate.run(() => _componentTestOffThread(json, level, outputDir));
  return jsonDecode(text) as Map<String, dynamic>;
}

String _componentTestOffThread(String request, int trust, String? outputDir) {
  final b = Bindings.instance;
  final req = request.toNativeUtf8();
  final out = outputDir == null ? nullptr : outputDir.toNativeUtf8();
  try {
    final r = b.componentTest(req, trust, out, nullptr);
    if (r == nullptr) return '{"ok":false,"error":"the testing suite returned no result"}';
    try {
      return r.toDartString();
    } finally {
      b.free(r);
    }
  } finally {
    calloc.free(req);
    if (out != nullptr) calloc.free(out);
  }
}

/// A sample pack rendering on its own isolate (docs/engine.md, "Sample packs"). Poll [progress] (0..1) and [cancel]
/// to stop it: files finished before it stay, and no manifest is written. [result] completes with the result JSON.
class SamplePackJob implements PackRun {
  SamplePackJob._(this._progress, this._cancel, this.result);

  final Pointer<Int32> _progress, _cancel;
  @override
  final Future<Map<String, dynamic>> result;
  bool _freed = false;

  /// 0..1, read from the engine's counter (shared memory; no message crosses isolates).
  @override
  double get progress => _freed ? 1 : (_progress.value / 1000).clamp(0.0, 1.0);

  @override
  void cancel() {
    if (!_freed) _cancel.value = 1;
  }

  /// Starts rendering [request] with [trust] for every library it names.
  static SamplePackJob start(Map<String, dynamic> request, {NativeComponentTrust trust = NativeComponentTrust.blocked}) {
    final progress = calloc<Int32>(), cancel = calloc<Int32>();
    final json = jsonEncode(request);
    final level = trust.nativeValue, p = progress.address, c = cancel.address;
    late SamplePackJob job;
    final result = Isolate.run(() => _samplePackOffThread(json, level, p, c)).then((text) {
      job._free();
      return jsonDecode(text) as Map<String, dynamic>;
    }, onError: (Object e) {
      job._free();
      return <String, dynamic>{'ok': false, 'error': '$e'};
    });
    job = SamplePackJob._(progress, cancel, result);
    return job;
  }

  void _free() {
    if (_freed) return;
    _freed = true;
    calloc.free(_progress);
    calloc.free(_cancel);
  }
}

String _samplePackOffThread(String request, int trust, int progress, int cancel) {
  final b = Bindings.instance;
  final req = request.toNativeUtf8();
  try {
    final r = b.samplePackRender(req, trust, Pointer<Int32>.fromAddress(progress), Pointer<Int32>.fromAddress(cancel));
    if (r == nullptr) return '{"ok":false,"error":"the sample-pack maker returned no result"}';
    try {
      return r.toDartString();
    } finally {
      b.free(r);
    }
  } finally {
    calloc.free(req);
  }
}
