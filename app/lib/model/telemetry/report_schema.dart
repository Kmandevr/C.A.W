// The caw-telemetry contract's shapes on the app's side (beta readiness plan H2, H4): rounding, size buckets and the
// allow-list every report and feedback body passes through before it is queued, so nothing on E6's list can leave.
import 'dart:convert';

/// H2's schema version.
const reportSchemaVersion = 1;

/// H2: a report is at most 8 KB; H4: a feedback body at most 32 KB; H4: feedback text at most 5,000 characters.
const maxReportBytes = 8 * 1024;
const maxFeedbackBytes = 32 * 1024;
const maxFeedbackChars = 5000;

/// H2: at most 20 error entries.
const maxErrorEntries = 20;

/// The screen ids `usage.screens` may name (the app's three sections). Anything else is sent as "other", as the
/// server does (H2).
const screenIds = {'build', 'files', 'arrange'};

/// Stress-test scenario ids (beta readiness plan C1), for `stress.scenarios`.
const stressScenarioIds = {
  'first_loop', 'three_tracks', 'song8', 'song8_extras', 'song16', 'drums_kit', 'flagship_heavy16',
  'flagship_heavy', 'song32_heavy', 'tail_floor',
};

// ---------- rounding (H2) ----------

/// [value] rounded to the nearest multiple of [step].
int roundToStep(num value, int step) => value.isFinite ? ((value / step).round() * step) : 0;

/// A clock in kHz (Linux and Android give kHz) as MHz rounded to 100 MHz.
int clockMHz(int khz) => roundToStep(khz / 1000, 100);

/// Bytes of RAM as a whole number of GB (GiB, as phones are sold).
int ramGB(int bytes) => (bytes / (1 << 30)).round();

/// A share of the callback's budget (1.0 = all of it) as a percentage rounded to 5%.
int budgetPct5(double share) => roundToStep(share * 100, 5);

/// Startup in ms, rounded to 50 ms.
int startupMs50(int ms) => roundToStep(ms, 50);

/// Seconds as minutes rounded to 5.
int minutes5(num seconds) => roundToStep(seconds / 60, 5);

/// H2's track buckets. A project with no tracks counts as the smallest bucket (H2 has no empty one).
String tracksBucket(int tracks) => tracks <= 4
    ? '1-4'
    : tracks <= 8
        ? '5-8'
        : tracks <= 16
            ? '9-16'
            : tracks <= 32
                ? '17-32'
                : '33+';

/// H2's clip buckets (no clips counts as the smallest bucket).
String clipsBucket(int clips) => clips <= 10
    ? '1-10'
    : clips <= 50
        ? '11-50'
        : clips <= 200
            ? '51-200'
            : '201+';

/// [shares] (any non-negative weights, 10 of them) as fractions of their sum, two decimals each; all zeros when
/// nothing was counted.
List<double> histogramShares(List<num> counts) {
  final total = counts.fold<num>(0, (a, b) => a + b);
  return [for (final c in counts) total <= 0 ? 0.0 : (c / total * 100).round() / 100];
}

// ---------- the allow-list (E6) ----------

/// One field's check: the value to keep, or null to drop it.
typedef TelemetryRule = Object? Function(Object? value);

final _hex32 = RegExp(r'^[0-9a-f]{32}$');
final _hex64 = RegExp(r'^[0-9a-f]{64}$');
final _day = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _version = RegExp(r'^[0-9A-Za-z.+-]{1,40}$');
final _osVersion = RegExp(r'^\d{1,3}$'); // digits only (H2 update 2026-11-12)
final _backend = RegExp(r'^[a-z0-9_]{1,24}$'); // lowercase a-z, 0-9 and _ only (H2 update)
final _errorType = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$<>, ?]{0,79}$');
// A relative C.A.W source location (H2 update 2026-11-12): one of the relay's prefixes, then `:<line>`; no `..`.
final _where = RegExp(r'^(lib/|src/|engine/|app/|platform/|include/|package:caw/)[A-Za-z0-9_][A-Za-z0-9_./-]{0,150}:\d{1,6}$');
final _componentId = RegExp(r'^[a-z0-9]+(\.[a-z0-9_-]+)+$');
final _scenarioId = RegExp(r'^[a-z0-9_]{1,32}$');
final _email = RegExp(r'^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$');

