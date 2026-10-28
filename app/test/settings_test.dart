// Tests saving and loading the settings and custom themes, and the startup screen's choices.
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/storage.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('caw_settings'));
  tearDown(() {
    dir.deleteSync(recursive: true);
    Neon.active = calmNeon;
  });

  test('defaults: Calm neon, comfortable, auto-update on at 400 ms, swap now', () async {
    final s = await Settings.open(base: dir);
    expect(s.themeName, 'Calm neon');
    expect(s.density, Density.comfortable);
    expect(s.liveUpdate, isTrue);
    expect(s.liveDelayMs, 400);
    expect(s.swapTiming, SwapTiming.now);
  });

  test('settings and a custom theme are saved and loaded back', () async {
    final s = await Settings.open(base: dir);
    await s.update((x) {
      x.density = Density.compact;
      x.liveUpdate = false;
      x.liveDelayMs = 750;
      x.swapTiming = SwapTiming.bar;
    });
    final mine = calmNeon.copyWith(name: 'Mine').withColor('bg', const Color(0xFF123456));
    await s.saveTheme(mine);
    expect(Neon.bg.toARGB32(), 0xFF123456);

    final back = await Settings.open(base: dir);
    expect(back.density, Density.compact);
    expect(back.liveUpdate, isFalse);
    expect(back.liveDelayMs, 750);
    expect(back.swapTiming, SwapTiming.bar);
    expect(back.themeName, 'Mine');
    expect(back.theme['bg'].toARGB32(), 0xFF123456);
    expect(File('${dir.path}/themes/Mine.theme').readAsStringSync(), contains('kind: theme'));
  });

  test('a starter theme is never overwritten: saving it makes a copy', () async {
    final s = await Settings.open(base: dir);
    final saved = await s.saveTheme(calmNeon.withColor('pink', const Color(0xFF00FF00)));
    expect(saved.name, 'Calm neon copy');
    expect(s.themeNamed('Calm neon')['pink'].toARGB32(), 0xFFFF2BD6);
    await s.deleteTheme(saved.name);
    expect(s.themeName, 'Calm neon');
    expect(s.customThemes, isEmpty);
  });

  test('damaged settings fall back to the defaults', () async {
    File('${dir.path}/settings.json').writeAsStringSync('{not json');
    final s = await Settings.open(base: dir);
    expect(s.liveDelayMs, 400);
  });

  test('startup offers Continue only when the last project still exists', () {
    final a = ProjectSummary('a', 'Alpha', DateTime(2026));
    final b = ProjectSummary('b', 'Beta', DateTime(2026));
    expect(startupChoices('b', [a, b]).last?.name, 'Beta');
    expect(startupChoices('gone', [a, b]).last, isNull);
    expect(startupChoices(null, const []).last, isNull);
  });
}
