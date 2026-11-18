// Pins how much of Arrange rebuilds per frame while it scrolls and plays (#241): a scroll frame rebuilds nothing; a
// lanes window that moves on builds only the clips coming into view, not every lane's clips again; the timeline
// growing ahead near its end doesn't rebuild the whole arrangement each frame; playing rebuilds only the playhead.
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/timeline_window.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as w;
import 'package:flutter_test/flutter_test.dart';

import 'perf_fixture.dart';

void main() {
  test('the window\'s origin stays put between anchors, so clips it keeps are not placed again', () {
    const stepW = 10.0, view = 300.0;
    final a = TimelineWindow.around(900, view, stepW), b = TimelineWindow.around(2400, view, stepW);
    expect(a == b, isFalse, reason: 'the window moved on');
    expect(a.originStep, b.originStep, reason: 'but placed from the same origin');
    expect(b.x(500, stepW), (500 - b.originStep) * stepW);
    expect(b.shows(0, 8), isFalse, reason: 'what left the window is not built');
    final far = TimelineWindow.around(TimelineWindow.anchorPx * 3 + 600, view, stepW);
    expect(far.originStep * stepW, closeTo(TimelineWindow.anchorPx * 3, stepW), reason: 'far out, the numbers stay small');
    expect(far.x(far.startStep, stepW), lessThan(TimelineWindow.anchorPx));
  });

  testWidgets('scrolling and playing in Arrange rebuild only what changes', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var clock = 0;
    final s = AppState(settings: Settings(), clockUs: () => clock);
    final p = bigProject(s);
    for (final l in p.layers.take(6)) {
      l.showLanes = true; // automation lanes open (1.0.5)
    }
    final m = p.modules.first;
    p.layers[3]
      ..clips.add(ClipDoc(id: 'tk', patternId: m.id, startSteps: 600, lengthSteps: 16, takes: [m.id, m.id, m.id]))
      ..showTakes = true; // take lanes open (1.0.5)
    s.project = p;
    s.ready = true;
    s.starting = false;
    s.settings.followPlayhead = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s)))));
    await tester.pump(const Duration(seconds: 2));

    final clipSlots = <int>[], laneBuilds = <int>[];
    final perFrame = <int>[];
    var slots = 0, lanes = 0;
    w.debugOnRebuildDirtyWidget = (e, _) {
      final t = e.widget.runtimeType.toString();
      if (t == 'ClipSlot') slots++;
      if (t == '_TimelineLane') lanes++;
      perFrame[perFrame.length - 1]++;
    };
    addTearDown(() => w.debugOnRebuildDirtyWidget = null);
    Future<void> frames(int n, void Function(int i) each) async {
      perFrame.clear();
      clipSlots.clear();
      laneBuilds.clear();
      for (var i = 0; i < n; i++) {
        each(i);
        perFrame.add(0);
        slots = lanes = 0;
        await tester.pump(const Duration(microseconds: 8333));
        clipSlots.add(slots);
        laneBuilds.add(lanes);
      }
    }

    ScrollPosition h() => tester.stateList<ScrollableState>(find.byType(Scrollable))
        .where((st) => axisDirectionToAxis(st.axisDirection) == Axis.horizontal)
        .map((st) => st.position)
        .reduce((a, b) => a.maxScrollExtent >= b.maxScrollExtent ? a : b);

    // A second of sideways scroll (30 px a frame, past several window moves).
    await frames(120, (_) => h().jumpTo(h().pixels + 30));
    final quiet = [for (var i = 1; i < perFrame.length; i++) if (laneBuilds[i] == 0) perFrame[i]];
    expect(quiet.every((n) => n == 0), isTrue, reason: 'a scroll frame inside the window rebuilds nothing: $perFrame');
    expect(laneBuilds.where((n) => n > 0).length, inInclusiveRange(3, 8), reason: 'the window moved on a few times');
    // Before #241 each move rebuilt every lane's clips (132 slots, 633 to 789 widgets in one frame).
    expect(clipSlots.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(16),
        reason: 'only the clips coming into view: $clipSlots');
    expect(perFrame.reduce((a, b) => a > b ? a : b), lessThan(450), reason: '$perFrame');

    // Near the timeline's end it grows ahead: once every few screens, not a whole rebuild every frame (3,226
    // widgets a frame before #241).
    h().jumpTo(h().maxScrollExtent - h().viewportDimension * 1.5);
    await tester.pump(const Duration(seconds: 1));
    await frames(60, (_) => h().jumpTo(h().pixels + 30));
    expect(perFrame.reduce((a, b) => a > b ? a : b), lessThan(450), reason: '$perFrame');

    // Playing: an engine read every 33 ms, the line drawn every frame; only the playhead rebuilds.
    s.meters = const EngineMeters(playing: true, loopLength: 1 << 20, cpu: 0.2);
    s.playheadClock.read(step: 0, atUs: clock, playing: true, stepsPerSecond: 8, to: 4096);
    s.tick.value++;
    s.notifyListeners();
    await tester.pump();
    await frames(120, (i) {
      clock = i * 8333;
      if (i % 4 != 0) return;
      s.meters = EngineMeters(playing: true, loopLength: 1 << 20, position: i * 1000, cpu: 0.2);
      s.playheadClock.read(step: clock * 8 / 1e6, atUs: clock, playing: true, stepsPerSecond: 8, to: 4096);
      s.tick.value++;
    });
    expect(perFrame.skip(1).every((n) => n <= 8), isTrue, reason: 'the playhead alone: $perFrame');

    s.meters = const EngineMeters();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    s.dispose();
  });
}
