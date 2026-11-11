// Tests the theme editor's palette builder (deterministic, AA in both modes for every mood, harmony and shuffle) and
// that the theme's feel tokens (corners, clip look, haptic feel, the motion style) reach the app.
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/clip_look.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/haptics.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/panel_motion.dart';
import 'package:caw/ui/theme.dart';
import 'package:caw/ui/theme_palette.dart';
import 'package:caw/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder implements HapticsDevice {
  final played = <(HapticKind, double)>[];
  @override
  void play(HapticKind kind, double scale) => played.add((kind, scale));
}

void main() {
  tearDown(() {
    Neon.active = calmNeon;
    Radii.scale = 1;
    ClipLook.corner = ClipCorner.rounded;
    ClipLook.fill = ClipFill.standard;
    EditMotion.feel = MotionFeel.subtle;
    Haptics.feel = {};
    Haptics.device = const FlutterHaptics();
    Haptics.reset();
    Glass.enabled = true;
  });

  group('palette builder', () {
    test('the same recipe always makes the same palettes; Shuffle makes another', () {
      const r = PaletteRecipe(seed: Color(0xFF1E9BD7), harmony: Harmony.triadic, variation: 3);
      final a = buildPalettes(r), b = buildPalettes(r);
      expect(a.dark, b.dark);
      expect(a.light, b.light);
      final c = buildPalettes(r.copyWith(variation: 4));
      expect(c.dark, isNot(a.dark));
    });

    test('every mood, harmony, seed and shuffle passes AA in dark and light', () {
      final recipes = [
        for (final m in paletteMoods) m.recipe,
        for (final seed in seedSwatches)
          for (final h in Harmony.values)
            for (final v in [0, 1, 2]) PaletteRecipe(seed: seed, harmony: h, variation: v),
        const PaletteRecipe(seed: Color(0xFF808080), second: Color(0xFFFFFF00), harmony: Harmony.complementary),
      ];
      for (final r in recipes) {
        final p = buildPalettes(r);
        expect(contrastFailures(p.dark), isEmpty, reason: 'dark ${r.seed} ${r.harmony} ${r.variation}');
        expect(contrastFailures(p.light), isEmpty, reason: 'light ${r.seed} ${r.harmony} ${r.variation}');
        expect(isLightPalette(p.dark), isFalse);
        expect(isLightPalette(p.light), isTrue);
      }
    });

    test('the seed is the main accent, the danger accent stays red to magenta, tracks are eight distinct colours', () {
      final p = buildPalettes(const PaletteRecipe(seed: Color(0xFF39D353), harmony: Harmony.analogous)).dark;
      final seedHue = HSLColor.fromColor(const Color(0xFF39D353)).hue;
      expect((HSLColor.fromColor(p['green']!).hue - seedHue).abs(), lessThan(4));
      for (final h in Harmony.values) {
        for (final v in [0, 1, 5]) {
          final pink = HSLColor.fromColor(
              buildPalettes(PaletteRecipe(seed: const Color(0xFF1FA8FF), harmony: h, variation: v)).dark['pink']!).hue;
          expect(pink >= 315 || pink <= 20, isTrue, reason: '$h $v: $pink');
        }
      }
      expect({for (final s in layerSlots) p[s]!.toARGB32()}.length, 8);
    });
  });

  group('feel tokens', () {
    test('corner roundness, clip look, haptic feel and motion style reach the app from a profile', () {
      final s = Settings();
      s.applyProfile({
        'look.roundness': '0',
        'look.clip_corner': 'round',
        'look.clip_fill': 'outline',
        'behaviour.haptic_feel': 'tick:off,tap:firm',
        'behaviour.motion_feel': 'quick,snappy,fadeScale,fade',
      });
      s.update((_) {});
      expect(Radii.scale, 0);
      expect(Radii.m, 0);
      expect(ClipLook.radius(40), 20);
      expect(ClipLook.under(Colors.red, false), Colors.transparent);
      expect(ClipLook.gradient(Colors.red, false), isNull);
      expect(EditMotion.feel, MotionFeel.presets['Snappy']);
      expect(Motion.move(Motion.standard, MotionLevel.full), Motion.standard * 0.7);
      expect(Motion.fade(Motion.small, MotionLevel.reduced), Motion.small * 0.7);
      expect(Motion.move(Motion.standard, MotionLevel.reduced), Duration.zero, reason: 'Reduced still only fades');
      expect(EditMotion.scaled(MotionLevel.full, EditMotionKind.panels, pageTransition), pageTransition * 0.7);
      expect(EditMotion.scaled(MotionLevel.off, EditMotionKind.panels, pageTransition), isNull);
      expect(EditMotion.curve, Curves.fastOutSlowIn);
      final rec = _Recorder();
      Haptics.device = rec;
      Haptics.reset();
      Haptics.tick();
      Haptics.tap();
      expect(rec.played.single.$1, HapticKind.tap);
      expect(rec.played.single.$2, closeTo(Haptics.baseScale[HapticKind.tap]! * Haptics.firmScale, 1e-9));
      // The profile carries them back out.
      final p = s.captureProfile();
      expect(p['look.clip_corner'], 'round');
      expect(p['behaviour.motion_feel'], 'quick,snappy,fadeScale,fade');
      expect(p['behaviour.haptic_feel'], 'tap:firm,tick:off');
    });

    test('Subtle and Playful are motion styles; the defaults keep the app as it was', () {
      final s = Settings();
      expect(s.motionFeel, MotionFeel.subtle);
      expect(Motion.move(Motion.standard, MotionLevel.full), Motion.standard);
      s.update((x) => x.editMotionStyle = EditMotionStyle.playful);
      expect(EditMotion.feel, MotionFeel.playful);
      expect(EditMotion.style, EditMotionStyle.playful);
      expect(EditMotion.durationFor(MotionLevel.full, EditMotionKind.notes), const Duration(milliseconds: 260));
      s.update((x) => x.motionFeel = MotionFeel.presets['Calm']!);
      expect(EditMotion.style, EditMotionStyle.subtle);
      expect(MotionFeel.decode(MotionFeel.presets['Bouncy']!.encode()), MotionFeel.presets['Bouncy']);
      expect(MotionFeel.decode('nonsense'), isNull);
    });

    testWidgets('a page pushed with the Bouncy style scales in; Reduced only fades', (tester) async {
      EditMotion.feel = MotionFeel.presets['Bouncy']!;
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      Navigator.of(ctx).push(panelRoute<void>(ctx, (_) => const Text('page')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.ancestor(of: find.text('page'), matching: find.byType(ScaleTransition)), findsWidgets);
      await tester.pumpAndSettle();
    });
  });
}
