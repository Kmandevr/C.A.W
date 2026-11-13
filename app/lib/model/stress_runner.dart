// Runs the Benchmark's Quick or Full plan step by step: safety stops, memory skips, the app's audio set aside, telemetry after.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../engine/execution.dart';
import '../engine/stress.dart';
import 'stress_result.dart';

/// Quick (about a minute) or Full (about five).
enum StressPlanKind {
  quick('Quick', 'About 1 minute'),
  full('Full', 'About 5 minutes');

  const StressPlanKind(this.label, this.duration);
  final String label, duration;
}

/// One step of a plan: a request and the words the screen shows for it.
class StressStep {
  const StressStep(this.request, this.label, {required this.estimateSeconds});
  final StressRequest request;
  final String label;

  /// About how long it takes, for the overall progress.
  final double estimateSeconds;
}

/// What the Benchmark sets aside while it runs: the app's own transport and audio device (AppState).
abstract class StressHost {
  void suspendForStress();
  void resumeAfterStress();
}

/// The plans (docs/app.md, "Benchmark"). Every step is DSP (timed on a worker at 256-frame callbacks, as the CI
/// bench) unless it says live (the device, muted).
List<StressStep> stressPlan(StressPlanKind kind, List<StressScenarioInfo> scenarios, {String? workDir}) {
  final full = kind == StressPlanKind.full;
  final plain = full ? 4.0 : 1.5, rampStep = full ? 1.5 : 0.5;
  return [
    for (final s in scenarios)
      StressStep(StressRequest(scenario: s.id, seconds: plain, workDir: workDir), 'Playing ${s.name}',
          estimateSeconds: plain + 0.5),
    StressStep(StressRequest(kind: StressKind.rampTracks, seconds: rampStep, workDir: workDir), 'Adding tracks',
        estimateSeconds: rampStep * 12),
    StressStep(StressRequest(kind: StressKind.rampVoices, seconds: rampStep, workDir: workDir), 'Adding Flagship voices',
        estimateSeconds: rampStep * 11),
    StressStep(StressRequest(kind: StressKind.rampEffects, seconds: rampStep, workDir: workDir), 'Adding effects to one track',
        estimateSeconds: rampStep * 11),
    for (final id in full ? const ['song8', 'song16', 'flagship_heavy16'] : const ['song8'])
      StressStep(StressRequest(scenario: id, kind: StressKind.profile, seconds: full ? 3 : 2, workDir: workDir),
          'Finding what takes the time', estimateSeconds: (full ? 3 : 2) + 1.5),
    for (final id in full ? const ['song8', 'song16'] : const ['song8'])
      StressStep(StressRequest(scenario: id, mode: StressMode.live, seconds: full ? 10 : 5, workDir: workDir),
          'Through the audio device (muted)', estimateSeconds: (full ? 10 : 5) + 0.5),
    if (full)
      StressStep(StressRequest(scenario: 'song16', kind: StressKind.sustained, seconds: 120, workDir: workDir),
          'Holding a heavy song for 2 minutes', estimateSeconds: 120),
  ];
}

/// Pressures that stop a run: severe heat or battery saver (beta plan C4).
String? stressStopReason(EnginePressure p) => switch (p) {
      EnginePressure.thermalHot || EnginePressure.thermalCritical => 'The device got too hot, so the Benchmark stopped to let it cool',
      EnginePressure.batterySaver => 'Battery saver is on, so the Benchmark stopped (it would measure a slowed-down device)',
      _ => null,
    };

class StressRunner extends ChangeNotifier {
  StressRunner({
    StressBackend? backend,
    this.host,
    this.memoryBudgetMiB,
    Stream<EnginePressure>? pressure,
    this.readPressure,
    this.sendTelemetry,
    this.workDir,
    this.device = const {},
  })  : backend = backend ?? StressBackend.current,
        _pressureChanges = pressure;

  final StressBackend backend;
  final StressHost? host;

  /// The engine's work-memory budget: Extreme scenarios that need more are skipped (null: unknown, none skipped).
  final int? memoryBudgetMiB;
  final Stream<EnginePressure>? _pressureChanges;
  final Future<EnginePressure> Function()? readPressure;

  /// Sends H2 `stress` (Telemetry.sendStressReport when telemetry is on); null: not sent.
  final Future<void> Function(Map<String, Object?> stress)? sendTelemetry;

