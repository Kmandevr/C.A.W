// The companion app's link and adapters (docs/companion-protocol.md) against fake links: absent, a timeout, another
// protocol version, the known-bad override and a relay round trip; the Android link's checks; the build flavours.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/companion/companion_relay.dart';
import 'package:caw/model/companion/companion_updates.dart';
import 'package:caw/model/companion/trust_source.dart';
import 'package:caw/model/native_trust.dart';
import 'package:caw/model/updates/update_service.dart';
import 'package:caw/platform/companion_link.dart';
import 'package:caw/platform/distribution.dart';
import 'package:caw/platform/update_installer.dart';
import 'package:caw_services/companion/companion_protocol.dart';
import 'package:caw_services/telemetry/relay_client.dart';
import 'package:caw_services/telemetry/telemetry_config.dart';
import 'package:caw_services/updates/releases.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A companion that answers each kind with [answers] (absent when [present] is false), and records what it got.
class _FakeLink extends CompanionLink {
  _FakeLink({this.present = true, this.answers = const {}});
  final bool present;
  final Map<CompanionKind, CompanionReply> answers;
  final sent = <(CompanionKind, Map<String, Object?>)>[];
  var _status = CompanionStatus.unknown;

  @override
  CompanionStatus get status => _status;

  @override
  Future<CompanionReply> hello() async {
    _status = present ? CompanionStatus.present : CompanionStatus.absent;
    return present ? const CompanionReply(CompanionOutcome.ok) : const CompanionReply.absent();
  }

  @override
  Future<CompanionReply> request(CompanionKind kind, Map<String, Object?> body) async {
    if (await probe() != CompanionStatus.present) return const CompanionReply.absent();
    sent.add((kind, body));
    return answers[kind] ?? const CompanionReply(CompanionOutcome.unsupported);
  }
}

class _Http implements RelayHttp {
  final calls = <String>[];
  @override
  Future<RelayResponse> send(String method, Uri url, {required Map<String, String> headers, String? body}) async {
    calls.add('$method ${url.path}');
    return const RelayResponse(202, body: '{"receipt":"in-app"}');
  }
}

class _Source implements UpdateSource {
  var calls = 0;
  @override
  String get name => 'GitHub Releases';
  @override
  Future<List<ReleaseInfo>> releases() async {
    calls++;
    return const [ReleaseInfo(tag: 'v9.9.9', version: null)];
  }
}

class _Installer extends NoUpdateInstaller {
  var installs = 0;
  @override
  Future<UpdateOutcome> install(File file, AssetKind kind, {bool silent = false}) async {
    installs++;
    return const UpdateOutcome('in-app');
  }
}

