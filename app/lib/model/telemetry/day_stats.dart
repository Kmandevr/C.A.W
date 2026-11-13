// One UTC day of anonymous performance and usage counts (beta readiness plan E4), fed from the 30 Hz meter reads, the
// frame timings and a once-a-minute tick, and turned into an H2 report. No names, paths or content are ever kept.
import 'dart:math' as math;

import 'report_schema.dart';

/// The day's counts. Kept in the telemetry file so a restart the same day carries on.
class DayStats {
  DayStats(this.day);

  /// The UTC day, `YYYY-MM-DD`.
  final String day;

  /// Meter reads while playing, by CPU load in 10% steps (the last bucket holds 90% and over).
  final List<int> cpuBuckets = List.filled(10, 0);
  int dropouts = 0;
  double worstCpu = 0;

  /// Frame times in 1 ms bins (the last holds 100 ms and over), and frames over their budget.
  final List<int> frameBins = List.filled(101, 0);
  int slowFrames = 0;

  int? startupMs;
  int thermalEvents = 0;
  double batterySaverSeconds = 0;
  double openSeconds = 0, playingSeconds = 0;
  final Map<String, double> screenSeconds = {};
  final Map<String, int> builtins = {};
  int maxTracks = -1, maxClips = -1;

  /// The audio callback's core kind ("big", "little", "other", "unknown") at each audio-threads sample while playing
  /// (caw_audio_threads, [threads]), and the platform's scheduling hint ("on", "off", "unsupported"): "on" once it
  /// was on, else "off" once a platform that has one ran without it; null before any sample.
  final Map<String, int> coreKinds = {};
  String? schedHint;

  /// (type, where) → count, as H2's `errors`.
  final Map<String, int> errors = {};

  bool get empty => openSeconds <= 0 && playingSeconds <= 0 && startupMs == null;

  int get frames => frameBins.fold(0, (a, b) => a + b);

  // ---------- feeding ----------

  /// One meter read: [cpu] the share of the callback's budget (0..1+), [secondsSinceLast] the time it covers
  /// (capped, so a pause doesn't count as playing), [newDropouts] overruns since the last read.
  void meter({required double cpu, required bool playing, required double secondsSinceLast, int newDropouts = 0}) {
    if (newDropouts > 0) dropouts += newDropouts;
    if (!playing || !cpu.isFinite) return;
    cpuBuckets[(cpu * 10).floor().clamp(0, 9)]++;
    worstCpu = math.max(worstCpu, cpu);
    playingSeconds += secondsSinceLast.clamp(0, 1);
  }

  /// One audio-threads sample while playing: [coreKind] the callback's core kind, [hint] "on", "off" or
  /// "unsupported". Values outside H2's sets read as "unknown" and "unsupported".
  void threads({required String coreKind, required String hint}) {
    final kind = const {'big', 'little', 'other'}.contains(coreKind) ? coreKind : 'unknown';
    coreKinds[kind] = (coreKinds[kind] ?? 0) + 1;
    final h = const {'on', 'off'}.contains(hint) ? hint : 'unsupported';
    if (schedHint != 'on' && (h != 'unsupported' || schedHint == null)) schedHint = h;
  }

  /// The core kind the callback ran on most often today; "unknown" when no sample knew it.
  String get callbackCoreType {
    String? best;
    for (final k in const ['big', 'little', 'other']) {
      final n = coreKinds[k] ?? 0;
      if (n > 0 && (best == null || n > coreKinds[best]!)) best = k;
    }
    return best ?? 'unknown';
  }

  void frame(double totalMs, double budgetMs) {
    if (!totalMs.isFinite || totalMs < 0) return;
    frameBins[totalMs.floor().clamp(0, 100)]++;
    if (totalMs > budgetMs) slowFrames++;
  }

  void error(String type, String where) {
    final key = '$type\n$where';
    if (errors.containsKey(key) || errors.length < maxErrorEntries) errors[key] = (errors[key] ?? 0) + 1;
  }

  // ---------- the report ----------

  double _framePercentile(double p) {
    final n = frames;
    if (n == 0) return 0;
    final target = (n * p).ceil().clamp(1, n);
    var seen = 0;
    for (var i = 0; i < frameBins.length; i++) {
      seen += frameBins[i];
      if (seen >= target) return (i + 1).toDouble(); // the bin's upper edge: a frame took at most this long
    }
    return 101;
  }

