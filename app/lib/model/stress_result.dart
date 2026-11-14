// A Benchmark result: per-scenario rows and features, tiers, limits, engine parts and costs, the verdict, tips, its JSON export, H2 `stress` and a plain-words summary.
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
    this.deviceSizes = false,
    String feature = '',
    this.parts = const [],
  }) : feature = stressFeatures.containsKey(feature) ? feature : scenarioFeature(id);

  final String id, name;

  /// What it tests ([stressFeatures]): the engine's own, else the contract's for the ids it predates.
  final String feature;

  /// Its engine parts, when the engine profiled it (local only, like the costs).
  final List<EnginePart> parts;

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

  /// Live: the device called back with its own sizes, not the size asked (Low latency; or a playing-buffer run on
  /// Android 11 and older, where a size never reaches the stream, so it ran at the burst, not 1024 frames).
  final bool deviceSizes;

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
      deviceSizes: j['mode'] == 'live' && j['device_sizes'] == true,
      feature: j['feature'] is String ? j['feature'] as String : '',
      parts: EnginePart.parseList(j['parts']),
    );
  }

  /// The row's key and words: a scenario's DSP row, or its live row at a buffer.
  String get key => live ? '$id-true${buffer == null ? '' : '-$buffer'}' : '$id-false';
  String get modeLabel => !live
      ? ''
      : buffer == StressBuffer.lowLatency
          ? ' · live, Low latency'
          : deviceSizes
              ? ' · live, device\'s own sizes'
              : ' · live';

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'tier': tier,
        'feature': feature,
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
          if (parts.isNotEmpty) 'parts': [for (final p in parts) p.toJson()],
          if (live) ...{
            'buffer': buffer,
            'requested_frames': requestedFrames,
            'callback_core': callbackCore,
            'warmup_xruns': warmupXruns,
            'device_sizes': deviceSizes,
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

  /// Each profiled scenario's engine parts (API 30; empty from an older engine), local only.
  final Map<String, List<EnginePart>> partsByScenario = {};

  /// The scenario [parts] comes from: song8, else the first profiled (null: none).
  String? get partsScenario =>
      partsByScenario.isEmpty ? null : (partsByScenario.containsKey('song8') ? 'song8' : partsByScenario.keys.first);

  /// The headline parts, costliest first.
  List<EnginePart> get parts {
    final k = partsScenario;
    return k == null ? const [] : ([...partsByScenario[k]!]..sort((a, b) => b.pct.compareTo(a.pct)));
  }

  /// A scenario's name as it ran (its id when it didn't).
  String scenarioName(String id) => scenarios.where((s) => s.id == id).firstOrNull?.name ?? id;

  /// Part [id] in each profiled scenario, where it cost the most first.
  List<({String scenario, EnginePart part})> partAcross(String id) => [
        for (final e in partsByScenario.entries)
          for (final p in e.value)
            if (p.id == id) (scenario: e.key, part: p),
      ]..sort((a, b) => b.part.pct.compareTo(a.part.pct));

  /// The verdict: the worst of the normal and heavy tiers (Extreme is meant to overload a phone, so it doesn't
  /// count), else Extreme's when only it ran; null when nothing ran. [Assumption] the owner's "overall tier".
  StressTier? get overall {
    final ts = [tier('normal'), tier('heavy')].whereType<StressTier>().toList();
    if (ts.isEmpty) return tier('extreme');
    return ts.reduce((a, b) => a.index >= b.index ? a : b);
  }

  /// The verdict in plain words: which kinds of project fit.
  String get verdictText {
    final n = tier('normal'), h = tier('heavy');
    if (n == null && h == null) return overall == null ? 'Nothing finished, so there is no verdict yet.' : 'Only the extreme tests ran.';
    String words(StressTier t) => switch (t) {
          StressTier.comfortable => 'comfortable',
          StressTier.tight => 'tight',
          StressTier.over => 'over budget',
        };
    if (n != null && h != null && n == h) return 'Normal and heavy projects: ${words(n)}.';
    if (n == null) return 'Heavy projects: ${words(h!)}.';
    if (h == null) return 'Normal projects: ${words(n)}.';
    return 'Normal projects: ${words(n)}; heavy projects: ${words(h)}.';
  }

  /// "~54 tracks · 64 voices · 64 effects": ~ where a count failed (the limit is about there), none where every
  /// count held.
  String get limitsShort {
    String part(String kind, String unit) {
      final r = ramps[kind];
      if (r == null || r.error != null) return '';
      return '${r.capped ? '' : '~'}${r.limit} $unit${r.limit == 1 ? '' : 's'}';
    }

    return [part('tracks', 'track'), part('voices', 'voice'), part('effects', 'effect')].where((p) => p.isNotEmpty).join(' · ');
  }

  /// "Biggest cost: instruments and effects (62%), mostly Flagship", from the parts, else the costliest component.
  String? get biggestCost {
    final ps = parts;
    if (ps.isNotEmpty) {
      final top = ps.first;
      final costly = holdingBack.where((c) => c.id != 'host').firstOrNull;
      final mostly = top.id == 'devices' && costly != null ? ', mostly ${costly.name}' : '';
      return 'Biggest cost: ${top.name.toLowerCase()} (${top.pct.round()}%)$mostly';
    }
    final c = holdingBack.firstOrNull;
    return c == null ? null : 'Biggest cost: ${c.name} (${c.pct.round()}%)';
  }
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
        'parts_scenario': partsScenario,
        'parts': [for (final p in parts) p.toJson()],
        'parts_by_scenario': {
          for (final e in partsByScenario.entries) e.key: [for (final p in e.value) p.toJson()],
        },
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
        b.writeln('${s.name}${s.live ? ' (${s.modeLabel.substring(3)})' : ''}: mean ${s.meanPct.round()}%, p99 ${s.p99Pct.round()}%, '
            'worst ${s.worstPct.round()}% of the budget, ${s.live ? '${s.dropouts} dropouts' : '${s.overBudget} callbacks over'}');
      } else {
        b.writeln('${s.name}: ${s.skipped ?? s.error ?? 'not run'}');
      }
    }
    return b.toString();
  }
}

