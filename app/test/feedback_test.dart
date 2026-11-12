// Tests the shared touch feedback: pressed controls dip and glow (motion permitting), grips grow when grabbed, and
// grabs, steps and drops are felt (Haptics with a recording device).
import 'package:caw/model/app_state.dart';
import 'package:caw/ui/arrange/knob.dart';
import 'package:caw/ui/feedback.dart';
import 'package:caw/ui/frame/frame_widgets.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/haptics.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder implements HapticsDevice {
  final played = <HapticKind>[];
  @override
  void play(HapticKind kind, double scale) => played.add(kind);
}

/// The press feedback around [control] (an IconButton inside it) or inside it (an InkWell around it).
Finder _pressable(Finder control) {
  final up = find.ancestor(of: control, matching: find.byKey(const ValueKey('pressable')));
  return up.evaluate().isNotEmpty ? up.first : find.descendant(of: control, matching: find.byKey(const ValueKey('pressable'))).first;
}

double _scaleOf(WidgetTester tester, Finder control) => tester.widget<AnimatedScale>(_pressable(control)).scale;

void main() {
  late _Recorder rec;
  var t = const Duration(seconds: 1);
  setUp(() {
    rec = _Recorder();
    Haptics.device = rec;
    Haptics.now = () => t;
    Haptics.reset();
    Motion.setting = MotionLevel.full;
  });
  tearDown(() {
    Haptics.device = const FlutterHaptics();
    Haptics.now = Haptics.realNow;
    Haptics.reset();
    Motion.setting = MotionLevel.full;
  });

  Future<AppState> pumpTransport(WidgetTester tester) async {
    final s = AppState();
    s.project = s.demoProject();
    final sections = SectionController();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      const Spacer(),
      SizedBox(width: 390, child: BottomTransport(state: s)),
      ListenableBuilder(listenable: sections, builder: (_, _) => SectionBar(sections: sections)),
    ]))));
    return s;
  }

  testWidgets('the transport and section buttons dip while pressed and come back on release', (tester) async {
    await pumpTransport(tester);
    for (final key in ['transport-play', 'transport-undo', 'transport-stop', 'transport-record', 'section-files']) {
      final control = find.byKey(ValueKey(key));
      expect(_scaleOf(tester, control), 1, reason: key);
      final g = await tester.startGesture(tester.getCenter(control));
      await tester.pump();
      expect(_scaleOf(tester, control), pressedScale, reason: '$key pressed');
      await g.up();
      await tester.pumpAndSettle();
      expect(_scaleOf(tester, control), 1, reason: '$key released');
    }
  });

  testWidgets('a press that turns into a scroll lets go; Reduced motion glows without moving', (tester) async {
    await pumpTransport(tester);
    final play = find.byKey(const ValueKey('transport-play'));
    final g = await tester.startGesture(tester.getCenter(play));
    await tester.pump();
    await g.moveBy(const Offset(0, -30));
    await tester.pump();
    expect(_scaleOf(tester, play), 1);
    await g.up();
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    await pumpTransport(tester);
    Motion.setting = MotionLevel.reduced; // after the app state, whose settings set it
    rec.played.clear();
    final g2 = await tester.startGesture(tester.getCenter(play));
    await tester.pump();
    expect(_scaleOf(tester, play), 1, reason: 'no movement with Reduced motion');
    final glow = tester.widget<DecoratedBox>(find.descendant(of: _pressable(play), matching: find.byType(DecoratedBox)).first);
    expect((glow.decoration as BoxDecoration).boxShadow, isNotEmpty, reason: 'the glow stays');
    await g2.up();
    await tester.pumpAndSettle();
  });

  testWidgets('play is felt as a tap; a scrub grabs, ticks each bar and drops', (tester) async {
    await pumpTransport(tester);
    await tester.tap(find.byKey(const ValueKey('transport-play')));
    await tester.pump();
    expect(rec.played, [HapticKind.tap]);
    rec.played.clear();
    t += const Duration(seconds: 1);
    final g = await tester.startGesture(tester.getCenter(find.byType(BottomTransport)) + const Offset(-60, 0));
    for (var i = 0; i < 6; i++) {
      t += const Duration(milliseconds: 100);
      await g.moveBy(const Offset(25, 0));
      await tester.pump();
    }
    t += const Duration(milliseconds: 100);
    await g.up();
    await tester.pump();
    expect(rec.played.first, HapticKind.grab);
    expect(rec.played.where((k) => k == HapticKind.tick).length, greaterThanOrEqualTo(2));
    expect(rec.played.last, HapticKind.drop);
  });

  testWidgets('a knob grows while held, is felt when grabbed and at each step', (tester) async {
    var v = 0.0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: StatefulBuilder(
      builder: (context, set) => Knob(value: v, min: 0, max: 10, step: 1, label: 'Steps',
          onChanged: (n) => set(() => v = n)),
    )))));
    AnimatedScale held() => tester.widget<AnimatedScale>(find.byKey(const ValueKey('knob-held')));
    expect(held().scale, 1);
    final g = await tester.startGesture(tester.getCenter(find.byType(Knob)));
    await g.moveBy(const Offset(0, -20));
    await tester.pump();
    expect(held().scale, greaterThan(1));
    for (var i = 0; i < 4; i++) {
      t += const Duration(milliseconds: 100);
      await g.moveBy(const Offset(0, -20));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(held().scale, 1);
    expect(rec.played.first, HapticKind.grab);
    expect(rec.played.where((k) => k == HapticKind.tick).length, greaterThanOrEqualTo(3), reason: 'a tick per step');
  });

  testWidgets('a drag edge grows and lights when grabbed and is felt on grab and drop', (tester) async {
    var moved = 0.0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(height: 200, child: DragEdge(
      axis: Axis.horizontal, onStart: () {}, onDrag: (m) => moved = m, onEnd: () {}))))));
    Size mark() => tester.getSize(find.byType(GripMark));
    final rest = mark();
    final g = await tester.startGesture(tester.getCenter(find.byType(DragEdge)));
    await g.moveBy(const Offset(30, 0));
    await tester.pumpAndSettle();
    expect(mark().height, greaterThan(rest.height * 1.5));
    t += const Duration(seconds: 1);
    await g.up();
    await tester.pumpAndSettle();
    expect(mark(), rest);
    expect(moved, greaterThan(20));
    expect(rec.played, [HapticKind.grab, HapticKind.drop]);
  });
}
