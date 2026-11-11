// Arrange: the focus view (open, next track, close by swipe, tap and Back), the FX stack and long-press menus.
import 'dart:io';

import 'package:caw/engine/component_info.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/native_components.dart';
import 'package:caw/model/native_trust.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/arrange/track_color.dart';
import 'package:caw/ui/theme.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _width = NativeComponentInfo(id: 'org.caw.stereo.width', name: 'Width', role: 'effect', builtin: true,
    parameters: [ComponentParameterInfo(id: 'width', name: 'Width', defaultValue: 1, min: 0, max: 2)]);
const _chorus = NativeComponentInfo(id: 'org.caw.chorus', name: 'Chorus', role: 'effect', builtin: true,
    parameters: [ComponentParameterInfo(id: 'mix', name: 'Mix', defaultValue: 0.5, min: 0, max: 1)]);

ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Arrange test', layers: [
      LayerDoc(id: 'a', name: 'Drums', color: 0),
      LayerDoc(id: 'b', name: 'Bass', color: 1),
      LayerDoc(id: 'c', name: 'Lead', color: 2),
    ]);

void main() {
  _steppedKnobs();
  late AppState s;
  late SectionController sections;
  late List<String> haptics;

  setUp(() {
    s = AppState(settings: Settings());
    s.project = _project();
    sections = SectionController();
    haptics = [];
  });

  tearDown(() {
    s.dispose();
    sections.dispose();
  });

  void listenForHaptics(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  Future<void> pumpArranger(WidgetTester tester, Size size, {bool withSections = true}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final screen = Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s)));
    await tester.pumpWidget(MaterialApp(
        home: withSections ? SectionScope(controller: sections, child: screen) : screen));
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // let autosave and history timers run out
  }

  group('focus view', () {
    testWidgets('a tap pins the track on top with its panel; swipes, tap and Back go next or close', (tester) async {
      listenForHaptics(tester);
      await pumpArranger(tester, const Size(412, 900));
      await tester.tap(find.byKey(const ValueKey('track-header-a')));
      await tester.pumpAndSettle();
      expect(sections.focusedLayer, 'a');
      expect(s.selectedLayerId, 'a');
      expect(find.byKey(const ValueKey('focus-panel')), findsOneWidget);
      expect(find.text('FX STACK'), findsOneWidget);
      // Only the focused track is shown, pinned in the top fifth; the panel fills the rest.
      expect(find.byKey(const ValueKey('track-header-b')), findsNothing);
      final panel = tester.getRect(find.byKey(const ValueKey('focus-panel')));
      expect(panel.top, lessThan(900 * 0.35));
      expect(panel.height, greaterThan(900 * 0.6));
      expect(tester.takeException(), isNull);

      // A sideways swipe on the pinned track: the next track (with a tick), then back.
      await tester.fling(find.byKey(const ValueKey('track-header-a')), const Offset(-200, 0), 1000);
      await tester.pumpAndSettle();
      expect(sections.focusedLayer, 'b');
      expect(haptics, contains('HapticFeedbackType.selectionClick'));
      await tester.tap(find.byTooltip('Next track'));
      await tester.pumpAndSettle();
      expect(sections.focusedLayer, 'c');
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_right)).onPressed, isNull,
          reason: 'the last track has no next');
      await tester.fling(find.byKey(const ValueKey('track-header-c')), const Offset(200, 0), 1000);
      await tester.pumpAndSettle();
      expect(sections.focusedLayer, 'b');

      // Swiping the panel down closes it.
      await tester.fling(find.byKey(const ValueKey('focus-panel-header')), const Offset(0, 300), 1000);
      await tester.pumpAndSettle();
      expect(sections.focusedLayer, isNull);
      expect(find.byKey(const ValueKey('focus-panel')), findsNothing);
      expect(find.byKey(const ValueKey('track-header-c')), findsOneWidget);

      // Tapping the pinned track closes it too.
      await tester.tap(find.byKey(const ValueKey('track-header-b')));
      await tester.pumpAndSettle();
      expect(sections.focusedLayer, 'b');
      await tester.tap(find.byKey(const ValueKey('track-header-b')));
      await tester.pumpAndSettle();
      expect(sections.focusedLayer, isNull);

      // Android Back leaves the focus view instead of the app.
      await tester.tap(find.byKey(const ValueKey('track-header-a')));
      await tester.pumpAndSettle();
      expect(sections.focusedLayer, 'a');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(sections.focusedLayer, isNull);
      await settle(tester);
    });

    testWidgets('the FX button opens the FX tab; the tabs switch', (tester) async {
      await pumpArranger(tester, const Size(412, 900));
      await tester.tap(find.byKey(const ValueKey('fx-button-b')));
      await tester.pumpAndSettle();
      expect(sections.focusedLayer, 'b');
      expect(find.text('FX STACK'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('focus-tab-automation')));
      await tester.pumpAndSettle();
      expect(find.textContaining('No lanes yet'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('focus-tab-mixer')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mix-pan')), findsOneWidget);
      expect(find.byKey(const ValueKey('fader-b')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('focus-tab-clip')));
      await tester.pumpAndSettle();
      expect(find.text('No clip on this track yet.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await settle(tester);
    });

    testWidgets('landscape puts the panel on the right, two thirds wide; its edge resizes it and the size is saved',
        (tester) async {
      listenForHaptics(tester);
      await pumpArranger(tester, const Size(860, 400));
      await tester.tap(find.byKey(const ValueKey('track-header-a')));
      await tester.pumpAndSettle();
      Rect panel() => tester.getRect(find.byKey(const ValueKey('focus-panel')));
      expect(panel().left, greaterThan(860 * 0.25));
      expect(panel().width, closeTo(860 * 2 / 3, 20));
      expect(find.byKey(const ValueKey('track-header-c')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Grabbed, the edge grows and a ghost shows where the panel will land; it moves only on release.
      final edge = find.byKey(const ValueKey('focus-panel-edge'));
      final before = panel().width;
      final g = await tester.startGesture(tester.getCenter(edge));
      await g.moveBy(const Offset(20, 0));
      await g.moveBy(const Offset(120, 0));
      await tester.pump();
      expect(find.byKey(const ValueKey('focus-panel-ghost')), findsOneWidget);
      expect(panel().width, before, reason: 'the ghost previews; the panel waits for the drop');
      await g.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('focus-panel-ghost')), findsNothing);
      expect(panel().width, closeTo(before - 140, 6));
      expect(s.settings.focusPanelShare, closeTo((before + 4 - 140) / 860, 0.02), reason: 'remembered in settings');
      expect(haptics, contains('HapticFeedbackType.lightImpact'), reason: 'a grab');

      // Near a half it snaps there, with a tick; a double-tap goes back to two thirds.
      final g2 = await tester.startGesture(tester.getCenter(edge));
      final toHalf = panel().right - 860 * 0.5 - 4 - tester.getCenter(edge).dx + 7;
      await g2.moveBy(Offset(toHalf.sign * 20, 0));
      await g2.moveBy(Offset(toHalf - toHalf.sign * 20 + 5, 0));
      await tester.pump();
      expect(find.text('½'), findsOneWidget);
      await g2.up();
      await tester.pumpAndSettle();
      expect(s.settings.focusPanelShare, 0.5);
      await tester.tap(edge);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(edge);
      await tester.pumpAndSettle();
      expect(s.settings.focusPanelShare, closeTo(2 / 3, 1e-9));
      await settle(tester);
    });

    testWidgets('a desktop shows the panel beside the arrangement; without the frame the focus stays local',
        (tester) async {
      await pumpArranger(tester, const Size(1400, 900), withSections: false);
      await tester.tap(find.byKey(const ValueKey('track-header-c')));
      await tester.pumpAndSettle();
      final panel = tester.getRect(find.byKey(const ValueKey('focus-panel')));
      expect(panel.left, greaterThan(800));
      expect(find.byKey(const ValueKey('track-header-a')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('focus-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('focus-panel')), findsNothing);
      await settle(tester);
    });
  });

  group('FX stack', () {
    Future<void> pumpStack(WidgetTester tester, LayerDoc layer) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: SectionScope(controller: sections, child: Scaffold(
        body: ListenableBuilder(listenable: s, builder: (_, _) => FxStack(state: s, layer: layer))))));
      await tester.pump();
    }

    testWidgets('a built-in native effect shows its plugin UI inline; a knob, bypass, reorder and remove edit the project',
        (tester) async {
      listenForHaptics(tester);
      s.componentCatalog.set(const [_width, _chorus]);
      final layer = s.project.layers.first;
      s.addNativeEffect(layer, 'org.caw.stereo.width');
      await pumpStack(tester, layer);
      expect(find.text('CODE EFFECTS · .caw'), findsOneWidget);
      expect(find.text('NATIVE EFFECTS · C++'), findsOneWidget);
      expect(find.text('Width'), findsWidgets);
      expect(find.byKey(const ValueKey('fx-inline-0')), findsOneWidget, reason: 'its plugin UI, inline');
      expect(find.text('UTILITY'), findsOneWidget);

      // A knob turned up is stored in the project; passing the centre ticks.
      final knob = find.descendant(of: find.byKey(const ValueKey('fx-inline-0')), matching: find.byKey(const ValueKey('dknob-width')));
      await tester.drag(knob, const Offset(0, -60));
      await tester.pumpAndSettle();
      expect(layer.components.first.params['width'], greaterThan(1.0));
      await tester.drag(knob, const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(layer.components.first.params['width'], lessThan(1.0));
      expect(haptics, contains('HapticFeedbackType.selectionClick'), reason: 'a knob reaching centre ticks');
      // A double tap puts it back to its default.
      await tester.tap(knob);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(knob);
      await tester.pumpAndSettle();
      expect(layer.components.first.params['width'], 1.0);

      await tester.tap(find.byKey(const ValueKey('fx-bypass-0')));
      await tester.pumpAndSettle();
      expect(layer.components.first.bypass, isTrue);
      expect(layer.toJson()['components'], [{'id': 'org.caw.stereo.width', 'params': {'width': 1.0}, 'bypass': true}]);

      // A second effect goes after it; "Move up" in its long-press menu puts it first.
      s.addNativeEffect(layer, 'org.caw.chorus');
      await tester.pumpAndSettle();
      expect(layer.components.map((c) => c.id), ['org.caw.stereo.width', 'org.caw.chorus']);
      await tester.longPress(find.byKey(const ValueKey('fx-native-title-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('long-press-menu')), findsOneWidget);
      await tester.tap(find.text('Move up'));
      await tester.pumpAndSettle();
      expect(layer.components.map((c) => c.id), ['org.caw.chorus', 'org.caw.stereo.width']);

      // Dragging the handle reorders too.
      final handle = find.byIcon(Icons.drag_indicator).first;
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump(const Duration(milliseconds: 100));
      // Past the next device's whole plugin UI, in finger-sized steps (one jump over it can land short of its middle).
      final past = tester.getSize(find.byKey(const ValueKey('fx-inline-1'))).height;
      for (var moved = 0.0; moved < past; moved += 20) {
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(layer.components.map((c) => c.id), ['org.caw.stereo.width', 'org.caw.chorus']);

      await tester.tap(find.byTooltip('Remove Chorus'));
      await tester.pumpAndSettle();
      expect(layer.components.map((c) => c.id), ['org.caw.stereo.width']);

      // The Routing toggle shows the same chain left to right.
      await tester.tap(find.byKey(const ValueKey('fx-routing-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fx-routing')), findsOneWidget);
      expect(find.text('Bypassed'), findsOneWidget);
      expect(find.text('Master'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await settle(tester);
    });

    testWidgets('a project C++ effect from elsewhere waits greyed for Trust or Block; its title opens its code',
        (tester) async {
      final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('caw-fx'));
      addTearDown(() => dir!.deleteSync(recursive: true));
      final trust = NativeTrustStore(File('${dir!.path}/trust.json'));
      s.nativeComponents = NativeComponentManager(
        trust: trust,
        cacheFile: File('${dir.path}/builds.json'),
        build: (_, _) async => throw StateError('no build in this test'),
        load: ({required artifactPath, required expectedComponentId, required trust, reload = false}) async =>
            throw StateError('no load in this test'),
      );
      final fuzz = CppComponentDoc(id: 'cc', name: 'My fuzz', componentId: 'com.example.fuzz',
          files: {'fuzz.cpp': '// fuzz'});
      s.project.cppComponents.add(fuzz);
      final layer = s.project.layers.first;
      s.addNativeEffect(layer, 'org.caw.stereo.width');
      s.addNativeEffect(layer, 'com.example.fuzz');
      s.addNativeEffect(layer, 'org.caw.chorus');
      s.nativeStatus = NativeComponentsStatus()..needsTrust.add(fuzz);
      // The engine plays the built-ins; the fuzz waits, so the chorus is the engine's second component.
      expect(s.engineComponentIndex(layer, 2), 1);
      expect(s.engineComponentIndex(layer, 1), isNull);
      expect(s.nativeEffectState('com.example.fuzz'), NativeEffectState.needsTrust);

      await pumpStack(tester, layer);
      expect(find.text('Native code from ‘Arrange test’'), findsOneWidget);
      expect(find.text('Trust'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Block'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(s.nativeEffectState('com.example.fuzz'), NativeEffectState.blocked);
      expect(find.textContaining('Blocked on this device'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('fx-native-title-1')));
      await tester.pumpAndSettle();
      expect(sections.current, Section.build);
      expect(sections.activeBuildTab, const BuildTab(BuildTabKind.cpp, 'com.example.fuzz'));
      await settle(tester);
    });

    testWidgets('drops and picks: effects join the chain, a pattern becomes a clip at the drop step', (tester) async {
      final layer = s.project.layers.first;
      s.project.modules.addAll([
        ModuleDoc(id: 'fx1', name: 'Echo', source: '---\nkind: effect\n---\n'),
        ModuleDoc(id: 'pat', name: 'Beat', source: '---\nkind: pattern\n---\n'),
      ]);
      expect(s.dropAsset(layer, const AssetDrag(AssetKind.cawModule, 'fx1', 'Echo')), isTrue);
      expect(layer.effectIds, ['fx1']);
      expect(s.dropAsset(layer, const AssetDrag(AssetKind.nativeEffect, 'org.caw.chorus', 'Chorus')), isTrue);
      expect(layer.components.single.id, 'org.caw.chorus');

      // Dragged from elsewhere onto a lane: a clip where it lands.
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
        const Draggable<AssetDrag>(data: AssetDrag(AssetKind.pattern, 'pat', 'Beat'),
          feedback: SizedBox(width: 10, height: 10), child: Text('drag me')),
        Expanded(child: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))),
      ]))));
      await tester.pump();
      final lane = tester.getTopLeft(find.byKey(const ValueKey('track-header-b'))) + const Offset(184 + 200, 30);
      final gesture = await tester.startGesture(tester.getCenter(find.text('drag me')));
      await gesture.moveTo(lane);
      await tester.pump();
      await gesture.moveTo(lane + const Offset(1, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      final bass = s.project.layers[1];
      expect(bass.clips, hasLength(1));
      expect(bass.clips.single.patternId, 'pat');
      expect(bass.clips.single.startSteps, greaterThan(0));
      await settle(tester);
    });
  });

  testWidgets('phone portrait: the focus panel opens higher over the pinned track, and back', (tester) async {
    await pumpArranger(tester, const Size(412, 900));
    await tester.tap(find.byKey(const ValueKey('track-header-a')));
    await settle(tester);
    final panel = find.byKey(const ValueKey('focus-panel'));
    final low = tester.getTopLeft(panel).dy;
    await tester.tap(find.byKey(const ValueKey('focus-expand')));
    await settle(tester);
    expect(tester.getTopLeft(panel).dy, lessThan(low - 80));
    await tester.fling(find.byKey(const ValueKey('focus-panel-header')), const Offset(0, 200), 1000);
    await settle(tester);
    expect(tester.getTopLeft(panel).dy, closeTo(low, 1), reason: 'a swipe down lowers it first');
    expect(sections.focusedLayer, 'a');
    await tester.fling(find.byKey(const ValueKey('focus-panel-header')), const Offset(0, -200), 1000);
    await settle(tester);
    expect(tester.getTopLeft(panel).dy, lessThan(low - 80), reason: 'a swipe up opens it higher');
  });

  testWidgets('phone portrait: dragging the focus panel\'s header follows the finger and says what letting go does',
      (tester) async {
    await pumpArranger(tester, const Size(412, 900));
    await tester.tap(find.byKey(const ValueKey('track-header-a')));
    await settle(tester);
    final panel = find.byKey(const ValueKey('focus-panel'));
    final rest = tester.getTopLeft(panel).dy;
    final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('focus-panel-header'))));
    await g.moveBy(const Offset(0, 20));
    await g.moveBy(const Offset(0, 20));
    await tester.pump();
    expect(tester.getTopLeft(panel).dy, greaterThan(rest + 5), reason: 'the panel follows the finger');
    expect(find.byKey(const ValueKey('focus-panel-hint')), findsNothing, reason: 'not past the threshold yet');
    await g.moveBy(const Offset(0, 60));
    await tester.pump();
    expect(find.text('Let go to close'), findsOneWidget);
    await g.moveBy(const Offset(0, -90));
    await tester.pump();
    expect(find.byKey(const ValueKey('focus-panel-hint')), findsNothing);
    await g.up();
    await settle(tester);
    expect(sections.focusedLayer, 'a', reason: 'let go before the threshold: the panel springs back');
    expect(tester.getTopLeft(panel).dy, closeTo(rest, 1));
  });

  group('track headers', () {
    testWidgets('drag the headers\' right edge and a row\'s bottom edge to resize them; the sizes are saved',
        (tester) async {
      await pumpArranger(tester, const Size(412, 900));
      final header = find.byKey(const ValueKey('track-header-a'));
      final w0 = tester.getSize(header).width, h0 = tester.getSize(header).height;
      await tester.drag(find.byKey(const ValueKey('header-width-grip')), const Offset(-30, 0));
      await settle(tester);
      expect(tester.getSize(header).width, closeTo(w0 - 30, 1.5));
      expect(s.settings.headerWidth, closeTo(w0 - 30, 1.5));
      await tester.drag(find.byKey(const ValueKey('track-height-grip-a')), const Offset(0, -20));
      await settle(tester);
      expect(tester.getSize(header).height, closeTo(h0 - 20, 1.5));
      expect(s.settings.trackHeight, closeTo(h0 - 20, 1.5));
      expect(Settings()..fromJson(s.settings.toJson()), isA<Settings>()
          .having((x) => x.headerWidth, 'width', s.settings.headerWidth)
          .having((x) => x.trackHeight, 'height', s.settings.trackHeight));
      await settle(tester);
    });

    testWidgets('zoom: the zoom bar\'s sliders, a sideways pinch and an upright pinch, Ctrl + wheel', (tester) async {
      await pumpArranger(tester, const Size(412, 900));
      await tester.tap(find.byKey(const ValueKey('arrange-zoom')));
      await settle(tester);
      expect(find.byKey(const ValueKey('arrange-zoom-bar')), findsOneWidget);
      double clipW() => tester.getSize(find.text('Double-tap for a clip, or drop a pattern here').first).width;
      expect(clipW(), greaterThan(0));
      final ruler = find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_RulerPainter');
      double barW() => (tester.widget<CustomPaint>(ruler).painter as dynamic).stepW as double;
      final w0 = barW();
      await tester.tap(find.byTooltip('Zoom in'));
      await settle(tester);
      expect(barW(), closeTo(w0 * 1.4, 0.01));
      // Sideways pinch: time only.
      final header = find.byKey(const ValueKey('track-header-a'));
      final h0 = tester.getSize(header).height;
      final at = tester.getCenter(find.byKey(const ValueKey('track-header-b'))) + const Offset(200, 0);
      final a = await tester.startGesture(at - const Offset(40, 0), kind: PointerDeviceKind.touch);
      final b = await tester.startGesture(at + const Offset(40, 0), kind: PointerDeviceKind.touch);
      await a.moveBy(const Offset(-40, 0));
      await b.moveBy(const Offset(40, 0));
      await a.up();
      await b.up();
      await settle(tester);
      expect(barW(), closeTo(w0 * 2.8, 0.05));
      expect(tester.getSize(header).height, h0);
      // Upright pinch: the track height only, saved.
      final c = await tester.startGesture(at - const Offset(0, 40), kind: PointerDeviceKind.touch);
      final d = await tester.startGesture(at + const Offset(0, 40), kind: PointerDeviceKind.touch);
      await c.moveBy(const Offset(0, -20));
      await d.moveBy(const Offset(0, 20));
      await c.up();
      await d.up();
      await settle(tester);
      expect(tester.getSize(header).height, closeTo(h0 * 1.5, 1));
      expect(s.settings.trackHeight, closeTo(h0 * 1.5, 1));
      // Ctrl + wheel zooms out.
      final before = barW();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(at));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(barW(), lessThan(before));
    });

    test('tracks in a folder take shades of its colour unless they have their own', () {
      final folder = LayerDoc(id: 'f', name: 'Drums', color: 3, isFolder: true);
      final kick = LayerDoc(id: 'k', name: 'Kick', color: 0, parentId: 'f');
      final snare = LayerDoc(id: 'n', name: 'Snare', color: 1, parentId: 'f');
      final own = LayerDoc(id: 'o', name: 'Own', color: 5, parentId: 'f', ownColor: true);
      final top = LayerDoc(id: 't', name: 'Top', color: 6);
      final layers = [folder, kick, snare, own, top];
      final base = Neon.layer(3);
      expect(trackColorIn(layers, folder), base);
      expect(trackColorIn(layers, kick), isNot(base));
      expect(trackColorIn(layers, kick), isNot(trackColorIn(layers, snare)), reason: 'siblings get different shades');
      // A shade of the folder's colour: the same hue, give or take rounding.
      expect(HSVColor.fromColor(trackColorIn(layers, kick)).hue, closeTo(HSVColor.fromColor(base).hue, 3));
      expect(trackColorIn(layers, own), Neon.layer(5));
      expect(trackColorIn(layers, top), Neon.layer(6));
      expect(LayerDoc.fromJson(own.toJson()).ownColor, isTrue);
      expect(LayerDoc.fromJson(kick.toJson()).ownColor, isFalse);
    });
  });

  group('long-press menus', () {
    testWidgets('a track opens a compact list near the finger, with a tick; record-arm waits for the engine',
        (tester) async {
      listenForHaptics(tester);
      await pumpArranger(tester, const Size(412, 900));
      final header = find.byKey(const ValueKey('track-header-a'));
      await tester.longPress(header);
      await tester.pumpAndSettle();
      final menu = find.byKey(const ValueKey('long-press-menu'));
      expect(menu, findsOneWidget);
      expect(haptics, contains('HapticFeedbackType.selectionClick'));
      // Near the finger: its top within a header's reach of the header.
      expect((tester.getRect(menu).top - tester.getCenter(header).dy).abs(), lessThan(120));
      expect(find.text('Record arm'), findsOneWidget);
      await tester.tap(find.text('Record arm'));
      await tester.pumpAndSettle();
      expect(menu, findsOneWidget, reason: 'a disabled entry does nothing');
      await tester.tap(find.text('Move down'));
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(s.project.layers.map((l) => l.id), ['b', 'a', 'c']);
      expect(sections.focusedLayer, isNull, reason: 'a long-press is not a tap');
      await settle(tester);
    });

    testWidgets('the ring setting opens a ring around the finger', (tester) async {
      s.settings.longPressMenu = LongPressMenuStyle.ring;
      expect(s.settings.toJson()['long_press_menu'], 'ring');
      await pumpArranger(tester, const Size(412, 900));
      await tester.longPress(find.byKey(const ValueKey('track-header-c')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('long-press-ring')), findsOneWidget);
      expect(find.byKey(const ValueKey('long-press-menu')), findsNothing);
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(s.project.layers.map((l) => l.id), ['a', 'b']);
      await settle(tester);
    });

    testWidgets('the setting round-trips and defaults to the list', (tester) async {
      final fresh = Settings();
      expect(fresh.longPressMenu, LongPressMenuStyle.list);
      fresh.fromJson({'long_press_menu': 'ring'});
      expect(fresh.longPressMenu, LongPressMenuStyle.ring);
      fresh.fromJson({'long_press_menu': 'wheel'});
      expect(fresh.longPressMenu, LongPressMenuStyle.ring, reason: 'an unknown value keeps the current one');
    });
  });

  testWidgets('the phone mixer card floats over the tracks; tapping a strip widens it', (tester) async {
    await pumpArranger(tester, const Size(412, 900));
    await tester.tap(find.byTooltip('Mixer'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mixer-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('track-header-a')), findsOneWidget, reason: 'the tracks stay behind it');
    expect(find.byKey(const ValueKey('fader-b')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('narrow-b')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wide-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('fader-b')), findsOneWidget);
    await tester.tap(find.byTooltip('Mute Drums'));
    await tester.pumpAndSettle();
    expect(s.project.layers.first.mute, isTrue);
    await tester.tap(find.byTooltip('Close mixer'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mixer-card')), findsNothing);
    expect(tester.takeException(), isNull);
    await settle(tester);
  });

  testWidgets('with the engine: the built-ins list their knobs, and a knob on a track moves live (needs CAW_LIB)',
      (tester) async {
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    final layer = s.project.layers.firstWhere((l) => !l.isFolder);
    await tester.runAsync(() async {
      s.componentCatalog.refreshIfStale();
      for (var i = 0; i < 250 && s.componentInfo('org.caw.stereo.width') == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    final width = s.componentInfo('org.caw.stereo.width');
    expect(width, isNotNull);
    expect(width!.builtin, isTrue);
    expect(width.parameters.map((p) => p.id), contains('width'));
    s.addNativeEffect(layer, 'org.caw.stereo.width');
    await tester.runAsync(() async => s.info = await s.engine!.setProject(s.project.toEngineJson()));
    expect(s.engineComponentIndex(layer, 0), 0);
    s.setNativeParamLive(layer, 0, 'width', 1.5);
    expect(s.engine!.setComponentParam(layer.id, 0, 'width', 1.5), isTrue);
    expect(layer.components.single.params['width'], 1.5);
    await tester.pump(const Duration(seconds: 1));
  }, skip: Platform.environment['CAW_LIB']?.isNotEmpty != true);
}

void _steppedKnobs() {
  // Owner (2026-11-10): "the unison knob, I have to touch it any time I want it to move one notch". One slow drag
  // must move a stepped knob through as many steps as its travel covers, for every stepped built-in knob.
  testWidgets('with the engine: one slow drag moves a stepped knob through several steps (needs CAW_LIB)',
      (tester) async {
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    await tester.runAsync(() async {
      s.componentCatalog.refreshIfStale();
      for (var i = 0; i < 250 && s.componentInfo('org.caw.synth.flagship') == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    final layer = s.project.layers.firstWhere((l) => !l.isFolder);
    s.setNativeInstrument(layer, 'org.caw.synth.flagship');
    // Every built-in effect with a stepped knob goes on the track too.
    final stepped = [
      for (final c in s.componentCatalog.value.values)
        if (c.builtin && !c.isInstrument && c.parameters.any((p) => p.step > 0 && !p.isChoice)) c,
    ];
    for (final c in stepped) {
      s.addNativeEffect(layer, c.id);
    }
    tester.view.physicalSize = const Size(600, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: ListenableBuilder(listenable: s, builder: (_, _) => FxStack(state: s, layer: layer)))));
    await tester.pump();
    final knobs = <(String, ComponentParameterInfo)>[
      for (final c in [s.componentInfo('org.caw.synth.flagship')!, ...stepped])
        for (final p in c.parameters)
          // Flagship's one unison knob stands for its stepped knobs (the others sit on pages and oscillators not shown).
          if (p.step > 0 && !p.isChoice && (p.max - p.min) / p.step >= 4 && (!c.isInstrument || p.id == 'osc1_unison'))
            (c.id, p),
    ];
    expect(knobs.map((k) => k.$2.id), contains('osc1_unison'));
    double valueOf(String id, String param) => (id == 'org.caw.synth.flagship'
        ? layer.instrument!.params[param]
        : layer.components.firstWhere((c) => c.id == id).params[param]) ?? double.nan;
    // Built-ins show their plugin UIs inline: each knob is found in its own device's UI; a knob the inline UI
    // leaves to MORE or the full-screen editor is skipped (the unison knob must be there).
    var tried = 0;
    for (final (id, p) in knobs) {
      final slot = id == 'org.caw.synth.flagship' ? 'instrument' : '${layer.components.indexWhere((c) => c.id == id)}';
      final knob = find.descendant(of: find.byKey(ValueKey('fx-inline-$slot')), matching: find.byKey(ValueKey('dknob-${p.id}')));
      if (knob.evaluate().isEmpty) {
        expect(p.id, isNot('osc1_unison'), reason: 'the flagship shows its unison knob inline');
        continue;
      }
      tried++;
      await tester.ensureVisible(knob);
      await tester.pumpAndSettle();
      // Set to the minimum first (double-tap goes to the default, so drag far down).
      await tester.drag(knob, const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(valueOf(id, p.id), p.min, reason: '$id ${p.id} at the bottom');
      // Then one slow drag up, a pixel at a time, over 60% of the travel (200 px covers it all).
      final g = await tester.startGesture(tester.getCenter(knob));
      for (var i = 0; i < 140; i++) {
        await g.moveBy(const Offset(0, -1));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();
      final steps = (valueOf(id, p.id) - p.min) / p.step;
      expect(steps, greaterThanOrEqualTo(2), reason: '$id ${p.id} moved $steps steps in one slow drag');
    }
    expect(tried, greaterThanOrEqualTo(1));
    await tester.pump(const Duration(seconds: 1));
  }, skip: Platform.environment['CAW_LIB']?.isNotEmpty != true);
}