/// The scenario features (contract API 30), in the order the results group them, with their plain names.
const stressFeatures = {
  'baseline': 'Baseline',
  'instrument': 'Instruments',
  'effect': 'Effects',
  'routing': 'Folder routing',
  'sends': 'Sends',
  'automation': 'Automation',
  'modulation': 'Modulation',
  'voices': 'Voices',
  'samples': 'Samples',
  'audio': 'Audio tracks',
  'metering': 'Meters',
  'mix_pool': 'Mix pool',
  'all': 'Whole songs',
};

/// A scenario's feature when the engine doesn't say (an API 29 engine): the contract's for the ids it had.
String scenarioFeature(String id) {
  const known = {
    'empty': 'baseline', 'tail_floor': 'baseline', 'drums_kit': 'instrument', 'single_synth': 'instrument',
    'single_sampler': 'instrument', 'single_drums': 'instrument', 'every_instrument': 'instrument',
    'single_audio': 'audio', 'folders_shallow': 'routing', 'folders_deep': 'routing', 'sends_few': 'sends',
    'sends_many': 'sends', 'sends_chained': 'sends', 'automation_light': 'automation', 'automation_dense': 'automation',
    'modulation_dense': 'modulation', 'voice_storm': 'voices', 'sample_stream': 'samples', 'resample': 'samples',
    'every_effect': 'effect', 'metering_heavy': 'metering', 'worst_all': 'all',
  };
  final k = known[id];
  if (k != null) return k;
  if (id.startsWith('flagship')) return 'instrument';
  return 'all'; // song*, first_loop, three_tracks: whole songs
}

/// One engine part's share of a profiled scenario's process() time (contract API 30, section 2).
class EnginePart {
  const EnginePart({required this.id, required this.pct, this.meanUs = 0, this.p99Us = 0});
  final String id;
  final double pct, meanUs, p99Us;