final _config = TelemetryConfig.parse(channel: 'beta', relayUrl: 'https://relay.example', appKey: 'k');
const _fp = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only the play flavour hides the self-updater; tests and other builds have it', () {
    expect(distributionFor('play'), Distribution.play);
    expect(distributionFor('github'), Distribution.github);
    expect(distributionFor(null), Distribution.github);
    expect(selfUpdates, isTrue);
  });

  group('protocol', () {
    test('kinds have their wire numbers and timeouts', () {
      expect(CompanionKind.values.map((k) => k.what), [for (var i = 1; i <= 10; i++) i]);
      expect(CompanionKind.byWhat(9), CompanionKind.trustQuery);
      expect(CompanionKind.byWhat(11), isNull);
      expect(CompanionKind.telemetryReport.timeout, const Duration(seconds: 25));
      expect(CompanionKind.updateCheck.timeout, const Duration(seconds: 10));
      expect(CompanionKind.updateOpen.readOnly, isFalse);
    });

    test('bodies are JSON objects of at most 64 KiB', () {
      expect(encodeCompanionBody({'a': 'x' * 100}), isNotNull);
      expect(encodeCompanionBody({'a': 'x' * companionMaxBodyBytes}), isNull);
      expect(decodeCompanionBody('{"a":1}'), {'a': 1});
      expect(decodeCompanionBody('[1]'), isNull);
      expect(decodeCompanionBody('not json'), isNull);
      expect(decodeCompanionBody('"${'x' * companionMaxBodyBytes}"'), isNull);
    });
  });

  group('absent', () {
    test('no companion: every adapter takes the in-app path', () async {
      final link = NoCompanionLink();
      final source = _Source(), installer = _Installer(), http = _Http();
      expect((await CompanionUpdateSource(link, source).releases()).single.tag, 'v9.9.9');
      expect(CompanionUpdateSource(link, source).name, 'GitHub Releases');
      expect((await CompanionUpdateInstaller(link, installer).install(File('x'), AssetKind.apk)).message, 'in-app');
      final relay = CompanionRelay(link, RelayClient(_config, http));
      expect((await relay.postReport('{"v":1}')).status, 202);
      expect(http.calls, ['POST /v1/report']);
      expect(trustSourceFor(link, NativeTrustStore(File('unused'))), isA<LocalTrustSource>());
    });

    test('an installed but older companion (unsupported) also falls back', () async {
      final link = _FakeLink(); // answers unsupported to everything
      final source = _Source(), http = _Http();
      expect((await CompanionUpdateSource(link, source).releases()).single.tag, 'v9.9.9');
      expect((await CompanionRelay(link, RelayClient(_config, http)).getReport('ab')).status, 202);
      expect(http.calls, ['GET /v1/report/ab']);
    });
  });

  group('timeouts', () {
    test('a read falls back in-app; a send is never repeated in-app', () async {
      const late = CompanionReply(CompanionOutcome.timeout);
      final link = _FakeLink(answers: {CompanionKind.updateCheck: late, CompanionKind.telemetryReport: late});
      final source = _Source(), http = _Http();
      await CompanionUpdateSource(link, source).releases();
      expect(source.calls, 1);
      final res = await CompanionRelay(link, RelayClient(_config, http)).postReport('{}');
      expect(res.offline, isTrue);
      expect(res.mayHaveArrived, isTrue);
      expect(http.calls, isEmpty);
    });
  });

  group('relay round trip', () {
    test('the report goes as a fixed kind and the relay answer comes back as the relay gave it', () async {
      final link = _FakeLink(answers: {
        CompanionKind.telemetryReport:
            const CompanionReply(CompanionOutcome.ok, body: {'status': 202, 'body': '{"receipt":"r1"}'}),
        CompanionKind.telemetryDelete:
            const CompanionReply(CompanionOutcome.ok, body: {'status': 429, 'body': '', 'retryAfter': 90}),
        CompanionKind.feedbackPost: const CompanionReply(CompanionOutcome.ok, body: {'status': 0, 'sent': false}),
      });
      final http = _Http();
      final relay = CompanionRelay(link, RelayClient(_config, http));
      final report = await relay.postReport(jsonEncode({'v': 1, 'app': 'caw'}));
      expect(report.status, 202);
      expect(report.json, {'receipt': 'r1'});
      expect(link.sent.single.$1, CompanionKind.telemetryReport);
      expect(link.sent.single.$2, {'report': {'v': 1, 'app': 'caw'}}); // the report, never a URL or a method
      final del = await relay.delete([(receipt: 'r1', deleteKey: 'd1')]);
      expect(del.backOff, isTrue);
      expect(del.retryAfter, const Duration(seconds: 90));
      expect(link.sent.last.$2, {'items': [{'receipt': 'r1', 'deleteKey': 'd1'}]});
      final fb = await relay.postFeedback('{"text":"hi"}');
      expect(fb.offline, isTrue);
      expect(fb.mayHaveArrived, isFalse);
      expect(http.calls, isEmpty);
    });

    test('a build with no relay sends nothing, through the companion or not', () async {
      final link = _FakeLink(answers: {
        CompanionKind.telemetryReport: const CompanionReply(CompanionOutcome.ok, body: {'status': 202}),
      });
      final off = TelemetryConfig.parse(channel: 'beta', relayUrl: '', appKey: '');
      expect((await CompanionRelay(link, RelayClient(off, _Http())).postReport('{}')).offline, isTrue);
      expect(link.sent, isEmpty);
    });

    test('odd relay answers read as no answer, and waits are capped', () {
      expect(CompanionRelay.relayAnswer({'status': 'x'}).offline, isTrue);
      expect(CompanionRelay.relayAnswer({'status': 900}).offline, isTrue);
      expect(CompanionRelay.relayAnswer({'status': 503, 'retryAfter': 999999}).retryAfter, maxRetryAfter);
    });
  });

  group('updates through the companion', () {
    test('releases are parsed defensively and the install opens the companion', () async {
      final link = _FakeLink(answers: {
        CompanionKind.updateCheck: const CompanionReply(CompanionOutcome.ok, body: {
          'releases': [
            {
              'tag_name': 'v1.0.7',
              'assets': [
                {'name': 'caw-1.0.7-android.apk', 'size': 10, 'browser_download_url': 'https://evil.example/caw.apk'},
                {
                  'name': 'caw-1.0.7-windows.zip',
                  'size': 20,
                  'browser_download_url': 'https://github.com/Kmandevr/C.A.W/releases/download/v1.0.7/caw-1.0.7-windows.zip'
                },
              ],
            },
          ],
        }),
        CompanionKind.updateOpen: const CompanionReply(CompanionOutcome.ok),
      });
      final source = CompanionUpdateSource(link, _Source());
      final list = await source.releases();
      expect(list.single.tag, 'v1.0.7');
      expect(list.single.assets.map((a) => a.name), ['caw-1.0.7-windows.zip']); // the off-repository URL is dropped
      expect(source.name, 'the C.A.W companion app');
      final installer = _Installer();
      final out = await CompanionUpdateInstaller(link, installer).install(File('x.apk'), AssetKind.apk);
      expect(out.started, isTrue);
      expect(installer.installs, 0);
      expect(await CompanionUpdateInstaller(link, installer).canInstall(), isTrue);
    });

    test('a refusal is an error, not a silent fallback', () async {
      final link = _FakeLink(answers: {CompanionKind.updateCheck: const CompanionReply(CompanionOutcome.refused)});
      final source = _Source();
      await expectLater(CompanionUpdateSource(link, source).releases(), throwsA(isA<Exception>()));
      expect(source.calls, 0);
    });
  });

  group('trust', () {
    late Directory dir;
    late NativeTrustStore store;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('caw_companion_trust');
      store = NativeTrustStore(File('${dir.path}/trust.json'))..remember('org.x.fx', _fp, NativeComponentTrust.trusted);
    });
    tearDown(() => dir.delete(recursive: true));

    test('the known-bad answer wins over a local Trusted', () async {
      final link = _FakeLink(answers: {
        CompanionKind.trustQuery: const CompanionReply(CompanionOutcome.ok, body: {'verdict': 'bad', 'reason': 'steals files'}),
      });
      final d = await trustSourceFor(link, store).decide('org.x.fx', _fp);
      expect(d.trust, NativeComponentTrust.blocked);
      expect(d.knownBadReason, 'steals files');
      expect(link.sent.single.$2, {'component': 'org.x.fx', 'sha256': _fp});
    });

    test('unknown, absent, a timeout or a malformed fingerprint keep the local choice', () async {
      for (final link in [
        _FakeLink(answers: {CompanionKind.trustQuery: const CompanionReply(CompanionOutcome.ok, body: {'verdict': 'unknown'})}),
        _FakeLink(present: false),
        _FakeLink(answers: {CompanionKind.trustQuery: const CompanionReply(CompanionOutcome.timeout)}),
      ]) {
        final d = await CompanionTrustSource(link, store).decide('org.x.fx', _fp);
        expect(d.trust, NativeComponentTrust.trusted);
        expect(d.knownBad, isFalse);
      }
      final link = _FakeLink(answers: {CompanionKind.trustQuery: const CompanionReply(CompanionOutcome.ok, body: {'verdict': 'bad'})});
      expect((await CompanionTrustSource(link, store).decide('org.x.fx', 'NOT-HEX')).trust, isNull);
      expect(link.sent, isEmpty);
    });
  });

  group('the Android link', () {
    const channel = MethodChannel('caw/companion');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    void answer(Object? Function(Map args) reply) => messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'request');
          return reply(call.arguments as Map);
        });

    test('a hello answered properly makes it present, and a request carries v, id and the body', () async {
      final seen = <Map>[];
      answer((a) {
        seen.add(a);
        return {'outcome': 'reply', 'v': 1, 'id': a['id'], 'status': 'ok', 'body': '{"app":"1.0.7"}'};
      });
      final link = AndroidCompanionLink();
      expect(await link.probe(), CompanionStatus.present);
      final r = await link.request(CompanionKind.knownBadVersion, const {});
      expect(r.ok, isTrue);
      expect(seen.map((a) => a['what']), [1, 10]);
      expect(seen.last['v'], 1);
      expect(seen.last['timeoutMs'], 10000);
      expect(seen.last['body'], '{}');
    });

    test('absent, a timed-out bind and a higher version leave it absent', () async {
      for (final a in [
        {'outcome': 'absent'},
        {'outcome': 'timeout'},
        {'outcome': 'reply', 'v': 2, 'id': 1, 'status': 'ok', 'body': '{}'},
      ]) {
        answer((_) => a);
        final link = AndroidCompanionLink();
        expect(await link.probe(), CompanionStatus.absent);
        expect((await link.request(CompanionKind.updateCheck, const {})).outcome, CompanionOutcome.absent);
      }
    });

    test('no channel at all (MissingPlugin) is absent', () async {
      final link = AndroidCompanionLink();
      expect(await link.probe(), CompanionStatus.absent);
    });

    test('replies are checked: version, id, status and body', () {
      expect(AndroidCompanionLink.readReply({'outcome': 'reply', 'v': 2, 'id': 1}, 1).outcome, CompanionOutcome.unsupported);
      expect(AndroidCompanionLink.readReply({'outcome': 'reply', 'v': 1, 'id': 2, 'status': 'ok', 'body': '{}'}, 1).outcome,
          CompanionOutcome.error);
      expect(AndroidCompanionLink.readReply({'outcome': 'reply', 'v': 1, 'id': 1, 'status': 'ok', 'body': '[]'}, 1).outcome,
          CompanionOutcome.error);
      expect(AndroidCompanionLink.readReply({'outcome': 'reply', 'v': 1, 'id': 1, 'status': 'busy', 'body': '{}'}, 1).outcome,
          CompanionOutcome.busy);
      expect(AndroidCompanionLink.readReply({'outcome': 'refused'}, 1).outcome, CompanionOutcome.refused);
      expect(AndroidCompanionLink.readReply({'outcome': 'reply', 'v': 1, 'id': 1, 'status': 'unsupported'}, 1).fallBack, isTrue);
      expect(AndroidCompanionLink.readReply('nonsense', 1).outcome, CompanionOutcome.error);
    });

    test('a body over 64 KiB is refused before it is sent', () async {
      var calls = 0;
      answer((a) {
        calls++;
        return {'outcome': 'reply', 'v': 1, 'id': a['id'], 'status': 'ok', 'body': '{}'};
      });
      final link = AndroidCompanionLink();
      await link.probe();
      final r = await link.request(CompanionKind.feedbackPost, {'feedback': 'x' * companionMaxBodyBytes});
      expect(r.outcome, CompanionOutcome.badRequest);
      expect(calls, 1); // the hello only
    });
  });
}
