// A Benchmark result: per-scenario rows, tiers, limits and costs, its JSON export, H2 `stress` and a plain-words summary.
import 'dart:convert';

import 'cpp_reference.dart';

/// How a tier fared: comfortable (p99 at most 70% of the budget), tight (at most 100%), over budget.
enum StressTier {
  comfortable('Comfortable'),
  tight('Tight'),
  over('Over budget');

  const StressTier(this.label);
  final String label;

  /// The H2 value.
  String get wire => switch (this) { comfortable => 'comfortable', tight => 'tight', over => 'over' };

  /// The tier for a worst p99 of [p99Pct] percent of the budget.
  static StressTier of(double p99Pct) => p99Pct <= comfortablePct ? comfortable : p99Pct <= 100 ? tight : over;

  /// [Assumption] 30% of headroom left is "comfortable": room for the UI, other apps and a warmer phone.
  static const double comfortablePct = 70;
}

/// One scenario's numbers (from the engine's result JSON).
class ScenarioResult {
  ScenarioResult({
    required this.id,
    required this.name,
    required this.tier,
    this.live = false,
    this.meanPct = 0,
    this.p99Pct = 0,
    this.worstPct = 0,
    this.meanUs = 0,
    this.p99Us = 0,
    this.worstUs = 0,
    this.budgetUs = 0,
    this.callbacks = 0,
    this.overBudget = 0,
    this.dropouts = 0,
    this.xruns,
    this.frames = 0,
    this.skipped,
    this.error,
    this.buffer,
    this.requestedFrames = 0,
    this.firstCallbackUs = 0,
    this.worstAtS = 0,
    this.warmupS = 0,
    this.slopePctPerMin = 0,
    this.callbackCore = -1,
    this.coreKhzStart = -1,
    this.coreKhzEnd = -1,
    this.coreMaxKhz = -1,
    this.mixWorkers = 0,
    this.mixActiveWorkers = 0,
    this.warmupXruns,
  });

  final String id, name;

  /// normal, heavy, extreme or idle.
  final String tier;

  /// Through the audio device (else timed on a worker).
  final bool live;
  final double meanPct, p99Pct, worstPct, meanUs, p99Us, worstUs, budgetUs;
  final int callbacks, overBudget, dropouts, frames;

  /// Live: the platform's underruns (null where it reports none).
  final int? xruns;

  /// Why it didn't run (memory, a safety stop); null when it ran.
  final String? skipped;
  final String? error;

  /// Live: which buffer it asked for, [StressBuffer.playing] or [StressBuffer.lowLatency]; null for DSP.
  final String? buffer;

  /// Local only (the JSON export; H2 keeps its allow-list): the callback size asked (live: 0 is Low latency), the
  /// first callback after Play (untimed, kept apart), the slowest's time from Play, the untimed warm-up, the load's
  /// trend (% of the budget a minute), the callback's core (live) and the timed span's core clock at its start and
  /// end (kHz, -1 unknown), the mix pool's workers and those Auto had working at the end, and live underruns during
  /// the warm-up.
  final int requestedFrames, callbackCore, coreKhzStart, coreKhzEnd, coreMaxKhz, mixWorkers, mixActiveWorkers;
  final double firstCallbackUs, worstAtS, warmupS, slopePctPerMin;
  final int? warmupXruns;

  bool get ran => skipped == null && error == null && callbacks > 0;

  factory ScenarioResult.fromEngine(Map<String, dynamic> j, {required String name, required String tier, String? buffer}) {
    double d(String k) => (j[k] as num?)?.toDouble() ?? 0;
    int i(String k) => (j[k] as num?)?.toInt() ?? 0;
    final err = '${j['error'] ?? ''}';
    final xr = i('xruns');
    final wx = (j['warmup_xruns'] as num?)?.toInt() ?? -1;
    int k(String key) => (j[key] as num?)?.toInt() ?? -1;
    return ScenarioResult(
      id: '${j['scenario']}',
      name: name,
      tier: tier,
      live: j['mode'] == 'live',
      meanPct: d('mean_pct'),
      p99Pct: d('p99_pct'),
      worstPct: d('worst_pct'),
      meanUs: d('mean_us'),
      p99Us: d('p99_us'),
      worstUs: d('worst_us'),
      budgetUs: d('budget_us'),
      callbacks: i('callbacks'),
      overBudget: i('over_budget'),
      dropouts: i('dropouts'),
      xruns: xr >= 0 ? xr : null,
      frames: i('frames'),
      error: j['ok'] == true || err.isEmpty ? null : err,
      buffer: j['mode'] == 'live' ? buffer : null,
      requestedFrames: i('requested_frames'),
      firstCallbackUs: d('first_callback_us'),
      worstAtS: d('worst_at_s'),
      warmupS: d('warmup_s'),
      slopePctPerMin: d('slope_pct_per_min'),
      callbackCore: k('callback_core'),
      coreKhzStart: k('core_khz_start'),
      coreKhzEnd: k('core_khz_end'),
      coreMaxKhz: k('core_max_khz'),
      mixWorkers: i('mix_workers'),
      mixActiveWorkers: i('mix_active_workers'),
      warmupXruns: wx >= 0 ? wx : null,
    );
  }

