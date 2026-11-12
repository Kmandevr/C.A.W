// Anonymous telemetry and feedback (beta readiness plan E, F; the caw-telemetry contract H): the on/off choice by
// build channel, the day's counts, the report queue (1 MB), one daily report and stress-test reports within the
// relay's limits, receipts and delete keys kept only on this device, "My data", and the feedback queue.
// Everything here runs on the UI isolate's event loop from meter reads the app already makes: no FFI, no audio thread.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../sha256.dart';
import 'day_stats.dart';
import 'device_probe.dart';
import 'relay_client.dart';
import 'report_schema.dart';
import 'telemetry_config.dart';

/// Where the telemetry state is kept (one JSON file in app-private storage; memory in tests).
abstract class TelemetryStore {
  Future<String?> read();
  Future<void> write(String text);
}

class FileTelemetryStore implements TelemetryStore {
  FileTelemetryStore(this.file);
  final File file;

  @override
  Future<String?> read() async {
    try {
      return await file.exists() ? await file.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String text) async {
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Storage full or gone: the state lives on in memory for this run.
    }
  }
}

class MemoryTelemetryStore implements TelemetryStore {
  String? text;
  @override
  Future<String?> read() async => text;
  @override
  Future<void> write(String text) async => this.text = text;
}

/// What the rest of the app tells telemetry (filled in by main and the shell; null parts read as unknown).
class TelemetryApp {
  String appVersion = '0.0.0';
  String engineVersion = 'unknown';
  int capiVersion = 0;

  /// The section in front ("arrange", "build", "files").
  String Function()? screen;

  /// H2 `device.audio`, the running device as the engine reports it.
  Map<String, Object?> Function()? audio;

  /// "full", "balanced", "lightweight" or "minimal".
  String Function()? profile;
  bool Function()? eco;
  int Function()? refreshHz;

  /// The built-in component ids the engine knows (H2: only these may be named).
  bool Function(String id)? isBuiltin;
}

enum ReportKind { daily, stress }

/// A report's state in "My data" (E5).
enum ReportStatus { queued, sent, published, rejected, deleteRequested, notFound }

/// One report this device made: its receipt, its delete key (both only ever on this device), and the exact JSON.
class ReportRecord {
  ReportRecord({
    required this.receipt,
    required this.deleteKey,
    required this.day,
    required this.kind,
    required this.json,
    required this.created,
    this.status = ReportStatus.queued,
    this.attempts = 0,
    this.sent,
  });

  final String receipt, deleteKey, day, json;
  final ReportKind kind;
  final DateTime created;
  ReportStatus status;
  int attempts;
  DateTime? sent;

  int get bytes => utf8.encode(json).length;

  Map<String, Object?> toJson() => {
        'receipt': receipt, 'deleteKey': deleteKey, 'day': day, 'kind': kind.name, 'json': json,
        'created': created.toUtc().toIso8601String(), 'status': status.name, 'attempts': attempts,
        'sent': sent?.toUtc().toIso8601String(),
      };

