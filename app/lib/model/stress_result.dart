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

  bool get ran => skipped == null && error == null && callbacks > 0;

  factory ScenarioResult.fromEngine(Map<String, dynamic> j, {required String name, required String tier}) {
    double d(String k) => (j[k] as num?)?.toDouble() ?? 0;
    int i(String k) => (j[k] as num?)?.toInt() ?? 0;
    final err = '${j['error'] ?? ''}';
    final xr = i('xruns');
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
    );
  }

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
        },
      };
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

/// A component's share of the callback, from the profiled runs.
class StressCost {
  const StressCost({required this.id, required this.pct, this.ranPct = 100, this.instances = 1});
  final String id;
  final double pct, ranPct;
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

/// A sustained run: the load over time; a rise from the first tenth to the last shows heat.
class SustainedResult {
  const SustainedResult({required this.scenario, required this.seconds, required this.firstPct, required this.lastPct, this.points = const []});
  final String scenario;
  final double seconds, firstPct, lastPct;

  /// The load every 100 ms (a share of the budget).
  final List<double> points;

  /// How much slower the end ran than the start, in percent (positive: slower).
  double get driftPct => firstPct <= 0 ? 0 : 100 * (lastPct - firstPct) / firstPct;

  Map<String, Object?> toJson() =>
      {'scenario': scenario, 'seconds': _r1(seconds), 'first_pct': _r1(firstPct), 'last_pct': _r1(lastPct), 'drift_pct': _r1(driftPct)};
}

/// A whole Benchmark run.
class StressResult {
  StressResult({required this.plan, required this.startedAt});

  /// quick or full.
  final String plan;
  final DateTime startedAt;
  final List<ScenarioResult> scenarios = [];
  final Map<String, RampResult> ramps = {};
  final List<StressCost> costs = [];
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
        'costs': [for (final c in holdingBack) c.toJson()],
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
      // Dropouts: a live run's of the same scenario when there was one, else the DSP callbacks over budget.
      final live = scenarios.where((x) => x.live && x.ran && x.id == s.id).firstOrNull;
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
        b.writeln('${s.name}${s.live ? ' (live)' : ''}: mean ${s.meanPct.round()}%, p99 ${s.p99Pct.round()}%, '
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