  /// The row's key and words: a scenario's DSP row, or its live row at a buffer.
  String get key => live ? '$id-true${buffer == null ? '' : '-$buffer'}' : '$id-false';
  String get modeLabel => !live ? '' : buffer == StressBuffer.lowLatency ? ' · live, Low latency' : ' · live';

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'tier': tier,
        'mode': live ? 'live' : 'dsp',
        if (skipped != null) 'skipped': skipped,
        if (error != null) 'error': error,
        if (ran) ...{
          'mean_pct': _r1(meanPct),
          'p99_pct': _r1(p99Pct),
          'worst_pct': _r1(worstPct),
          'mean_us': _r1(meanUs),
          'p99_us': _r1(p99Us),
          'worst_us': _r1(worstUs),
          'budget_us': _r1(budgetUs),
          'frames': frames,
          'callbacks': callbacks,
          'over_budget': overBudget,
          'dropouts': dropouts,
          'xruns': xruns,
          'worst_at_s': _r2(worstAtS),
          'first_callback_us': _r1(firstCallbackUs),
          'warmup_s': _r2(warmupS),
          'slope_pct_per_min': _r2(slopePctPerMin),
          'mix_workers': mixWorkers,
          'mix_active_workers': mixActiveWorkers,
          'core_khz_start': coreKhzStart,
          'core_khz_end': coreKhzEnd,
          'core_max_khz': coreMaxKhz,
          if (live) ...{
            'buffer': buffer,
            'requested_frames': requestedFrames,
            'callback_core': callbackCore,
            'warmup_xruns': warmupXruns,
            // Each callback's budget is its own length, not its real deadline (the frames the device has queued):
            // over_budget overstates; xruns (the platform's underruns) are the dropouts heard.
            'budget_basis': 'callback_length',
          },
        },
      };
}

/// The live runs' buffers: the app's playing buffer (Auto while not recording, 1024 frames: audio_miniaudio.cpp's
/// kLargeBufferFrames) and Low latency (the device's own burst-sized callbacks).
abstract final class StressBuffer {
  static const playing = 'playing', lowLatency = 'low_latency';
  static const playingFrames = 1024;
}

/// A ramp's outcome: the last count that held.
class RampResult {
  const RampResult({required this.kind, required this.limit, this.firstFailed, this.capped = false, this.error});

  /// tracks, voices or effects.
  final String kind;
  final int limit;
  final int? firstFailed;

  /// Every count held up to the ramp's cap.
  final bool capped;
  final String? error;

  Map<String, Object?> toJson() =>
      {'kind': kind, 'limit': limit, 'first_failed': firstFailed, 'capped': capped, if (error != null) 'error': error};
}

/// A component's share of one profiled scenario's callback.
class StressCost {
  const StressCost({required this.id, required this.pct, this.ranPct = 100, this.instances = 1});
  final String id;

  /// Its share of its scenario's callback (%), and of the blocks it was seen in, the share it processed.
  final double pct, ranPct;

  /// How many of it the scenario's project has (the engine's count; 1 for the host).
  final int instances;

  /// Its name in plain words.
  String get name {
    if (id == 'host') return 'The engine itself (mixing, routing, meters)';
    for (final b in cppBuiltins) {
      if (b.id == id) return b.name;
    }
    final last = id.split('.').last;
    return last.isEmpty ? id : '${last[0].toUpperCase()}${last.substring(1)}';
  }

  Map<String, Object?> toJson() => {'id': id, 'pct': _r1(pct), 'ran_pct': _r1(ranPct), 'instances': instances};
}

