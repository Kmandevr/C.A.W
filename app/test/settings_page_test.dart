// Tests the Settings screen: the five sections and every page opening, every setting from before the rework (#244)
// in exactly one card, every searchable setting's row in its card (its More fold opened), search by keyword jumping to
// a setting (its fold opened, scrolled to and flashing), the desktop's two panes, and a row's control changing it.
import 'package:caw/model/settings.dart';
import 'package:caw/ui/settings/settings_deps.dart';
import 'package:caw/ui/settings/settings_page.dart';
import 'package:caw/ui/settings/settings_registry.dart';
import 'package:caw/ui/settings/settings_widgets.dart';
import 'package:caw/ui/startup_screen.dart' show openAlphaNotice;
import 'package:caw/ui/theme.dart';
import 'package:caw/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every setting id the registry had before the rework (#244, 12 sections and 136 settings).
const _before = [
  'audio.status', 'audio.device', 'audio.rate', 'audio.buffer', 'audio.mode', 'audio.exclusive', 'audio.quality',
  'audio.background', 'audio.test', 'audio.input', 'audio.inputDevice', 'audio.inputChannels', 'audio.latency',
  'audio.latencyOffset', 'audio.outputLatency', 'audio.punch', 'audio.recordFormat', 'midi.devices',
  'midi.bluetooth', 'midi.mpe', 'midi.bendRange', 'midi.mappings', 'midi.device', 'midi.channel', 'midi.velocity',
  'midi.fixedVelocity', 'midi.thru', 'midi.keysVelocity', 'midi.keysFixedVelocity', 'midi.keysOctave',
  'recording.metronome', 'recording.clickSound', 'recording.clickVolume', 'recording.countIn', 'recording.preRoll',
  'recording.offset', 'recording.automation', 'editing.grid', 'editing.snap', 'editing.tool', 'editing.noteLength',
  'editing.follow', 'editing.followStyle', 'editing.followResume', 'editing.wheel', 'editing.confirmDelete',
  'editing.rowHeight', 'editing.velocityLane', 'editing.chanceLane', 'editing.gridLines', 'editing.grab',
  'editing.hold', 'editing.keyNames', 'editing.emptyDrag', 'editing.valueGrid', 'editing.hearNotes',
  'code.autoUpdate', 'code.delay', 'code.swap', 'code.fontSize', 'code.tabWidth', 'code.lineNumbers', 'code.wrap',
  'code.solo', 'code.scope', 'code.barOnTop', 'look.family', 'look.mode', 'look.theme', 'look.density',
  'look.layout', 'look.glass', 'look.blur', 'look.glow', 'look.meterFall', 'look.trackGap', 'look.headerWidth',
  'look.trackHeight', 'look.focusShare', 'feel.motion', 'feel.editStyle', 'feel.edit.notes', 'feel.edit.clips',
  'feel.edit.tracks', 'feel.edit.lengths', 'feel.edit.panels', 'feel.startupAnimation', 'feel.haptics',
  'feel.hapticStrength', 'feel.quickActions', 'feel.longPress', 'performance.profile', 'performance.lightAuto',
  'performance.frameRate', 'performance.benchmark', 'performance.hardware', 'performance.plan', 'projects.autosave',
  'projects.restorePoints', 'projects.newStart', 'projects.newTempo', 'projects.newMeter', 'projects.storage',
  'projects.clearCaches', 'export.kind', 'export.rate', 'export.depth', 'export.seconds', 'export.naming',
  'keys.bindings', 'keys.vim', 'keys.hints', 'keys.vimKeys', 'keys.keyRow', 'about.beta', 'about.whatsNew',
  'about.updates', 'about.updates.check', 'about.updates.prompts', 'about.updates.install', 'about.updates.channel',
  'about.updates.versions', 'about.privacy', 'about.feedback', 'privacy.telemetry', 'privacy.whatsSent',
  'privacy.myData', 'privacy.feedback', 'privacy.policy', 'privacy.terms', 'privacy.dashboard', 'about.policy',
  'about.terms', 'about.report', 'about.diagnostics', 'about.licences',
];

