// Golden tests of Settings: the section list and the Audio page at phone size, and the two panes on a desktop.
import 'package:caw/model/settings.dart';
import 'package:caw/ui/settings/settings_page.dart';
import 'package:caw/ui/settings/settings_registry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

void main() {
  testWidgets('settings list, phone', (tester) async {
    await pumpGolden(tester, SettingsPage(settings: Settings()), goldenSizes['phone']!);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/settings_phone.png'));
  });

  testWidgets('settings Audio page, phone', (tester) async {
    await pumpGolden(tester, SettingsPage(settings: Settings()), goldenSizes['phone']!);
    await tester.tap(find.text('Audio'));
    await tester.pumpAndSettle();
    await expectLater(goldenScreen, matchesGoldenFile('goldens/settings_audio_phone.png'));
  });

  testWidgets('settings list and Recording page, desktop', (tester) async {
    await pumpGolden(
        tester, SettingsPage(settings: Settings(), initial: SettingsSection.recording), goldenSizes['desktop']!);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/settings_desktop.png'));
  });
}
