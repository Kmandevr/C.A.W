// The Benchmark's engine calls (API 29): its scenarios, and one run as a native worker-pool job polled for progress and load.
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'execution.dart';

/// What a run does (CAW_STRESS_* in caw.h).
enum StressKind { plain, rampTracks, rampVoices, rampEffects, sustained, profile }

/// DSP: timed on a worker, repeatable. Live: through the audio device, muted, its real callbacks timed.
enum StressMode { dsp, live }

/// One Benchmark run.
class StressRequest {
  const StressRequest({
    this.scenario = '',
    this.kind = StressKind.plain,
    this.mode = StressMode.dsp,
    required this.seconds,
    this.frames = 0,
    this.quality = 1,
    this.workDir,
  });

  final String scenario;
  final StressKind kind;
  final StressMode mode;
  final double seconds;

  /// DSP: the callback size timed (0: 256, as the CI bench). Live: asked of the device with the low-latency profile
  /// (1024: as Auto while not recording, the playing buffer; 0: Low latency, the device's own burst).
  final int frames;
  final int quality;

  /// A folder the run may write two small WAVs into (song8_extras).
  final String? workDir;
}

/// A scenario as the engine lists it (caw_stress_scenarios).
class StressScenarioInfo {
  const StressScenarioInfo({required this.id, required this.name, required this.tier, required this.memoryMiB});
  final String id, name;

  /// normal, heavy, extreme or idle.
  final String tier;
  final int memoryMiB;

  static List<StressScenarioInfo> parse(Map<String, dynamic> json) => [
        for (final s in (json['scenarios'] as List? ?? const []).whereType<Map>())
          StressScenarioInfo(
            id: '${s['id']}',
            name: '${s['name']}',
            tier: '${s['tier']}',
            memoryMiB: (s['memory_mib'] as num?)?.toInt() ?? 64,
          ),
      ];
}

/// What a run shows while it goes.
class StressProgress {
  const StressProgress({
    this.fraction = 0,
    this.step = 0,
    this.count = 0,
    this.held = 0,
    this.load = 0,
    this.callbacks = 0,
    this.overBudget = 0,
  });

  /// 0..1 of the run.
  final double fraction;

  /// Ramps: steps run, the count the current step plays, the largest that held.
  final int step, count, held;

  /// The last 100 ms's load, a share of the callback's budget (1 = all of it).
  final double load;
  final int callbacks, overBudget;
}

/// A running Benchmark job.
abstract class StressJob {
  StressProgress progress();

  /// The load points (every 100 ms of audio) since the last call.
  List<double> takeHistory();
  void cancel();

  /// The engine's result JSON (always with `ok`, `stop_reason` and `error`).
  Future<Map<String, dynamic>> get result;
}

/// Where the Benchmark sends its runs: the engine, or a fake in tests.
abstract class StressBackend {
  static StressBackend current = const EngineStress();

  List<StressScenarioInfo> scenarios();
  StressJob start(StressRequest request);
}

/// The engine's own Benchmark.
class EngineStress implements StressBackend {
  const EngineStress();

  @override
  List<StressScenarioInfo> scenarios() {
    final b = Bindings.instance;
    final p = b.stressScenarios();
    if (p == nullptr) return const [];
    try {
      return StressScenarioInfo.parse(jsonDecode(p.toDartString()) as Map<String, dynamic>);
    } finally {
      b.free(p);
    }
  }

  @override
  StressJob start(StressRequest request) => EngineStressJob.submit(request);
}

/// A run submitted to the native worker pool (a CawJob of kind Stress). The handle is read on this isolate while it
/// runs (progress and history: shared memory, no message crosses isolates) and released once its result is read.
class EngineStressJob implements StressJob {
  EngineStressJob._(this._b, this._handle) {
    result = _wait();
  }

  final Bindings _b;
  final Pointer<Void> _handle;
  final Pointer<CawStressProgressStruct> _progress = calloc<CawStressProgressStruct>();
  final Pointer<Float> _points = calloc<Float>(256);
  final Pointer<Uint32> _next = calloc<Uint32>();
  int _from = 0;
  bool _done = false;
  StressProgress _last = const StressProgress();
  @override
  late final Future<Map<String, dynamic>> result;

  /// Submits [r]; a job whose result is an error when the pool refuses it.
  static StressJob submit(StressRequest r) {
    final b = Bindings.instance;
    final req = calloc<CawStressRequestStruct>();
    final scenario = r.scenario.toNativeUtf8();
    final dir = (r.workDir ?? '').toNativeUtf8();
    try {
      req.ref
        ..structSize = sizeOf<CawStressRequestStruct>()
        ..scenario = scenario
        ..kind = r.kind.index
        ..mode = r.mode.index
        ..seconds = r.seconds
        ..frames = r.frames
        ..threads = 0
        ..quality = r.quality
        ..workDir = r.workDir == null ? nullptr : dir;
      final handle = NativeEngineWorkPool.shared.submitStressRaw(req);
      if (handle == nullptr) return _RefusedJob();
      return EngineStressJob._(b, handle);
    } finally {
      calloc
        ..free(req)
        ..free(scenario)
        ..free(dir);
    }
  }

  @override
  StressProgress progress() {
    if (_done) return _last;
    _progress.ref.structSize = sizeOf<CawStressProgressStruct>();
    if (_b.stressProgress(_handle, _progress) != 0) return _last;
    final p = _progress.ref;
    return _last = StressProgress(
      fraction: (p.permille / 1000).clamp(0.0, 1.0),
      step: p.step,
      count: p.count,
      held: p.held,
      load: p.load.isFinite ? p.load : 0,
      callbacks: p.callbacks,
      overBudget: p.overBudget,
    );
  }

  @override
  List<double> takeHistory() {
    if (_done) return const [];
    final out = <double>[];
    for (var guard = 0; guard < 64; guard++) {
      final n = _b.stressHistory(_handle, _from, _points, 256, _next);
      if (n <= 0) break;
      for (var i = 0; i < n; i++) {
        out.add(_points[i].isFinite ? _points[i] : 0);
      }
      _from = _next.value;
      if (n < 256) break;
    }
    return out;
  }

  @override
  void cancel() {
    if (!_done) _b.jobCancel(_handle);
  }

  Future<Map<String, dynamic>> _wait() async {
    try {
      final address = _handle.address;
      final code = await Isolate.run<int>(() => Bindings.instance.jobWait(Pointer<Void>.fromAddress(address), 0xffffffff));
      if (code != 0) return {'ok': false, 'stop_reason': 'error', 'error': 'the Benchmark job could not be waited for ($code)'};
      progress();
      final out = _b.jobResult(_handle);
      if (out != nullptr) {
        try {
          return jsonDecode(out.toDartString()) as Map<String, dynamic>;
        } finally {
          _b.free(out);
        }
      }
      final err = _b.jobError(_handle);
      final text = err == nullptr ? 'the Benchmark run failed' : err.toDartString();
      if (err != nullptr) _b.free(err);
      return {'ok': false, 'stop_reason': text == 'cancelled' ? 'cancelled' : 'error', 'error': text};
    } finally {
      _done = true;
      _b.jobRelease(_handle);
      calloc
        ..free(_progress)
        ..free(_points)
        ..free(_next);
    }
  }
}

class _RefusedJob implements StressJob {
  @override
  StressProgress progress() => const StressProgress();
  @override
  List<double> takeHistory() => const [];
  @override
  void cancel() {}
  @override
  final Future<Map<String, dynamic>> result =
      Future.value({'ok': false, 'stop_reason': 'error', 'error': 'the engine\'s worker pool did not take the run'});
}