  /// H2's `perf`; a figure nothing measured is null (owner, 2026-11-12). `schedHint` and `callbackCoreType` come
  /// from the day's audio-threads samples ([threads]); with none, H2 has no null for them, so "off" and "unknown".
  Map<String, Object?> perf() {
    final played = cpuBuckets.any((c) => c > 0);
    return {
      'cpuLoadHistogram': played ? histogramShares(cpuBuckets) : null,
      'dropouts': dropouts,
      'worstCallbackPct': played ? budgetPct5(worstCpu) : null,
      'frames': {
        'p50ms': frames == 0 ? null : _framePercentile(0.5),
        'p99ms': frames == 0 ? null : _framePercentile(0.99),
        'slowPct': frames == 0 ? null : (slowFrames / frames * 100).round(), // a whole percent (PLAN.md)
      },
      'startupMs': startupMs == null ? null : startupMs50(startupMs!),
      'thermalEvents': thermalEvents,
      'batterySaverMinutes': minutes5(batterySaverSeconds),
      'schedHint': schedHint ?? 'off',
      'callbackCoreType': callbackCoreType,
    };
  }

  /// H2's `usage`.
  Map<String, Object?> usage() => {
        'minutesOpen': minutes5(openSeconds),
        'minutesPlaying': minutes5(playingSeconds),
        'screens': {for (final e in screenSeconds.entries) e.key: minutes5(e.value)},
        'builtins': Map.of(builtins),
        'projectSize': {'tracks': tracksBucket(math.max(0, maxTracks)), 'clips': clipsBucket(math.max(0, maxClips))},
      };

  /// H2's `errors`, the most frequent first.
  List<Map<String, Object?>> errorList() {
    final list = [
      for (final e in errors.entries)
        {'type': e.key.split('\n').first, 'where': e.key.split('\n').last, 'count': e.value},
    ]..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
    return list.take(maxErrorEntries).toList();
  }

  // ---------- saving ----------

  Map<String, Object?> toJson() => {
        'day': day, 'cpu': cpuBuckets, 'dropouts': dropouts, 'worstCpu': worstCpu, 'frames': frameBins,
        'slow': slowFrames, 'startupMs': startupMs, 'thermal': thermalEvents, 'saver': batterySaverSeconds,
        'open': openSeconds, 'playing': playingSeconds, 'screens': screenSeconds, 'builtins': builtins,
        'tracks': maxTracks, 'clips': maxClips, 'errors': errors, 'coreKinds': coreKinds, 'hint': schedHint,
      };

  /// Null when [j] has no day; a wrong-typed field reads as empty, so one bad value never loses the rest.
  static DayStats? fromJson(Object? j) {
    if (j is! Map || j['day'] is! String) return null;
    final s = DayStats(j['day'] as String);
    double d(Object? v) => v is num && v.isFinite ? v.toDouble() : 0;
    int n(Object? v, [int or = 0]) => v is num && v.isFinite ? v.toInt() : or;
    void ints(Object? from, List<int> into) {
      if (from is! List || from.length != into.length) return;
      for (var i = 0; i < into.length; i++) {
        into[i] = n(from[i]);
      }
    }

    ints(j['cpu'], s.cpuBuckets);
    ints(j['frames'], s.frameBins);
    s
      ..dropouts = n(j['dropouts'])
      ..worstCpu = d(j['worstCpu'])
      ..slowFrames = n(j['slow'])
      ..startupMs = j['startupMs'] is num ? n(j['startupMs']) : null
      ..thermalEvents = n(j['thermal'])
      ..batterySaverSeconds = d(j['saver'])
      ..openSeconds = d(j['open'])
      ..playingSeconds = d(j['playing'])
      ..maxTracks = n(j['tracks'], -1)
      ..maxClips = n(j['clips'], -1)
      ..schedHint = const {'on', 'off', 'unsupported'}.contains(j['hint']) ? j['hint'] as String : null;
    for (final (key, into) in [('screens', s.screenSeconds)]) {
      if (j[key] case final Map m) {
        for (final e in m.entries) {
          if (e.key is String && e.value is num) into[e.key as String] = d(e.value);
        }
      }
    }
    for (final (key, into) in [('builtins', s.builtins), ('errors', s.errors), ('coreKinds', s.coreKinds)]) {
      if (j[key] case final Map m) {
        for (final e in m.entries) {
          if (e.key is String && e.value is num) into[e.key as String] = n(e.value);
        }
      }
    }
    return s;
  }
}

/// `YYYY-MM-DD` of [t] in UTC.
String utcDay(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}';
}
