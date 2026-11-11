// Goldens of key screens in light (and Flat) palettes: Arrange at phone size, a device editor and Settings › Look,
// in Dawn light, Neon light and Flat light or dark, so light mode is checked by eye where it matters most.
import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/clip_preview.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/settings/settings_page.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

const _source = '---\ncaw: 1\nkind: pattern\nname: Riff\nlength: 1 bar\n---\n0 C4 4 1\n4 E4 4 1\n8 G4 8 1\n12 C5 4 1\n';

ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Light test', modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: _source),
    ], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [
        ClipDoc(id: 'c1', patternId: 'pat', startSteps: 0, lengthSteps: 32),
        ClipDoc(id: 'c2', patternId: 'pat', startSteps: 32, lengthSteps: 16),
      ]),
      LayerDoc(id: 'b', name: 'Bass', color: 1, clips: [ClipDoc(id: 'c3', patternId: 'pat', startSteps: 16, lengthSteps: 32)]),
      LayerDoc(id: 'c', name: 'Drums', color: 2, clips: [ClipDoc(id: 'c4', patternId: 'pat', startSteps: 0, lengthSteps: 64)]),
      LayerDoc(id: 'd', name: 'Pads', color: 3),
    ]);

/// Puts [family] in force in [mode] on [s] (and so on Neon.active).
void _look(Settings s, String family, LookMode mode) {
  s.chooseTheme(family);
  s.setLookMode(mode);
}

void main() {
  var motion = MotionLevel.full;
  setUp(() {
    motion = Motion.setting;
    ClipPictureCache.instance.clear();
  });
  tearDown(() {
    Motion.setting = motion;
    Neon.active = calmNeon;
    Glass.enabled = true;
  });

  const looks = {
    'dawn_light': ('Dawn', LookMode.light),
    'neon_light': ('Neon', LookMode.light),
  };

  for (final e in {...looks, 'flat_dark': ('Flat', LookMode.dark)}.entries) {
    testWidgets('golden: Arrange at phone size, ${e.key}', (tester) async {
      final s = AppState(settings: Settings());
      final sections = SectionController();
      addTearDown(() {
        s.dispose();
        sections.dispose();
      });
      s.project = _project();
      _look(s.settings, e.value.$1, e.value.$2);
      await pumpGolden(tester, SectionScope(controller: sections,
          child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s)))),
          goldenSizes['phone']!);
      expect(tester.takeException(), isNull);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/theme_arrange_${e.key}_phone.png'));
      await tester.pump(const Duration(seconds: 2));
    });
  }

  for (final e in {...looks, 'flat_light': ('Flat', LookMode.light)}.entries) {
    testWidgets('golden: the EQ editor at phone size, ${e.key}', (tester) async {
      final source = DeviceDisplaySource.current;
      final display = FakeDisplay();
      DeviceDisplaySource.current = display;
      addTearDown(() => DeviceDisplaySource.current = source);
      const id = 'org.caw.eq';
      final s = stateWith(id, make: PreviewState.new);
      addTearDown(s.dispose);
      Motion.setting = MotionLevel.off;
      _look(s.settings, e.value.$1, e.value.$2);
      display.frame.value = fakeFrame(id);
      late BuildContext ctx;
      await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      })), goldenSizes['phone']!);
      openDevice(ctx, s, id);
      await tester.pumpAndSettle();
      for (var i = 30; i >= 0; i--) {
        display.frame.value = fakeFrame(id, tick: i);
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/theme_device_${e.key}_phone.png'));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  for (final e in looks.entries) {
    testWidgets('golden: Settings › Look at phone size, ${e.key}', (tester) async {
      final s = Settings();
      _look(s, e.value.$1, e.value.$2);
      await pumpGolden(tester, SettingsPage(settings: s), goldenSizes['phone']!);
      await tester.tap(find.text('Look'));
      await tester.pumpAndSettle();
      expect(find.text('Theme family'), findsOneWidget);
      expect(find.text('Follow system'), findsOneWidget);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/theme_settings_${e.key}_phone.png'));
    });
  }
}
