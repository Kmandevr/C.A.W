// Benchmarks the arranger body on a 16-track project with 8 clips a track (notes drawn in the clips): a sideways
// scroll, a vertical scroll and a two-finger time zoom, 30 frames each at a 120 Hz display. Counts frames, widget
// rebuilds and render objects painted per gesture frame. Prints BENCH lines.
import 'package:caw/model/app_state.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'perf_fixture.dart';
import 'perf_util.dart';

void main() {
  testWidgets('arranger: scroll and zoom 16 tracks of clips', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = AppState(settings: Settings());
    s.project = bigProject(s);
    s.ready = true;
    s.starting = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s)))));
    await tester.pump(const Duration(seconds: 1));
    final lanes = tester.getCenter(find.byType(ArrangerScreen)) + const Offset(60, 0);

    // A scroll frame as a fling makes it: the position moves (a drag on the lanes would grab a clip).
    // The longest scroller on that axis: the timeline sideways, the tracks up and down.
    ScrollPosition scroller(Axis axis) => tester.stateList<ScrollableState>(find.byType(Scrollable))
        .where((st) => axisDirectionToAxis(st.axisDirection) == axis)
        .map((st) => st.position)
        .reduce((a, b) => a.maxScrollExtent >= b.maxScrollExtent ? a : b);
    Future<FrameCount> scroll(Axis axis, double by) async {
      final p = scroller(axis);
      final c = await countFrames(tester, 30, onFrame: (_) async => p.jumpTo(p.pixels + by));
      await tester.pump(const Duration(seconds: 2));
      return c;
    }

    final sideways = await scroll(Axis.horizontal, 12);
    final vertical = await scroll(Axis.vertical, 10);
    final a = await tester.startGesture(lanes - const Offset(40, 0), pointer: 7);
    final b = await tester.startGesture(lanes + const Offset(40, 0), pointer: 8);
    await tester.pump(const Duration(milliseconds: 20));
    final zoom = await countFrames(tester, 30, onFrame: (_) async {
      await a.moveBy(const Offset(-3, 0));
      await b.moveBy(const Offset(3, 0));
    });
    await a.up();
    await b.up();
    await tester.pump(const Duration(seconds: 2));
    // ignore: avoid_print
    print('BENCH arranger 30 frames: sideways scroll $sideways; vertical scroll $vertical; pinch zoom $zoom');
    s.dispose();
  });
}
