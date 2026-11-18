// Golden tests of Settings (#244): the section list and the Sound page's glass cards at phone size (with a More fold
// open), and the two panes on a desktop.
import 'package:caw/model/settings.dart';
import 'package:caw/ui/settings/settings_page.dart';
import 'package:caw/ui/settings/settings_registry.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

void main() {
  testWidgets('settings list, phone', (tester) async {
    await pumpGolden(tester, SettingsPage(settings: Settings()), goldenSizes['phone']!);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/settings_phone.png'));
  });

  testWidgets('settings Sound page, phone', (tester) async {
    await pumpGolden(tester, SettingsPage(settings: Settings()), goldenSizes['phone']!);
    await tester.tap(find.text('Sound'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('more-devices')));
    await tester.pumpAndSettle();
    await expectLater(goldenScreen, matchesGoldenFile('goldens/settings_sound_phone.png'));
  });

  testWidgets('settings list and Editing page, desktop', (tester) async {
    await pumpGolden(
        tester, SettingsPage(settings: Settings(), initial: SettingsSection.editing), goldenSizes['desktop']!);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/settings_desktop.png'));
  });
}
