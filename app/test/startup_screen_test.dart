// The startup screen: steps tick off as loading reports them, it leaves when loading is done, a still logo without
// motion, no overflow at 360 dp or on a desktop window, and its goldens at phone and desktop sizes mid-reveal.
import 'package:caw/model/app_state.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/startup_progress.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/startup_screen.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

Future<void> _pump(WidgetTester tester, Widget child, Size size) async {
  await loadAppFonts(tester);
  imageCache
    ..clear()
    ..clearLiveImages();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: Neon.theme(),
    builder: (context, c) => RepaintBoundary(key: goldenKey, child: GlassBackdrop(child: c ?? const SizedBox.shrink())),
    home: child,
  ));
}

StartupScreen _screen(StartupProgress p) => StartupScreen(progress: p, version: '0.9.0-beta.1');

Finder get _painter => find.byWidgetPredicate((w) => w is CustomPaint && w.painter is WaveformRevealPainter);

void main() {
  tearDown(() {
    Motion.setting = MotionLevel.full;
    Motion.minimalProfile = false;
  });

  testWidgets('the steps appear as they begin and tick off as they end', (tester) async {
    final p = StartupProgress();
    addTearDown(p.dispose);
    await _pump(tester, _screen(p), const Size(390, 844));
    expect(find.text('v0.9.0-beta.1'), findsOneWidget);
    expect(find.text('Starting audio engine'), findsNothing);

    p.begin(StartupStep.engine);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Starting audio engine'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNothing);

    p.finish(StartupStep.engine);
    p.begin(StartupStep.components);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.text('Loading C++ components'), findsOneWidget);

    p.finish(StartupStep.components, ok: false); // no compiler on this device
    p.finish(StartupStep.projects);
    p.begin(StartupStep.project, project: 'Mid tempo');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
    expect(find.text('Opening Mid tempo'), findsOneWidget);

    p.finish(StartupStep.project);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(3));
  });

  testWidgets('the reveal runs on a Ticker and ends by itself', (tester) async {
    final p = StartupProgress();
    addTearDown(p.dispose);
    await _pump(tester, _screen(p), const Size(390, 844));
    expect(_painter, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.binding.hasScheduledFrame, isTrue); // still revealing, frame by frame
    await tester.pump(revealDuration);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse); // done: no frames while loading waits
  });

  testWidgets('the screen leaves the moment loading is done, without waiting for the reveal', (tester) async {
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    await _pump(tester, StartupGate(state: s, child: const Scaffold(body: Text('the app'))), const Size(390, 844));
    expect(find.byType(StartupScreen), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200)); // mid-reveal

    s.ready = true;
    s.clipSelectionChanged(); // any notification
    await tester.pump();
    // The app takes input at once; the screen fades out over it in the standard fade.
    expect(tester.widget<IgnorePointer>(
        find.ancestor(of: find.byType(StartupScreen), matching: find.byType(IgnorePointer)).first).ignoring, isTrue);
    await tester.pump(Motion.standard + const Duration(milliseconds: 20));
    expect(find.byType(StartupScreen), findsNothing);
    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('with motion off the screen goes at once', (tester) async {
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    Motion.setting = MotionLevel.off;
    await _pump(tester, StartupGate(state: s, child: const Scaffold(body: Text('the app'))), const Size(390, 844));
    s.ready = true;
    s.clipSelectionChanged();
    await tester.pump();
    expect(find.byType(StartupScreen), findsNothing);
  });

  for (final (name, set) in [
    ('motion off', () => Motion.setting = MotionLevel.off),
    ('reduced motion', () => Motion.setting = MotionLevel.reduced),
    ('the Minimal profile', () => Motion.minimalProfile = true),
  ]) {
    testWidgets('$name shows the still logo with the steps', (tester) async {
      set();
      final p = StartupProgress()..begin(StartupStep.engine);
      addTearDown(p.dispose);
      await _pump(tester, _screen(p), const Size(390, 844));
      expect(_painter, findsNothing);
      expect(find.bySemanticsLabel('C.A.W.'), findsOneWidget);
      expect(find.text('Starting audio engine'), findsOneWidget);
      await tester.pumpAndSettle(); // Reduced still fades the row in
      expect(_painter, findsNothing);
    });
  }

  for (final size in const [Size(360, 640), Size(640, 360), Size(1280, 800), Size(1920, 1080)]) {
    testWidgets('no overflow at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      final p = StartupProgress();
      addTearDown(p.dispose);
      for (final step in StartupStep.values) {
        p.begin(step, project: step == StartupStep.project ? 'A very long project name that does not fit' : null);
      }
      await _pump(tester, _screen(p), size);
      await tester.pump(const Duration(milliseconds: 700));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final (name, size) in [('phone', goldenSizes['phone']!), ('desktop', goldenSizes['desktop']!)]) {
    testWidgets('golden: startup screen mid-reveal on $name', (tester) async {
      final p = StartupProgress()
        ..finish(StartupStep.engine)
        ..finish(StartupStep.components)
        ..begin(StartupStep.projects);
      addTearDown(p.dispose);
      await _pump(tester, _screen(p), size);
      await tester.pump(revealDuration * 0.62); // the outline mostly traced, the wave calming
      await expectLater(goldenScreen, matchesGoldenFile('goldens/startup_$name.png'));
    });
  }
}
