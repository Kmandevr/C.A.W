// Golden (screenshot) test helpers: loads real fonts (the bundled JetBrains Mono, and the Flutter SDK's Roboto and
// Material icons, Android's UI font) so layouts measure like on a phone, and pumps a widget at the plan's sizes.
import 'dart:io';

import 'package:caw/ui/glass.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The screen sizes every workspace is checked at (logical pixels), from the UI plan.
const Map<String, Size> goldenSizes = {
  'phone': Size(390, 844),
  'landscape': Size(844, 390),
  'desktop': Size(1280, 800),
};

bool _fontsLoaded = false;

/// Loads JetBrains Mono from the app's assets, and Roboto and the Material icons from the Flutter SDK the tests run
/// with (`FLUTTER_ROOT`), so text has real widths instead of the test font's square blocks.
Future<void> loadAppFonts(WidgetTester tester) async {
  if (_fontsLoaded) return;
  await tester.runAsync(_load);
  _fontsLoaded = true;
}

Future<void> _load() async {
  await (FontLoader(Neon.mono)
        ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'))
        ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Bold.ttf')))
      .load();
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) throw StateError('FLUTTER_ROOT is not set; run golden tests with `flutter test`');
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<ByteData> file(String name) async => ByteData.sublistView(await File('$dir/$name').readAsBytes());
  await (FontLoader('Roboto')
        ..addFont(file('Roboto-Regular.ttf'))
        ..addFont(file('Roboto-Medium.ttf'))
        ..addFont(file('Roboto-Bold.ttf')))
      .load();
  await (FontLoader('MaterialIcons')..addFont(file('MaterialIcons-Regular.otf'))).load();
}

/// The whole screen with the glass backdrop behind it; goldens of see-through screens capture this.
final goldenKey = GlobalKey(debugLabel: 'golden');

/// Finds [goldenKey]'s boundary, for `matchesGoldenFile`.
Finder get goldenScreen => find.byKey(goldenKey);

/// Pumps [child] in the app's theme at [size], with animations settled.
Future<void> pumpGolden(WidgetTester tester, Widget child, Size size) async {
  await loadAppFonts(tester);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: Neon.theme(),
    builder: (context, c) => RepaintBoundary(key: goldenKey, child: GlassBackdrop(child: c ?? const SizedBox.shrink())),
    home: child,
  ));
  await tester.pumpAndSettle();
}
