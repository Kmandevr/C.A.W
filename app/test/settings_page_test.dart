// Tests the Settings screen: the section list and every page opening, every searchable setting having its row,
// search by keyword jumping to a setting (scrolled to and flashing), the desktop's two panes, and a row's control
// changing its setting.
import 'package:caw/model/settings.dart';
import 'package:caw/ui/settings/settings_page.dart';
import 'package:caw/ui/settings/settings_registry.dart';
import 'package:caw/ui/settings/settings_widgets.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
  testWidgets('the list shows every section with a summary, and each opens its page', (tester) async {
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
      // Every setting the search knows for this section has its row on the page.
      for (final e in settingEntries.where((e) => e.section == section && e.searchable)) {
        expect(find.byKey(ValueKey('setting-${e.id}'), skipOffstage: false), findsOneWidget, reason: e.id);
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
  });

  test('search finds settings by title, description and keyword, grouped by section', () {
    final latency = searchSettings('latency');
    expect(latency[SettingsSection.audio]!.map((e) => e.id), containsAll(['audio.buffer', 'audio.exclusive']));
    expect(latency[SettingsSection.recording]!.map((e) => e.id), contains('recording.offset'));
    expect(searchSettings('autoscroll')[SettingsSection.editing]!.single.id, 'editing.follow');
    expect(searchSettings('vibration').keys, [SettingsSection.feel]);
    expect(searchSettings('click volume')[SettingsSection.recording]!.single.id, 'recording.clickVolume');
    expect(searchSettings('nothing like this'), isEmpty);
    expect(settingEntries.map((e) => e.id).toSet().length, settingEntries.length, reason: 'ids are unique');
  });

  testWidgets('a search result opens its page scrolled to the setting, which flashes', (tester) async {
    final s = Settings();
    await _pump(tester, s);
    await tester.enterText(find.byKey(const ValueKey('settings-search')), 'restore');
    await tester.pumpAndSettle();
    expect(find.text('PROJECTS AND FILES'), findsOneWidget);
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
    expect(find.byKey(const ValueKey('section-audio')), findsOneWidget);
    expect(find.byKey(const ValueKey('section-page-audio')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('section-export')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('section-page-export')), findsOneWidget);
    expect(find.byKey(const ValueKey('section-audio')), findsOneWidget, reason: 'the list stays');
    await tester.enterText(find.byKey(const ValueKey('settings-search')), 'tab width');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('result-code.tabWidth')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('section-page-code')), findsOneWidget);
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
    await tester.tap(find.text('Select').first);
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
