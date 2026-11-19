// The bird theme and personality (1.1.0): theme renames and their migration, Parrot's motion rules, the hidden surprises' triggers, generated names and the project card's stats.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:caw/model/easter_eggs.dart';
import 'package:caw/model/project_library.dart';
import 'package:caw/model/project_names.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/startup_progress.dart';
import 'package:caw/ui/crow.dart';
import 'package:caw/ui/devices/kit/presets.dart';
import 'package:caw/ui/egg_layer.dart';
import 'package:caw/ui/files/project_library_view.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/parrot.dart';
import 'package:caw/ui/settings/about_settings.dart';
import 'package:caw/ui/startup_screen.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCaw implements CawPlayer {
  int played = 0, stopped = 0;
  @override
  Future<void> play() async => played++;
  @override
  void stop() => stopped++;
}

void main() {
  tearDown(() {
    Neon.active = calmNeon;
    Motion.setting = MotionLevel.full;
  });

  group('themes', () {
    test('the built-ins are Raven, Jackdaw, Magpie and Jay; Raven is the default', () {
      expect(starterThemes.map((t) => t.name), ['Raven', 'Jackdaw', 'Magpie', 'Jay']);
      expect(Settings().themeName, 'Raven');
    });

    test('old names map to the bird families; a file with the bird names keeps its name', () {
      for (final (old, now) in [('Neon', 'Raven'), ('Flat', 'Jackdaw'), ('Dusk', 'Jackdaw'), ('Dawn', 'Jay'),
        ('Amber', 'Magpie'), ('Calm neon', 'Raven'), ('Night', 'Jackdaw'), ('Amber terminal', 'Magpie')]) {
        expect(migrateThemeName(old, birdFamilies: false), now, reason: old);
        expect((Settings()..fromJson({'theme': old})).themeName, now);
      }
      expect(migrateThemeName('My theme', birdFamilies: false), 'My theme');
      expect(migrateThemeName('Raven', birdFamilies: true), 'Raven');
      expect(migrateThemeName(null, birdFamilies: false), isNull);
      // A custom theme that took a bird name before the families had it stays chosen under its new name.
      expect(migrateThemeName('Jay', birdFamilies: false, customNames: {'Jay (mine)'}), 'Jay (mine)');
      expect(migrateThemeName('Jay', birdFamilies: true, customNames: {'Jay (mine)'}), 'Jay');
    });

    test('settings saved now carry the bird names and read back unchanged', () async {
      final dir = Directory.systemTemp.createTempSync('caw_birds');
      addTearDown(() => dir.deleteSync(recursive: true));
      final s = Settings(dir: dir);
      await s.chooseTheme('Magpie');
      final j = jsonDecode(File('${dir.path}/settings.json').readAsStringSync()) as Map<String, dynamic>;
      expect((j['theme'], j['theme_families']), ('Magpie', 2));
      expect((await Settings.open(base: dir)).themeName, 'Magpie');
    });

    test('Parrot is hidden until found and never the default', () async {
      final s = Settings();
      expect(s.themes.any((t) => t.name == 'Parrot'), isFalse);
      expect((Settings()..fromJson({'theme': 'Parrot', 'theme_families': 2})).themeName, 'Raven');
      await s.unlockParrot();
      expect(s.themes.any((t) => t.name == 'Parrot'), isTrue);
      expect(s.themeName, 'Raven', reason: 'found, not chosen');
      expect(s.isStarter('Parrot'), isTrue);
      final back = Settings()..fromJson(s.toJson()..['theme'] = 'Parrot');
      expect((back.parrotUnlocked, back.themeName), (true, 'Parrot'));
    });
  });

  group('Parrot motion', () {
    // A flash: a pair of opposing luminance changes of 10% or more (WCAG 2.3.1's general flash).
    int flashesInWorstSecond(MotionLevel level) {
      const stepMs = 5;
      final lum = [for (var ms = 0; ms <= 10000; ms += stepMs) ParrotMotion.luminanceAt(Duration(milliseconds: ms), level)];
      // Turning points of the curve, then swings of 10% or more between them.
      final turns = <(int, double)>[(0, lum.first)];
      for (var i = 1; i + 1 < lum.length; i++) {
        if ((lum[i] - lum[i - 1]) * (lum[i + 1] - lum[i]) < 0) turns.add((i * stepMs, lum[i]));
      }
      turns.add((10000, lum.last));
      final swings = <int>[];
      for (var i = 1; i < turns.length; i++) {
        final a = turns[i - 1].$2, b = turns[i].$2;
        if ((b - a).abs() / math.max(a, b) >= 0.1) swings.add(turns[i].$1);
      }
      var worst = 0;
      for (final at in swings) {
        worst = math.max(worst, swings.where((t) => t >= at && t < at + 1000).length);
      }
      return (worst / 2).ceil();
    }

    test('it never flashes more than three times a second', () {
      expect(flashesInWorstSecond(MotionLevel.full), lessThanOrEqualTo(ParrotMotion.maxFlashesPerSecond));
    });

    test('it holds still with Motion Off and Reduced', () {
      for (final level in [MotionLevel.off, MotionLevel.reduced]) {
        final a = (ParrotMotion.hueAt(Duration.zero, level), ParrotMotion.washAlphaAt(Duration.zero, level));
        for (final ms in [137, 1500, 4200, 9999]) {
          final t = Duration(milliseconds: ms);
          expect((ParrotMotion.hueAt(t, level), ParrotMotion.washAlphaAt(t, level)), a);
        }
        expect(flashesInWorstSecond(level), 0);
      }
      expect(ParrotMotion.hueAt(const Duration(seconds: 3), MotionLevel.full), closeTo(180, 0.01));
    });

    testWidgets('the glow runs no ticker with Motion Off', (tester) async {
      Motion.setting = MotionLevel.off;
      await tester.pumpWidget(const MaterialApp(home: ParrotGlow(on: true, child: SizedBox.expand())));
      expect(find.byKey(const ValueKey('parrot-glow')), findsOneWidget);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  group('surprises', () {
    test('seven quick taps on the version unlock Parrot; a pause starts again', () {
      var now = DateTime(2026, 5, 5, 12);
      final e = EasterEggs(clock: () => now);
      for (var i = 0; i < 6; i++) {
        expect(e.versionTapped(), isFalse);
        now = now.add(const Duration(milliseconds: 300));
      }
      now = now.add(const Duration(seconds: 3));
      expect(e.versionTapped(), isFalse, reason: 'the pause restarted the count');
      for (var i = 0; i < 5; i++) {
        e.versionTapped();
      }
      expect(e.versionTapped(), isTrue);
      expect(e.events.value?.kind, EggKind.parrotUnlocked);
    });

    test('B-A-D-E-G-G in any octave hatches a crow', () {
      final e = EasterEggs();
      for (final n in [60, 71, 69, 62, 64, 67, 67]) {
        e.notePlayed(n);
      }
      expect(e.events.value?.kind, EggKind.hatch);
      final f = EasterEggs();
      for (final n in [71, 69, 62, 64, 67, 69]) {
        f.notePlayed(n);
      }
      expect(f.events.value, isNull);
    });

    test('the Konami code on the on-screen keys flashes Parrot; from a USB keyboard it does nothing', () {
      const code = [60, 62, 64, 62, 60, 59, 60, 57, 59, 71, 69];
      final e = EasterEggs();
      for (final n in code) {
        e.notePlayed(n);
      }
      expect(e.events.value, isNull);
      for (final n in code) {
        e.notePlayed(n, onScreen: true);
      }
      expect(e.events.value?.kind, EggKind.parrotFlash);
      expect(EasterEggs.isKonami([60, 62, 64, 62, 60, 59, 60, 57, 59, 72, 69]), isFalse);
    });

    test('fifty undos in a row: "Time flies."; an edit in between starts again', () {
      final e = EasterEggs();
      for (var i = 0; i < 49; i++) {
        e.undone();
      }
      e.streakBroken();
      e.undone();
      expect(e.events.value, isNull);
      for (var i = 0; i < 49; i++) {
        e.undone();
      }
      expect(e.events.value?.kind, EggKind.timeFlies);
    });

    test('the clock rules: sleep, seasons, 1 April', () {
      expect(crowSleepsAt(DateTime(2026, 1, 1, 1, 59)), isFalse);
      expect(crowSleepsAt(DateTime(2026, 1, 1, 2)), isTrue);
      expect(crowSleepsAt(DateTime(2026, 1, 1, 4, 59)), isTrue);
      expect(crowSleepsAt(DateTime(2026, 1, 1, 5)), isFalse);
      expect(crowSeasonOn(DateTime(2026, 12, 3)), CrowSeason.scarf);
      expect(crowSeasonOn(DateTime(2027, 11, 13)), CrowSeason.partyHat);
      expect(crowSeasonOn(DateTime(2026, 10, 31)), CrowSeason.pumpkin);
      expect(crowSeasonOn(DateTime(2026, 6, 1)), CrowSeason.none);
      var now = DateTime(2027, 4, 1, 10);
      final e = EasterEggs(clock: () => now);
      e.countInStarted();
      expect(e.events.value?.kind, EggKind.caw);
      final seq = e.events.value!.seq;
      e.countInStarted();
      expect(e.events.value!.seq, seq, reason: 'once a day');
      now = DateTime(2027, 4, 2);
      final g = EasterEggs(clock: () => now)..countInStarted();
      expect(g.events.value, isNull);
    });

    test('133.7 BPM, 4:33 of silence, a project called Murder', () {
      expect(isLeetTempo(133.7), isTrue);
      expect(isLeetTempo(133.8), isFalse);
      expect(isCageSilence(seconds: 273.2, peakDb: -200), isTrue);
      expect(isCageSilence(seconds: 273.2, peakDb: -40), isFalse);
      expect(isCageSilence(seconds: 280, peakDb: -200), isFalse);
      expect(isMurderName(' murder '), isTrue);
      expect(isMurderName('Murders'), isFalse);
    });

    test('a startup blink is rare', () {
      final r = math.Random(1);
      final blinks = List.generate(4000, (_) => startupBlinks(r)).where((b) => b).length;
      expect(blinks, inInclusiveRange(50, 150));
    });

    test('the caw is a short WAV made here', () {
      final wav = synthCawWav();
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(wav.length, lessThan(64 * 1024));
    });

    test('hidden presets exist only where the engine has one', () {
      expect(DevicePresets.hidden.keys, unorderedEquals(['org.caw.vocoder', 'org.caw.pack.granular']));
    });

    testWidgets('the layer shows "Time flies.", hatches a crow, and a tap stops the caw', (tester) async {
      final e = EasterEggs();
      final caw = _FakeCaw();
      await tester.pumpWidget(MaterialApp(
          home: EggLayer(settings: Settings(), eggs: e, player: caw, child: const Scaffold(body: SizedBox.expand()))));
      e.undone();
      for (var i = 1; i < undoStreakRemark; i++) {
        e.undone();
      }
      await tester.pump();
      expect(find.text('Time flies.'), findsOneWidget);
      e.notePlayed(71);
      for (final n in [71, 69, 62, 64, 67, 67]) {
        e.notePlayed(n);
      }
      await tester.pump();
      expect(find.byKey(const ValueKey('hatching-crow')), findsOneWidget);
      e.caw();
      await tester.pump();
      expect(caw.played, 1);
      await tester.tapAt(const Offset(10, 300));
      expect(caw.stopped, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Time flies.'), findsNothing);
      expect(find.byKey(const ValueKey('hatching-crow')), findsNothing);
    });

    testWidgets('About: seven taps on the version unlock Parrot; holding the crow caws', (tester) async {
      final e = EasterEggs();
      final s = Settings();
      final caw = _FakeCaw();
      await tester.pumpWidget(MaterialApp(
          home: EggLayer(settings: s, eggs: e, player: caw,
              child: Scaffold(body: ListView(children: [AboutCrowRow(eggs: e)])))));
      for (var i = 0; i < versionTapsToUnlock; i++) {
        await tester.tap(find.byKey(const ValueKey('about-version')));
      }
      await tester.pump();
      expect(s.parrotUnlocked, isTrue);
      await tester.longPress(find.byKey(const ValueKey('about-crow')));
      await tester.pump();
      expect(caw.played, 1);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the startup crow dresses for the season and blinks once in a long while', (tester) async {
      for (final (date, season) in [(DateTime(2026, 12, 2), 'scarf'), (DateTime(2026, 11, 13), 'partyHat'),
        (DateTime(2026, 10, 31), 'pumpkin')]) {
        await tester.pumpWidget(MaterialApp(
            home: StartupScreen(key: ValueKey(season), progress: StartupProgress(), version: '1', now: date, blink: false)));
        expect(find.byKey(ValueKey('startup-crow-$season')), findsOneWidget);
      }
      await tester.pumpWidget(MaterialApp(
          home: StartupScreen(key: const ValueKey('b'), progress: StartupProgress(), version: '1', now: DateTime(2026, 6, 1), blink: true)));
      expect(find.byKey(const ValueKey('startup-crow-none')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(MaterialApp(
          home: StartupScreen(key: const ValueKey('c'), progress: StartupProgress(), version: '1', now: DateTime(2026, 6, 1), blink: false)));
      expect(find.byKey(const ValueKey('startup-crow-none')), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('133.7 BPM reads "leet" for a moment', (tester) async {
      Widget at(double bpm) => MaterialApp(home: TempoLeet(bpm: bpm, child: Text('$bpm BPM')));
      await tester.pumpWidget(at(120));
      await tester.pumpWidget(at(133.7));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('leet'), findsOneWidget);
      await tester.pump(leetTime);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('leet'), findsNothing);
      expect(find.text('133.7 BPM'), findsOneWidget);
    });

    testWidgets('the perched crow sleeps between 2 and 5 am', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Column(children: [
        PerchedCrow(now: DateTime(2026, 1, 1, 3)),
        PerchedCrow(now: DateTime(2026, 1, 1, 14)),
      ])));
      expect(find.byKey(const ValueKey('crow-asleep')), findsOneWidget);
      expect(find.byKey(const ValueKey('crow-perched')), findsOneWidget);
    });

    testWidgets('the loader circles with full motion and holds still with Off', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Center(child: CrowLoader())));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      expect(CrowLoaderPainter.frame(0.25, MotionLevel.full).angle, closeTo(math.pi / 2, 1e-9));
      expect(CrowLoaderPainter.frame(0.25, MotionLevel.reduced).angle, 0);
      Motion.setting = MotionLevel.off;
      await tester.pumpWidget(const MaterialApp(home: Center(child: CrowLoader(key: ValueKey('off')))));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('crow-loader-off')), findsOneWidget);
    });
  });

  group('projects', () {
    test('generated names are two words and never one already taken', () {
      final r = math.Random(3);
      final taken = <String>[];
      for (var i = 0; i < 200; i++) {
        final n = generateProjectName(taken, random: r);
        expect(n.split(' ').length, anyOf(2, 3));
        expect(taken.map((t) => t.toLowerCase()), isNot(contains(n.toLowerCase())));
        taken.add(n);
      }
      expect(projectNameCount, greaterThan(800));
    });

    test('a new project gets a generated name unless Settings turns them off', () {
      final s = Settings();
      expect(s.generatedProjectNames, isTrue);
      final off = Settings()..fromJson({'generated_project_names': false});
      expect(off.generatedProjectNames, isFalse);
      expect(off.toJson()['generated_project_names'], isFalse);
    });

    test('the card reads time spent, bars, tracks and the last export on one line', () {
      final m = ProjectMeta(id: 'a', name: 'A', modified: DateTime(2026), tracks: 6, bars: 32, spentSeconds: 8100,
          lastExport: DateTime(2026, 11, 3, 12));
      expect(projectStatsLine(m), startsWith('2 h 15 min spent · 32 bars · 6 tracks · exported '));
      expect(projectStatsLine(ProjectMeta(id: 'b', name: 'B', modified: DateTime(2026), tracks: 1, bars: 1)),
          'under a minute spent · 1 bar · 1 track · not exported yet');
      // An index entry from before the stats is read again from its project.
      expect(ProjectMeta.fromJson('a', {'name': 'A', 'modified': 1, 'tracks': 1, 'seconds': 1, 'bpm': 120, 'bytes': 1}),
          isNull);
      final back = ProjectMeta.fromJson('a', m.toJson())!;
      expect((back.bars, back.spentSeconds, back.lastExport), (32, 8100, m.lastExport!.toUtc()));
    });
  });
}
