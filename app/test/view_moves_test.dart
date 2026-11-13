// Moves a view makes on its own (owner, 2026-11-11): one glide for the left edge and the zoom ([ViewGlide]), timed by
// distance and retargeted; Arrange's zoom buttons, zoom to fit, a picked clip or track off screen; the piano roll's
// playhead, its following and requestRevealStart; header right-clicks and the second tap where the first one was.
import 'dart:convert';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/focus_panel.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:caw/ui/view_glide.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _pattern = '---\nkind: pattern\nlength: 8\n---\n0 C4 1 1\n4 E4 1 1\n';

ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Moves', modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: _pattern),
    ], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [
        ClipDoc(id: 'c1', patternId: 'pat', startSteps: 0, lengthSteps: 512),
        ClipDoc(id: 'far', patternId: 'pat', startSteps: 3000, lengthSteps: 16),
      ]),
      for (var i = 0; i < 20; i++) LayerDoc(id: 't$i', name: 'T$i', color: i % 8),
    ])..loopBars = 400;

class _Glider extends StatefulWidget {
  const _Glider({required this.onState});
  final ValueChanged<_GliderState> onState;
  @override
  State<_Glider> createState() => _GliderState();
}

class _GliderState extends State<_Glider> with TickerProviderStateMixin {
  ViewPlace place = (left: 0, zoom: 10);
  late final ViewGlide glide = ViewGlide(this, read: () => place, apply: (v) => place = v);
  @override
  void initState() {
    super.initState();
    widget.onState(this);
  }