  /// Makes (and later removes) the folder runs may write into; null: none (song8_extras is skipped).
  final Future<Directory?> Function()? workDir;
  final Map<String, Object?> device;

  bool _running = false;
  bool get running => _running;
  StressResult? _result;
  StressResult? get result => _result;

  /// What the current step does, in plain words.
  String phase = '';
  double fraction = 0;
  double load = 0;

  /// The load every 100 ms of audio while it runs (a share of the budget), the newest last.
  final List<double> loadPoints = [];
  static const int maxPoints = 600;

  /// Points received so far (the graph repaints when it moves).
  int pointsSeen = 0;

  StressJob? _job;
  bool _cancelled = false;
  String? _safetyStop;
  StreamSubscription<EnginePressure>? _pressureSub;
  Timer? _poll;

  /// Stops the run (it ends within a step); the result keeps what finished.
  void cancel() {
    if (!_running) return;
    _cancelled = true;
    _job?.cancel();
  }

  void _stopFor(String reason) {
    if (!_running || _safetyStop != null) return;
    _safetyStop = reason;
    _job?.cancel();
  }

  Future<StressResult> run(StressPlanKind kind) async {
    if (_running) throw StateError('a Benchmark is already running');
    _running = true;
    _cancelled = false;
    _safetyStop = null;
    loadPoints.clear();
    pointsSeen = 0;
    fraction = 0;
    load = 0;
    phase = 'Getting ready';
    final result = StressResult(plan: kind == StressPlanKind.full ? 'full' : 'quick', startedAt: DateTime.now())
      ..device = device;
    _result = result;
    notifyListeners();
    final watch = Stopwatch()..start();
    Directory? dir;
    try {
      final now = await readPressure?.call();
      final early = now == null ? null : stressStopReason(now);
      if (early != null) {
        result.stoppedBecause = early;
        return result;
      }
      _pressureSub = _pressureChanges?.listen((p) {
        final why = stressStopReason(p);
        if (why != null) _stopFor(why);
      });
      host?.suspendForStress();
      dir = await workDir?.call();
      final scenarios = backend.scenarios();
      final names = {for (final s in scenarios) s.id: s};
      final steps = stressPlan(kind, scenarios, workDir: dir?.path);
      final total = steps.fold<double>(0, (a, s) => a + s.estimateSeconds);
      var done = 0.0;
      for (final step in steps) {
        if (_cancelled || _safetyStop != null) break;
        final r = step.request;
        final info = names[r.scenario];
        // Memory: an Extreme scenario that needs more than the work budget is skipped, not run.
        if (r.kind == StressKind.plain && r.mode == StressMode.dsp && info != null) {
          final budget = memoryBudgetMiB;
          if (info.tier == 'extreme' && budget != null && info.memoryMiB > budget) {
            result.scenarios.add(ScenarioResult(
                id: info.id, name: info.name, tier: info.tier, skipped: 'Skipped: needs about ${info.memoryMiB} MiB of memory'));
            done += step.estimateSeconds;
            continue;
          }
          if (info.id == 'song8_extras' && r.workDir == null) {
            result.scenarios.add(ScenarioResult(
                id: info.id, name: info.name, tier: info.tier, skipped: 'Skipped: no folder for its audio files'));
            done += step.estimateSeconds;
            continue;
          }
        }
        phase = step.label;
        notifyListeners();
        final json = await _runStep(step, done / total, step.estimateSeconds / total);
        done += step.estimateSeconds;
        fraction = (done / total).clamp(0.0, 1.0);
        _take(result, step, json, info);
        notifyListeners();
      }
      result.stoppedBecause = _safetyStop ?? (_cancelled ? 'You stopped it' : null);
      return result;
    } finally {
      watch.stop();
      result.took = watch.elapsed;
      _poll?.cancel();
      await _pressureSub?.cancel();
      _pressureSub = null;
      _job = null;
      host?.resumeAfterStress();
      if (dir != null) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {
          // A leftover folder in the app's cache is harmless.
        }
      }
      _running = false;
      phase = result.stoppedBecause ?? 'Done';
      fraction = result.stoppedBecause == null ? 1 : fraction;
      notifyListeners();
      // Every run goes out as telemetry, as far as it got (owner, 2026-11-12): only when telemetry is on.
      if (result.scenarios.any((s) => s.ran) || result.ramps.isNotEmpty) {
        try {
          await sendTelemetry?.call(result.toTelemetryStress());
        } catch (_) {
          // Telemetry never breaks the Benchmark.
        }
      }
    }
  }

  Future<Map<String, dynamic>> _runStep(StressStep step, double from, double span) async {
    final job = backend.start(step.request);
    _job = job;
    if (_cancelled || _safetyStop != null) job.cancel();
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final p = job.progress();
      final pts = job.takeHistory();
      if (pts.isNotEmpty) {
        pointsSeen += pts.length;
        loadPoints.addAll(pts);
        if (loadPoints.length > maxPoints) loadPoints.removeRange(0, loadPoints.length - maxPoints);
      }
      load = p.load;
      fraction = (from + span * p.fraction).clamp(0.0, 1.0);
      if (step.request.kind.index >= StressKind.rampTracks.index && step.request.kind.index <= StressKind.rampEffects.index && p.count > 0) {
        phase = '${step.label}: ${p.count}';
      }
      notifyListeners();
    });
    try {
      return await job.result;
    } finally {
      _poll?.cancel();
      _poll = null;
      final rest = job.takeHistory();
      pointsSeen += rest.length;
      loadPoints.addAll(rest);
      if (loadPoints.length > maxPoints) loadPoints.removeRange(0, loadPoints.length - maxPoints);
    }
  }

  void _take(StressResult result, StressStep step, Map<String, dynamic> json, StressScenarioInfo? info) {
    final r = step.request;
    final stop = '${json['stop_reason'] ?? ''}';
    if (stop == 'cancelled') return; // a cut-short step reports nothing
    switch (r.kind) {
      case StressKind.plain:
        result.scenarios.add(ScenarioResult.fromEngine(json, name: info?.name ?? r.scenario, tier: info?.tier ?? 'normal'));
      case StressKind.rampTracks || StressKind.rampVoices || StressKind.rampEffects:
        final kind = switch (r.kind) { StressKind.rampTracks => 'tracks', StressKind.rampVoices => 'voices', _ => 'effects' };
        final failed = (json['first_failed'] as num?)?.toInt() ?? -1;
        final ok = json['ok'] == true;
        result.ramps[kind] = RampResult(
          kind: kind,
          limit: (json['limit'] as num?)?.toInt() ?? 0,
          firstFailed: failed >= 0 ? failed : null,
          capped: ok && failed < 0,
          error: ok ? null : '${json['error'] ?? 'failed'}',
        );
      case StressKind.profile:
        _addCosts(result, json);
      case StressKind.sustained:
        final b = (json['budget_us'] as num?)?.toDouble() ?? 0;
        double pct(String k) => b <= 0 ? 0 : 100 * ((json[k] as num?)?.toDouble() ?? 0) / b;
        result.sustained = SustainedResult(
          scenario: r.scenario,
          seconds: (json['seconds'] as num?)?.toDouble() ?? 0,
          firstPct: pct('mean_first_us'),
          lastPct: pct('mean_last_us'),
        );
    }
  }

  // Costs from several profiled scenarios: each id's share averaged over them (so one scenario can't outweigh).
  int _profiles = 0;
  final Map<String, (double, double, int)> _costSums = {};

  void _addCosts(StressResult result, Map<String, dynamic> json) {
    final rows = (json['costs'] as List? ?? const []).whereType<Map>().toList();
    if (rows.isEmpty) return;
    if (result.costs.isEmpty) {
      _profiles = 0;
      _costSums.clear();
    }
    _profiles++;
    for (final c in rows) {
      final id = '${c['id']}';
      final s = _costSums[id] ?? (0.0, 0.0, 0);
      _costSums[id] = (s.$1 + ((c['pct'] as num?)?.toDouble() ?? 0), s.$2 + ((c['ran_pct'] as num?)?.toDouble() ?? 0), s.$3 + 1);
    }
    result.costs
      ..clear()
      ..addAll([
        for (final e in _costSums.entries)
          StressCost(id: e.key, pct: e.value.$1 / _profiles, ranPct: e.value.$2 / e.value.$3, instances: e.value.$3),
      ]);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _pressureSub?.cancel();
    _job?.cancel();
    super.dispose();
  }
}
