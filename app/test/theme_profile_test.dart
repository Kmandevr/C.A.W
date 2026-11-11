// Tests theme profiles (look, layout, behaviour in a theme), old colours-only themes, Off keeping usability motion,
// edit-animation settings and the theme editor's sections.
import 'dart:io';

import 'package:caw/model/settings.dart';
import 'package:caw/ui/feedback.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/haptics.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/panel_motion.dart';
import 'package:caw/ui/theme.dart';
import 'package:caw/ui/theme_editor.dart';
import 'package:caw/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('caw_profile'));
  tearDown(() {
    dir.deleteSync(recursive: true);
    Neon.active = calmNeon;
    Neon.performanceMode = PerformanceMode.balanced.index;
    Neon.light = false;
    Neon.showScopes = true;
    Neon.glowStrength = 1;
    Radii.scale = 1;
    Motion.setting = MotionLevel.full;
    Motion.minimalProfile = false;
    Haptics.enabled = true;
    EditMotion.style = EditMotionStyle.subtle;
    EditMotion.kinds = {...EditMotionKind.values};
    Glass.enabled = true;
  });

  group('theme file', () {
    test('a profile survives the file round trip, grouped by part', () {
      final t = calmNeon.copyWith(name: 'Mine', profile: {
        'look.font': 'mono',
        'layout.dock': '{"desktop":{"a":[1,2]}}',
        'behaviour.motion': 'reduced',
      });
      final f = t.toFile();
      expect(f.indexOf('look.font'), lessThan(f.indexOf('layout.dock')));
      expect(f.indexOf('layout.dock'), lessThan(f.indexOf('behaviour.motion')));
      final back = CawTheme.parse(f);
      expect(back.profile, t.profile);
      expect(back.toFile(), f);
    });

    test('a colours-only theme writes no profile lines, as before profiles', () {
      expect(calmNeon.toFile(), isNot(contains('look.')));
      final old = CawTheme.parse('---\nkind: theme\nname: Old\n---\nbg: #112233\nglow: off\n');
      expect(old.profile, isEmpty);
    });
  });

  group('settings', () {
    Future<Settings> withCustom(Settings s, String name, Map<String, String> profile) =>
        s.saveTheme(calmNeon.copyWith(name: name, profile: profile)).then((_) => s);

    test('saving a theme captures the whole profile and loading reads it back', () async {
      final s = await Settings.open(base: dir);
      await s.update((x) {
        x.uiFont = UiFont.mono;
        x.textScale = 1.15;
        x.roundness = 0.5;
        x.glowStrength = 1.5;
        x.trackHeight = 72;
        x.headerWidth = 150;
        x.focusPanelShare = 0.5;
        x.dockLayouts = {'desktop': {'probe': 1}};
        x.longPressMenu = LongPressMenuStyle.ring;
        x.hapticStrength = 0.8;
        x.motion = MotionLevel.reduced;
        x.editMotionStyle = EditMotionStyle.playful;
        x.editMotionKinds = {EditMotionKind.notes};
        x.rollSnap = false;
        x.rollGrid = 8;
      });
      final saved = await s.saveTheme(calmNeon.copyWith(name: 'Studio', profile: s.captureProfile()));
      expect(saved.profile['look.font'], 'mono');
      expect(saved.profile['behaviour.edit_kinds'], 'notes');
      final file = File('${dir.path}/themes/Studio.theme').readAsStringSync();
      expect(file, contains('layout.track_height: 72.0'));

      final back = await Settings.open(base: dir);
      expect(back.theme.profile, saved.profile);
      expect(back.textScale, 1.15);
      expect(back.editMotionKinds, {EditMotionKind.notes});
      expect(EditMotion.style, EditMotionStyle.playful, reason: 'applied to the statics on load');
      expect(Radii.scale, 0.5);
      expect(Neon.glowStrength, 1.5);
    });

    test('switching theme applies its layout and behaviour; a starter puts the user\'s own values back', () async {
      final s = await Settings.open(base: dir);
      await s.update((x) {
        x.trackHeight = 60;
        x.longPressMenu = LongPressMenuStyle.list;
        x.motion = MotionLevel.full;
      });
      await withCustom(s, 'Big', {
        'layout.track_height': '120',
        'layout.header_width': '200',
        'layout.dock': '{"phonePortrait":{"x":1}}',
        'behaviour.long_press_menu': 'ring',
        'behaviour.motion': 'off',
        'behaviour.haptics': 'off',
        'behaviour.edit_style': 'playful',
      });
      expect(s.themeName, 'Big');
      expect(s.trackHeight, 120);
      expect(s.headerWidth, 200);
      expect(s.dockLayouts['phonePortrait'], {'x': 1});
      expect(s.longPressMenu, LongPressMenuStyle.ring);
      expect(Motion.setting, MotionLevel.off);
      expect(Haptics.enabled, isFalse);
      expect(EditMotion.style, EditMotionStyle.playful);

      await s.chooseTheme('Dusk');
      expect(s.trackHeight, 60, reason: 'the starters share the values in force before Big');
      expect(s.longPressMenu, LongPressMenuStyle.list);
      expect(s.motion, MotionLevel.full);

      await s.chooseTheme('Big');
      expect(s.trackHeight, 120);
    });

    test('an old colours-only theme keeps the current values (no reset), then fills in its profile', () async {
      Directory('${dir.path}/themes').createSync(recursive: true);
      File('${dir.path}/themes/Old.theme').writeAsStringSync('---\nkind: theme\nname: Old\n---\nbg: #112233\n');
      final s = await Settings.open(base: dir);
      await s.update((x) {
        x.trackHeight = 88;
        x.motion = MotionLevel.reduced;
        x.roundness = 1.4;
      });
      await s.chooseTheme('Old');
      expect(s.trackHeight, 88);
      expect(s.motion, MotionLevel.reduced);
      expect(s.roundness, 1.4);
      expect(s.theme.profile['layout.track_height'], '88.0', reason: 'saved into the theme on choosing it');
      expect(File('${dir.path}/themes/Old.theme').readAsStringSync(), contains('behaviour.motion: reduced'));
    });

    test('editing a value with a custom theme chosen saves it into that theme; a starter is never changed', () async {
      final s = await withCustom(await Settings.open(base: dir), 'Mine', const {});
      await s.update((x) => x.headerWidth = 180);
      expect(s.theme.profile['layout.header_width'], '180.0');
      expect(File('${dir.path}/themes/Mine.theme').readAsStringSync(), contains('layout.header_width: 180.0'));

      await s.chooseTheme('Neon');
      await s.update((x) => x.headerWidth = 140);
      expect(calmNeon.profile, isEmpty);
      expect(s.themeNamed('Mine').profile['layout.header_width'], '180.0');
      await s.chooseTheme('Mine');
      expect(s.headerWidth, 180);
    });

    test('damaged profile values keep the current settings', () async {
      final s = await Settings.open(base: dir);
      await s.update((x) => x.trackGap = 4);
      s.applyProfile({
        'layout.track_gap': 'wide',
        'layout.dock': '{not json',
        'look.text_scale': '9',
        'behaviour.grid': '7',
      });
      expect(s.trackGap, 4);
      expect(s.textScale, Settings.maxTextScale, reason: 'clamped');
      expect(s.rollGrid, 16);
    });

    test('edit animation style and kinds are saved and wired to EditMotion', () async {
      final s = await Settings.open(base: dir);
      await s.update((x) {
        x.editMotionStyle = EditMotionStyle.playful;
        x.editMotionKinds = {EditMotionKind.clips, EditMotionKind.panels};
      });
      expect(EditMotion.kinds, {EditMotionKind.clips, EditMotionKind.panels});
      expect(EditMotion.durationFor(MotionLevel.full, EditMotionKind.notes), isNull);
      expect(EditMotion.durationFor(MotionLevel.full, EditMotionKind.clips), isNotNull);
      EditMotion.kinds = {...EditMotionKind.values};
      final back = await Settings.open(base: dir);
      expect(back.editMotionStyle, EditMotionStyle.playful);
      expect(EditMotion.kinds, {EditMotionKind.clips, EditMotionKind.panels});
    });
  });

  group('motion', () {
    test('Off keeps usability motion; Reduced turns it into a fade', () {
      const d = Duration(milliseconds: 80);
      expect(Motion.fade(d, MotionLevel.off), Duration.zero);
      expect(Motion.fade(d, Motion.usability(MotionLevel.off)), d);
      expect(Motion.move(d, Motion.usability(MotionLevel.off)), d);
      expect(Motion.move(d, Motion.usability(MotionLevel.reduced)), Duration.zero);
      expect(Motion.fade(d, Motion.usability(MotionLevel.reduced)), d);
    });

    testWidgets('a pressed control still dips with motion Off', (tester) async {
      Motion.setting = MotionLevel.off;
      await tester.pumpWidget(const MaterialApp(home: Center(child: Pressable(child: SizedBox(width: 40, height: 40)))));
      final g = await tester.startGesture(tester.getCenter(find.byType(Pressable)));
      await tester.pump();
      final scale = tester.widget<AnimatedScale>(find.byKey(const ValueKey('pressable')));
      expect(scale.scale, pressedScale);
      expect(scale.duration, Motion.small);
      await g.up();
    });

    test('panel motion: Subtle keeps the old length, Playful is longer, a kind turned off or Off has none', () {
      expect(EditMotion.scaled(MotionLevel.full, EditMotionKind.panels, Motion.standard), Motion.standard);
      EditMotion.style = EditMotionStyle.playful;
      expect(EditMotion.scaled(MotionLevel.full, EditMotionKind.panels, Motion.standard),
          Motion.standard * EditMotion.playfulScale);
      expect(EditMotion.scaled(MotionLevel.off, EditMotionKind.panels, Motion.standard), isNull);
      EditMotion.kinds = {EditMotionKind.notes};
      expect(EditMotion.scaled(MotionLevel.full, EditMotionKind.panels, Motion.standard), isNull);
    });

    testWidgets('pages: Material\'s route with Subtle, none when panels are off', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      expect(panelRoute<void>(ctx, (_) => const SizedBox()), isA<MaterialPageRoute<void>>());
      expect(sheetAnimation(ctx), isNull);
      EditMotion.kinds = {};
      final r = panelRoute<void>(ctx, (_) => const SizedBox()) as PageRouteBuilder<void>;
      expect(r.transitionDuration, Duration.zero);
      expect(sheetAnimation(ctx), AnimationStyle.noAnimation);
    });
  });

  testWidgets('the theme editor groups the builder, Feel, Layout, Behaviour and Advanced, and a starter offers a duplicate',
      (tester) async {
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = Settings();
    await tester.pumpWidget(MaterialApp(home: ThemeEditor(settings: s)));
    for (final h in ['PALETTE BUILDER', 'FEEL', 'LAYOUT', 'BEHAVIOUR', 'Advanced: every colour']) {
      expect(find.text(h), findsOneWidget, reason: h);
    }
    expect(find.byKey(const ValueKey('theme-offer-duplicate')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('theme-haptics')));
    await tester.pump();
    expect(s.haptics, isFalse);
    expect(find.byKey(const ValueKey('theme-offer-duplicate')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