/// Opens every More fold on the page shown.
Future<void> _openFolds(WidgetTester tester, SettingsSection section) async {
  for (final card in section.cards) {
    final more = find.byKey(ValueKey('more-${card.name}'));
    if (more.evaluate().isEmpty) continue;
    await tester.ensureVisible(more.first);
    await tester.pumpAndSettle();
    await tester.tap(more.first);
    await tester.pumpAndSettle();
  }
}

Future<void> _pump(WidgetTester tester, Settings s, {Size size = const Size(390, 844)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: Neon.theme(),
    home: SettingsPage(settings: s, onEditKeys: (_) async {}),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a dropdown with a long choice goes under its title, never squeezing it (owner, 2026-11-18)',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final scale in [1.0, 1.3]) {
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(size: const Size(360, 800), textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                  body: ListView(children: [
                settingDropdown<String>('audio.inputDevice', 'a', const [
                  ('a', 'Default Capture Device · 2 ch'),
                  ('b', 'USB Audio Interface With A Very Long Name · 8 ch'),
                ], (_) {}, icon: Icons.mic),
                settingDropdown<String>('audio.inputDevice', 'x', const [('x', 'Short'), ('y', 'Other')], (_) {}),
              ])))));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final title = find.text(settingEntry('audio.inputDevice')!.title);
      for (final e in title.evaluate()) {
        expect(tester.getSize(find.byWidget(e.widget)).width, greaterThan(100), reason: 'scale $scale');
      }
      // The long choice sits below the title, the short one on the right.
      final rows = find.byType(ListTile);
      final longDropdown = find.descendant(of: rows.first, matching: find.byType(DropdownButton<String>));
      expect(tester.getTopLeft(longDropdown).dy, greaterThan(tester.getTopLeft(title.first).dy + 10));
      final shortDropdown = find.descendant(of: rows.at(1), matching: find.byType(DropdownButton<String>));
      expect(tester.getTopLeft(shortDropdown).dx, greaterThan(180));
    }
  });

  test('every setting from before the rework is in exactly one section, once (#244)', () {
    expect(_before, hasLength(136));
    final ids = [for (final e in settingEntries) e.id];
    expect(ids.toSet().length, ids.length, reason: 'each id once');
    for (final id in _before) {
      final now = mergedSettings[id] ?? id;
      final found = settingEntries.where((e) => e.id == now).toList();
      expect(found, hasLength(1), reason: id);
      expect(SettingsSection.values.where((s) => s.cards.contains(found.single.card)), hasLength(1), reason: id);
    }
    // The merged ids were duplicates: their one place stays.
    expect(mergedSettings.keys.where(ids.contains), isEmpty);
    expect(SettingsSection.values.map((s) => s.title),
        ['Sound', 'Editing', 'Appearance and feel', 'Projects and export', 'App']);
    expect(SettingsSection.sound.cards.map((c) => c.title), [
      'Audio devices', 'Quality and buffer', 'Latency and Bluetooth', 'Recording and metronome', 'MIDI and controllers',
    ]);
    // Each card holds at least one everyday row; nothing is only under a fold.
    for (final card in SettingsCard.values) {
      expect(card.entries.where((e) => !e.more), isNotEmpty, reason: card.name);
    }
    // Recording offsets live together in Latency and Bluetooth, distinctly named.
    expect(settingEntry('audio.latencyOffset')!.card, SettingsCard.latency);
    expect(settingEntry('recording.offset')!.card, SettingsCard.latency);
    expect(settingEntries.where((e) => e.title == 'Recording offset'), isEmpty);
    // Privacy Policy, Terms and Send feedback once each.
    for (final title in ['Privacy Policy', 'Terms', 'Send feedback']) {
      expect(settingEntries.where((e) => e.title == title), hasLength(1), reason: title);
    }
    expect(settingEntry('about.diagnostics')!.card, SettingsCard.about);
  });

  testWidgets('the list shows the five sections with a summary; each page has every row in its card', (tester) async {
    final s = Settings();
    await _pump(tester, s);
    for (final section in SettingsSection.values) {
      final tile = find.byKey(ValueKey('section-${section.name}'));
      await tester.scrollUntilVisible(tile, 100, scrollable: find.byType(Scrollable).first);
      expect(find.descendant(of: tile, matching: find.text(section.title)), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.text(section.summary(s))), findsOneWidget);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('section-page-${section.name}')), findsOneWidget);
      for (final card in section.cards) {
        expect(find.byKey(ValueKey('card-${card.name}'), skipOffstage: false), findsOneWidget, reason: card.name);
      }
      // Folded rows are not built until their fold opens.
      for (final e in settingEntries.where((e) => e.section == section && e.more && settingAvailable(e))) {
        expect(find.byKey(ValueKey('setting-${e.id}'), skipOffstage: false), findsNothing, reason: e.id);
      }
      await _openFolds(tester, section);
      // Every setting the search knows for this section has its row, once, inside its own card.
      for (final e in settingEntries.where((e) => e.section == section && e.searchable && settingAvailable(e))) {
        final row = find.byKey(ValueKey('setting-${e.id}'), skipOffstage: false);
        expect(row, findsOneWidget, reason: e.id);
        expect(
            find.descendant(of: find.byKey(ValueKey('card-${e.card.name}'), skipOffstage: false), matching: row,
                skipOffstage: false),
            findsOneWidget,
            reason: '${e.id} in ${e.card.name}');
        if (e.more) {
          expect(
              find.descendant(of: find.byKey(ValueKey('fold-${e.card.name}'), skipOffstage: false), matching: row,
                  skipOffstage: false),
              findsOneWidget,
              reason: '${e.id} under the fold');
        }
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
  });

  test('search finds every searchable setting by its own title (#244)', () {
    for (final e in settingEntries.where((e) => e.searchable && settingAvailable(e))) {
      expect(searchSettings(e.title)[e.section]?.map((x) => x.id), contains(e.id), reason: e.id);
    }
    // A merged setting's old words still lead to its place.
    expect(searchSettings('terms')[SettingsSection.app]!.map((e) => e.id), contains('about.privacy'));
  });

  testWidgets('a search result in a More fold opens the fold, scrolled to the row (#244)', (tester) async {
    for (final e in settingEntries.where((e) => e.more && e.searchable && settingAvailable(e))) {
      await tester.pumpWidget(MaterialApp(
        theme: Neon.theme(),
        home: Scaffold(
            body: SettingsSectionBody(
                key: ValueKey(e.id), section: e.section, deps: SettingsDeps(settings: Settings()), highlight: e.id)),
      ));
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('setting-${e.id}'));
      expect(find.descendant(of: find.byKey(ValueKey('fold-${e.card.name}')), matching: row), findsOneWidget,
          reason: e.id);
      final rect = tester.getRect(row);
      expect(rect.top, greaterThanOrEqualTo(0), reason: e.id);
      expect(rect.top, lessThan(600), reason: '${e.id} scrolled into view');
    }
  });

  testWidgets('About shows the version with the owner\'s open-alpha line, as the startup screen does', (tester) async {
    await _pump(tester, Settings());
    final tile = find.byKey(const ValueKey('section-app'));
    await tester.scrollUntilVisible(tile, 100, scrollable: find.byType(Scrollable).first);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.textContaining('v$appVersion · $openAlphaNotice'), findsOneWidget);
  });

  test('search finds settings by title, description and keyword, grouped by section', () {
    final latency = searchSettings('latency');
    expect(latency[SettingsSection.sound]!.map((e) => e.id),
        containsAll(['audio.buffer', 'audio.exclusive', 'recording.offset', 'audio.latencyOffset']));
    expect(searchSettings('autoscroll')[SettingsSection.editing]!.single.id, 'editing.follow');
    expect(searchSettings('vibration').keys, [SettingsSection.appearance]);
    expect(searchSettings('click volume')[SettingsSection.sound]!.single.id, 'recording.clickVolume');
    expect(searchSettings('headphones unplug')[SettingsSection.sound]!.single.id, 'audio.pauseOnUnplug');
    expect(searchSettings('nothing like this'), isEmpty);
    expect(settingEntries.map((e) => e.id).toSet().length, settingEntries.length, reason: 'ids are unique');
  });

  testWidgets('a search result opens its page scrolled to the setting, which flashes', (tester) async {
    final s = Settings();
    await _pump(tester, s);
    await tester.enterText(find.byKey(const ValueKey('settings-search')), 'restore');
    await tester.pumpAndSettle();
    expect(find.text('PROJECTS AND EXPORT'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('result-projects.restorePoints')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final row = find.byKey(const ValueKey('setting-projects.restorePoints'));
    expect(row, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 150));
    final box = tester.widget<DecoratedBox>(find.descendant(of: row, matching: find.byType(DecoratedBox)).first);
    expect((box.decoration as BoxDecoration).color!.a, greaterThan(0), reason: 'flashing');
    await tester.pumpAndSettle();
    final after = tester.widget<DecoratedBox>(find.descendant(of: row, matching: find.byType(DecoratedBox)).first);
    expect((after.decoration as BoxDecoration).color!.a, 0, reason: 'the flash fades');
    final rect = tester.getRect(row);
    expect(rect.top, greaterThan(56));
    expect(rect.bottom, lessThan(844), reason: 'scrolled into view');
    // A keyword not in the title: "autoscroll" finds Follow the playhead.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('settings-search')), 'autoscroll');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('result-editing.follow')), findsOneWidget);
  });

  testWidgets('desktop: the list and a page side by side; a result switches the page', (tester) async {
    final s = Settings();
    await _pump(tester, s, size: const Size(1280, 800));
    expect(find.byKey(const ValueKey('section-sound')), findsOneWidget);
    expect(find.byKey(const ValueKey('section-page-sound')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('section-projects')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('section-page-projects')), findsOneWidget);
    expect(find.byKey(const ValueKey('section-sound')), findsOneWidget, reason: 'the list stays');
    await tester.enterText(find.byKey(const ValueKey('settings-search')), 'tab width');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('result-code.tabWidth')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('section-page-app')), findsOneWidget);
    expect(find.byKey(const ValueKey('setting-code.tabWidth')), findsOneWidget, reason: 'its fold opened');
  });

  testWidgets('a row\'s control changes its setting and the list summary follows', (tester) async {
    final s = Settings();
    await _pump(tester, s);
    await tester.tap(find.byKey(const ValueKey('section-editing')));
    await tester.pumpAndSettle();
    expect(s.followPlayhead, isTrue);
    await tester.tap(find.byKey(const ValueKey('switch-editing.follow')));
    await tester.pumpAndSettle();
    expect(s.followPlayhead, isFalse);
    final select = find.descendant(of: find.byKey(const ValueKey('choice-editing.tool')), matching: find.text('Select'));
    await tester.ensureVisible(select);
    await tester.pumpAndSettle();
    await tester.tap(select);
    await tester.pumpAndSettle();
    expect(s.rollTool, StartTool.select);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text(SettingsSection.editing.summary(s)), findsOneWidget);
    expect(SettingsSection.editing.summary(s), contains('Select'));
  });

  test('SettingRow keys match the registry ids', () {
    expect(SettingRow(id: 'x', child: const SizedBox()).key, const ValueKey('setting-x'));
  });
}
