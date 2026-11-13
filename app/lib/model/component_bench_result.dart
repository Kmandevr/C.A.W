// A plug-in benchmark's result (contract API 30, section 4): the component's cost, its checks, its own sections and the curves, parsed with limits.
import 'dart:convert';

/// A check's outcome.
enum BenchCheckStatus {
  fail('✗'),
  warn('⚠'),
  pass('✓');

  const BenchCheckStatus(this.mark);
  final String mark;

  static BenchCheckStatus? parse(Object? v) => switch (v) { 'pass' => pass, 'warn' => warn, 'fail' => fail, _ => null };
}

/// One check: allocations, denormals, the cost per voice (instruments), scaling, parameter changes, silence.
class BenchCheck {
  const BenchCheck({required this.id, required this.status, this.value, this.detail = ''});
  final String id;
  final BenchCheckStatus status;
  final double? value;

  /// The engine's own words ("No allocations in the audio path").
  final String detail;

  static const names = {
    'allocations': 'Allocations',
    'denormals': 'Denormals',
    'cost_per_voice': 'Cost per voice',
    'block_size_scaling': 'Block size',
    'sample_rate_scaling': 'Sample rate',
    'param_change_cost': 'Parameter changes',
    'silence_cost': 'At silence',
  };

  String get name => names[id] ?? _words(id);
}

/// A section the component timed with CAW_PROFILE_SCOPE("name").
class BenchSection {
  const BenchSection({required this.name, required this.pct, this.meanNs = 0, this.calls = 0});
  final String name;

  /// Its share of the component's own time.
  final double pct, meanNs;
  final int calls;
}

/// A curve: the component's cost (% of a block) against voices, block size or sample rate.
class BenchCurve {
  const BenchCurve({required this.id, required this.points});
  final String id;
  final List<(double, double)> points;

  static const names = {'voices': 'Voices', 'block_frames': 'Block size (frames)', 'sample_rate': 'Sample rate (Hz)'};
  String get name => names[id] ?? _words(id);
}

class ComponentBenchResult {
  ComponentBenchResult({
    this.componentId = '',
    this.name = '',
    this.kind = 'effect',
    this.costPct = 0,
    this.meanUs = 0,
    this.p99Us = 0,
    this.budgetUs = 0,
    this.checks = const [],
    this.sections = const [],
    this.curves = const [],
    this.error,
  });

  final String componentId, name;

  /// effect or instrument.
  final String kind;

  /// Its share of one block's time budget, and its times.
  final double costPct, meanUs, p99Us, budgetUs;

  /// Fails first, then warnings, then passes (each in the engine's order).
  final List<BenchCheck> checks;

  /// Slowest first.
  final List<BenchSection> sections;

  /// voices (instruments), block_frames and sample_rate, in that order when present.
  final List<BenchCurve> curves;

  /// Why there is no result (the engine refused or failed, or its JSON was unreadable); null when there is one.
  final String? error;

  bool get ok => error == null;
  bool get isInstrument => kind == 'instrument';

  /// Limits on what is read: a result is the engine's, but its names are the user's code's.
  static const maxBytes = 256 * 1024, maxChecks = 16, maxSections = 32, maxPoints = 64, maxText = 160;

  /// Reads the engine's JSON text; never throws (an unreadable or oversized one is a result with an [error]).
  static ComponentBenchResult parseText(String text) {
    if (text.length > maxBytes) return ComponentBenchResult(error: 'The result was too large to read');
    try {
      return parse(jsonDecode(text));
    } on FormatException {
      return ComponentBenchResult(error: 'The result could not be read');
    }
  }

  /// Reads the engine's decoded JSON; never throws.
  static ComponentBenchResult parse(Object? json) {
    if (json is! Map) return ComponentBenchResult(error: 'The result could not be read');
    final err = json['error'];
    if (json['ok'] == false || (err is String && err.isNotEmpty)) {
      return ComponentBenchResult(error: _text(err is String && err.isNotEmpty ? err : 'The benchmark failed'));
    }
    if (json['tool'] != null && json['tool'] != 'caw_component_bench') {
      return ComponentBenchResult(error: 'That is not a plug-in benchmark result');
    }
    final c = json['component'] is Map ? json['component'] as Map : const {};
    final checks = <BenchCheck>[];
    for (final x in (json['checks'] is List ? json['checks'] as List : const []).whereType<Map>()) {
      if (checks.length >= maxChecks) break;
      final status = BenchCheckStatus.parse(x['status']);
      final id = x['id'];
      if (status == null || id is! String || id.isEmpty) continue;
      final v = x['value'];
      checks.add(BenchCheck(
          id: _text(id, 48),
          status: status,
          value: v is num && v.isFinite ? v.toDouble() : null,
          detail: x['detail'] is String ? _text(x['detail'] as String) : ''));
    }
    final ordered = [for (final s in BenchCheckStatus.values) ...checks.where((c) => c.status == s)];
    final sections = <BenchSection>[];
    for (final x in (json['sections'] is List ? json['sections'] as List : const []).whereType<Map>()) {
      if (sections.length >= maxSections) break;
      final n = x['name'];
      if (n is! String || n.isEmpty) continue;
      sections.add(BenchSection(
          name: _text(n, 48), pct: _num(x['pct'], 100), meanNs: _num(x['mean_ns'], 1e12), calls: _num(x['calls'], 1e12).toInt()));
    }
    sections.sort((a, b) => b.pct.compareTo(a.pct));
    final curves = <BenchCurve>[];
    final raw = json['curves'] is Map ? json['curves'] as Map : const {};
    for (final id in const ['voices', 'block_frames', 'sample_rate']) {
      final pts = <(double, double)>[];
      for (final p in (raw[id] is List ? raw[id] as List : const [])) {
        if (pts.length >= maxPoints) break;
        if (p is! List || p.length < 2 || p[0] is! num || p[1] is! num) continue;
        final x = (p[0] as num).toDouble(), y = (p[1] as num).toDouble();
        if (!x.isFinite || !y.isFinite || x < 0) continue;
        pts.add((x, y < 0 ? 0 : (y > 1000 ? 1000 : y)));
      }
      pts.sort((a, b) => a.$1.compareTo(b.$1));
      if (pts.length >= 2) curves.add(BenchCurve(id: id, points: pts));
    }
    return ComponentBenchResult(
      componentId: c['id'] is String ? _text(c['id'] as String, 128) : '',
      name: c['name'] is String ? _text(c['name'] as String, 64) : '',
      kind: c['kind'] == 'instrument' ? 'instrument' : 'effect',
      costPct: _num(json['cost_pct'], 1e4),
      meanUs: _num(json['mean_us'], 1e9),
      p99Us: _num(json['p99_us'], 1e9),
      budgetUs: _num(json['budget_us'], 1e9),
      checks: ordered,
      sections: sections,
      curves: curves,
    );
  }

  static String _text(String s, [int max = maxText]) {
    final t = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return t.length > max ? '${t.substring(0, max - 1)}…' : t;
  }

  static double _num(Object? v, double max) {
    final d = v is num ? v.toDouble() : 0.0;
    return d.isFinite && d > 0 ? (d > max ? max : d) : 0;
  }
}

String _words(String id) {
  final t = id.replaceAll('_', ' ');
  return t.isEmpty ? id : '${t[0].toUpperCase()}${t.substring(1)}';
}