  /// The parts the engine reports, with their plain names and what each covers.
  static const info = {
    'mix': ('Mixing', 'Summing the tracks, gain and pan'),
    'routing': ('Folder routing', 'Folder tracks and their buses'),
    'sends': ('Sends', 'Send buses and what they feed'),
    'automation': ('Automation and modulation', 'Reading automation lanes and modulation'),
    'voices': ('Voice handling', 'Starting, stealing and releasing notes'),
    'samples': ('Sample streaming', 'Reading audio clips and samples, and resampling them'),
    'metering': ('Meters', 'Level meters and their peaks'),
    'device_io': ('Audio device', 'Handing audio to and from the device (live runs only)'),
    'mix_pool': ('Mix threads', 'Waiting for and handing out work to the mix threads'),
    'master': ('Master chain', 'The master effects and the limiter'),
    'devices': ('Instruments and effects', 'Every instrument\'s and effect\'s own processing'),
    'other': ('Other', 'Everything else in a callback'),
  };

  String get name => info[id]?.$1 ?? (id.isEmpty ? 'Other' : '${id[0].toUpperCase()}${id.substring(1).replaceAll('_', ' ')}');
  String get about => info[id]?.$2 ?? 'An engine part this version of the app doesn\'t know yet';

  /// At most this many parts are read from one scenario (the contract has 12).
  static const maxParts = 24;

  /// The parts in [raw] (engine JSON): non-numbers read as 0, negatives and non-finite values as 0, shares capped
  /// at 100%, ids at 32 characters, at most [maxParts], a repeated id once.
  static List<EnginePart> parseList(Object? raw) {
    if (raw is! List) return const [];
    final out = <EnginePart>[];
    final seen = <String>{};
    for (final p in raw.whereType<Map>()) {
      if (out.length >= maxParts) break;
      final id = p['id'];
      if (id is! String || id.isEmpty) continue;
      final key = id.length > 32 ? id.substring(0, 32) : id;
      if (!seen.add(key)) continue;
      double n(String k, double max) {
        final v = p[k];
        final d = v is num ? v.toDouble() : 0.0;
        return d.isFinite && d > 0 ? (d > max ? max : d) : 0;
      }

      out.add(EnginePart(id: key, pct: n('pct', 100), meanUs: n('mean_us', 1e7), p99Us: n('p99_us', 1e7)));
    }
    return out;
  }

  Map<String, Object?> toJson() => {'id': id, 'pct': _r1(pct), 'mean_us': _r1(meanUs), 'p99_us': _r1(p99Us)};
}

/// Plain tips for part [id] at a share of [pct] percent (the drill-down). Each is about the project, not settings.
List<String> partTips(String id, double pct) {
  final p = '${pct.round()}%';
  if (pct < 5) return ['${EnginePart(id: id, pct: pct).name} costs $p: small, not worth changing a project for.'];
  return switch (id) {
    'mix' => ['Mixing costs $p; it grows with the number of tracks, so fewer tracks (or bounced ones) cost less.'],
    'routing' => ['Folder routing costs $p; flatter folders (fewer levels inside each other) cost less.'],
    'sends' => ['Sends cost $p; fewer sends, or folder tracks instead, cost less.'],
    'automation' => ['Automation and modulation cost $p; fewer dense lanes, or slower modulation, cost less.'],
    'voices' => ['Voice handling costs $p; fewer notes at once and shorter releases mean fewer voices to start and steal.'],
    'samples' => ['Sample streaming costs $p; audio files at the project\'s sample rate skip resampling.'],
    'metering' => ['Meters cost $p; that is the engine\'s own work, so there is little to change in a project.'],
    'device_io' => ['The audio device costs $p; a larger buffer gives each callback more time.'],
    'mix_pool' => ['The mix threads\' handoff costs $p; it pays off on big projects and can cost more than it saves on small ones.'],
    'master' => ['The master chain costs $p; fewer master effects cost less.'],
    'devices' => [
        'Instruments and effects cost $p; the list below shows which.',
        'Fewer copies of the costliest one, or a lighter setting of it, helps most.',
      ],
    _ => ['${EnginePart(id: id, pct: pct).name} costs $p.'],
  };
}

/// The ten scenario ids section H2 and the relay know.
const telemetryScenarioIds = {
  'first_loop', 'three_tracks', 'song8', 'song8_extras', 'flagship_heavy', 'flagship_heavy16', 'drums_kit', 'song16',
  'song32_heavy', 'tail_floor',
};

double _r1(double v) => v.isFinite ? (v * 10).roundToDouble() / 10 : 0;
double _r2(double v) => v.isFinite ? (v * 100).roundToDouble() / 100 : 0;
