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
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/frame/sections.dart';
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

    testWidgets('landscape puts the panel on the right, about 40% wide, and keeps every track', (tester) async {
      await pumpArranger(tester, const Size(860, 400));
      await tester.tap(find.byKey(const ValueKey('track-header-a')));
      await tester.pumpAndSettle();
      final panel = tester.getRect(find.byKey(const ValueKey('focus-panel')));
      expect(panel.left, greaterThan(860 * 0.5));
      expect(panel.width, closeTo(860 * 0.4, 20));
      expect(find.byKey(const ValueKey('track-header-c')), findsOneWidget);
      expect(tester.takeException(), isNull);
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

    testWidgets('a built-in native effect shows its knobs; a knob, bypass, reorder and remove edit the project',
        (tester) async {
      listenForHaptics(tester);
      s.componentCatalog.set(const [_width, _chorus]);
      final layer = s.project.layers.first;
      s.addNativeEffect(layer, 'org.caw.stereo.width');
      await pumpStack(tester, layer);
      expect(find.text('CODE EFFECTS · .caw'), findsOneWidget);
      expect(find.text('NATIVE EFFECTS · C++'), findsOneWidget);
      expect(find.text('Width'), findsWidgets);
      expect(find.text('Built-in'), findsOneWidget);

      // A knob turned up is stored in the project; passing the centre ticks.
      final knob = find.byKey(const ValueKey('knob-org.caw.stereo.width-width'));
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
      expect(find.text('Needs engine recording'), findsOneWidget);
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