TelemetryRule _match(RegExp re) => (v) => v is String && re.hasMatch(v) ? v : null;

/// A short hardware name (CPU, GPU): printable text that can't be a path, an address or an email.
Object? _hardwareText(Object? v) {
  if (v is! String) return null;
  final t = v.trim();
  if (t.isEmpty || t.length > 80) return null;
  if (!RegExp(r'^[\x20-\x7e]+$').hasMatch(t)) return null;
  if (t.contains('\\') || t.contains('@') || t.contains(':') || t.contains('//')) return null;
  if (t.startsWith('/') || t.startsWith('~') || t.startsWith('.')) return null;
  return t;
}

TelemetryRule _int(int min, int max) => (v) => v is int && v >= min && v <= max ? v : null;
TelemetryRule _num(num min, num max) => (v) => v is num && v.isFinite && v >= min && v <= max ? v : null;
Object? _bool(Object? v) => v is bool ? v : null;
TelemetryRule _oneOf(Set<String> values) => (v) => v is String && values.contains(v) ? v : null;

/// An object with only [fields]; a field whose value fails its rule is left out.
TelemetryRule _object(Map<String, TelemetryRule> fields) => (v) {
      if (v is! Map) return null;
      final out = <String, Object?>{};
      for (final MapEntry(:key, value: rule) in fields.entries) {
        if (!v.containsKey(key)) continue;
        final r = rule(v[key]);
        if (r != null) out[key] = r;
      }
      return out;
    };

/// [rule] or an explicit null (H2 allows null for `stress`).
TelemetryRule _nullable(TelemetryRule rule) => (v) => v == null ? _keepNull : rule(v);
const _keepNull = _KeepNull();

class _KeepNull {
  const _KeepNull();
}

TelemetryRule _list(TelemetryRule item, int max) => (v) {
      if (v is! List) return null;
      final out = <Object?>[];
      for (final e in v) {
        if (out.length >= max) break;
        final r = item(e);
        if (r != null) out.add(r);
      }
      return out;
    };

/// A map from built-in ids to a number: an id [allowed] doesn't accept becomes "other" (values added up).
TelemetryRule _idMap(bool Function(String id) allowed, TelemetryRule value) => (v) {
      if (v is! Map) return null;
      final out = <String, num>{};
      for (final e in v.entries) {
        final n = value(e.value);
        if (n is! num) continue;
        final key = e.key is String && allowed(e.key as String) ? e.key as String : 'other';
        out[key] = (out[key] ?? 0) + n;
      }
      return out;
    };

/// The allow-list for H2 reports and H4 feedback: only the fields the contract names, with the types and values it
/// allows. Everything else (names, paths, notes, devices, accounts, contacts, locations, ids) is dropped.
class TelemetryAllowList {
  TelemetryAllowList({required this._isBuiltin});

  final bool Function(String id) _isBuiltin;

  bool _builtin(String id) => _componentId.hasMatch(id) && _isBuiltin(id);

  late final TelemetryRule device = _object({
    'platform': _oneOf({'android', 'windows', 'linux'}),
    'osVersion': _match(_osVersion),
    'cpu': _hardwareText,
    'cores': _object({'big': _int(0, 1024), 'little': _int(0, 1024), 'other': _int(0, 1024)}),
    'maxClockMHz': _list(_int(0, 20000), 4), // up to 4 core types (the relay's PLAN.md)
    'ramGB': _int(0, 4096),
    'gpu': _hardwareText,
    'refreshHz': _int(0, 1000),
    'audio': _object({
      'backend': _match(_backend),
      'exclusive': _bool,
      'lowLatency': _bool,
      'bufferFrames': _int(0, 1 << 20),
      'sampleRate': _int(0, 1000000),
    }),
    'profile': _oneOf({'full', 'balanced', 'lightweight', 'minimal'}),
    'eco': _bool,
  });

