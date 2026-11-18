// Pins Arrange's smooth time zoom (owner, 2026-11-18: "stay the same relative size instead of stretching and then
// jumping"): a two-finger pinch lays the lanes out at a new zoom on every frame, so a clip's name keeps its size, no
// scale reaches the clips, the beat under the fingers stays under them, the zoom moves on every frame and nothing
// jumps when the fingers lift, and a zoom frame builds only what depends on the zoom.
import 'package:caw/model/app_state.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as w;
import 'package:flutter_test/flutter_test.dart';

import 'perf_fixture.dart';

void main() {
  late AppState s;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    s = AppState(settings: Settings());
    final p = bigProject(s);
    for (final l in p.layers.take(4)) {
      l.showLanes = true; // automation lanes open: they zoom too
    }
    s.project = p;
    s.ready = true;
    s.starting = false;
    s.settings.followPlayhead = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s)))));
    await tester.pump(const Duration(seconds: 2));
  }

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    s.dispose();
  }

  void sameSize(Size a, Size b, String why) {
    expect(a.width, closeTo(b.width, 1e-6), reason: why);
    expect(a.height, closeTo(b.height, 1e-6), reason: why);
  }

  // The ruler's pixels per step: the zoom the lanes are laid out at.
  double stepW(WidgetTester tester) => (tester.widget<CustomPaint>(find.byWidgetPredicate((x) =>
      x is CustomPaint && x.painter.runtimeType.toString() == '_RulerPainter')).painter as dynamic).stepW as double;

  // The first clip on screen, its body and its name, as drawn on screen (transforms included).
  final body = find.byWidgetPredicate((x) => x.key is ValueKey<String> &&
      (x.key! as ValueKey<String>).value.startsWith('clip-body-')).first;
  Finder name() => find.descendant(of: body, matching: find.byType(Text)).first;

  // How much the clip's name is scaled sideways on screen: 1 when nothing scales it.
  double nameScale(WidgetTester tester) => tester.renderObject(name()).getTransformTo(null).entry(0, 0);

  testWidgets('a pinch lays the lanes out every frame: text keeps its size, the beat stays under the fingers, '
      'nothing jumps at the end', (tester) async {
    await pump(tester);
    final lanesLeft = tester.getTopLeft(find.byKey(const ValueKey('arrange-ruler'))).dx;
    final at = Offset(lanesLeft + 150, tester.getCenter(body).dy);
    final name0 = tester.getRect(name()).size;
    final w0 = stepW(tester);
    final x0 = tester.getRect(body).left;

    // Two passes: both fingers apart around a still midpoint, then one finger still and the other moving (the
    // midpoint moves, and the view goes with it).
    for (final (moveA, moveB) in [(-4.0, 4.0), (0.0, 3.0)]) {
      final startW = stepW(tester), startX = tester.getRect(body).left;
      var fa = at - const Offset(40, 0), fb = at + const Offset(40, 0);
      final span0 = fb.dx - fa.dx, focal0 = (fa.dx + fb.dx) / 2;
      final a = await tester.startGesture(fa, kind: PointerDeviceKind.touch);
      final b = await tester.startGesture(fb, kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 8));
      final zooms = <double>[];
      final builds = <int>[];
      var built = 0, clipsBuilt = 0;
      w.debugOnRebuildDirtyWidget = (e, _) {
        built++;
        if (e.widget.runtimeType.toString() == '_TimelineClip') clipsBuilt++;
      };
      for (var i = 0; i < 12; i++) {
        if (moveA != 0) await a.moveBy(Offset(moveA, 0));
        await b.moveBy(Offset(moveB, 0));
        fa += Offset(moveA, 0);
        fb += Offset(moveB, 0);
        built = 0;
        await tester.pump(const Duration(milliseconds: 8));
        builds.add(built);
        final k = (fb.dx - fa.dx) / span0, focal = (fa.dx + fb.dx) / 2;
        zooms.add(stepW(tester));
        expect(zooms.last, closeTo(startW * k, 1e-6), reason: 'laid out at the pinch\'s zoom on frame $i');
        sameSize(tester.getRect(name()).size, name0, 'the name keeps its size on frame $i');
        expect(nameScale(tester), 1.0, reason: 'nothing scales the clip on frame $i');
        // The clip's left edge stays where the zoom around the fingers puts it: the beat under them holds still.
        expect(tester.getRect(body).left, closeTo(focal + (startX - focal0) * k, 1.0), reason: 'frame $i');
      }
      w.debugOnRebuildDirtyWidget = null;
      for (var i = 1; i < zooms.length; i++) {
        expect(zooms[i], greaterThan(zooms[i - 1]), reason: 'the zoom moves on every frame: $zooms');
      }
      expect(clipsBuilt, 0, reason: 'the clips lay out at the zoom without being built again');
      expect(builds.every((n) => n <= 450), isTrue, reason: 'a zoom frame builds what depends on the zoom: $builds');
      final last = zooms.last, lastX = tester.getRect(body).left;
      await a.up();
      await tester.pump(const Duration(milliseconds: 8));
      await b.up();
      await tester.pump(const Duration(milliseconds: 8));
      await tester.pump(const Duration(milliseconds: 8));
      expect(stepW(tester), last, reason: 'no jump to another zoom when the fingers lift');
      expect(tester.getRect(body).left, closeTo(lastX, 0.5), reason: 'and the view stays where it is');
      sameSize(tester.getRect(name()).size, name0, 'after the pinch');
      await tester.pump(const Duration(seconds: 1));
    }
    expect(stepW(tester), greaterThan(w0 * 1.5));
    expect(tester.getRect(body).left, lessThan(x0), reason: 'zoomed in around the fingers, right of the clip\'s start');
    expect(find.byWidgetPredicate((x) => x is Transform && (x.transform.entry(0, 0) - 1).abs() > 1e-9 &&
        find.descendant(of: find.byWidget(x), matching: body).evaluate().isNotEmpty), findsNothing,
        reason: 'no scale above the lanes');
    await done(tester);
  });

  testWidgets('the zoom buttons glide through the same layout: every frame at its zoom, the middle held still',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('arrange-zoom')));
    await tester.pump(const Duration(seconds: 1));
    final name0 = tester.getRect(name()).size;
    final w0 = stepW(tester);
    final view = tester.stateList<ScrollableState>(find.byType(Scrollable))
        .where((st) => axisDirectionToAxis(st.axisDirection) == Axis.horizontal)
        .reduce((a, b) => a.position.maxScrollExtent >= b.position.maxScrollExtent ? a : b).position;
    final mid = view.viewportDimension / 2;
    final beat = (view.pixels + mid) / w0;
    // The bar's + (its press; the bar sits under the toolbar here, without the app's sections).
    tester.widget<IconButton>(find.ancestor(of: find.byTooltip('Zoom in'), matching: find.byType(IconButton))).onPressed!();
    final zooms = <double>[];
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 8));
      zooms.add(stepW(tester));
      expect(beat * zooms.last - view.pixels, closeTo(mid, 1.0), reason: 'the middle holds still on frame $i');
      sameSize(tester.getRect(name()).size, name0, 'after the pinch');
    }
    for (var i = 1; i < zooms.length; i++) {
      expect(zooms[i], greaterThanOrEqualTo(zooms[i - 1]));
    }
    expect(zooms.toSet().length, greaterThan(5), reason: 'it glides: $zooms');
    expect(zooms.last, closeTo(w0 * 1.4, 1e-6));
    await done(tester);
  });
}
