// The theme editor that builds the theme for you: the builder's flow (mood, seed, harmony, Shuffle, Save), Start
// from, the feel controls in force at once, Advanced folded, and goldens of the editor on a phone and a desktop.
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/clip_look.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/haptics.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/theme.dart';
import 'package:caw/ui/theme_editor.dart';
import 'package:caw/ui/theme_palette.dart';
import 'package:caw/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

void main() {
  tearDown(() {
    Neon.active = calmNeon;
    Neon.glowStrength = 1;
    Radii.scale = 1;
    ClipLook.corner = ClipCorner.rounded;
    ClipLook.fill = ClipFill.standard;
    EditMotion.feel = MotionFeel.subtle;
    EditMotion.kinds = {...EditMotionKind.values};
    Motion.setting = MotionLevel.full;
    Haptics.feel = {};
    Haptics.enabled = true;
    Glass.enabled = true;
  });

  Future<Settings> open(WidgetTester tester, {Size size = const Size(800, 9000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = Settings();
    await tester.pumpWidget(MaterialApp(theme: Neon.theme(), home: ThemeEditor(settings: s)));
    await tester.pump();
    return s;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('a mood builds both palettes live, Shuffle varies them, and Save keeps them', (tester) async {
    final s = await open(tester);
    expect(find.byKey(const ValueKey('theme-preview-arrange')), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-preview-device')), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-preview-roll')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mood-Forest')));
    await tester.pump();
    final forest = buildPalettes(paletteMoods.firstWhere((m) => m.name == 'Forest').recipe);
    expect(Neon.green.toARGB32(), forest.dark['green']!.toARGB32(), reason: 'shown live everywhere');
    await tester.tap(find.byKey(const ValueKey('theme-shuffle')));
    await tester.pump();
    expect(Neon.green.toARGB32(), isNot(forest.dark['green']!.toARGB32()));
    await tester.tap(find.byKey(const ValueKey('tile-Triadic')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('seed-#FF8A1F')));
    await tester.pump();
    final built = buildPalettes(const PaletteRecipe(seed: Color(0xFFFF8A1F), harmony: Harmony.triadic));
    expect(Neon.green.toARGB32(), built.dark['green']!.toARGB32());
    await tester.enterText(find.byType(TextField).first, 'Orange grove');
    await tester.tap(find.byKey(const ValueKey('theme-save')));
    await tester.pumpAndSettle();
    expect(s.themeName, 'Orange grove');
    expect(s.theme.hasOwnLight, isTrue);
    expect(s.theme.lightColors['green'], built.light['green']);
    expect(contrastFailures(s.theme.lightColors), isEmpty);
    await close(tester);
  });

  testWidgets('Start from makes a custom theme from a family, its profile in force', (tester) async {
    final s = await open(tester);
    await tester.tap(find.byKey(const ValueKey('theme-start-from')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('start-from-Dawn')));
    await tester.pumpAndSettle();
    expect(s.themeName, 'My Dawn');
    expect(s.isStarter('My Dawn'), isFalse);
    expect(s.theme.lightColors['bg'], dawnTheme.lightColors['bg']);
    await close(tester);
  });

  testWidgets('the feel controls are in force at once', (tester) async {
    final s = await open(tester);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('theme-clip-corner')), matching: find.text('Round')));
    await tester.pump();
    expect(ClipLook.corner, ClipCorner.round);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('theme-clip-fill')), matching: find.text('Outline')));
    await tester.pump();
    expect(ClipLook.fill, ClipFill.outline);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('theme-header-style')), matching: find.text('Roomy')));
    await tester.pump();
    expect((s.headerWidth, s.trackHeight), (200.0, 88.0));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('haptic-feel-tick')), matching: find.text('Off')));
    await tester.pump();
    expect(Haptics.feel[HapticKind.tick], HapticFeel.off);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('theme-motion-preset')), matching: find.text('Snappy')));
    await tester.pump();
    expect(EditMotion.feel, MotionFeel.presets['Snappy']);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('theme-motion-enter')), matching: find.text('Slide')));
    await tester.pump();
    expect(EditMotion.feel.enter, MotionTransition.slide);
    await tester.tap(find.byKey(const ValueKey('theme-motion-tile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme-offer-duplicate')), findsOneWidget, reason: 'a starter offers a copy');
    await close(tester);
  });

  testWidgets('Flat turns glow and glass off in the editor; Advanced is folded until opened', (tester) async {
    final s = await open(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Flat'));
    await tester.pumpAndSettle();
    expect(s.themeName, 'Flat');
    final glass = tester.widget<SwitchListTile>(find.byKey(const ValueKey('theme-glass')));
    expect(glass.onChanged, isNull);
    expect(find.byKey(const ValueKey('slot-bg')), findsNothing);
    await tester.tap(find.text('Advanced: every colour'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('slot-bg')), findsOneWidget);
    await close(tester);
  });

  for (final e in goldenSizes.entries.where((e) => e.key != 'landscape')) {
    testWidgets('golden: the theme editor, ${e.key}', (tester) async {
      final s = Settings();
      await pumpGolden(tester, ThemeEditor(settings: s), e.value);
      await tester.tap(find.byKey(const ValueKey('mood-Sunset')));
      await tester.pumpAndSettle();
      await expectLater(goldenScreen, matchesGoldenFile('goldens/theme_editor_${e.key}.png'));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
