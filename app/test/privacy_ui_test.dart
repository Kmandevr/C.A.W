// Tests the privacy and feedback screens at 360 dp wide (beta readiness plan E2, E3, E5, F): the first-run page,
// Settings › About and beta › Privacy, My data and the feedback sheet, with goldens of each new screen.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:caw/model/telemetry/device_probe.dart';
import 'package:caw/model/telemetry/relay_client.dart';
import 'package:caw/model/telemetry/telemetry.dart';
import 'package:caw/model/telemetry/telemetry_config.dart';
import 'package:caw/ui/privacy/feedback_sheet.dart';
import 'package:caw/ui/privacy/my_data_page.dart';
import 'package:caw/ui/privacy/privacy_pages.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/settings/settings_deps.dart';
import 'package:caw/ui/settings/settings_page.dart';
import 'package:caw/ui/settings/privacy_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

const phone360 = Size(360, 780);

class _Relay implements RelayHttp {
  final bodies = <String>[];
  RelayResponse next = const RelayResponse(202);
  @override
  Future<RelayResponse> send(String method, Uri url, {required Map<String, String> headers, String? body}) async {
    if (body != null) bodies.add(body);
    return next;
  }
}

class _Probe implements DeviceProbe {
  @override
  Future<DeviceFacts> read() async =>
      const DeviceFacts(platform: 'android', osVersion: '14', cpu: 'SM8450', big: 4, little: 4, other: 0, maxClockMHz: [3000, 1800], ramGB: 8);
}

