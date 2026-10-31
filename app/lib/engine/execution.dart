// Native hardware policy and bounded scheduling for non-real-time app work.
import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

enum EngineWorkload {
  interactiveAudition,
  interactivePreview,
  backgroundGeneration,
  offlineRender,
  idle,
}

enum EnginePressure {
  normal,
  batterySaver,
  thermalWarm,
  thermalHot,
  thermalCritical,
}

class EngineHardwareProfile {
  const EngineHardwareProfile({
    required this.logicalCores,
    required this.memoryBudgetMiB,
    required this.supportsSimd,
    required this.supportsGpuCompute,
  });

  final int logicalCores;
  final int memoryBudgetMiB;
  final bool supportsSimd;
  final bool supportsGpuCompute;
}

class EngineExecutionPlan {
  const EngineExecutionPlan({
    required this.workerThreads,
    required this.maxConcurrentJobs,
    required this.preferredBatchFrames,
    required this.latencySensitive,
    required this.useSimd,
    required this.allowGpu,
    required this.yieldToForeground,
  });

  final int workerThreads;
  final int maxConcurrentJobs;
  final int preferredBatchFrames;
  final bool latencySensitive;
  final bool useSimd;
  final bool allowGpu;
  final bool yieldToForeground;
}

/// Calls the engine's single source of truth for hardware detection and workload policy.
class EngineExecutionPolicy {
  EngineExecutionPolicy._();

  static EngineHardwareProfile? _hardwareProfile;

  static EngineHardwareProfile get hardwareProfile {
    final cached = _hardwareProfile;
    if (cached != null) return cached;

    final b = Bindings.instance;
    final out = calloc<CawHardwareProfileStruct>();
    try {
      final result = b.hardwareProfileDetect(out);
      if (result != 0) throw StateError('engine hardware detection failed ($result)');
      final value = EngineHardwareProfile(
        logicalCores: out.ref.logicalCores,
        memoryBudgetMiB: out.ref.memoryBudgetMiB,
        supportsSimd: out.ref.supportsSimd != 0,
        supportsGpuCompute: out.ref.supportsGpuCompute != 0,
      );
      _hardwareProfile = value;
      return value;
    } finally {
      calloc.free(out);
    }
  }

  static EngineExecutionPlan plan({
    required EngineWorkload workload,
    EnginePressure pressure = EnginePressure.normal,
    bool foregroundBusy = false,
    bool allowGpu = false,
  }) {
    final b = Bindings.instance;
    final hardware = hardwareProfile;
    final hw = calloc<CawHardwareProfileStruct>();
    final request = calloc<CawExecutionRequestStruct>();
    final out = calloc<CawExecutionPlanStruct>();
    try {
      hw.ref
        ..logicalCores = hardware.logicalCores
        ..memoryBudgetMiB = hardware.memoryBudgetMiB
        ..supportsSimd = hardware.supportsSimd ? 1 : 0
        ..supportsGpuCompute = hardware.supportsGpuCompute ? 1 : 0;
      request.ref
        ..workload = workload.index
        ..pressure = pressure.index
        ..foregroundBusy = foregroundBusy ? 1 : 0
        ..allowGpu = allowGpu ? 1 : 0;

      final result = b.executionPlan(hw, request, out);
      if (result != 0) throw ArgumentError('engine rejected execution request ($result)');
      return EngineExecutionPlan(
        workerThreads: out.ref.workerThreads,
        maxConcurrentJobs: out.ref.maxConcurrentJobs,
        preferredBatchFrames: out.ref.preferredBatchFrames,
        latencySensitive: out.ref.latencySensitive != 0,
        useSimd: out.ref.useSimd != 0,
        allowGpu: out.ref.allowGpu != 0,
        yieldToForeground: out.ref.yieldToForeground != 0,
      );
    } finally {
      calloc
        ..free(hw)
        ..free(request)
        ..free(out);
    }
  }
}

enum NativeJobPriority { background, offline, foreground }

/// Owns the engine's bounded native pool. Work is submitted as native job types;
/// Dart callbacks are never invoked from native worker threads.
class NativeEngineWorkPool {
  NativeEngineWorkPool._(this._bindings, this._handle);

  static final NativeEngineWorkPool shared = NativeEngineWorkPool._create();

  final Bindings _bindings;
  final Pointer<Void> _handle;
  bool _disposed = false;

  factory NativeEngineWorkPool._create() {
    final bindings = Bindings.instance;
    final hardware = EngineExecutionPolicy.hardwareProfile;
    final memoryWorkers = math.max(1, hardware.memoryBudgetMiB ~/ 64);
    final maxWorkers = math.min(16, math.min(hardware.logicalCores, memoryWorkers)).toInt();
    final handle = bindings.workerPoolCreate(maxWorkers);
    if (handle == nullptr) throw StateError('could not create the native worker pool');
    final pool = NativeEngineWorkPool._(bindings, handle);
    try {
      // Keep a second slot available for foreground checks/project compilation while an export runs.
      pool.apply(workload: EngineWorkload.interactivePreview);
      return pool;
    } catch (_) {
      bindings.workerPoolDestroy(handle);
      rethrow;
    }
  }

