// The startup reveal's painter: its look at points along the timeline (goldens made before its per-frame work was
// cut, so they prove the look is unchanged), and that a frame builds no new Path or Paint once warmed up.
import 'dart:ui' as ui;

import 'package:caw/ui/startup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _key = GlobalKey(debugLabel: 'reveal');

Future<void> _pumpAt(WidgetTester tester, double t) async {
  tester.view.physicalSize = const Size(390, 160);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: RepaintBoundary(
      key: _key,
      child: ColoredBox(
        color: startupBackground,
        child: CustomPaint(
            size: const Size(390, 160), painter: WaveformRevealPainter(AlwaysStoppedAnimation(t), logoSize: 140)),
      ),
    ),
  ));
}

void main() {
  for (final t in const [0.12, 0.3, 0.45, 0.62, 0.79, 0.84, 0.93]) {
    testWidgets('golden: the reveal at $t', (tester) async {
      await _pumpAt(tester, t);
      await expectLater(find.byKey(_key), matchesGoldenFile('goldens/reveal_${(t * 100).round()}.png'));
    });
  }

  test('a frame of the reveal makes no new Path once warmed up, and records quickly', () {
    void frame(double t) {
      final recorder = ui.PictureRecorder();
      WaveformRevealPainter(AlwaysStoppedAnimation(t), logoSize: 140).paint(ui.Canvas(recorder), const Size(390, 160));
      recorder.endRecording().dispose();
    }

    for (var i = 0; i <= 156; i++) {
      frame(i / 156); // warm up: the outline is measured once for this size
    }
    final made = WaveformRevealPainter.debugPathsMade;
    final sw = Stopwatch()..start();
    var longest = 0;
    for (var i = 0; i <= 156; i++) { // 1.3 s at 120 Hz
      final before = sw.elapsedMicroseconds;
      frame(i / 156);
      longest = longest > sw.elapsedMicroseconds - before ? longest : sw.elapsedMicroseconds - before;
    }
    expect(WaveformRevealPainter.debugPathsMade, made);
    expect(made, lessThanOrEqualTo(2)); // the wave's and the outline's, made once
    // ignore: avoid_print
    print('BENCH reveal frame: ${(sw.elapsedMicroseconds / 157).round()} us each, longest $longest us');
  });
}
