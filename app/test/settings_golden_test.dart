// Golden test of the Settings page at phone size: the Look and Motion sections (theme, density, motion, haptics, glow).
import 'package:caw/model/settings.dart';
import 'package:caw/ui/theme_editor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

void main() {
  testWidgets('settings page, phone', (tester) async {
    await pumpGolden(tester, SettingsPage(settings: Settings()), goldenSizes['phone']!);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/settings_phone.png'));
  });
}
