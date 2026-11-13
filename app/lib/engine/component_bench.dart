// The plug-in benchmark's engine binding (API 30, #197): one built component timed as a native worker-pool job.
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../model/component_bench.dart';
import 'bindings.dart';
import 'execution.dart';

/// CAW_NATIVE_TRUST_TRUSTED: a library reaches the bench only as the user's own build (or one they chose to trust).
const int _trusted = 2;

/// The engine's plug-in benchmark (caw_worker_pool_submit_component_bench).
class EngineComponentBench implements ComponentBenchBackend {
  const EngineComponentBench({this.seconds = 1.0});

  /// Audio per measurement (0.1..10); a whole bench plays about 12 times this, offline.
  final double seconds;

  @override
  ComponentBenchJob start(ComponentBenchRequest request) => EngineComponentBenchJob.submit(request, seconds: seconds);
}

/// A plug-in benchmark submitted to the native worker pool (a CawJob of kind ComponentBench): its progress read from
/// the job's status, its result JSON once it ends, the handle released then.
class EngineComponentBenchJob implements ComponentBenchJob {
  EngineComponentBenchJob._(this._b, this._handle) {
    result = _wait();
  }

  final Bindings _b;
  final Pointer<Void> _handle;
  final Pointer<CawJobStatusStruct> _status = calloc<CawJobStatusStruct>();
  bool _done = false;
  double _fraction = 0;
  @override
  late final Future<Map<String, dynamic>> result;

  /// Submits [r]: the library (the user's own build, so Trusted) or a built-in by id. A refused job's result says why.
  static ComponentBenchJob submit(ComponentBenchRequest r, {double seconds = 1.0}) {
    if (r.componentId.isEmpty) return _Refused('the component has no id');
    final b = Bindings.instance;
    final req = calloc<CawComponentBenchRequestStruct>();
    final id = r.componentId.toNativeUtf8();
    final library = (r.libraryPath ?? '').toNativeUtf8();
    try {
      req.ref
        ..structSize = sizeOf<CawComponentBenchRequestStruct>()
        ..componentId = id
        ..library = r.libraryPath == null ? nullptr : library
        ..trustLevel = r.libraryPath == null ? 0 : _trusted
        ..seconds = seconds;
      final handle = NativeEngineWorkPool.shared.submitComponentBenchRaw(req);
      if (handle == nullptr) return _Refused('the engine\'s worker pool did not take the benchmark');
      return EngineComponentBenchJob._(b, handle);
    } finally {
      calloc
        ..free(req)
        ..free(id)
        ..free(library);
    }
  }

  @override
  double get fraction {
    if (_done) return _fraction;
    _status.ref.structSize = sizeOf<CawJobStatusStruct>();
    if (_b.jobGetStatus(_handle, _status) == 0) _fraction = (_status.ref.progress / 1000).clamp(0.0, 1.0);
    return _fraction;
  }

  @override
  void cancel() {
    if (!_done) _b.jobCancel(_handle);
  }

  Future<Map<String, dynamic>> _wait() async {
    try {
      final address = _handle.address;
      final code = await Isolate.run<int>(() => Bindings.instance.jobWait(Pointer<Void>.fromAddress(address), 0xffffffff));
      if (code != 0) return {'ok': false, 'error': 'the plug-in benchmark could not be waited for ($code)'};
      _status.ref.structSize = sizeOf<CawJobStatusStruct>();
      final cancelled = _b.jobGetStatus(_handle, _status) == 0 && _status.ref.state == 4;
      final err = _b.jobError(_handle);
      final error = err == nullptr ? '' : err.toDartString();
      if (err != nullptr) _b.free(err);
      if (cancelled || error == 'cancelled') return {'ok': false, 'stop_reason': 'cancelled', 'error': 'cancelled'};
      final out = _b.jobResult(_handle);
      if (out != nullptr) {
        try {
          final text = out.toDartString();
          if (text.isNotEmpty) return jsonDecode(text) as Map<String, dynamic>;
        } finally {
          _b.free(out);
        }
      }
      return {'ok': false, 'error': error.isEmpty ? 'the plug-in benchmark failed' : error};
    } finally {
      _fraction = 1;
      _done = true;
      _b.jobRelease(_handle);
      calloc.free(_status);
    }
  }
}

class _Refused implements ComponentBenchJob {
  _Refused(String why) : result = Future.value({'ok': false, 'error': why});
  @override
  double get fraction => 0;
  @override
  void cancel() {}
  @override
  final Future<Map<String, dynamic>> result;
}