  EngineExecutionPlan apply({
    required EngineWorkload workload,
    EnginePressure pressure = EnginePressure.normal,
    bool foregroundBusy = false,
    bool allowGpu = false,
  }) {
    if (_disposed) throw StateError('native worker pool is disposed');
    final request = calloc<CawExecutionRequestStruct>();
    final out = calloc<CawExecutionPlanStruct>();
    try {
      request.ref
        ..workload = workload.index
        ..pressure = pressure.index
        ..foregroundBusy = foregroundBusy ? 1 : 0
        ..allowGpu = allowGpu ? 1 : 0;
      final result = _bindings.workerPoolApply(_handle, request, out);
      if (result != 0) throw StateError('native worker pool rejected the execution plan ($result)');
      return EngineExecutionPlan(
        workerThreads: out.ref.workerThreads,
        maxConcurrentJobs: out.ref.maxConcurrentJobs,
        preferredBatchFrames: out.ref.preferredBatchFrames,
        latencySensitive: out.ref.latencySensitive != 0,
        useSimd: out.ref.useSimd != 0,
        allowGpu: out.ref.allowGpu != 0,
        yieldToForeground: out.ref.yieldToForeground != 0,
      );
    } finally {
      calloc
        ..free(request)
        ..free(out);
    }
  }

  NativeEngineJob submitCheck(String source) {
    final text = source.toNativeUtf8();
    try {
      final job = _bindings.workerPoolSubmitCheck(_handle, text, NativeJobPriority.foreground.index);
      if (job == nullptr) throw StateError('native check queue is full or has no available capacity');
      return NativeEngineJob._(_bindings, job, includeResult: true);
    } finally {
      calloc.free(text);
    }
  }

  NativeEngineJob submitProject(Pointer<Void> engine, String projectJson) {
    final json = projectJson.toNativeUtf8();
    try {
      final job = _bindings.workerPoolSubmitProject(
        _handle, engine, json, NativeJobPriority.foreground.index,
      );
      if (job == nullptr) throw StateError('native project queue is full or has no available capacity');
      return NativeEngineJob._(_bindings, job, includeResult: true);
    } finally {
      calloc.free(json);
    }
  }

  NativeEngineJob submitRender({
    required String projectJson,
    required int kind,
    required String outPath,
    required int sampleRate,
    required bool float32,
    required double seconds,
    required int frames,
    String target = '',
    String param = '',
  }) {
    final options = calloc<CawRenderOptionsStruct>();
    final json = projectJson.toNativeUtf8();
    final path = outPath.toNativeUtf8();
    final targetText = target.toNativeUtf8();
    final paramText = param.toNativeUtf8();
    try {
      options.ref
        ..kind = kind
        ..sampleRate = sampleRate
        ..float32 = float32 ? 1 : 0
        ..frames = frames
        ..seconds = seconds
        ..target = targetText
        ..param = param.isEmpty ? nullptr : paramText;
      final job = _bindings.workerPoolSubmitRender(
        _handle, json, options, path, NativeJobPriority.offline.index,
      );
      if (job == nullptr) throw StateError('native render queue is full or has no available capacity');
      return NativeEngineJob._(_bindings, job, includeResult: false);
    } finally {
      calloc
        ..free(options)
        ..free(json)
        ..free(path)
        ..free(targetText)
        ..free(paramText);
    }
  }

  void waitIdle() {
    if (!_disposed) _bindings.workerPoolWaitIdle(_handle);
  }

  void dispose() {
    if (_disposed) return;
    _bindings.workerPoolDestroy(_handle);
    _disposed = true;
  }
}

/// Dart owner for an opaque native job handle. Native input is copied at submission,
/// and this object releases the handle after reading its terminal result.
class NativeEngineJob {
  NativeEngineJob._(this._bindings, this._handle, {required this._includeResult}) {
    result = _wait();
  }

  static const int _succeeded = 2;
  static const int _cancelled = 4;

  final Bindings _bindings;
  final Pointer<Void> _handle;
  final bool _includeResult;
  final Pointer<CawJobStatusStruct> _status = calloc<CawJobStatusStruct>();
  late final Future<String?> result;
  int _lastState = 0;
  int _lastProgress = 0;
  bool _done = false;

  double get progress {
    if (_done) return _lastProgress / 1000.0;
    _readStatus();
    return _lastProgress / 1000.0;
  }

  void cancel() {
    if (!_done) _bindings.jobCancel(_handle);
  }

  void _readStatus() {
    _status.ref.structSize = sizeOf<CawJobStatusStruct>();
    final code = _bindings.jobGetStatus(_handle, _status);
    if (code != 0) throw StateError('could not read native job status ($code)');
    _lastState = _status.ref.state;
    _lastProgress = _status.ref.progress.clamp(0, 1000).toInt();
  }

  Future<String?> _wait() async {
    try {
      final address = _handle.address;
      final waitCode = await Isolate.run<int>(() {
        final workerBindings = Bindings.instance;
        final workerHandle = Pointer<Void>.fromAddress(address);
        return workerBindings.jobWait(workerHandle, 0xffffffff);
      });
      if (waitCode != 0) throw StateError('native job wait failed ($waitCode)');
      _readStatus();
      if (_lastState == _succeeded) {
        _lastProgress = 1000;
        if (!_includeResult) return null;
        final output = _bindings.jobResult(_handle);
        if (output == nullptr) throw StateError('native job succeeded without a result');
        try {
          return output.toDartString();
        } finally {
          _bindings.free(output);
        }
      }
      final error = _bindings.jobError(_handle);
      if (error == nullptr) return _lastState == _cancelled ? 'cancelled' : 'native job failed';
      try {
        return error.toDartString();
      } finally {
        _bindings.free(error);
      }
    } finally {
      _done = true;
      _bindings.jobRelease(_handle);
      calloc.free(_status);
    }
  }
}
