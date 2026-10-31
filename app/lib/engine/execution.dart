// Native hardware policy and bounded scheduling for non-real-time app work.
import 'dart:async';
import 'dart:ffi';

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

/// Queues app-side isolate work using the native engine's workload limits and priority policy.
/// It never runs work on, or calls into, the real-time audio callback.
class EngineWorkScheduler {
  EngineWorkScheduler({this.maxPending = 64});

  static final EngineWorkScheduler shared = EngineWorkScheduler();

  final int maxPending;
  final List<_ScheduledEngineWork<dynamic>> _pending = [];
  final List<_ScheduledEngineWork<dynamic>> _active = [];
  int _nextSequence = 0;
  EngineExecutionPlan? lastPlan;

  int get queued => _pending.length;
  int get active => _active.length;
  EngineHardwareProfile get hardwareProfile => EngineExecutionPolicy.hardwareProfile;

  Future<T> run<T>({
    required EngineWorkload workload,
    EnginePressure pressure = EnginePressure.normal,
    bool foregroundBusy = false,
    bool allowGpu = false,
    required Future<T> Function() task,
  }) {
    if (workload == EngineWorkload.idle) {
      return Future<T>.error(ArgumentError.value(workload, 'workload', 'idle cannot run a job'));
    }
    if (_pending.length + _active.length >= maxPending) {
      return Future<T>.error(StateError('engine work queue is full'));
    }
    final work = _ScheduledEngineWork<T>(
      sequence: _nextSequence++,
      workload: workload,
      pressure: pressure,
      foregroundBusy: foregroundBusy,
      allowGpu: allowGpu,
      task: task,
    );
    _pending.add(work);
    _pump();
    return work.result;
  }

  bool _isForeground(EngineWorkload workload) =>
      workload == EngineWorkload.interactiveAudition || workload == EngineWorkload.interactivePreview;

  void _pump() {
    _pending.sort((a, b) {
      final priority = a.workload.index.compareTo(b.workload.index);
      return priority != 0 ? priority : a.sequence.compareTo(b.sequence);
    });

    var started = true;
    while (started && _pending.isNotEmpty) {
      started = false;
      final foregroundDemand =
          _pending.any((work) => _isForeground(work.workload)) ||
          _active.any((work) => _isForeground(work.workload));

      for (var i = 0; i < _pending.length; i++) {
        final next = _pending[i];
        final foreground = _isForeground(next.workload);
        final yieldsToForeground = !foreground && foregroundDemand;
        final nextPlan = EngineExecutionPolicy.plan(
          workload: next.workload,
          pressure: next.pressure,
          foregroundBusy: next.foregroundBusy || yieldsToForeground,
          allowGpu: next.allowGpu,
        );
        lastPlan = nextPlan;
        if (nextPlan.maxConcurrentJobs <= 0) {
          _pending.removeAt(i);
          next.fail(StateError('engine policy returned no capacity for ${next.workload.name}'));
          started = true;
          break;
        }

        final groupActive = _active.where((work) => _isForeground(work.workload) == foreground).length;
        var groupLimit = nextPlan.maxConcurrentJobs;
        for (final active in _active.where((work) => _isForeground(work.workload) == foreground)) {
          final activePlan = EngineExecutionPolicy.plan(
            workload: active.workload,
            pressure: active.pressure,
            foregroundBusy: active.foregroundBusy || (!foreground && foregroundDemand),
            allowGpu: active.allowGpu,
          );
          if (activePlan.maxConcurrentJobs < groupLimit) groupLimit = activePlan.maxConcurrentJobs;
        }

        // Each scheduled isolate consumes one worker slot. Keep the combined
        // foreground/background total inside both native hardware budgets.
        final hardware = hardwareProfile;
        final memoryLimit = hardware.memoryBudgetMiB ~/ 64;
        final totalLimit = memoryLimit < 1
            ? 1
            : hardware.logicalCores < memoryLimit
                ? hardware.logicalCores
                : memoryLimit;
        if (_active.length >= totalLimit) return;
        if (groupActive >= groupLimit) {
          if (i == 0) return;
          continue;
        }

        _pending.removeAt(i);
        _active.add(next);
        next.execute().whenComplete(() {
          _active.remove(next);
          _pump();
        });
        started = true;
        break;
      }
    }
  }
}

class _ScheduledEngineWork<T> {
  _ScheduledEngineWork({
    required this.sequence,
    required this.workload,
    required this.pressure,
    required this.foregroundBusy,
    required this.allowGpu,
    required this.task,
  });

  final int sequence;
  final EngineWorkload workload;
  final EnginePressure pressure;
  final bool foregroundBusy;
  final bool allowGpu;
  final Future<T> Function() task;
  final Completer<T> _completer = Completer<T>();

  Future<T> get result => _completer.future;

  Future<void> execute() async {
    try {
      _completer.complete(await task());
    } catch (error, stack) {
      _completer.completeError(error, stack);
    }
  }

  void fail(Object error) => _completer.completeError(error);
}
