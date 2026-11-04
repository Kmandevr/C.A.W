// Tests glass surfaces: the Glass setting is saved and applied, the Lightweight and Minimal profiles turn it off,
// only floating surfaces blur, and a golden of both surfaces, half on the plain background and half over colour.
import 'dart:io';

import 'package:caw/model/settings.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

void main() {
  tearDown(() {
    Glass.enabled = true;
    Glass.blurEnabled = true;
    Neon.performanceMode = PerformanceMode.balanced.index;
  });

  group('setting', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('caw_glass'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('on by default; saved, loaded and applied; damage keeps the default', () async {
      final s = await Settings.open(base: dir);
      expect(s.glass, isTrue);
      await s.update((x) => x.glass = false);
      expect(Glass.enabled, isFalse);
      Glass.enabled = true;
      final back = await Settings.open(base: dir);
      expect(back.glass, isFalse);
      expect(Glass.enabled, isFalse);
      final d = Settings()..fromJson({'glass': 'yes'});
      expect(d.glass, isTrue);
    });

    test('Lightweight keeps glass without blur, Minimal turns it off; the blur switch turns blur off', () {
      for (final m in PerformanceMode.values) {
        Neon.performanceMode = m.index;
        expect(Glass.active, m != PerformanceMode.minimal, reason: m.name);
        expect(Glass.blur, m == PerformanceMode.fullExperience || m == PerformanceMode.balanced, reason: m.name);
      }
      Neon.performanceMode = PerformanceMode.balanced.index;
      Glass.blurEnabled = false;
      expect(Glass.active, isTrue);
      expect(Glass.blur, isFalse);
    });

    test('the blur switch and the track gap are saved and loaded; damage keeps the defaults', () {
      final s = Settings()..fromJson({'glass_blur': false, 'track_gap': 12});
      expect(s.glassBlur, isFalse);
      expect(s.trackGap, 12);
      final back = Settings()..fromJson(s.toJson());
      expect(back.glassBlur, isFalse);
      expect(back.trackGap, 12);
      final d = Settings()..fromJson({'glass_blur': 'no', 'track_gap': double.nan});
      expect(d.glassBlur, isTrue);
      expect(d.trackGap, 6);
      expect((Settings()..fromJson({'track_gap': 500})).trackGap, Settings.maxTrackGap);
    });
  });

  group('surfaces', () {
    Future<void> pump(WidgetTester tester) => tester.pumpWidget(const MaterialApp(
          home: Column(children: [
            GlassPanel(child: SizedBox(width: 50, height: 50)),
            GlassOverlay(child: SizedBox(width: 50, height: 50)),
          ]),
        ));

    testWidgets('only the floating surface blurs', (tester) async {
      await pump(tester);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.descendant(of: find.byType(GlassPanel), matching: find.byType(BackdropFilter)), findsNothing);
    });

    testWidgets('nothing blurs with glass off, with blur off, or in the Lightweight profile', (tester) async {
      Glass.enabled = false;
      await pump(tester);
      expect(find.byType(BackdropFilter), findsNothing);
      Glass.enabled = true;
      Glass.blurEnabled = false;
      await pump(tester);
      expect(find.byType(BackdropFilter), findsNothing);
      Glass.blurEnabled = true;
      Neon.performanceMode = PerformanceMode.lightweight.index;
      await pump(tester);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('golden: glass with blur off still reads as glass', (tester) async {
      Glass.blurEnabled = false;
      await pumpGolden(
        tester,
        Scaffold(
          body: Stack(children: [
            Positioned.fill(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Spacer(flex: 8),
                for (var i = 0; i < 8; i++) Expanded(child: ColoredBox(color: Neon.layer(i).withValues(alpha: 0.5))),
              ]),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 40,
              child: GlassOverlay(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text('Floating toolbar, no blur', style: TextStyle(color: Neon.text)),
              ),
            ),
            Positioned(left: 16, right: 16, top: 60, child: Slider(value: 0.6, onChanged: (_) {})),
          ]),
        ),
        goldenSizes['phone']!,
      );
      await expectLater(goldenScreen, matchesGoldenFile('goldens/glass_noblur_phone.png'));
    });
  });

  testWidgets('golden: a glass panel and a frosted toolbar over track colours', (tester) async {
    await pumpGolden(
      tester,
      Scaffold(
        body: Stack(children: [
          Positioned.fill(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Spacer(flex: 8),
              for (var i = 0; i < 8; i++) Expanded(child: ColoredBox(color: Neon.layer(i).withValues(alpha: 0.5))),
            ]),
          ),
          Positioned(
            left: 16,
            right: 16,
            top: 40,
            // Half on the plain background (the usual case), half over colour.
            height: 300,
            child: GlassPanel(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Docked panel', style: TextStyle(color: Neon.text)),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 40,
            child: GlassOverlay(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(children: [
                Icon(Icons.play_arrow, color: Neon.green),
                const SizedBox(width: 12),
                Text('Floating toolbar', style: TextStyle(color: Neon.text)),
              ]),
            ),
          ),
        ]),
      ),
      goldenSizes['phone']!,
    );
    await expectLater(goldenScreen, matchesGoldenFile('goldens/glass_phone.png'));
  });
}
