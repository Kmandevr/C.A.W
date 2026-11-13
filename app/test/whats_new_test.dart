// Tests What's new: the changelog parser and its page, the bundled copy staying identical to the repository's
// CHANGELOG.md, the once-after-update rule (fresh install, same, newer and older versions), and the startup order.
import 'dart:io';
import 'dart:math';

import 'package:caw/model/changelog.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/telemetry/relay_client.dart';
import 'package:caw/model/telemetry/telemetry.dart';
import 'package:caw/model/telemetry/telemetry_config.dart';
import 'package:caw/ui/app_prompts.dart';
import 'package:caw/ui/privacy/privacy_pages.dart';
import 'package:caw/ui/settings/settings_registry.dart';
import 'package:caw/ui/whats_new.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _sample = '''
# Changelog

What changed in each release, newest first.
Versions keep the `-alpha.N` suffix.

## 1.0.2-alpha.1 (not yet released)

### New
- **Changelog:** this list, in the app.

## 1.0.1-alpha.1 (2026-11-13)

The polish release.

### Improved
- **Benchmark:**
  - It measures what the app really does.
  - Live runs at your playing buffer
    and at Low latency.
- Plain **bold in the middle** and an unmatched ** marker.

## 1.0.0-alpha.1
- First.
''';

Future<String> _load(String _) async => _sample;

class _Relay implements RelayHttp {
  @override
  Future<RelayResponse> send(String method, Uri url, {required Map<String, String> headers, String? body}) async =>
      const RelayResponse(202);
}

/// A loaded telemetry; [accepted] says whether its first-run page was answered at an earlier launch.
Future<Telemetry> _telemetry(WidgetTester tester, {required bool accepted}) async {
  final t = Telemetry(
    config: TelemetryConfig.parse(channel: 'beta', relayUrl: 'https://relay.example.dev', appKey: 'k'),
    store: MemoryTelemetryStore(),
    http: _Relay(),
    now: () => DateTime.utc(2026, 11, 13, 10),
    random: Random(3),
  );
  await tester.runAsync(() async {
    await t.load();
    if (accepted) await t.acceptFirstRun();
  });
  return t;
}

Future<void> _pump(WidgetTester tester, Widget child, {Size size = const Size(360, 780)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

/// A page with a button that runs [prompts] (built from its context) as the shell does.
Widget _host(List<Future<void> Function()> Function(BuildContext) prompts) => Scaffold(
      body: Builder(
        builder: (c) => Center(
          child: TextButton(
            key: const ValueKey('go'),
            onPressed: () => AppPrompts.runInOrder(prompts(c)),
            child: const Text('go'),
          ),
        ),
      ),
    );

void main() {
  group('parser', () {
    test('entries, newest first, with the suffix kept apart from the version', () {
      final log = Changelog.parse(_sample);
      expect(log.title, 'Changelog');
      expect(log.entries.map((e) => e.version), ['1.0.2-alpha.1', '1.0.1-alpha.1', '1.0.0-alpha.1']);
      expect(log.entries.map((e) => e.note), ['not yet released', '2026-11-13', '']);
      expect(log.entryFor('1.0.1-alpha.1'), same(log.entries[1]));
      expect(log.entryFor('1.0.1'), isNull);
      // Two lines with no blank between are one paragraph; backticks are code.
      expect(log.intro.single.kind, ChangelogKind.paragraph);
      expect(log.intro.single.text, 'What changed in each release, newest first. Versions keep the -alpha.N suffix.');
      expect(log.intro.single.spans[1], const ChangelogSpan('-alpha.N', code: true));
    });

    test('subheadings, paragraphs, nested bullets, continuation lines and bold', () {
      final lines = Changelog.parse(_sample).entryFor('1.0.1-alpha.1')!.lines;
      expect([for (final l in lines) (l.kind, l.depth)], [
        (ChangelogKind.paragraph, 0),
        (ChangelogKind.subheading, 0),
        (ChangelogKind.bullet, 0),
        (ChangelogKind.bullet, 1),
        (ChangelogKind.bullet, 1),
        (ChangelogKind.bullet, 0),
      ]);
      expect(lines[1].text, 'Improved');
      expect(lines[2].spans, [const ChangelogSpan('Benchmark:', bold: true)]);
      expect(lines[4].text, 'Live runs at your playing buffer and at Low latency.');
      expect(lines[5].spans, [
        const ChangelogSpan('Plain '),
        const ChangelogSpan('bold in the middle', bold: true),
        const ChangelogSpan(' and an unmatched ** marker.'),
      ]);
    });

    test('limits: a huge or odd file still parses', () {
      expect(Changelog.parse('').entries, isEmpty);
      final deep = Changelog.parse('## 1.0.0\n${'          - deep'}\n');
      expect(deep.entries.single.lines.single.depth, Changelog.maxDepth);
      final big = Changelog.parse('## 1.0.0\n${'- x\n' * 10000}');
      expect(big.entries.single.lines.length, lessThan(Changelog.maxLines));
    });

    test("the bundled copy is the repository's CHANGELOG.md, and every release since 1.0.0 has an entry", () {
      final root = File('../CHANGELOG.md').readAsStringSync();
      final bundled = File('assets/CHANGELOG.md').readAsStringSync();
      expect(bundled, root, reason: 'copy it again: cp CHANGELOG.md app/assets/CHANGELOG.md');
      final log = Changelog.parse(bundled);
      for (final v in ['1.0.0-alpha.1', '1.0.1-alpha.1']) {
        expect(log.entryFor(v)?.lines, isNotEmpty, reason: v);
      }
      expect(File('pubspec.yaml').readAsStringSync(), contains('- $changelogAsset'));
    });
  });

  group('once after an update', () {
    test('fresh install, same version, newer, older', () {
      const now = '1.0.2-alpha.1';
      expect(whatsNewDue(lastSeen: '', current: now, freshInstall: true), WhatsNewDue.record);
      expect(whatsNewDue(lastSeen: '', current: now, freshInstall: false), WhatsNewDue.show,
          reason: 'an update from a build that stored no version');
      expect(whatsNewDue(lastSeen: now, current: now, freshInstall: false), WhatsNewDue.none);
      expect(whatsNewDue(lastSeen: '1.0.1-alpha.1', current: now, freshInstall: false), WhatsNewDue.show);
      expect(whatsNewDue(lastSeen: '1.0.2-alpha.2', current: now, freshInstall: false), WhatsNewDue.record,
          reason: 'a downgrade: no sheet, just recorded');
      expect(whatsNewDue(lastSeen: '1.0.2-alpha.1+9', current: now, freshInstall: false), WhatsNewDue.record);
      expect(whatsNewDue(lastSeen: 'garbled', current: now, freshInstall: false), WhatsNewDue.record);
    });

    test('the last version seen is saved with the settings', () async {
      final dir = Directory.systemTemp.createTempSync('caw-whatsnew-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fresh = await Settings.open(base: dir);
      expect(fresh.existedOnLoad, isFalse);
      expect(fresh.lastSeenVersion, '');
      await fresh.update((s) => s.lastSeenVersion = '1.0.2-alpha.1');
      final again = await Settings.open(base: dir);
      expect(again.existedOnLoad, isTrue);
      expect(again.lastSeenVersion, '1.0.2-alpha.1');
      expect((Settings()..fromJson({'last_seen_version': 'x' * 65})).lastSeenVersion, '', reason: 'too long: ignored');
    });

    testWidgets('a newer version: its entry as a sheet, once; See all changes opens the page', (tester) async {
      final s = Settings()..lastSeenVersion = '1.0.1-alpha.1';
      await _pump(tester, _host((c) => [() => showWhatsNew(c, s, WhatsNewDue.show, version: '1.0.2-alpha.1', load: _load)]));
      await tester.tap(find.byKey(const ValueKey('go')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('whats-new-sheet')), findsOneWidget);
      expect(find.text("What's new in v1.0.2-alpha.1"), findsOneWidget);
      expect(find.textContaining('this list, in the app'), findsOneWidget);
      expect(find.text('The polish release.'), findsNothing, reason: 'only the new version');
      expect(s.lastSeenVersion, '1.0.2-alpha.1');
      expect(AppPrompts.free, isFalse);
      await tester.tap(find.byKey(const ValueKey('whats-new-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('whats-new-sheet')), findsNothing);
      expect(find.byKey(const ValueKey('whats-new-entry:1.0.0-alpha.1')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(AppPrompts.free, isTrue);
      // The same version again: nothing.
      expect(whatsNewDue(lastSeen: s.lastSeenVersion, current: '1.0.2-alpha.1', freshInstall: false), WhatsNewDue.none);
    });

    testWidgets('Close closes it; a version with no entry, a record or none shows nothing', (tester) async {
      final s = Settings();
      await _pump(tester, _host((c) => [() => showWhatsNew(c, s, WhatsNewDue.show, version: '1.0.1-alpha.1', load: _load)]));
      await tester.tap(find.byKey(const ValueKey('go')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('whats-new-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('whats-new-sheet')), findsNothing);
      expect(find.byType(WhatsNewPage), findsNothing);
      for (final (due, version) in [
        (WhatsNewDue.show, '9.9.9'),
        (WhatsNewDue.record, '0.9.0-beta.1'),
        (WhatsNewDue.none, '0.9.0-beta.1'),
      ]) {
        final ctx = tester.element(find.byKey(const ValueKey('go')));
        await tester.runAsync(() => showWhatsNew(ctx, s, due, version: version, load: _load));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('whats-new-sheet')), findsNothing, reason: '$due $version');
      }
      expect(s.lastSeenVersion, '0.9.0-beta.1', reason: 'recorded; none leaves it');
    });
  });

  group('startup order', () {
    testWidgets('a fresh install: the first-run page, then only the version recorded', (tester) async {
      final t = await _telemetry(tester, accepted: false);
      final s = Settings(); // no settings file
      await _pump(tester, _host((c) => startupPrompts(c, t, s, version: '1.0.2-alpha.1', load: _load)));
      await tester.tap(find.byKey(const ValueKey('go')));
      await tester.pumpAndSettle();
      expect(find.byType(FirstRunPage), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('first-run-continue')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('whats-new-sheet')), findsNothing);
      expect(s.lastSeenVersion, '1.0.2-alpha.1');
      expect(AppPrompts.free, isTrue);
    });

    testWidgets('an update: What\'s new after the first-run page, holding the prompts throughout', (tester) async {
      // Unusual but possible (an old build's settings, the first-run page never answered): both, in order.
      final t = await _telemetry(tester, accepted: false);
      final s = Settings()
        ..existedOnLoad = true
        ..lastSeenVersion = '1.0.1-alpha.1';
      await _pump(tester, _host((c) => startupPrompts(c, t, s, version: '1.0.2-alpha.1', load: _load)));
      await tester.tap(find.byKey(const ValueKey('go')));
      await tester.pumpAndSettle();
      expect(find.byType(FirstRunPage), findsOneWidget);
      expect(find.byKey(const ValueKey('whats-new-sheet')), findsNothing, reason: 'never over another prompt');
      expect(AppPrompts.free, isFalse);
      await tester.tap(find.byKey(const ValueKey('first-run-continue')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      expect(find.byType(FirstRunPage), findsNothing);
      expect(find.byKey(const ValueKey('whats-new-sheet')), findsOneWidget);
      expect(AppPrompts.free, isFalse, reason: 'the update prompt still waits');
      await tester.tap(find.byKey(const ValueKey('whats-new-close')));
      await tester.pumpAndSettle();
      expect(AppPrompts.free, isTrue);
    });

    testWidgets('an accepted install with the version seen: no prompts at all', (tester) async {
      final t = await _telemetry(tester, accepted: true);
      final s = Settings()
        ..existedOnLoad = true
        ..lastSeenVersion = '1.0.2-alpha.1';
      await _pump(tester, _host((c) {
        final p = startupPrompts(c, t, s, version: '1.0.2-alpha.1', load: _load);
        expect(p, isEmpty);
        return p;
      }));
      await tester.tap(find.byKey(const ValueKey('go')));
      await tester.pumpAndSettle();
      // An update from a build that stored no version, first run long answered: What's new alone.
      final older = Settings()..existedOnLoad = false;
      final ctx = tester.element(find.byKey(const ValueKey('go')));
      expect(startupPrompts(ctx, t, older, version: '1.0.2-alpha.1', load: _load), hasLength(1));
    });
  });

  group('page', () {
    testWidgets('every entry with its date, and Settings search finds it', (tester) async {
      await _pump(tester, const WhatsNewPage(load: _load));
      expect(find.text("What's new"), findsOneWidget);
      expect(find.text('v1.0.2-alpha.1'), findsOneWidget);
      expect(find.text('not yet released'), findsOneWidget);
      expect(find.text('NEW'), findsNothing, reason: 'subheadings keep their case');
      expect(find.text('New'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('v1.0.0-alpha.1'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('v1.0.0-alpha.1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final found = searchSettings('changelog');
      expect(found[SettingsSection.about]?.map((e) => e.id), contains('about.whatsNew'));
    });

    testWidgets('a missing changelog says so instead of failing', (tester) async {
      await _pump(tester, WhatsNewPage(load: (_) async => throw StateError('no asset')));
      expect(find.text('The changelog is not in this build.'), findsOneWidget);
    });
  });
}
