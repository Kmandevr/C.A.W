// Tests the light and dark theme families: AA contrast of every built-in palette, the light/dark generator (round
// trip, old one-palette files), the migration of old theme names, the Mode switch and Follow system.
import 'dart:convert';
import 'dart:io';

import 'package:caw/main.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/theme.dart';
import 'package:caw/ui/theme_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    Neon.active = calmNeon;
    Glass.enabled = true;
  });

  group('contrast', () {
    for (final t in starterThemes) {
      for (final light in [false, true]) {
        test('${t.name} ${light ? 'light' : 'dark'} passes AA on every surface', () {
          final shown = t.shown(light);
          expect(shown.light, light);
          final p = shown.colors;
          expect(isLightPalette(p), light);
          expect(contrastFailures(p), isEmpty);
          // The floors themselves, spelled out: text, dim and the accents 4.5:1, track colours 3:1.
          for (final s in ['text', 'dim', ...accentSlots]) {
            expect(worstContrast(p, p[s]!), greaterThanOrEqualTo(4.5), reason: s);
          }
          for (final s in layerSlots) {
            expect(worstContrast(p, p[s]!), greaterThanOrEqualTo(3.0), reason: s);
          }
          // The code colours that are not slots, and text on an accent button (onPrimary is the background).
          Neon.active = shown;
          expect(worstContrast(p, Neon.codeString), greaterThanOrEqualTo(4.5));
          expect(worstContrast(p, Neon.codeOperator), greaterThanOrEqualTo(4.5));
          expect(contrast(p['bg']!, p['green']!), greaterThanOrEqualTo(4.5));
        });
      }
    }

    test('the generator meets AA for any dark or light palette it is given', () {
      final odd = {
        ...calmNeon.darkColors,
        'bg': const Color(0xFF102030),
        'text': const Color(0xFF808080),
        'green': const Color(0xFF00FF00),
        'yellow': const Color(0xFFFFFF00),
      };
      expect(contrastFailures(lightFrom(odd)), isEmpty);
      expect(contrastFailures(darkFrom(lightFrom(odd))), isEmpty);
    });
  });

  group('light and dark palettes', () {
    test('a family keeps its hues in both modes', () {
      for (final t in starterThemes) {
        for (final s in [...accentSlots, ...layerSlots]) {
          final d = HSLColor.fromColor(t.darkColors[s]!), l = HSLColor.fromColor(t.lightColors[s]!);
          if (d.saturation < 0.25) continue; // a grey has no hue to keep
          final diff = (d.hue - l.hue).abs() % 360;
          expect(diff > 180 ? 360 - diff : diff, lessThan(8), reason: '${t.name} $s');
        }
      }
    });

    test('Make light version, then dark: hues kept, both pass, and the result is editable', () {
      final mine = calmNeon.copyWith(name: 'Mine').withColor('pink', const Color(0xFFE0409A));
      final light = mine.makeLight();
      expect(light.hasOwnLight, isTrue);
      expect(contrastFailures(light.lightColors), isEmpty);
      final back = light.shown(true).makeDark();
      expect(contrastFailures(back.darkColors), isEmpty);
      for (final s in accentSlots) {
        final a = HSLColor.fromColor(mine.darkColors[s]!).hue, b = HSLColor.fromColor(back.darkColors[s]!).hue;
        final diff = (a - b).abs() % 360;
        expect(diff > 180 ? 360 - diff : diff, lessThan(8), reason: s);
      }
      // An edit to the light palette stays in it; the dark one is untouched.
      final edited = light.shown(true).withColor('bg', const Color(0xFFFFFFFF));
      expect(edited.lightColors['bg']!.toARGB32(), 0xFFFFFFFF);
      expect(edited.darkColors['bg'], mine.darkColors['bg']);
      // Both palettes survive the file; an older build reads the plain lines (the dark palette).
      final file = edited.toFile();
      expect(file, contains('light.bg: #FFFFFF\n'));
      final read = CawTheme.parse(file);
      expect(read.lightColors['bg']!.toARGB32(), 0xFFFFFFFF);
      expect(read.darkColors['pink']!.toARGB32(), 0xFFE0409A);
    });

    test('an old one-palette file loads as dark, or as light by its background, with the other made', () {
      final dark = CawTheme.parse('---\nkind: theme\nname: Old\n---\nbg: #101010\npink: #FF0088\n');
      expect(dark.hasOwnLight, isFalse);
      expect(dark.darkColors['bg']!.toARGB32(), 0xFF101010);
      expect(contrastFailures(dark.lightColors), isEmpty);
      final light = CawTheme.parse('---\nkind: theme\nname: Paper\n---\nbg: #FAFAF5\ntext: #202020\n');
      expect(light.hasOwnLight, isTrue);
      expect(light.lightColors['bg']!.toARGB32(), 0xFFFAFAF5);
      expect(isLightPalette(light.darkColors), isFalse);
      expect(contrastFailures(light.darkColors), isEmpty);
    });

    test('a theme in either mode is one object, so the Material theme is kept', () {
      final light = dawnTheme.shown(true);
      expect(dawnTheme.shown(true), same(light));
      expect(light.shown(false), same(dawnTheme));
      expect(Neon.theme(look: light).brightness, Brightness.light);
      expect(Neon.theme(look: dawnTheme).brightness, Brightness.dark);
    });

    test('ink is white on dark and the text colour on light', () {
      Neon.active = calmNeon;
      expect(Neon.ink.toARGB32(), 0xFFFFFFFF);
      Neon.active = neonLight;
      expect(Neon.ink.toARGB32(), neonLight['text'].toARGB32());
    });

    test('Flat: no glow, no glass and solid fills, in both modes', () {
      for (final light in [false, true]) {
        final s = Settings();
        s.chooseTheme('Flat');
        s.setLookMode(light ? LookMode.light : LookMode.dark);
        expect(s.glass, isTrue, reason: 'the user\'s own setting stays');
        expect(Glass.enabled, isFalse);
        expect(Neon.flat, isTrue);
        expect(Neon.glow(Neon.green), isEmpty);
        expect(Neon.strokeGlow, 0);
        final r = Neon.ramp([const Color(0xFF000000), const Color(0xFFFFFFFF)]);
        expect(r[0], r[1]);
        s.chooseTheme('Neon');
        expect(Glass.enabled, isTrue);
        expect(Neon.ramp([const Color(0xFF000000), const Color(0xFFFFFFFF)])[0].toARGB32(), 0xFF000000);
      }
    });
  });

  group('settings', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('caw_modes'));
    tearDown(() => dir.deleteSync(recursive: true));

    for (final (old, family) in [('Night', 'Dusk'), ('Calm neon', 'Neon'), ('Amber terminal', 'Amber')]) {
      test('a saved "$old" opens as $family, dark', () async {
        File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({'theme': old}));
        final s = await Settings.open(base: dir);
        expect(s.themeName, family);
        expect(s.lookMode, LookMode.dark);
        expect(s.activeTheme.light, isFalse);
        expect(Neon.active.name, family);
      });
    }

    test('a custom theme named like a new family keeps its colours under another name', () async {
      Directory('${dir.path}/themes').createSync();
      File('${dir.path}/themes/Dawn.theme').writeAsStringSync('---\nkind: theme\nname: Dawn\n---\nbg: #123456\n');
      final s = await Settings.open(base: dir);
      expect(s.themeNamed('Dawn (mine)')['bg'].toARGB32(), 0xFF123456);
      expect(s.isStarter('Dawn'), isTrue);
    });

    test('Mode changes only the palette, saved, and the theme object is kept per mode', () async {
      final s = Settings(dir: dir);
      await s.update((x) {
        x.trackGap = 11;
        x.roundness = 1.5;
      });
      await s.chooseTheme('Dawn');
      final dark = s.activeTheme;
      await s.setLookMode(LookMode.light);
      expect(s.activeTheme.light, isTrue);
      expect(Neon.bg.toARGB32(), dawnTheme.lightColors['bg']!.toARGB32());
      expect((s.trackGap, s.roundness, s.themeName), (11.0, 1.5, 'Dawn'));
      await s.setLookMode(LookMode.dark);
      expect(s.activeTheme, same(dark));
      await s.setLookMode(LookMode.light);
      final back = await Settings.open(base: dir);
      expect(back.lookMode, LookMode.light);
      expect(back.activeTheme.light, isTrue);
    });

    test('Follow system follows the platform, and only then; one rebuild per change', () {
      final s = Settings();
      s.setPlatformBrightness(Brightness.light);
      expect(s.activeTheme.light, isFalse, reason: 'Mode is Dark');
      s.setLookMode(LookMode.system);
      expect(s.activeTheme.light, isTrue);
      final rev = s.lookRevision;
      s.setPlatformBrightness(Brightness.dark);
      expect(s.activeTheme.light, isFalse);
      expect(s.lookRevision, rev + 1);
      s.setPlatformBrightness(Brightness.dark);
      expect(s.lookRevision, rev + 1, reason: 'no change, no rebuild');
    });
  });

  testWidgets('the app follows the system brightness live (Follow system)', (tester) async {
    final s = AppState();
    addTearDown(s.dispose);
    s.settings.lookMode = LookMode.system;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(CawApp(state: s));
    await tester.pump();
    ThemeData theme() => tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!;
    expect(theme().brightness, Brightness.dark);
    final rev = s.settings.lookRevision;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pump();
    expect(Neon.active.light, isTrue);
    expect(theme().brightness, Brightness.light);
    expect(s.settings.lookRevision, rev + 1, reason: 'one remount for the mode switch');
    final kept = theme();
    await tester.pump();
    expect(theme(), same(kept), reason: 'the theme object is kept while the look is the same');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
