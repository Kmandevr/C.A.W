// Tests telemetry and feedback's model (beta readiness plan E, F, H): H2 report building and rounding, the allow-list
// (E6 and the 2026-11-12 H updates), the 1 MB queue, one daily report, Retry-After, channel defaults, receipts and
// delete keys, stress-test reports within the relay's limits, and feedback limits, with a fake relay and clock.
import 'dart:convert';
import 'dart:math';

import 'package:caw/model/problem_log.dart';
import 'package:caw/model/sha256.dart';
import 'package:caw/model/telemetry/day_stats.dart';
import 'package:caw/model/telemetry/device_probe.dart';
import 'package:caw/model/telemetry/relay_client.dart';
import 'package:caw/model/telemetry/report_schema.dart';
import 'package:caw/model/telemetry/telemetry.dart';
import 'package:caw/model/telemetry/telemetry_config.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRelay implements RelayHttp {
  final requests = <({String method, Uri url, Map<String, String> headers, String? body})>[];

  /// Answers by path prefix; the default is 202.
  RelayResponse Function(String method, String path, String? body) answer = (_, _, _) => const RelayResponse(202);

  List<Map<String, Object?>> get reportBodies => [
        for (final r in requests)
          if (r.url.path == '/v1/report' && r.method == 'POST') (jsonDecode(r.body!) as Map).cast<String, Object?>(),
      ];

  @override
  Future<RelayResponse> send(String method, Uri url, {required Map<String, String> headers, String? body}) async {
    requests.add((method: method, url: url, headers: headers, body: body));
    return answer(method, url.path, body);
  }
}

class FakeProbe implements DeviceProbe {
  @override
  Future<DeviceFacts> read() async => const DeviceFacts(
      platform: 'android', osVersion: '14', cpu: 'SM8450', big: 4, little: 4, maxClockMHz: [3000, 2500, 1800], ramGB: 8);
}


TelemetryConfig config({BuildChannel channel = BuildChannel.beta, bool relay = true}) => TelemetryConfig.parse(
    channel: channel.name, relayUrl: relay ? 'https://caw-telemetry.kmandevr.workers.dev' : '', appKey: 'caw-beta-1');

class Rig {
  Rig({BuildChannel channel = BuildChannel.beta, MemoryTelemetryStore? store, bool relay = true, DateTime? at})
      : store = store ?? MemoryTelemetryStore(),
        now = at ?? DateTime.utc(2026, 11, 12, 10) {
    t = Telemetry(
      config: config(channel: channel, relay: relay),
      store: this.store,
      http: http,
      probe: FakeProbe(),
      now: () => now,
      random: Random(7),
    );
    t.app
      ..appVersion = '0.9.0-beta.1'
      ..engineVersion = '0.9.0-beta.1'
      ..capiVersion = 23
      ..screen = (() => 'arrange')
      ..audio = (() => {'backend': 'aaudio', 'exclusive': true, 'lowLatency': true, 'bufferFrames': 192, 'sampleRate': 48000})
      ..profile = (() => 'balanced')
      ..eco = (() => false)
      ..refreshHz = (() => 120)
      ..isBuiltin = const {'org.caw.synth.flagship', 'org.caw.reverb', 'org.caw.drums'}.contains;
  }

  final MemoryTelemetryStore store;
  final http = FakeRelay();
  late final Telemetry t;
  DateTime now;

  /// A minute of use, playing at [cpu].
  Future<void> use({double cpu = 0.25}) async {
    for (var i = 0; i < 30; i++) {
      now = now.add(const Duration(seconds: 1));
      t.onMeters(cpu: cpu, playing: true, overloaded: 0);
    }
    await t.tick(seconds: 60, foreground: true);
  }

  Future<void> nextDay() async {
    now = now.add(const Duration(days: 1));
    await t.tick(seconds: 60, foreground: true);
  }
}