/// A loaded telemetry on a fixed day; [reports] daily reports already sent.
Future<(Telemetry, _Relay)> _telemetry(WidgetTester tester, {int reports = 0}) async {
  final relay = _Relay();
  var now = DateTime.utc(2026, 11, 12, 10);
  final t = Telemetry(
    config: TelemetryConfig.parse(channel: 'beta', relayUrl: 'https://relay.example.dev', appKey: 'k'),
    store: MemoryTelemetryStore(),
    http: relay,
    probe: _Probe(),
    now: () => now,
    random: Random(3),
  );
  t.app
    ..appVersion = '0.9.0-beta.1'
    ..engineVersion = '0.9.0-beta.1'
    ..capiVersion = 23
    ..isBuiltin = const {'org.caw.reverb'}.contains;
  await tester.runAsync(() async {
    await t.load();
    await t.acceptFirstRun();
    for (var i = 0; i < reports; i++) {
      t.onMeters(cpu: 0.3, playing: true, overloaded: 0);
      await t.tick(seconds: 600, foreground: true);
      await t.closeDay();
      await t.pump();
      now = now.add(const Duration(days: 1));
    }
  });
  return (t, relay);
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = phone360;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('first run: one page, Continue accepts; the texts open offline', (tester) async {
    var continued = false;
    await _pump(tester, FirstRunPage(telemetryOn: true, onContinue: () => continued = true));
    expect(find.text('What is sent'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('What is never sent'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('What is never sent'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Turning it off'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('All of it is public'), findsOneWidget);
    expect(find.textContaining('Settings › About and beta › Privacy'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('first-run-continue')));
    expect(continued, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bundled Privacy Policy shows, with its published link', (tester) async {
    await _pump(tester, LegalTextPage(which: LegalText.privacy, load: (_) async => '# Policy\n\nDraft text'));
    expect(find.textContaining('Draft text'), findsOneWidget);
    expect(LegalText.privacy.url, 'https://github.com/Kmandevr/C.A.W-Telemetry/blob/main/PRIVACY.md');
    expect(LegalText.terms.url, 'https://github.com/Kmandevr/C.A.W-Telemetry/blob/main/TERMS.md');
  });

  test('the bundled Privacy Policy is the published one: the minimum age (16) is stated, no placeholder left', () {
    // The copy must match PRIVACY.md in Kmandevr/C.A.W-Telemetry (450e773, 2026-11-12: minimum age 16). TERMS.md's
    // governing law is still the owner's to choose there, so its placeholder stays as published.
    final privacy = File('assets/legal/PRIVACY.md').readAsStringSync();
    expect(privacy, contains('You must be at least 16'));
    expect(privacy, isNot(contains('[Owner:')));
  });

  testWidgets('Privacy: the toggle turns telemetry off and wipes the queue', (tester) async {
    final (t, relay) = await _telemetry(tester);
    relay.next = const RelayResponse.offline();
    await tester.runAsync(() async {
      t.onMeters(cpu: 0.3, playing: true, overloaded: 0);
      await t.tick(seconds: 600, foreground: true);
      await t.closeDay();
    });
    expect(t.queued, hasLength(1));
    Telemetry.current = t;
    addTearDown(() => Telemetry.current = null);
    await _pump(tester, SettingsPage(settings: Settings()));
    // Settings › About and beta › Privacy, the published policy's path.
    await tester.tap(find.text('About and beta'));
    await tester.pumpAndSettle();
    // Below the Updates rows on a phone.
    await tester.ensureVisible(find.text('Privacy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();
    expect(find.textContaining('workers.dev/dashboard'), findsOneWidget);
    expect(find.text('Send anonymous telemetry'), findsOneWidget);
    expect(find.textContaining('1 waiting'), findsOneWidget);
    expect(find.text('Send feedback'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('switch-privacy.telemetry')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
    expect(t.enabled, isFalse);
    expect(t.queued, isEmpty);
    expect(find.textContaining('Off: nothing is sent'), findsOneWidget);
  });

  testWidgets('My data: each report\'s status, JSON, link and receipt', (tester) async {
    final (t, _) = await _telemetry(tester, reports: 2);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    String? exported;
    await _pump(tester, MyDataPage(telemetry: t, saveReceipts: (json) async {
      exported = json;
      return true;
    }));
    final r = t.reports.first;
    expect(find.text('Sent'), findsNWidgets(2));
    await tester.tap(find.byKey(ValueKey('report-json-${r.receipt}')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('json-${r.receipt}')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('report-copy-${r.receipt}')));
    await tester.tap(find.byKey(ValueKey('report-repo-${r.receipt}')));
    expect(copied, [r.receipt, 'https://github.com/Kmandevr/C.A.W-Telemetry/blob/main/data/${r.receipt.substring(0, 2)}/${r.receipt}.json']);
    await tester.tap(find.byKey(const ValueKey('my-data-export')));
    await tester.pumpAndSettle();
    // The warning comes before the save picker (security review, 2026-11-12).
    expect(find.textContaining('Keep this file private'), findsOneWidget);
    expect(exported, isNull);
    await tester.tap(find.byKey(const ValueKey('my-data-export-confirm')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
    expect((jsonDecode(exported!) as Map)['receipts'], hasLength(2));
    await tester.tap(find.byKey(const ValueKey('my-data-delete')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Git keeps a repository\'s history'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('my-data-delete-confirm')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
    expect(find.text('Deletion asked'), findsWidgets);
    expect(t.reports.every((r) => r.status == ReportStatus.deleteRequested), isTrue);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('feedback: type chips, attachments that show what they attach, the notice, Send', (tester) async {
    final (t, relay) = await _telemetry(tester);
    await t.setEnabled(false); // feedback works with telemetry off
    relay.next = const RelayResponse(201, body: '{"issue":"https://github.com/Kmandevr/C.A.W-Telemetry/issues/1"}');
    await _pump(tester, Scaffold(body: FeedbackForm(telemetry: t, errors: () => [
      {'type': 'StateError', 'where': 'package:caw/ui/shell.dart:120', 'count': 2},
    ])));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
    expect(find.text(feedbackNotice), findsOneWidget);
    expect(feedbackNotice, contains('Kmandevr/C.A.W-Telemetry'));
    for (final k in ['Bug', 'Idea', "Something's confusing", 'Praise']) {
      expect(find.text(k), findsOneWidget);
    }
    expect(find.text('No Benchmark result yet'), findsOneWidget);
    final send = find.byKey(const ValueKey('feedback-send'));
    expect(tester.widget<ButtonStyleButton>(send).onPressed, isNull, reason: 'no text yet');
    await tester.tap(find.text('Idea'));
    await tester.enterText(find.byKey(const ValueKey('feedback-text')), 'A darker theme');
    await tester.tap(find.byKey(const ValueKey('feedback-attach-errors')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('feedback-shows-errors')), findsOneWidget);
    expect(find.textContaining('package:caw/ui/shell.dart:120'), findsOneWidget);
    await tester.ensureVisible(send);
    await tester.tap(send);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    final body = jsonDecode(relay.bodies.single) as Map;
    expect(body['kind'], 'idea');
    expect(body['text'], 'A darker theme');
    expect((body['attachments'] as Map).keys, ['errors']);
    expect(body.containsKey('contact'), isFalse);
  });

  group('goldens', () {
    testWidgets('first run, phone', (tester) async {
      await pumpGolden(tester, FirstRunPage(telemetryOn: true, onContinue: () {}), phone360);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/privacy_first_run_phone.png'));
    });

    testWidgets('Privacy page, phone', (tester) async {
      final (t, _) = await _telemetry(tester, reports: 1);
      Telemetry.current = t;
      addTearDown(() => Telemetry.current = null);
      await pumpGolden(tester, PrivacyPage(deps: SettingsDeps(settings: Settings())), phone360);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/privacy_settings_phone.png'));
    });

    testWidgets('My data, phone', (tester) async {
      final (t, _) = await _telemetry(tester, reports: 2);
      await pumpGolden(tester, MyDataPage(telemetry: t), phone360);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/privacy_my_data_phone.png'));
    });

    testWidgets('feedback sheet, phone', (tester) async {
      final (t, _) = await _telemetry(tester);
      await pumpGolden(tester, Scaffold(body: Align(alignment: Alignment.bottomCenter, child: FeedbackForm(telemetry: t, errors: () => const []))), phone360);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.tap(find.byKey(const ValueKey('feedback-attach-device')));
      await tester.pumpAndSettle();
      await expectLater(goldenScreen, matchesGoldenFile('goldens/privacy_feedback_phone.png'));
    });
  });
}