  @override
  void dispose() {
    glide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  late AppState s;
  late SectionController sections;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = _project();
    s.ready = true;
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
    sections = SectionController();
  });
  tearDown(() {
    s.dispose();
    sections.dispose();
  });

  void play(double step) {
    final loop = s.project.engineLoopSteps;
    s.meters = EngineMeters(playing: true, position: (step / loop * 100000).round(), loopLength: 100000);
    s.tick.value++;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
  }

  group('the glide', () {
    test('150 ms for a nudge, 350 ms for a screen or more; a zoom counts by its doublings', () {
      expect(ViewGlide.durationFor(0, 800), ViewGlide.shortest);
      expect(ViewGlide.durationFor(5000, 800), ViewGlide.longest);
      final half = ViewGlide.durationFor(400, 800).inMilliseconds;
      expect(half, inInclusiveRange(240, 260));
      expect(ViewGlide.distanceOf((left: 0, zoom: 10), (left: 0, zoom: 20), 800), 400, reason: 'a doubling: half a screen');
      expect(ViewGlide.distanceOf((left: 0, zoom: 10), (left: 10, zoom: 10), 800), 100);
    });

    testWidgets('a new target retargets from where it is; with motion off it jumps', (tester) async {
      late _GliderState g;
      await tester.pumpWidget(_Glider(onState: (x) => g = x));
      g.glide.to(left: 100, view: 800, level: MotionLevel.full);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final mid = g.place.left;
      expect(mid, inExclusiveRange(1, 99));
      g.glide.to(left: 0, view: 800, level: MotionLevel.full);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(g.place.left, lessThanOrEqualTo(mid), reason: 'it turns back from where it was, no jump');
      expect(g.place.left, greaterThan(mid * 0.5));
      await tester.pumpAndSettle();
      expect(g.place.left, 0);
      // Zoom with a point kept still: the content under 400 px stays there all through.
      g.glide.to(zoom: 40, keep: 400, view: 800, level: MotionLevel.full);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        expect(g.place.left + 400 / g.place.zoom, closeTo(40, 1e-6));
      }
      await tester.pumpAndSettle();
      expect(g.place.zoom, 40);
      g.glide.to(left: 500, zoom: 5, view: 800, level: MotionLevel.off);
      expect(g.place, (left: 500.0, zoom: 5.0));
      expect(g.glide.active, isFalse);
    });
  });

  group('Arrange', () {
    Future<void> pump(WidgetTester tester, {Size size = const Size(900, 600)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: SectionScope(controller: sections,
          child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))))));
      await tester.pump();
    }

    // The lanes' and the tracks' scroll views: the longest of each way (the toolbar scrolls too).
    ScrollPosition longest(WidgetTester tester, AxisDirection d) => tester
        .stateList<ScrollableState>(find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == d))
        .map((st) => st.position)
        .reduce((a, b) => a.maxScrollExtent >= b.maxScrollExtent ? a : b);
    ScrollPosition hScroll(WidgetTester tester) => longest(tester, AxisDirection.right);
    ScrollPosition vScroll(WidgetTester tester) => longest(tester, AxisDirection.down);
    double clipW(WidgetTester tester) => tester.getSize(find.byKey(const ValueKey('clip-slot-c1'))).width;

    testWidgets('the zoom buttons glide, part way at half time; zoom to fit glides the pan and zoom together',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('arrange-zoom')));
      await settle(tester);
      final w0 = clipW(tester);
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final mid = clipW(tester);
      await settle(tester);
      final w1 = clipW(tester);
      expect(w1, closeTo(w0 * 1.4, 1));
      expect(mid, inExclusiveRange(w0 + 1, w1 - 1), reason: 'part way');
      // Two presses in a row go on from where the first was heading.
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(find.byTooltip('Zoom in'));
      await settle(tester);
      expect(clipW(tester), closeTo(w1 * 1.96, 2));
      hScroll(tester).jumpTo(2000);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('arrange-zoom-fit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(hScroll(tester).pixels, inExclusiveRange(0, 2000), reason: 'on its way');
      await settle(tester);
      expect(hScroll(tester).pixels, 0);
      final p = hScroll(tester);
      expect(p.maxScrollExtent + p.viewportDimension, lessThan(p.viewportDimension * 8),
          reason: 'the whole song shows, the timeline a few screens on');
    });

    testWidgets('a clip picked off screen glides into view; a track picked below the view glides up', (tester) async {
      await pump(tester);
      expect(hScroll(tester).pixels, 0);
      s.selectClip(s.project.layers.first, s.project.layers.first.clips.last);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final mid = hScroll(tester).pixels;
      await settle(tester);
      final p = hScroll(tester);
      expect(mid, inExclusiveRange(0, p.pixels), reason: 'it glides');
      final x = 3000 * 18.0;
      expect(x, inInclusiveRange(p.pixels, p.pixels + p.viewportDimension));
      // A tapped clip already in view stays where it is.
      final at = p.pixels;
      s.selectClip(s.project.layers.first, s.project.layers.first.clips.last);
      await settle(tester);
      expect(hScroll(tester).pixels, at);
      // The last track, below the view (the keyboard's Down).
      expect(vScroll(tester).pixels, 0);
      s.selectLayer(s.project.layers.last);
      await settle(tester);
      expect(vScroll(tester).pixels, greaterThan(0));
      final head = tester.getRect(find.byKey(const ValueKey('track-header-t19')));
      expect(head.bottom, lessThanOrEqualTo(600));
    });

    testWidgets('requestRevealStart with motion off jumps', (tester) async {
      final was = Motion.setting;
      Motion.setting = MotionLevel.off;
      addTearDown(() => Motion.setting = was);
      await pump(tester);
      hScroll(tester).jumpTo(3000);
      await tester.pump();
      s.requestRevealStart();
      await tester.pump();
      expect(hScroll(tester).pixels, 0);
    });
  });

  group('the header', () {
    Finder header(String id) => find.byKey(ValueKey('track-header-$id'));
    Future<void> pump(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      s.project = ProjectDoc(id: 'p', name: 'Moves', modules: _project().modules, layers: [
        LayerDoc(id: 'a', name: 'Keys', color: 0),
        LayerDoc(id: 'b', name: 'Bass', color: 1),
        LayerDoc(id: 'c', name: 'Lead', color: 2),
      ]);
      await tester.pumpWidget(MaterialApp(home: SectionScope(controller: sections,
          child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))))));
      await tester.pump();
    }

    testWidgets('a right-click opens the track menu', (tester) async {
      await pump(tester, const Size(1200, 800));
      await tester.tap(header('b'), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('long-press-menu')), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
    });

    testWidgets('on a phone a tap selects and a quick second tap where the first one was opens effects',
        (tester) async {
      await pump(tester, const Size(412, 900));
      final at = tester.getCenter(header('c'));
      await tester.tapAt(at);
      await tester.pump();
      expect(s.selectedLayerId, 'c', reason: 'selected at once');
      expect(sections.focusedLayer, isNull, reason: 'a tap only selects (owner, 2026-11-12)');
      await tester.pumpAndSettle();
      await tester.pump(kDoubleTapTimeout);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(sections.focusedLayer, 'c');
      expect(tester.widget<FocusPanel>(find.byType(FocusPanel)).tab, FocusTab.fx);
      await settle(tester);
    });
  });

  group('the piano roll', () {
    LayerDoc layer() => s.project.layers.first;
    ClipDoc clip() => layer().clips.first;

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
          builder: (_, _) => PatternEditor(state: s, module: s.project.module('pat')!, layer: layer(), clip: clip())))));
      await tester.pump();
    }

    RollPlayheadPainter head(WidgetTester tester) =>
        tester.widget<CustomPaint>(find.byKey(const ValueKey('roll-playhead'))).painter! as RollPlayheadPainter;

    testWidgets('it draws the playhead in the clip\'s time and pages after it; a finger pauses it', (tester) async {
      await pump(tester);
      // Stopped: the dimmer edit cursor where play starts, in the clip's time (owner, 2026-11-12, as Arrange).
      expect(head(tester).stopped, isTrue);
      expect(head(tester).step, closeTo(-clip().startSteps + clip().sourceOffsetSteps, 1e-9));
      play(1);
      await tester.pump();
      play(4);
      await tester.pump();
      expect(head(tester).step, closeTo(4, 0.1));
      expect(head(tester).stopped, isFalse);
      expect(head(tester).scrollX, 0);
      // Past the right edge: a page step glides.
      play(60);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final mid = head(tester).scrollX;
      await tester.pumpAndSettle();
      final x = head(tester).x;
      expect(mid, inExclusiveRange(0, head(tester).scrollX));
      expect(x, isNotNull, reason: 'back in view');
      // A finger down: the view stays while it is there and the quiet spell after it.
      final at = head(tester).scrollX;
      final g = await tester.startGesture(const Offset(600, 400), kind: PointerDeviceKind.touch);
      play(110);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(head(tester).scrollX, at);
      await g.up();
      await tester.pump(const Duration(milliseconds: 500));
      play(111);
      await tester.pump(const Duration(milliseconds: 400));
      expect(head(tester).scrollX, at, reason: 'still in the quiet spell');
      await tester.pump(const Duration(seconds: 3));
      play(112);
      await tester.pumpAndSettle();
      expect(head(tester).scrollX, greaterThan(at), reason: 'it resumes');
      // ⏮ glides the roll back to its start too.
      s.requestRevealStart();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(head(tester).scrollX, greaterThan(0));
      s.meters = const EngineMeters();
      await tester.pumpAndSettle();
      expect(head(tester).scrollX, 0);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Smooth holds the playhead a third in; off, it never moves the view', (tester) async {
      s.settings.followSmooth = true;
      await pump(tester);
      play(1);
      await tester.pump();
      play(80);
      await tester.pump();
      final h = head(tester);
      final grid = 900 - 44.0;
      expect(h.x! - 44, closeTo(grid / 3, 1));
      s.settings.followPlayhead = false;
      final at = h.scrollX;
      play(120);
      await tester.pump();
      expect(head(tester).scrollX, at);
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