/// A sustained run (the heat test): live, in real time, at the playing buffer; the load's trend over the run, the
/// platform's thermal state and the callback core's clock at the start and end.
class SustainedResult {
  const SustainedResult({
    required this.scenario,
    required this.seconds,
    required this.firstPct,
    required this.lastPct,
    this.slopePctPerMin,
    this.live = false,
    this.xruns,
    this.coreKhzStart = -1,
    this.coreKhzEnd = -1,
    this.coreMaxKhz = -1,
    this.thermalStart = const {},
    this.thermalEnd = const {},
    this.points = const [],
  });
  final String scenario;
  final double seconds, firstPct, lastPct;

  /// The least-squares trend of each callback's load, in % of the budget a minute (null: an engine without it).
  final double? slopePctPerMin;
  final bool live;
  final int? xruns;
  final int coreKhzStart, coreKhzEnd, coreMaxKhz;

  /// The platform's thermal status and headroom at the start and end ({'status', 'headroom'}; empty: unknown).
  final Map<String, Object?> thermalStart, thermalEnd;

  /// The load every 100 ms (a share of the budget).
  final List<double> points;

  /// How much slower the end ran than the start, in percent (positive: slower): the trend over the whole run
  /// against the start's load, or the last tenth against the first where there is no trend.
  double get driftPct {
    if (firstPct <= 0) return 0;
    final s = slopePctPerMin;
    if (s == null) return 100 * (lastPct - firstPct) / firstPct;
    return 100 * s * seconds / 60 / firstPct;
  }

  Map<String, Object?> toJson() => {
        'scenario': scenario,
        'mode': live ? 'live' : 'dsp',
        'seconds': _r1(seconds),
        'first_pct': _r1(firstPct),
        'last_pct': _r1(lastPct),
        'slope_pct_per_min': slopePctPerMin == null ? null : _r2(slopePctPerMin!),
        'drift_pct': _r1(driftPct),
        'xruns': xruns,
        'core_khz_start': coreKhzStart,
        'core_khz_end': coreKhzEnd,
        'core_max_khz': coreMaxKhz,
        'thermal_start': thermalStart,
        'thermal_end': thermalEnd,
      };
}

/// A whole Benchmark run.
class StressResult {
  StressResult({required this.plan, required this.startedAt});

  /// quick or full.
  final String plan;
  final DateTime startedAt;
  final List<ScenarioResult> scenarios = [];
  final Map<String, RampResult> ramps = {};

  /// Each profiled scenario's components (its own shares of that song's callback, its own instance counts).
  final Map<String, List<StressCost>> costsByScenario = {};

  /// The headline: the typical song's (song8, in both plans), else the first profiled.
  List<StressCost> get costs {
    if (costsByScenario.isEmpty) return const [];
    return costsByScenario['song8'] ?? costsByScenario.values.first;
  }

  /// The scenario [costs] comes from (null: none profiled).
  String? get costsScenario => costsByScenario.isEmpty ? null : (costsByScenario.containsKey('song8') ? 'song8' : costsByScenario.keys.first);
  SustainedResult? sustained;

  /// Why the run ended early (cancelled, thermal, battery saver), or null when it finished.
  String? stoppedBecause;
  Duration took = Duration.zero;

  /// Device facts for the export (cores, memory budget, platform), as the app knows them.
  Map<String, Object?> device = const {};

  Iterable<ScenarioResult> get _dsp => scenarios.where((s) => !s.live && s.ran);

  /// The tier's headline from its scenarios' worst p99 (DSP runs); null when none of it ran.
  StressTier? tier(String name) {
    final rows = _dsp.where((s) => s.tier == name).toList();
    if (rows.isEmpty) return null;
    var worst = 0.0;
    for (final s in rows) {
      if (s.p99Pct > worst) worst = s.p99Pct;
    }
    return StressTier.of(worst);
  }

  /// What's holding it back: the costliest components, largest first (the host's own share among them).
  List<StressCost> get holdingBack => [...costs]..sort((a, b) => b.pct.compareTo(a.pct));

  /// "holds 23 tracks / 41 voices / 12 effects", from what the ramps found.
  String get limitsText {
    String part(String kind, String unit) {
      final r = ramps[kind];
      if (r == null || r.error != null) return '';
      return '${r.capped ? 'all ' : ''}${r.limit} $unit${r.limit == 1 ? '' : 's'}';
    }

    final parts = [part('tracks', 'track'), part('voices', 'voice'), part('effects', 'effect')].where((p) => p.isNotEmpty);
    return parts.isEmpty ? '' : 'Holds ${parts.join(' / ')}';
  }