void main() {
  group('rounding and buckets (H2)', () {
    test('values round as H2 says', () {
      expect(clockMHz(2995200), 3000);
      expect(clockMHz(1785600), 1800);
      expect(ramGB(7 * (1 << 30) + 600 * (1 << 20)), 8);
      expect(budgetPct5(0.873), 85);
      expect(budgetPct5(0.876), 90);
      expect(startupMs50(1234), 1250);
      expect(minutes5(7 * 60), 5);
      expect(minutes5(8 * 60), 10);
      expect([0, 4, 5, 8, 9, 16, 17, 32, 33].map(tracksBucket),
          ['1-4', '1-4', '5-8', '5-8', '9-16', '9-16', '17-32', '17-32', '33+']);
      expect([0, 10, 11, 50, 51, 200, 201].map(clipsBucket), ['1-10', '1-10', '11-50', '11-50', '51-200', '51-200', '201+']);
    });

    test('core types: the slowest cluster is little, one cluster is other', () {
      final s22 = coreTypes([1785600, 1785600, 1785600, 1785600, 2496000, 2496000, 2496000, 2995200]);
      expect((s22.big, s22.little, s22.other), (4, 4, 0));
      expect(s22.clocks, [3000, 2500, 1800]);
      final pc = coreTypes(List.filled(8, 3600000));
      expect((pc.big, pc.little, pc.other), (0, 0, 8));
      expect(coreTypes([0, 0]).other, 2);
    });

    test('cpu, RAM and OS versions parse from the platform texts', () {
      expect(cpuFromCpuinfo('processor : 0\nmodel name : AMD Ryzen 7 5800X 8-Core Processor\n'),
          'AMD Ryzen 7 5800X 8-Core Processor');
      expect(cpuFromCpuinfo('CPU part : 0xd46\nCPU part : 0xd46\nCPU part : 0xd48\n'), 'arm 0xd46/0xd48');
      expect(ramFromMeminfo('MemTotal:       7868512 kB\n'), 7868512 * 1024);
      expect(majorVersion('14'), '14');
      expect(majorVersion('24.04'), '24');
      expect(majorVersion('unknown'), isNull);
      expect(windowsMajor('"Windows 10 Pro" 10.0 (Build 22631)'), '11');
      expect(windowsMajor('"Windows 10 Pro" 10.0 (Build 19045)'), '10');
    });

    test('a day becomes an H2 report with every field the contract names', () async {
      final rig = Rig();
      await rig.t.load();
      await rig.use(cpu: 0.25);
      await rig.use(cpu: 0.95);
      rig.t.onFrame(5.2);
      rig.t.onFrame(30);
      rig.t.onStartup(1234);
      rig.t.onPlay(componentIds: ['org.caw.synth.flagship', 'local.mine.x', 'org.caw.reverb'], tracks: 6, clips: 12);
      final r = (await rig.t.previewToday())!;
      expect(r.keys, containsAll(['schema', 'receipt', 'deleteHash', 'channel', 'day', 'app', 'device', 'perf', 'usage',
          'stress', 'errors']));
      expect(r['schema'], 1);
      expect(r['channel'], 'beta');
      expect(r['day'], '2026-11-12');
      expect(r['stress'], isNull);
      final perf = r['perf'] as Map;
      expect(perf['cpuLoadHistogram'], [0, 0, 0.5, 0, 0, 0, 0, 0, 0, 0.5]);
      expect(perf['worstCallbackPct'], 95);
      expect(perf['startupMs'], 1250);
      expect((perf['frames'] as Map)['slowPct'], 50); // 30 ms is over 120 Hz's 8.3 ms budget
      expect(perf['callbackCoreType'], 'unknown');
      final usage = r['usage'] as Map;
      expect(usage['minutesOpen'], 0); // 2 minutes rounds to 0
      expect(usage['builtins'], {'org.caw.synth.flagship': 1, 'org.caw.reverb': 1}); // local.mine.x never counted
      expect(usage['projectSize'], {'tracks': '5-8', 'clips': '11-50'});
      final device = r['device'] as Map;
      expect(device['cores'], {'big': 4, 'little': 4, 'other': 0});
      expect((device['audio'] as Map)['backend'], 'aaudio');
      expect(jsonBytes(r), lessThan(maxReportBytes));
    });
  });

  group('the allow-list (E6)', () {
    final allow = TelemetryAllowList(isBuiltin: const {'org.caw.reverb'}.contains);

    test('nothing on the never-send list survives, wherever it is put', () {
      final r = allow.report({
        'schema': 1,
        'receipt': 'a' * 32,
        'deleteHash': 'b' * 64,
        'channel': 'beta',
        'day': '2026-11-12',
        'projectName': 'My song',
        'installId': 'abc',
        'email': 'me@example.com',
        'location': {'lat': 1},
        'app': {'version': '0.9.0', 'engineVersion': '0.9.0', 'capiVersion': 23, 'account': 'kman'},
        'device': {
          'platform': 'android', 'osVersion': '14', 'cpu': '/home/kman/cpu', 'gpu': 'me@example.com',
          'midiDevices': ['Keystep'], 'serial': 'R5CT', 'cores': {'big': 4, 'little': 4, 'other': 0, 'names': ['x']},
          'audio': {'backend': 'aaudio', 'device': 'Galaxy Buds'},
        },
        'perf': {'dropouts': 1, 'notes': [60, 64]},
        'usage': {
          'screens': {'arrange': 5, 'My secret project': 10},
          'builtins': {'org.caw.reverb': 2, 'local.my_cool_fx.1': 3, 'org.caw.notreally': 1},
          'files': ['/sdcard/song.wav'],
        },
        'stress': null,
        'errors': [
          {'type': 'StateError', 'where': 'package:caw/ui/shell.dart:120', 'count': 2, 'message': 'C:\\Users\\kman'},
        ],
        'code': 'int main(){}',
        'audio': 'UklGRg==',
      });
      final text = jsonEncode(r);
      for (final banned in ['My song', 'abc', 'example.com', '"lat"', 'kman', 'Keystep', 'R5CT', 'Galaxy Buds', 'notes',
          'secret', 'my_cool_fx', 'sdcard', 'Users', 'int main', 'UklGRg', 'names', 'notreally']) {
        expect(text, isNot(contains(banned)), reason: banned);
      }
      expect((r['usage'] as Map)['screens'], {'arrange': 5, 'other': 10});
      expect((r['usage'] as Map)['builtins'], {'org.caw.reverb': 2, 'other': 4});
      expect(r.containsKey('stress'), isTrue);
      expect(r['stress'], isNull);
      expect(r['errors'], [
        {'type': 'StateError', 'where': 'package:caw/ui/shell.dart:120', 'count': 2},
      ]);
    });

    test('errors[].where must be a relative C.A.W location (H update 3)', () {
      List<Object?> keep(String where) =>
          allow.errors([{'type': 'StateError', 'where': where, 'count': 1}]) as List<Object?>;
      for (final ok in ['lib/ui/shell.dart:12', 'package:caw/ui/shell.dart:120', 'src/engine.cpp:9', 'engine/src/x.cpp:3',
          'app/lib/main.dart:5', 'platform/a.kt:1', 'include/caw.h:40']) {
        expect(keep(ok), hasLength(1), reason: ok);
      }
      for (final bad in ['/home/kman/C.A.W/app/lib/main.dart:5', 'C:\\Users\\k\\main.dart:5', 'file:///data/user/0/x.dart:3',
          'lib/../../etc/passwd:1', 'lib/ui/shell.dart', 'package:flutter/src/widgets.dart:3', 'unknown']) {
        expect(keep(bad), isEmpty, reason: bad);
      }
    });

    test('a stack frame is made relative on the device, or dropped', () {
      expect(ProblemLog.sourceLine('#0  build (package:caw/ui/shell.dart:120:7)'), 'package:caw/ui/shell.dart:120');
      expect(ProblemLog.sourceLine('#0  x (file:///home/kman/C.A.W/app/lib/ui/kit.dart:44:3)'), 'lib/ui/kit.dart:44');
      expect(
          ProblemLog.sourceLine('#0  a (package:flutter/src/x.dart:1:1)\n#1  b (package:caw/model/project.dart:9:2)'),
          'package:caw/model/project.dart:9');
      expect(ProblemLog.sourceLine('#0  a (file:///home/kman/other/main.dart:3:1)'), isNull);
      expect(ProblemLog.sourceLine('#00 abs 7000 virt 0012 _kDartIsolateSnapshotInstructions+0x1'), isNull);
    });

    test('histogram, osVersion and backend have the relay\'s shapes (H update 4)', () {
      Map<String, Object?> perf(Object? h) => (allow.report({'perf': {'cpuLoadHistogram': h}})['perf'] as Map).cast();
      expect(perf(List.filled(10, 0.1))['cpuLoadHistogram'], hasLength(10));
      expect(perf(List.filled(9, 0.1)).containsKey('cpuLoadHistogram'), isFalse);
      expect(perf(List.filled(11, 0.1)).containsKey('cpuLoadHistogram'), isFalse);
      expect(perf([...List.filled(9, 0.0), 1.5])['cpuLoadHistogram'], hasLength(9)); // 1.5 dropped: then the relay says 400
      expect(histogramShares(List.filled(10, 0)), List.filled(10, 0.0));
      expect(histogramShares([1, 3, 0, 0, 0, 0, 0, 0, 0, 0]).every((v) => v >= 0 && v <= 1), isTrue);

      Map<String, Object?> device(Map<String, Object?> d) => (allow.device(d) as Map).cast();
      expect(device({'osVersion': '14'})['osVersion'], '14');
      expect(device({'osVersion': '14.1'}).containsKey('osVersion'), isFalse);
      expect(device({'osVersion': 'unknown'}).containsKey('osVersion'), isFalse);
      expect(device({'audio': {'backend': 'aaudio'}})['audio'], {'backend': 'aaudio'});
      expect(device({'audio': {'backend': 'wasapi_shared'}})['audio'], {'backend': 'wasapi_shared'});
      expect(device({'audio': {'backend': 'AAudio'}})['audio'], isEmpty);
      expect(device({'audio': {'backend': 'core-audio'}})['audio'], isEmpty);
    });
  });

  group('receipts and delete keys', () {
    test('128-bit receipts, 32-byte keys, and the hash is of the raw bytes (H update 4)', () async {
      final rig = Rig();
      final a = rig.t.newReceipt(), b = rig.t.newReceipt();
      expect(a.receipt, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(a.deleteKey, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(a.receipt, isNot(b.receipt));
      final raw = [for (var i = 0; i < 64; i += 2) int.parse(a.deleteKey.substring(i, i + 2), radix: 16)];
      expect(a.deleteHash, sha256Hex(raw));
      expect(a.deleteHash, isNot(sha256Hex(utf8.encode(a.deleteKey))));
    });

    test('a receipt is used once: 400 on a resend counts as sent, 400 at first is rejected', () async {
      final rig = Rig();
      await rig.t.load();
      await rig.use();
      await rig.t.closeDay();
      // The first try never got an answer (it may still have arrived).
      rig.http.answer = (_, _, _) => const RelayResponse.offline();
      await rig.t.pump();
      expect(rig.t.queued, hasLength(1));
      rig.now = rig.now.add(const Duration(minutes: 20));
      rig.http.answer = (_, _, _) => const RelayResponse(400);
      await rig.t.pump();
      expect(rig.t.reports.single.status, ReportStatus.sent);
      expect(rig.http.reportBodies, hasLength(2));
      expect(rig.http.reportBodies.map((b) => b['receipt']).toSet(), hasLength(1));

      // A brand-new report rejected on its first POST is not retried.
      await rig.nextDay();
      await rig.use();
      await rig.t.closeDay();
      rig.now = rig.now.add(const Duration(days: 1));
      await rig.t.pump();
      expect(rig.t.reports.first.status, ReportStatus.rejected);
      final posts = rig.http.reportBodies.length;
      await rig.t.pump();
      expect(rig.http.reportBodies.length, posts);
    });

    test('My data: check, export and delete send only receipts and keys', () async {
      final rig = Rig();
      await rig.t.load();
      await rig.use();
      await rig.t.closeDay();
      await rig.t.pump();
      final rec = rig.t.reports.single;
      expect(rec.status, ReportStatus.sent);
      expect(rig.http.requests.last.headers['X-CAW-App-Key'], 'caw-beta-1');

      rig.http.answer = (m, p, _) => p.startsWith('/v1/report/') ? const RelayResponse(200, body: '{}') : const RelayResponse(202);
      expect(await rig.t.checkOnServer(), 1);
      expect(rig.t.reports.single.status, ReportStatus.published);
      expect(rig.http.requests.last.url.path, '/v1/report/${rec.receipt}');

      final export = jsonDecode(rig.t.exportReceipts()) as Map;
      expect((export['receipts'] as List).single, containsPair('deleteKey', rec.deleteKey));

      rig.http.answer = (_, _, _) => const RelayResponse(202, body: '{"deleted":1}');
      expect(await rig.t.deleteMyData(), 1);
      final body = jsonDecode(rig.http.requests.last.body!) as Map;
      expect(rig.http.requests.last.url.path, '/v1/delete');
      expect(body, {
        'items': [
          {'receipt': rec.receipt, 'deleteKey': rec.deleteKey},
        ],
      });
      expect(rig.t.reports.single.status, ReportStatus.deleteRequested);
      // Keys never go in a report.
      expect(rig.http.reportBodies.single.toString(), isNot(contains(rec.deleteKey)));
    });
  });

  group('queue and sending (E4, H5)', () {
    test('the queue is capped at 1 MB, the oldest going first', () async {
      final rig = Rig(relay: false);
      await rig.t.load();
      final filler = jsonEncode({'pad': 'x' * 7000});
      for (var i = 0; i < 200; i++) {
        rig.t.enqueueForTest(ReportRecord(
            receipt: i.toRadixString(16).padLeft(32, '0'), deleteKey: '0' * 64, day: '2026-11-12', kind: ReportKind.daily,
            json: filler, created: rig.now));
      }
      expect(rig.t.queueBytes, lessThanOrEqualTo(Telemetry.queueCapBytes));
      expect(rig.t.queued.first.receipt, isNot('0' * 32));
      expect(rig.t.queued.last.receipt, 199.toRadixString(16).padLeft(32, '0'));
    });

    test('at most one daily report per UTC day', () async {
      final rig = Rig();
      await rig.t.load();
      rig.http.answer = (_, _, _) => const RelayResponse.offline();
      await rig.use();
      await rig.nextDay(); // day 1 queued
      await rig.use();
      await rig.nextDay(); // day 2 queued
      expect(rig.t.queued, hasLength(2));
      rig.http.answer = (_, _, _) => const RelayResponse(202);
      rig.now = rig.now.add(const Duration(minutes: 30));
      await rig.t.pump();
      expect(rig.t.queued, hasLength(1));
      await rig.t.pump();
      expect(rig.t.queued, hasLength(1));
      await rig.nextDay();
      expect(rig.t.queued.where((r) => r.day == '2026-11-13'), isEmpty);
    });

    test('429 and 503 keep the report and honour Retry-After', () async {
      final rig = Rig();
      await rig.t.load();
      await rig.use();
      await rig.t.closeDay();
      rig.http.answer = (_, _, _) => const RelayResponse(429, retryAfter: Duration(minutes: 90));
      await rig.t.pump();
      expect(rig.t.queued, hasLength(1));
      final posts = rig.http.requests.length;
      rig.now = rig.now.add(const Duration(minutes: 60));
      await rig.t.pump();
      expect(rig.http.requests.length, posts, reason: 'still waiting');
      rig.http.answer = (_, _, _) => const RelayResponse(503, retryAfter: Duration(seconds: 30));
      rig.now = rig.now.add(const Duration(minutes: 31));
      await rig.t.pump();
      expect(rig.t.queued, hasLength(1));
      rig.http.answer = (_, _, _) => const RelayResponse(202);
      rig.now = rig.now.add(const Duration(minutes: 1));
      await rig.t.pump();
      expect(rig.t.queued, isEmpty);
      expect(parseRetryAfter('120', DateTime.utc(2026)), const Duration(seconds: 120));
      expect(parseRetryAfter('Thu, 12 Nov 2026 10:05:00 GMT', DateTime.utc(2026, 11, 12, 10)), const Duration(minutes: 5));
      expect(parseRetryAfter('soon', DateTime.utc(2026)), isNull);
    });

    test('no relay URL (the placeholder) sends nothing at all', () async {
      expect(TelemetryConfig.parse(channel: 'beta', relayUrl: '', appKey: 'k').canSend, isFalse);
      expect(TelemetryConfig.parse(channel: 'beta', relayUrl: 'http://x.dev', appKey: 'k').canSend, isFalse);
      expect(TelemetryConfig.parse(channel: 'beta', relayUrl: 'https://u:p@x.dev', appKey: 'k').canSend, isFalse);
      final rig = Rig(relay: false);
      await rig.t.load();
      await rig.use();
      await rig.t.closeDay();
      await rig.t.pump();
      expect(rig.http.requests, isEmpty);
      expect(rig.t.queued, hasLength(1));
    });

    test('turning it off stops sending and wipes the queue and the day', () async {
      final rig = Rig();
      await rig.t.load();
      rig.http.answer = (_, _, _) => const RelayResponse.offline();
      await rig.use();
      await rig.t.closeDay();
      await rig.use();
      await rig.t.setEnabled(false);
      expect(rig.t.queued, isEmpty);
      expect(rig.t.today, isNull);
      expect(await rig.t.previewToday(), isNull);
      final before = rig.http.reportBodies.length; // the offline tries before
      rig.http.answer = (_, _, _) => const RelayResponse(202);
      rig.now = rig.now.add(const Duration(days: 2));
      await rig.use();
      expect(rig.http.reportBodies, hasLength(before));
      expect(jsonDecode(rig.store.text!)['stats'], isNull);
    });
  });

  group('channel defaults (E1)', () {
    test('beta starts on, release starts off', () async {
      final beta = Rig(channel: BuildChannel.beta);
      await beta.t.load();
      expect(beta.t.enabled, isTrue);
      expect(beta.t.firstRunNeeded, isTrue);
      final release = Rig(channel: BuildChannel.release);
      await release.t.load();
      expect(release.t.enabled, isFalse);
      expect(release.t.askKeepNeeded, isFalse);
    });

    test('the first release launch after a beta build turns it off and asks once', () async {
      final store = MemoryTelemetryStore();
      final beta = Rig(store: store);
      await beta.t.load();
      await beta.t.acceptFirstRun();
      final release = Rig(channel: BuildChannel.release, store: store);
      await release.t.load();
      expect(release.t.enabled, isFalse);
      expect(release.t.askKeepNeeded, isTrue);
      await release.t.answerKeep(true);
      expect(release.t.enabled, isTrue);
      final again = Rig(channel: BuildChannel.release, store: store);
      await again.t.load();
      expect(again.t.askKeepNeeded, isFalse);
      expect(again.t.enabled, isTrue);
    });

    test('a beta user who had turned it off is not asked', () async {
      final store = MemoryTelemetryStore();
      final beta = Rig(store: store);
      await beta.t.load();
      await beta.t.acceptFirstRun();
      await beta.t.setEnabled(false);
      final release = Rig(channel: BuildChannel.release, store: store);
      await release.t.load();
      expect(release.t.askKeepNeeded, isFalse);
      expect(release.t.enabled, isFalse);
    });
  });

  group('stress-test reports (owner, 2026-11-12)', () {
    final stress = {
      'version': 1,
      'tiers': {'normal': 'comfortable', 'heavy': 'tight', 'extreme': 'over'},
      'limits': {'tracks': 23, 'voices': 41, 'effects': 12},
      'scenarios': {'song8': {'meanPct': 31, 'p99Pct': 44, 'worstPct': 61, 'dropouts': 0}},
      'topCosts': [
        {'component': 'org.caw.reverb', 'pct': 22},
        {'component': 'local.secret.fx', 'pct': 10},
      ],
    };

    test('sent at once as its own report, shown in My data', () async {
      final rig = Rig();
      await rig.t.load();
      await rig.use();
      expect(await rig.t.sendStressReport(stress), StressOutcome.sent);
      final sent = rig.http.reportBodies.single;
      expect((sent['stress'] as Map)['limits'], {'tracks': 23, 'voices': 41, 'effects': 12});
      expect((sent['stress'] as Map)['topCosts'], [
        {'component': 'org.caw.reverb', 'pct': 22},
        {'component': 'other', 'pct': 10},
      ]);
      expect(rig.t.reports.single.kind, ReportKind.stress);
      expect(rig.t.today, isNotNull, reason: 'the day goes on counting for the daily report');
    });

    test('telemetry off: nothing is sent or queued', () async {
      final rig = Rig(channel: BuildChannel.release);
      await rig.t.load();
      expect(await rig.t.sendStressReport(stress), StressOutcome.off);
      expect(rig.http.requests, isEmpty);
      expect(rig.t.reports, isEmpty);
      expect(rig.t.pendingStress, isNull);
      expect(rig.t.lastStress, isNotNull, reason: 'still attachable to feedback, on the device');
    });

    test('one of the 10 daily slots is kept for the daily report, then results ride on the next daily one', () async {
      final rig = Rig();
      await rig.t.load();
      await rig.use();
      for (var i = 0; i < 9; i++) {
        expect(await rig.t.sendStressReport(stress), StressOutcome.sent, reason: 'stress #$i');
      }
      final newest = {...stress, 'limits': {'tracks': 99, 'voices': 1, 'effects': 1}};
      expect(await rig.t.sendStressReport(newest), StressOutcome.attachedToNextDaily);
      expect(rig.http.reportBodies, hasLength(9));
      // The next day's daily report carries the newest result.
      await rig.nextDay();
      await rig.t.pump();
      final daily = rig.http.reportBodies.last;
      expect(rig.http.reportBodies, hasLength(10));
      expect(((daily['stress'] as Map)['limits'] as Map)['tracks'], 99);
      expect(rig.t.pendingStress, isNull);
      expect(rig.t.reports.where((r) => r.kind == ReportKind.stress), hasLength(9));
    });

    test('with the daily report already sent, all ten slots can be used', () async {
      final rig = Rig();
      await rig.t.load();
      await rig.use();
      await rig.nextDay(); // yesterday's daily report goes out today
      expect(rig.http.reportBodies, hasLength(1));
      for (var i = 0; i < 9; i++) {
        expect(await rig.t.sendStressReport(stress), StressOutcome.sent);
      }
      expect(await rig.t.sendStressReport(stress), StressOutcome.attachedToNextDaily);
    });
  });

  group('feedback (F, H4, H5)', () {
    Map<String, Object?> body(Telemetry t, [String text = 'The roll lags']) =>
        t.feedbackBody(kind: FeedbackKind.bug, text: text, contact: 'me@example.com');

    test('works with telemetry off, and the body has only H4\'s fields', () async {
      final rig = Rig(channel: BuildChannel.release);
      await rig.t.load();
      rig.http.answer = (_, _, _) => const RelayResponse(201, body: '{"issue":"https://github.com/Kmandevr/C.A.W-Telemetry/issues/7"}');
      final b = rig.t.feedbackBody(
          kind: FeedbackKind.confusing, text: 'Where is Export?', errors: [
        {'type': 'StateError', 'where': '/home/k/x.dart:1', 'count': 1},
      ], contact: 'not an email');
      expect(b.keys, unorderedEquals(['schema', 'kind', 'text', 'appVersion', 'platform', 'attachments']));
      expect((b['attachments'] as Map)['errors'], isEmpty);
      final r = await rig.t.submitFeedback(b);
      expect(r.outcome, FeedbackOutcome.sent);
      expect(r.issueUrl, 'https://github.com/Kmandevr/C.A.W-Telemetry/issues/7');
      expect(rig.http.requests.single.url.path, '/v1/feedback');
    });

    test('five a day; the sixth waits for tomorrow', () async {
      final rig = Rig();
      await rig.t.load();
      for (var i = 0; i < 5; i++) {
        expect((await rig.t.submitFeedback(body(rig.t, 'note $i'))).outcome, FeedbackOutcome.sent);
      }
      expect(rig.t.feedbackLeftToday, 0);
      expect((await rig.t.submitFeedback(body(rig.t))).outcome, FeedbackOutcome.dailyLimit);
      rig.now = rig.now.add(const Duration(days: 1));
      expect((await rig.t.submitFeedback(body(rig.t))).outcome, FeedbackOutcome.sent);
    });

    test('offline it queues, backs off on 429, and says when it went', () async {
      final rig = Rig();
      await rig.t.load();
      final events = <FeedbackSent>[];
      rig.t.feedbackSent.listen(events.add);
      rig.http.answer = (_, _, _) => const RelayResponse.offline();
      expect((await rig.t.submitFeedback(body(rig.t))).outcome, FeedbackOutcome.queued);
      expect(rig.t.feedbackQueued, 1);
      rig.http.answer = (_, _, _) => const RelayResponse(429, retryAfter: Duration(hours: 2));
      await rig.t.pump();
      expect(rig.t.feedbackQueued, 1);
      final calls = rig.http.requests.length;
      rig.now = rig.now.add(const Duration(hours: 1));
      await rig.t.pump();
      expect(rig.http.requests.length, calls);
      rig.http.answer = (_, _, _) => const RelayResponse(202, body: '{"status":"queued"}');
      rig.now = rig.now.add(const Duration(hours: 2));
      await rig.t.pump();
      await Future<void>.delayed(Duration.zero);
      expect(rig.t.feedbackQueued, 0);
      expect(events, hasLength(1));
    });

    test('a build without a relay says so instead of queueing forever', () async {
      final rig = Rig(relay: false);
      await rig.t.load();
      expect((await rig.t.submitFeedback(body(rig.t))).outcome, FeedbackOutcome.unavailable);
    });
  });

  test('the state survives a restart', () async {
    final store = MemoryTelemetryStore();
    final a = Rig(store: store);
    await a.t.load();
    await a.t.acceptFirstRun();
    await a.use();
    await a.t.closeDay();
    await a.t.pump();
    final b = Rig(store: store, at: a.now);
    await b.t.load();
    expect(b.t.firstRunNeeded, isFalse);
    expect(b.t.reports.single.receipt, a.t.reports.single.receipt);
    expect(b.t.reports.single.deleteKey, a.t.reports.single.deleteKey);
  });

  test('DayStats round-trips', () {
    final s = DayStats('2026-11-12')
      ..meter(cpu: 0.3, playing: true, secondsSinceLast: 0.5, newDropouts: 2)
      ..frame(4, 8)
      ..error('StateError', 'lib/a.dart:1')
      ..builtins['org.caw.reverb'] = 3;
    final back = DayStats.fromJson(jsonDecode(jsonEncode(s.toJson())))!;
    expect(jsonEncode(back.toJson()), jsonEncode(s.toJson()));
  });
}