  static ReportRecord? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return ReportRecord(
        receipt: j['receipt'] as String,
        deleteKey: j['deleteKey'] as String,
        day: j['day'] as String,
        kind: ReportKind.values.byName(j['kind'] as String? ?? 'daily'),
        json: j['json'] as String,
        created: DateTime.parse(j['created'] as String),
        status: ReportStatus.values.byName(j['status'] as String? ?? 'queued'),
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        sent: j['sent'] == null ? null : DateTime.parse(j['sent'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

/// The feedback form's types (F1) as H4's `kind`.
enum FeedbackKind {
  bug('Bug'),
  idea('Idea'),
  confusing("Something's confusing"),
  praise('Praise');

  const FeedbackKind(this.label);
  final String label;
}

enum FeedbackOutcome { sent, queued, dailyLimit, invalid, unavailable }

class FeedbackResult {
  const FeedbackResult(this.outcome, {this.issueUrl});
  final FeedbackOutcome outcome;

  /// The public issue the relay made (H4 `201 {"issue":url}`), when it said.
  final String? issueUrl;
}

/// What happened to a stress-test result handed to [Telemetry.sendStressReport].
enum StressOutcome {
  /// Telemetry is off: nothing was sent or queued.
  off,

  /// Its own report was sent.
  sent,

  /// Its own report is queued (offline, or backing off) and goes when it can.
  queued,

  /// Today's report slots are used up: it rides on the next daily report instead.
  attachedToNextDaily,
}

/// Feedback that went out after waiting in the queue: the shell says "Sent, thanks".
class FeedbackSent {
  const FeedbackSent(this.issueUrl);
  final String? issueUrl;
}

class Telemetry extends ChangeNotifier {
  Telemetry({
    required this.config,
    required this._store,
    RelayHttp? http,
    this._probe,
    TelemetryApp? app,
    DateTime Function()? now,
    Random? random,
  })  : _relay = RelayClient(config, http ?? IoRelayHttp()),
        app = app ?? TelemetryApp(),
        _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  /// The app's telemetry once it has loaded (null in tests and anywhere it wasn't started); the shell listens.
  static final ValueNotifier<Telemetry?> active = ValueNotifier(null);
  static Telemetry? get current => active.value;
  static set current(Telemetry? t) => active.value = t;

  final TelemetryConfig config;
  final TelemetryStore _store;
  final RelayClient _relay;
  final DeviceProbe? _probe;
  final TelemetryApp app;
  final DateTime Function() _now;
  final Random _random;

  // ---------- limits (E4, H5 and the 2026-11-12 update to H) ----------

  static const queueCapBytes = 1024 * 1024;

  /// The relay's reports per sender per UTC day; one is always kept for the daily report.
  static const relayReportsPerDay = 10;
  static const feedbackPerDay = 5;
  static const lookupsPerDay = 200;
  static const defaultBackOff = Duration(hours: 1);
  static const offlinePause = Duration(minutes: 15);

  late final TelemetryAllowList allowList = TelemetryAllowList(isBuiltin: (id) => app.isBuiltin?.call(id) ?? false);

  // ---------- state ----------

  bool? _enabled;
  String? _lastChannel;
  bool _accepted = false;
  bool _askKeep = false;
  DayStats? _stats;
  final List<ReportRecord> _reports = [];
  String? _dailySentDay;
  String _postsDay = '';
  int _postsToday = 0;
  String _lookupDay = '';
  int _lookupsToday = 0;
  DateTime? _reportBackOffUntil;
  DateTime? _feedbackBackOffUntil;
  DateTime? _offlineUntil;
  Map<String, Object?>? _pendingStress;
  final List<Map<String, Object?>> _feedbackQueue = [];
  String _feedbackDay = '';
  int _feedbackSubmitted = 0, _feedbackPosted = 0;
  bool _loaded = false;
  bool _busy = false;

  final _feedbackSent = StreamController<FeedbackSent>.broadcast();

  /// Queued feedback that has now gone out.
  Stream<FeedbackSent> get feedbackSent => _feedbackSent.stream;

  bool get enabled => _enabled ?? false;
  BuildChannel get channel => config.channel;

  /// The first-run page (E2) hasn't been accepted yet.
  bool get firstRunNeeded => _loaded && !_accepted;

  /// The first release launch after a beta build turned telemetry off and asks once whether to keep it (E1).
  bool get askKeepNeeded => _loaded && _accepted && _askKeep;

  /// Every report this device made, newest first.
  List<ReportRecord> get reports => List.unmodifiable(_reports.reversed);
  List<ReportRecord> get queued => [for (final r in _reports) if (r.status == ReportStatus.queued) r];
  int get queueBytes => queued.fold(0, (a, r) => a + r.bytes);
  int get feedbackQueued => _feedbackQueue.length;
  DayStats? get today => _stats;
  Map<String, Object?>? get pendingStress => _pendingStress;

  /// The newest stress-test result this run (H2 `stress`), or null until the stress test (section C) has run.
  Map<String, Object?>? lastStress;

  String get _today => utcDay(_now());

  // ---------- loading, saving and the channel default (E1) ----------

  Future<void> load() async {
    Map<String, Object?> j = const {};
    try {
      final text = await _store.read();
      if (text != null) j = (jsonDecode(text) as Map).cast<String, Object?>();
    } catch (_) {
      j = const {};
    }
    _enabled = j['enabled'] as bool?;
    _lastChannel = j['channel'] as String?;
    _accepted = j['accepted'] == true;
    _askKeep = j['askKeep'] == true;
    _stats = DayStats.fromJson(j['stats']);
    for (final r in (j['reports'] as List?) ?? const []) {
      final rec = ReportRecord.fromJson(r);
      if (rec != null) _reports.add(rec);
    }
    _dailySentDay = j['dailySentDay'] as String?;
    _postsDay = j['postsDay'] as String? ?? '';
    _postsToday = (j['postsToday'] as num?)?.toInt() ?? 0;
    _lookupDay = j['lookupDay'] as String? ?? '';
    _lookupsToday = (j['lookupsToday'] as num?)?.toInt() ?? 0;
    _reportBackOffUntil = DateTime.tryParse(j['reportBackOff'] as String? ?? '');
    _feedbackBackOffUntil = DateTime.tryParse(j['feedbackBackOff'] as String? ?? '');
    _pendingStress = (j['pendingStress'] as Map?)?.cast<String, Object?>();
    for (final f in (j['feedback'] as List?) ?? const []) {
      if (f is Map) _feedbackQueue.add(f.cast<String, Object?>());
    }
    _feedbackDay = j['feedbackDay'] as String? ?? '';
    _feedbackSubmitted = (j['feedbackSubmitted'] as num?)?.toInt() ?? 0;
    _feedbackPosted = (j['feedbackPosted'] as num?)?.toInt() ?? 0;

    final channel = config.channel.name;
    if (_enabled == null) {
      _enabled = config.channel == BuildChannel.beta; // a first install: on in beta, off in release
    } else if (config.channel == BuildChannel.release && _lastChannel == BuildChannel.beta.name) {
      // The first release launch after a beta build: off, and asked once.
      if (_enabled == true) _askKeep = true;
      _setEnabledQuietly(false);
    }
    _lastChannel = channel;
    _loaded = true;
    await _save();
    notifyListeners();
  }

  Future<void> _save() => _store.write(jsonEncode({
        'enabled': _enabled,
        'channel': _lastChannel,
        'accepted': _accepted,
        'askKeep': _askKeep,
        'stats': _stats?.toJson(),
        'reports': [for (final r in _reports) r.toJson()],
        'dailySentDay': _dailySentDay,
        'postsDay': _postsDay,
        'postsToday': _postsToday,
        'lookupDay': _lookupDay,
        'lookupsToday': _lookupsToday,
        'reportBackOff': _reportBackOffUntil?.toUtc().toIso8601String(),
        'feedbackBackOff': _feedbackBackOffUntil?.toUtc().toIso8601String(),
        'pendingStress': _pendingStress,
        'feedback': _feedbackQueue,
        'feedbackDay': _feedbackDay,
        'feedbackSubmitted': _feedbackSubmitted,
        'feedbackPosted': _feedbackPosted,
      }));

  // ---------- the user's choices (E2, E3) ----------

  Future<void> acceptFirstRun() async {
    _accepted = true;
    await _save();
    notifyListeners();
  }

  /// The once-only question after a beta build: keep sending or not.
  Future<void> answerKeep(bool keep) async {
    _askKeep = false;
    _setEnabledQuietly(keep);
    await _save();
    notifyListeners();
  }

  /// Settings › Privacy's toggle. Off stops sending at once and wipes the queue and the day's counts.
  Future<void> setEnabled(bool on) async {
    _setEnabledQuietly(on);
    _askKeep = false;
    await _save();
    notifyListeners();
    if (on) unawaited(pump());
  }

  void _setEnabledQuietly(bool on) {
    _enabled = on;
    if (on) return;
    _reports.removeWhere((r) => r.status == ReportStatus.queued);
    _stats = null;
    _pendingStress = null;
  }

  // ---------- collecting (only while on) ----------

  DayStats? get _collecting {
    if (!enabled) return null;
    final day = _today;
    final s = _stats;
    if (s != null && s.day == day) return s;
    if (s != null && !s.empty) unawaited(_queueDaily(s)); // the minute tick usually got there first ([_rollOver])
    return _stats = DayStats(day);
  }

  /// A new UTC day: the last day's counts become its queued report.
  Future<void> _rollOver() async {
    final s = _stats;
    if (s == null || s.day == _today) return;
    _stats = null;
    if (enabled && !s.empty) await _queueDaily(s);
  }

  int _lastOverloads = -1;
  DateTime? _lastMeter;

  /// A meter read the app already made (30 Hz while playing; AppState's poller).
  void onMeters({required double cpu, required bool playing, required int overloaded}) {
    final s = _collecting;
    final t = _now();
    final since = _lastMeter == null ? 0.0 : t.difference(_lastMeter!).inMicroseconds / 1e6;
    _lastMeter = t;
    final fresh = _lastOverloads < 0 || overloaded < _lastOverloads ? 0 : overloaded - _lastOverloads;
    _lastOverloads = overloaded;
    s?.meter(cpu: cpu, playing: playing, secondsSinceLast: since, newDropouts: fresh);
  }

  /// Play pressed: counts the built-ins in the project and its size ([componentIds] are every component the
  /// project's tracks use; non-built-ins are ignored here and never kept).
  void onPlay({required Iterable<String> componentIds, required int tracks, required int clips}) {
    final s = _collecting;
    if (s == null) return;
    for (final id in componentIds.toSet()) {
      if (app.isBuiltin?.call(id) ?? false) s.builtins[id] = (s.builtins[id] ?? 0) + 1;
    }
    s.maxTracks = max(s.maxTracks, tracks);
    s.maxClips = max(s.maxClips, clips);
  }

  void onFrame(double totalMs) {
    final hz = app.refreshHz?.call() ?? 60;
    _collecting?.frame(totalMs, 1000 / (hz <= 0 ? 60 : hz));
  }

  bool _hot = false;

  /// The platform's thermal and power state, as ResourceSignals reports it.
  void onPressure({required bool hot, required bool batterySaver}) {
    final s = _collecting;
    if (s != null && hot && !_hot) s.thermalEvents++;
    _hot = hot;
    _batterySaver = batterySaver;
  }

  bool _batterySaver = false;

  void onStartup(int ms) {
    final s = _collecting;
    if (s != null) s.startupMs ??= ms;
  }

  void onError(String type, String where) => _collecting?.error(type, where);

  /// The minute tick: [seconds] of time passed with the app in front when [foreground]. Rolls the day over, saves,
  /// and sends what is due.
  Future<void> tick({required double seconds, required bool foreground}) async {
    await _rollOver();
    final s = _collecting;
    if (s != null && foreground) {
      s.openSeconds += seconds;
      final screen = app.screen?.call();
      if (screen != null) s.screenSeconds[screen] = (s.screenSeconds[screen] ?? 0) + seconds;
      if (_batterySaver) s.batterySaverSeconds += seconds;
    }
    if (enabled || _feedbackQueue.isNotEmpty) await _save();
    await pump();
  }

  // ---------- building reports (H2) ----------

  String _hex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
  List<int> _bytes(int n) => [for (var i = 0; i < n; i++) _random.nextInt(256)];

  /// A fresh receipt (128 random bits) and delete key (32 random bytes) with its hash: SHA-256 of the key's raw
  /// bytes, lowercase hex (H2 and its 2026-11-12 update).
  ({String receipt, String deleteKey, String deleteHash}) newReceipt() {
    final key = _bytes(32);
    return (receipt: _hex(_bytes(16)), deleteKey: _hex(key), deleteHash: sha256Hex(key));
  }

  Future<Map<String, Object?>> _device() async {
    final facts = await (_probe?.read() ?? Future.value(const DeviceFacts(platform: null)));
    return {
      ...facts.toJson(),
      'refreshHz': app.refreshHz?.call() ?? 0,
      'audio': app.audio?.call() ?? const {},
      'profile': app.profile?.call() ?? 'balanced',
      'eco': app.eco?.call() ?? false,
    };
  }

  /// H2's `device`, allow-listed (the feedback form's "Attach device info").
  Future<Map<String, Object?>> deviceInfo() async =>
      (allowList.device(await _device()) as Map<String, Object?>?) ?? const {};

  /// The report for [stats] with [stress], allow-listed, as it would be queued.
  Future<Map<String, Object?>> buildReport(DayStats stats,
      {required String receipt, required String deleteHash, Map<String, Object?>? stress}) async {
    final raw = <String, Object?>{
      'schema': reportSchemaVersion,
      'receipt': receipt,
      'deleteHash': deleteHash,
      'channel': config.channel.name,
      'day': stats.day,
      'app': {'version': app.appVersion, 'engineVersion': app.engineVersion, 'capiVersion': app.capiVersion},
      'device': await _device(),
      'perf': stats.perf(),
      'usage': stats.usage(),
      'stress': stress,
      'errors': stats.errorList(),
    };
    var report = allowList.report(raw);
    // At most 8 KB: the error list goes first, then the stress details.
    if (jsonBytes(report) > maxReportBytes) report['errors'] = const <Object?>[];
    if (jsonBytes(report) > maxReportBytes) report['stress'] = null;
    return report;
  }

  Future<void> _queueDaily(DayStats s) async {
    final stress = _pendingStress;
    _pendingStress = null;
    final r = newReceipt();
    final report = await buildReport(s, receipt: r.receipt, deleteHash: r.deleteHash, stress: stress);
    _enqueue(ReportRecord(receipt: r.receipt, deleteKey: r.deleteKey, day: s.day, kind: ReportKind.daily,
        json: jsonEncode(report), created: _now()));
  }

  void _enqueue(ReportRecord rec) {
    if (rec.bytes > maxReportBytes) return;
    _reports.add(rec);
    // The queue is capped at 1 MB: the oldest queued reports go first (they were never sent, so nothing is lost
    // anywhere else).
    while (queueBytes > queueCapBytes) {
      _reports.remove(queued.first);
    }
    notifyListeners();
  }

  @visibleForTesting
  void enqueueForTest(ReportRecord rec) => _enqueue(rec);

  /// Ends the day now (tests, and the day rolling over): today's counts become a queued report.
  @visibleForTesting
  Future<void> closeDay() async {
    final s = _stats;
    if (s == null || !enabled) return;
    _stats = null;
    await _queueDaily(s);
    await _save();
  }

  /// What today's report holds so far (Settings › Privacy shows it beside the queue); null when off.
  Future<Map<String, Object?>?> previewToday() async {
    final s = _collecting;
    if (s == null) return null;
    return buildReport(s, receipt: '0' * 32, deleteHash: '0' * 64, stress: _pendingStress);
  }

  // ---------- stress-test results (owner, 2026-11-12) ----------

  void _countDay() {
    final day = _today;
    if (_postsDay != day) {
      _postsDay = day;
      _postsToday = 0;
    }
  }

  int get _stressQueuedToday =>
      _reports.where((r) => r.kind == ReportKind.stress && r.status == ReportStatus.queued && r.day == _today).length;

  /// Whether a stress report may take a slot today: one of the relay's 10 is always kept for the daily report.
  bool get stressSlotFree {
    _countDay();
    final reserve = _dailySentDay == _today ? 0 : 1;
    return _postsToday + _stressQueuedToday < relayReportsPerDay - reserve;
  }

  /// A finished stress test's H2 `stress` object, sent at once as its own report (device, app, today's perf so far,
  /// usage, errors and the result) when telemetry is on. With today's slots used up it rides on the next daily
  /// report instead (the newest result wins). Off: nothing is sent or kept.
  Future<StressOutcome> sendStressReport(Map<String, Object?> stress) async {
    final clean = allowList.stress(stress) as Map<String, Object?>?;
    if (clean == null) return StressOutcome.off;
    lastStress = clean; // the feedback form's "Attach last stress-test result", kept on the device either way
    if (!enabled) return StressOutcome.off;
    if (!stressSlotFree) {
      _pendingStress = clean;
      await _save();
      notifyListeners();
      return StressOutcome.attachedToNextDaily;
    }
    final stats = _collecting!;
    final r = newReceipt();
    final report = await buildReport(stats, receipt: r.receipt, deleteHash: r.deleteHash, stress: clean);
    final rec = ReportRecord(receipt: r.receipt, deleteKey: r.deleteKey, day: stats.day, kind: ReportKind.stress,
        json: jsonEncode(report), created: _now());
    _enqueue(rec);
    await _save();
    await pump();
    return rec.status == ReportStatus.queued ? StressOutcome.queued : StressOutcome.sent;
  }

  // ---------- sending ----------

  /// Sends what is due: queued reports (one daily report per UTC day, stress reports within the day's slots) and
  /// queued feedback. Gives up quietly offline and keeps everything for the next try.
  Future<void> pump() async {
    if (_busy || !_loaded) return;
    _busy = true;
    try {
      await _rollOver();
      await _sendReports();
      await _sendFeedback();
      await _save();
    } finally {
      _busy = false;
    }
    notifyListeners();
  }

  bool _waiting(DateTime? until) => until != null && _now().isBefore(until);

  Future<void> _sendReports() async {
    if (!enabled || !config.canSend || _waiting(_reportBackOffUntil) || _waiting(_offlineUntil)) return;
    for (final rec in queued) {
      _countDay();
      if (_postsToday >= relayReportsPerDay) return;
      if (rec.kind == ReportKind.daily && _dailySentDay == _today) continue;
      if (rec.kind == ReportKind.stress) {
        final reserve = _dailySentDay == _today ? 0 : 1;
        if (_postsToday >= relayReportsPerDay - reserve) continue;
      }
      rec.attempts++;
      final res = await _relay.postReport(rec.json);
      if (!res.offline) _postsToday++;
      if (!enabled) return; // turned off while it was on its way
      switch (res.status) {
        case 202 || 200 || 201:
          _markSent(rec);
        case 400 when rec.attempts > 1:
          // A receipt is good for one POST: a 400 on a resend means an earlier try got there.
          _markSent(rec);
        case 400 || 413:
          rec.status = ReportStatus.rejected;
        case 0:
          _offlineUntil = _now().add(offlinePause);
          return;
        default:
          _reportBackOffUntil = _now().add(res.retryAfter ?? defaultBackOff);
          return;
      }
    }
  }

  void _markSent(ReportRecord rec) {
    rec
      ..status = ReportStatus.sent
      ..sent = _now();
    if (rec.kind == ReportKind.daily) _dailySentDay = _today;
  }

  // ---------- My data (E5) ----------

  /// "Check on server" (H3 GET): each sent report's state; at most the relay's 200 lookups a day. Returns how
  /// many were checked, or null when the relay can't be reached.
  Future<int?> checkOnServer() async {
    if (!config.canSend) return null;
    var checked = 0;
    for (final rec in _reports.where((r) => r.status == ReportStatus.sent || r.status == ReportStatus.published)) {
      final day = _today;
      if (_lookupDay != day) {
        _lookupDay = day;
        _lookupsToday = 0;
      }
      if (_lookupsToday >= lookupsPerDay) break;
      _lookupsToday++;
      final res = await _relay.getReport(rec.receipt);
      if (res.offline) {
        await _save();
        notifyListeners();
        return checked == 0 ? null : checked;
      }
      if (res.backOff) break;
      checked++;
      rec.status = switch (res.status) {
        200 => ReportStatus.published,
        202 => ReportStatus.sent,
        404 => ReportStatus.notFound,
        _ => rec.status,
      };
    }
    await _save();
    notifyListeners();
    return checked;
  }

  /// "Delete my data" (H3 delete), 100 receipts per request; queued reports are simply dropped. Returns the
  /// number the relay said it will delete, or null when it couldn't be reached or asked to wait.
  Future<int?> deleteMyData() async {
    _reports.removeWhere((r) => r.status == ReportStatus.queued);
    _stats = null;
    _pendingStress = null;
    final sent = [
      for (final r in _reports)
        if (r.status == ReportStatus.sent || r.status == ReportStatus.published || r.status == ReportStatus.notFound) r,
    ];
    var deleted = 0;
    if (sent.isNotEmpty) {
      if (!config.canSend) {
        await _save();
        notifyListeners();
        return null;
      }
      for (var i = 0; i < sent.length; i += 100) {
        final batch = sent.sublist(i, min(i + 100, sent.length));
        final res = await _relay.delete([for (final r in batch) (receipt: r.receipt, deleteKey: r.deleteKey)]);
        if (res.status != 202 && res.status != 200) {
          await _save();
          notifyListeners();
          return null;
        }
        deleted += (res.json?['deleted'] as num?)?.toInt() ?? batch.length;
        for (final r in batch) {
          r.status = ReportStatus.deleteRequested;
        }
      }
    }
    await _save();
    notifyListeners();
    return deleted;
  }

  /// "Export my receipts": every receipt with its delete key, so the data can still be deleted after a reinstall.
  String exportReceipts() => const JsonEncoder.withIndent('  ').convert({
        'about': 'C.A.W telemetry receipts. Each delete key can delete its report from caw-telemetry; keep them private.',
        'exported': _now().toUtc().toIso8601String(),
        'receipts': [
          for (final r in _reports.reversed)
            {'receipt': r.receipt, 'deleteKey': r.deleteKey, 'day': r.day, 'status': r.status.name},
        ],
      });

  // ---------- feedback (F, H4) ----------

  void _feedbackCountDay() {
    final day = _today;
    if (_feedbackDay != day) {
      _feedbackDay = day;
      _feedbackSubmitted = 0;
      _feedbackPosted = 0;
    }
  }

  /// How many more feedback posts today allows (H5: five a day).
  int get feedbackLeftToday {
    _feedbackCountDay();
    return max(0, feedbackPerDay - _feedbackSubmitted);
  }

  /// The H4 body for the form's choices, allow-listed (shown in full before sending).
  Map<String, Object?> feedbackBody({
    required FeedbackKind kind,
    required String text,
    Map<String, Object?>? device,
    Map<String, Object?>? stress,
    List<Map<String, Object?>>? errors,
    String? contact,
  }) {
    final platform = Platform.isAndroid ? 'android' : Platform.isWindows ? 'windows' : 'linux';
    return allowList.feedback({
      'schema': 1,
      'kind': kind.name,
      'text': text.trim(),
      'appVersion': app.appVersion,
      'platform': platform,
      'attachments': {'device': ?device, 'stress': ?stress, 'errors': ?errors},
      if (contact != null && contact.trim().isNotEmpty) 'contact': contact.trim(),
    });
  }

  /// Sends the feedback form (works with telemetry off). Offline or backing off, it waits in the queue and
  /// [feedbackSent] says when it went.
  Future<FeedbackResult> submitFeedback(Map<String, Object?> body) async {
    if (body['text'] == null || body['kind'] == null) return const FeedbackResult(FeedbackOutcome.invalid);
    if (jsonBytes(body) > maxFeedbackBytes) return const FeedbackResult(FeedbackOutcome.invalid);
    if (feedbackLeftToday <= 0) return const FeedbackResult(FeedbackOutcome.dailyLimit);
    if (!config.canSend) return const FeedbackResult(FeedbackOutcome.unavailable);
    _feedbackSubmitted++;
    final entry = {'body': body, 'created': _now().toUtc().toIso8601String()};
    _feedbackQueue.add(entry);
    await _save();
    final res = await _postFeedback(entry, announce: false);
    await _save();
    notifyListeners();
    return res ?? const FeedbackResult(FeedbackOutcome.queued);
  }

  Future<FeedbackResult?> _postFeedback(Map<String, Object?> entry, {required bool announce}) async {
    if (_waiting(_feedbackBackOffUntil)) return null;
    _feedbackCountDay();
    if (_feedbackPosted >= feedbackPerDay) return null;
    final res = await _relay.postFeedback(jsonEncode(entry['body']));
    if (res.offline) return null;
    _feedbackPosted++;
    switch (res.status) {
      case 201 || 202 || 200:
        _feedbackQueue.remove(entry);
        final url = res.json?['issue'] as String?;
        final issue = url != null && url.startsWith('https://github.com/') ? url : null;
        if (announce) _feedbackSent.add(FeedbackSent(issue));
        return FeedbackResult(FeedbackOutcome.sent, issueUrl: issue);
      case 400 || 413:
        _feedbackQueue.remove(entry); // the relay will never take it
        return const FeedbackResult(FeedbackOutcome.invalid);
      default:
        _feedbackBackOffUntil = _now().add(res.retryAfter ?? defaultBackOff);
        return null;
    }
  }

  Future<void> _sendFeedback() async {
    if (!config.canSend) return;
    for (final entry in List.of(_feedbackQueue)) {
      final r = await _postFeedback(entry, announce: true);
      if (r == null) return;
    }
  }

  // ---------- running in the app ----------

  Timer? _timer;
  DateTime? _lastTick;
  bool foreground = true;

  /// Starts the once-a-minute tick (main.dart). Frame timings and lifecycle are wired by the caller.
  void start() {
    _timer?.cancel();
    _lastTick = _now();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      final t = _now();
      final seconds = _lastTick == null ? 60.0 : t.difference(_lastTick!).inMilliseconds / 1000;
      _lastTick = t;
      unawaited(tick(seconds: seconds.clamp(0, 120).toDouble(), foreground: foreground));
    });
    unawaited(pump());
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_feedbackSent.close());
    super.dispose();
  }
}