  late final TelemetryRule stress = _object({
    'version': _int(1, 1000),
    'tiers': _object({
      for (final t in const ['normal', 'heavy', 'extreme']) t: _oneOf({'comfortable', 'tight', 'over'}),
    }),
    'limits': _object({'tracks': _int(0, 100000), 'voices': _int(0, 100000), 'effects': _int(0, 100000)}),
    'scenarios': (Object? v) {
      if (v is! Map) return null;
      final rule = _object({
        'meanPct': _int(0, 100000), 'p99Pct': _int(0, 100000), 'worstPct': _int(0, 100000), 'dropouts': _int(0, 1 << 30),
      });
      return {
        for (final e in v.entries)
          if (e.key is String && _scenarioId.hasMatch(e.key as String))
            (stressScenarioIds.contains(e.key) ? e.key as String : 'other'): ?rule(e.value),
      };
    },
    'topCosts': _list(
        (v) => switch (_object({'component': (c) => c is String ? (_builtin(c) ? c : 'other') : null, 'pct': _int(0, 100000)})(v)) {
              final Map<String, Object?> m when m.containsKey('component') => m,
              _ => null,
            },
        10), // up to 10 (the relay's PLAN.md)
  });

  // An entry without a valid relative `where` is dropped whole (the relay answers an absolute path with 400).
  late final TelemetryRule errors = _list(
      (v) => switch (_object({'type': _match(_errorType), 'where': _match(_where), 'count': _int(0, 1 << 30)})(v)) {
            final Map<String, Object?> m when m.containsKey('where') && m.containsKey('type') && !(m['where'] as String).contains('..') => m,
            _ => null,
          },
      maxErrorEntries);

  late final TelemetryRule _report = _object({
    'schema': _int(reportSchemaVersion, reportSchemaVersion),
    'receipt': _match(_hex32),
    'deleteHash': _match(_hex64),
    'channel': _oneOf({'beta', 'release'}),
    'day': _match(_day),
    'app': _object({'version': _match(_version), 'engineVersion': _match(_version), 'capiVersion': _int(0, 100000)}),
    'device': device,
    'perf': _object({
      'cpuLoadHistogram': (v) => v is List && v.length == 10 ? _list(_num(0, 1), 10)(v) : null,
      'dropouts': _int(0, 1 << 30),
      'worstCallbackPct': _int(0, 100000),
      'frames': _object({'p50ms': _num(0, 100000), 'p99ms': _num(0, 100000), 'slowPct': _int(0, 100)}),
      'startupMs': _int(0, 1 << 30),
      'thermalEvents': _int(0, 1 << 30),
      'batterySaverMinutes': _int(0, 1 << 30),
      'schedHint': _oneOf({'on', 'off', 'unsupported'}),
      'callbackCoreType': _oneOf({'big', 'little', 'other', 'unknown'}),
    }),
    'usage': _object({
      'minutesOpen': _int(0, 1 << 30),
      'minutesPlaying': _int(0, 1 << 30),
      'screens': _idMap(screenIds.contains, _int(0, 1 << 30)),
      'builtins': _idMap(_builtin, _int(0, 1 << 30)),
      'projectSize': _object({
        'tracks': _oneOf({'1-4', '5-8', '9-16', '17-32', '33+'}),
        'clips': _oneOf({'1-10', '11-50', '51-200', '201+'}),
      }),
    }),
    'stress': _nullable(stress),
    'errors': errors,
  });

  late final TelemetryRule _feedback = _object({
    'schema': _int(1, 1),
    'kind': _oneOf({'bug', 'idea', 'confusing', 'praise'}),
    'text': (v) => v is String && v.trim().isNotEmpty && v.length <= maxFeedbackChars ? v : null,
    'appVersion': _match(_version),
    'platform': _oneOf({'android', 'windows', 'linux'}),
    'attachments': _object({'device': device, 'stress': stress, 'errors': errors}),
    'contact': (v) => v is String && v.length <= 254 && _email.hasMatch(v) ? v : null,
  });

  /// [report] with only H2's fields. The result is what gets queued and shown.
  Map<String, Object?> report(Map<String, Object?> report) => _unwrap(_report(report)) as Map<String, Object?>? ?? {};

  /// [body] with only H4's fields.
  Map<String, Object?> feedback(Map<String, Object?> body) => _unwrap(_feedback(body)) as Map<String, Object?>? ?? {};

  // The explicit-null marker back to null.
  static Object? _unwrap(Object? v) => switch (v) {
        _KeepNull() => null,
        Map() => {for (final e in v.entries) e.key as String: _unwrap(e.value)},
        List() => [for (final e in v) _unwrap(e)],
        _ => v,
      };
}

/// [json]'s UTF-8 size in bytes, as the relay counts it.
int jsonBytes(Object? json) => utf8.encode(jsonEncode(json)).length;