  Map<String, Object?> toJson() => {
        'tool': 'caw_benchmark',
        'format': 1,
        'plan': plan,
        'started': startedAt.toUtc().toIso8601String(),
        'seconds': took.inMilliseconds / 1000,
        'stopped_because': stoppedBecause,
        'device': device,
        'tiers': {for (final t in const ['normal', 'heavy', 'extreme']) t: tier(t)?.wire},
        'limits': {for (final r in ramps.values) r.kind: r.toJson()},
        'scenarios': [for (final s in scenarios) s.toJson()],
        'costs_scenario': costsScenario,
        'costs': [for (final c in holdingBack) c.toJson()],
        'costs_by_scenario': {
          for (final e in costsByScenario.entries) e.key: [for (final c in [...e.value]..sort((a, b) => b.pct.compareTo(a.pct))) c.toJson()],
        },
        'sustained': sustained?.toJson(),
      };

  String toJsonText() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// H2's `stress` object (docs/beta-readiness-plan.md section H): built-in ids only, the ten scenario ids, whole
  /// percentages, at most 10 costs, unknowns as null (the allow-list then leaves them out).
  Map<String, Object?> toTelemetryStress() {
    int? limit(String kind) {
      final r = ramps[kind];
      return r == null || r.error != null ? null : r.limit;
    }

    final rows = <String, Map<String, Object?>>{};
    for (final s in _dsp) {
      if (!telemetryScenarioIds.contains(s.id)) continue;
      // Dropouts: a live run's of the same scenario when there was one (at the playing buffer first), else the DSP
      // callbacks over budget.
      final lives = scenarios.where((x) => x.live && x.ran && x.id == s.id);
      final live = lives.where((x) => x.buffer != StressBuffer.lowLatency).firstOrNull ?? lives.firstOrNull;
      rows[s.id] = {
        'meanPct': s.meanPct.round(),
        'p99Pct': s.p99Pct.round(),
        'worstPct': s.worstPct.round(),
        'dropouts': live?.dropouts ?? s.overBudget,
      };
    }
    return {
      'version': 1,
      'tiers': {for (final t in const ['normal', 'heavy', 'extreme']) t: tier(t)?.wire},
      'limits': {'tracks': limit('tracks'), 'voices': limit('voices'), 'effects': limit('effects')},
      'scenarios': rows,
      'topCosts': [
        for (final c in holdingBack.where((c) => c.id.startsWith('org.caw.')).take(10)) {'component': c.id, 'pct': c.pct.round()},
      ],
    };
  }

  /// A plain-words summary, for sharing.
  String summary() {
    final b = StringBuffer('C.A.W Benchmark (${plan == 'full' ? 'Full' : 'Quick'} run)\n');
    for (final t in const ['normal', 'heavy', 'extreme']) {
      final v = tier(t);
      b.writeln('${t[0].toUpperCase()}${t.substring(1)} projects: ${v?.label ?? 'not run'}');
    }
    if (limitsText.isNotEmpty) b.writeln(limitsText);
    final top = holdingBack.take(3).toList();
    if (top.isNotEmpty) {
      b.writeln('What takes the time: ${[for (final c in top) '${c.name} ${c.pct.round()}%'].join(', ')}');
    }
    if (stoppedBecause != null) b.writeln('Stopped early: $stoppedBecause');
    b.writeln();
    for (final s in scenarios) {
      if (s.ran) {
        b.writeln('${s.name}${s.live ? s.buffer == StressBuffer.lowLatency ? ' (live, Low latency)' : ' (live)' : ''}: mean ${s.meanPct.round()}%, p99 ${s.p99Pct.round()}%, '
            'worst ${s.worstPct.round()}% of the budget, ${s.live ? '${s.dropouts} dropouts' : '${s.overBudget} callbacks over'}');
      } else {
        b.writeln('${s.name}: ${s.skipped ?? s.error ?? 'not run'}');
      }
    }
    return b.toString();
  }
}

/// The ten scenario ids section H2 and the relay know.
const telemetryScenarioIds = {
  'first_loop', 'three_tracks', 'song8', 'song8_extras', 'flagship_heavy', 'flagship_heavy16', 'drums_kit', 'song16',
  'song32_heavy', 'tail_floor',
};

double _r1(double v) => v.isFinite ? (v * 10).roundToDouble() / 10 : 0;
double _r2(double v) => v.isFinite ? (v * 100).roundToDouble() / 100 : 0;
