// Tests the docking shell: the controller's saved layouts, reveal, focus and screen shapes, and the shell at phone,
// landscape and desktop sizes with every panel shown in turn (no overflow), plus goldens of the shell and the phone mixer (they need CAW_LIB).
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/dock/dock_controller.dart';
import 'package:caw/ui/dock/dock_view.dart';
import 'package:caw/ui/dock/layout.dart';
import 'package:caw/ui/frame/frame_widgets.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/haptics.dart';
import 'package:caw/ui/mixer_screen.dart';
import 'package:caw/ui/shell.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

void main() {
  group('controller', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('caw_dock'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('each screen shape starts from its preset and keeps its own layout', () {
      final c = DockController(Settings());
      for (final f in FormFactor.values) {
        c.form = f;
        expect(c.layout.toJson(), DockLayout.preset(f).toJson());
      }
      c.form = FormFactor.desktop;
      c.reveal(Panels.mixer);
      c.form = FormFactor.phonePortrait;
      expect(c.layout.visible, isNot(contains(Panels.mixer)));
      c.form = FormFactor.desktop;
      expect(c.layout.visible, contains(Panels.mixer));
      c.dispose();
    });

    test('layouts are saved after a pause and read back; a damaged one falls back to the preset', () async {
      final s = await Settings.open(base: dir);
      final c = DockController(s)..form = FormFactor.phonePortrait;
      c.set(c.layout.dock(Panels.files, target: Panels.arrangement, edge: DockEdge.right));
      await c.flush();
      final back = await Settings.open(base: dir);
      final c2 = DockController(back)..form = FormFactor.phonePortrait;
      expect(c2.layout.toJson(), c.layout.toJson());
      back.dockLayouts['desktop'] = {'split': 'diagonal'};
      final c3 = DockController(back)..form = FormFactor.desktop;
      expect(c3.layout.toJson(), DockLayout.preset(FormFactor.desktop).toJson());
      final damaged = Settings()..fromJson({'dock_layouts': 'nope'});
      expect(damaged.dockLayouts, isEmpty);
      for (final c in [c, c2, c3]) {
        c.dispose();
      }
    });

    test('a new controller on the same settings sees a change not yet written to disk (the theme remount)', () {
      final s = Settings();
      final old = DockController(s)..form = FormFactor.desktop;
      old.reveal(Panels.mixer);
      final fresh = DockController(s)..form = FormFactor.desktop;
      expect(fresh.layout.toJson(), old.layout.toJson());
      old.dispose();
      fresh.dispose();
    });

    test('the key panel is the one touched last while it is on screen, else the first on screen', () {
      final c = DockController(Settings())..form = FormFactor.desktop;
      expect(c.keyPanel, Panels.arrangement);
      c.touch(Panels.builder);
      expect(c.keyPanel, Panels.builder);
      c.set(c.layout.activate(Panels.mixer));
      expect(c.keyPanel, Panels.arrangement, reason: 'the builder tab is hidden now');
      c.reveal(Panels.files);
      expect(c.keyPanel, Panels.files);
      c.dispose();
    });

    test('a panel floats out of the layout, moves, is saved, and docks back', () async {
      final s = await Settings.open(base: dir);
      final c = DockController(s)..form = FormFactor.desktop;
      c.float(Panels.mixer);
      expect(c.isFloating(Panels.mixer), isTrue);
      expect(c.layout.contains(Panels.mixer), isFalse);
      c.placeFloating(Panels.mixer, const Rect.fromLTWH(5, -3, 0.01, 2));
      final r = c.floating.single.rect;
      expect(r.top, 0.0, reason: 'the title bar stays on screen');
      expect(r.width, closeTo(0.2, 1e-9), reason: 'at least a fifth of the area');
      expect(r.height, closeTo(1.0, 1e-9));
      c.reveal(Panels.mixer);
      expect(c.isFloating(Panels.mixer), isTrue, reason: 'showing a floating panel raises its window');
      await c.flush();
      final back = DockController(await Settings.open(base: dir))..form = FormFactor.desktop;
      expect(back.floating.single.id, Panels.mixer);
      expect(back.layout.contains(Panels.mixer), isFalse);
      back.unfloat(Panels.mixer);
      expect(back.layout.visible, contains(Panels.mixer));
      expect(back.floating, isEmpty);
      for (final c in [c, back]) {
        await c.flush();
        c.dispose();
      }
    });

    test('the shell picks the screen shape from its size', () {
      expect(formFactorFor(const Size(390, 780)), FormFactor.phonePortrait);
      expect(formFactorFor(const Size(844, 330)), FormFactor.phoneLandscape);
      expect(formFactorFor(const Size(1280, 800)), FormFactor.desktop);
      expect(formFactorFor(const Size(800, 1280)), FormFactor.desktop, reason: 'a tablet in portrait');
      expect(formFactorFor(const Size(915, 412)), FormFactor.phoneLandscape, reason: 'a wide phone stays a phone');
      expect(formFactorFor(const Size(1000, 620)), FormFactor.desktop, reason: 'a DeX or freeform window');
      expect(formFactorFor(const Size(390, 780), mode: LayoutMode.desktop), FormFactor.desktop);
      expect(formFactorFor(const Size(844, 330), mode: LayoutMode.desktop), FormFactor.desktop);
      expect(formFactorFor(const Size(1280, 800), mode: LayoutMode.phone), FormFactor.phoneLandscape);
      expect(formFactorFor(const Size(800, 1280), mode: LayoutMode.phone), FormFactor.phonePortrait);
    });
  });

  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  Future<AppState> startState(WidgetTester tester) async {
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    s.selectedModuleId = s.project.modules.first.id;
    s.ready = true;
    s.starting = false;
    await tester.runAsync(() async => s.info = await s.engine!.setProject(s.project.toEngineJson()));
    return s;
  }

  for (final size in goldenSizes.entries) {
    testWidgets('the shell at ${size.key} size shows every panel without overflow', (tester) async {
      final s = await startState(tester);
      await pumpGolden(tester, Shell(state: s), size.value);
      expect(tester.takeException(), isNull);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/shell_${size.key}.png'));
      final dock = DockController.of(tester.element(find.byType(Scaffold).first));
      if (dock.form == FormFactor.desktop) {
        for (final id in Panels.all) {
          dock.reveal(id);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$id at ${size.key}');
          expect(dock.layout.visible, contains(id));
        }
      } else {
        // A phone shows one section at a time and the other workspaces as pages from More.
        for (final section in Section.values) {
          await tester.tap(find.byKey(ValueKey('section-${section.name}')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '${section.name} at ${size.key}');
        }
        for (final title in const ['Mixer', 'Automation']) {
          await tester.tap(find.byKey(const ValueKey('more-tools')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(title).last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$title at ${size.key}');
          await tester.pageBack();
          await tester.pumpAndSettle();
        }
      }
      s.dispose();
    }, skip: skip);
  }

  testWidgets('phone landscape draws edge to edge: the rail and the tracks keep clear of a camera cutout',
      (tester) async {
    final s = await startState(tester);
    tester.view.padding = const FakeViewPadding(left: 80);
    await pumpGolden(tester, Shell(state: s), const Size(924, 390));
    expect(tester.takeException(), isNull);
    // The rail's background starts at the screen's edge; its buttons and the tracks sit right of the cutout.
    expect(tester.getTopLeft(find.byType(SectionRail)).dx, 0);
    expect(tester.getTopLeft(find.byKey(const ValueKey('section-build'))).dx, greaterThanOrEqualTo(80));
    expect(tester.getTopLeft(find.byKey(ValueKey('track-header-${s.project.layers.first.id}'))).dx, greaterThan(80));
    expect(find.byKey(const ValueKey('transport-bpm')), findsOneWidget, reason: 'the tempo moves into the transport');
    s.dispose();
  }, skip: skip);

  testWidgets('Arrange\'s Files browser: an effect dragged from it lands on a track', (tester) async {
    final s = await startState(tester);
    await tester.runAsync(() async {
      s.componentCatalog.set(await s.refreshNativeCatalog());
    });
    await pumpGolden(tester, Shell(state: s), const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('arrange-browse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('arrange-browser')), findsOneWidget);
    await tester.tap(find.text('Built-in').last);
    await tester.pumpAndSettle();
    final layer = s.project.layers.first;
    final before = layer.components.length;
    final item = find.descendant(of: find.byKey(const ValueKey('arrange-browser')), matching: find.text('Distortion'));
    // The built-in list is long (the effects suite, #173): scroll to it.
    await tester.scrollUntilVisible(item, 60,
        scrollable: find.descendant(of: find.byKey(const ValueKey('arrange-browser')), matching: find.byType(Scrollable)).last);
    expect(item, findsOneWidget);
    final lane = tester.getCenter(find.byKey(ValueKey('track-header-${layer.id}'))) + const Offset(180, 0);
    await tester.ensureVisible(item);
    await tester.pumpAndSettle();
    final g = await tester.startGesture(tester.getCenter(item));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 400));
    await g.moveBy(const Offset(0, -30));
    await tester.pump();
    await g.moveTo(lane - const Offset(0, 20));
    await tester.pump();

    await g.moveTo(lane);
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(s.project.layers.firstWhere((l) => l.id == layer.id).components.length, before + 1);
    s.dispose();
  }, skip: skip);

  testWidgets('scrolling never hides the top bars; a deliberate pull on the grip does, and the tab brings them back',
      (tester) async {
    final s = await startState(tester);
    for (var i = 0; i < 12; i++) {
      s.addLayer();
    }
    final felt = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') felt.add(call.arguments as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    tester.view.padding = const FakeViewPadding(top: 30, bottom: 20);
    await pumpGolden(tester, Shell(state: s), const Size(390, 844));
    final status = find.byKey(const ValueKey('project-menu'));
    final toolbar = find.byKey(const ValueKey('arrange-toolbar'));
    expect(tester.getTopLeft(status).dy, greaterThanOrEqualTo(30), reason: 'clear of the status bar');
    final top0 = tester.getTopLeft(toolbar).dy;
    final tracks = find.byKey(ValueKey('track-header-${s.project.layers[3].id}'));
    await tester.drag(tracks, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(status).dy, greaterThanOrEqualTo(30), reason: 'a scroll leaves the status row');
    expect(tester.getTopLeft(toolbar).dy, top0, reason: 'and the toolbar');

    // A short pull follows the finger, shows the hint, and springs back on release.
    final grip = find.byKey(const ValueKey('bars-handle'));
    expect(grip, findsOneWidget);
    Haptics.reset();
    final g = await tester.startGesture(tester.getCenter(grip));
    await g.moveBy(const Offset(0, -12));
    await g.moveBy(const Offset(0, -10));
    await tester.pump();
    expect(tester.getTopLeft(toolbar).dy, lessThan(top0), reason: 'the bars follow the finger');
    expect(find.text('Pull up to hide the bars'), findsOneWidget);
    await g.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(toolbar).dy, top0, reason: 'short of the threshold it snaps back');

    // Past the threshold: a tick, the hint changes, and letting go hides the bars.
    Haptics.reset();
    felt.clear();
    final g2 = await tester.startGesture(tester.getCenter(grip));
    await g2.moveBy(const Offset(0, -20));
    await g2.moveBy(const Offset(0, -20));
    await tester.pump();
    expect(find.text('Let go to hide'), findsOneWidget);
    expect(felt, containsAll(['HapticFeedbackType.lightImpact']), reason: 'a grab and a threshold tick');
    await g2.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(status).bottom, lessThanOrEqualTo(31), reason: 'the status row tucked away');
    expect(tester.getTopLeft(toolbar).dy, lessThan(top0));
    expect(find.byKey(const ValueKey('bars-tab')), findsOneWidget, reason: 'a slim tab stays to bring them back');

    // Scrolling still changes nothing; the tab, tapped, brings the bars back.
    await tester.drag(tracks, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(tester.getRect(status).bottom, lessThanOrEqualTo(31));
    await tester.tap(find.byKey(const ValueKey('bars-handle')));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(status).dy, greaterThanOrEqualTo(30));
    expect(tester.getTopLeft(toolbar).dy, top0);

    // And a pull down on the tab does too.
    await tester.drag(find.byKey(const ValueKey('bars-handle')), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(tester.getRect(status).bottom, lessThanOrEqualTo(31));
    await tester.drag(find.byKey(const ValueKey('bars-handle')), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(toolbar).dy, top0);
    s.dispose();
  }, skip: skip);

  testWidgets('arrangement: the track gap and a spacer keep headers level with their lanes; the grip resizes it',
      (tester) async {
    final s = await startState(tester);
    s.settings.trackGap = 12;
    final first = s.project.layers.first, second = s.project.layers[1];
    s.setSpaceBelow(first, 30);
    await pumpGolden(tester, Shell(state: s), goldenSizes['desktop']!);
    // The second track's header and its lane start at the same height: below the first, its spacer and the gap.
    final header = tester.getTopLeft(find.text(second.name).first);
    final firstHeader = tester.getTopLeft(find.text(first.name).first);
    expect(header.dy - firstHeader.dy, closeTo(76 + 30 + 12, 1));
    // One grid behind all the tracks, reaching the bottom of the view below the last one (owner: like Reaper).
    final grid = find.byWidgetPredicate((w) => w is CustomPaint && '${w.painter.runtimeType}' == '_ArrangementGrid');
    expect(grid, findsOneWidget);
    final lastLane = tester.getBottomLeft(find.text(s.project.layers.last.name).first).dy;
    expect(tester.getRect(grid).bottom, greaterThan(lastLane + 100));
    await tester.drag(find.byKey(ValueKey('spacer-grip-${first.id}')), const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(first.spaceBelow, greaterThan(50));
    await expectLater(goldenScreen, matchesGoldenFile('goldens/shell_desktop_spacer.png'));
    s.dispose();
  }, skip: skip);

  testWidgets('the Mix preset on a desktop: mixer strips, meters and toggles', (tester) async {
    final s = await startState(tester);
    await pumpGolden(tester, Shell(state: s), goldenSizes['desktop']!);
    DockController.of(tester.element(find.byType(Scaffold).first)).usePreset(DockPreset.mix);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/shell_desktop_mix.png'));
    s.dispose();
  }, skip: skip);

  testWidgets('the transport tempo: tap to type it, long-press for the tap pad (#19)', (tester) async {
    final s = await startState(tester);
    await pumpGolden(tester, Shell(state: s), goldenSizes['phone']!);
    // Tap tempo runs on the real clock, so the test times the gap itself: the tempo is 60 s over it.
    final gap = Stopwatch();
    Future<void> halfASecond() => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    double tempoOf(Stopwatch w) => (60000 / w.elapsedMilliseconds).clamp(20, 400).toDouble();
    // The T key runs the same tap tempo as the pad.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    gap.start();
    await halfASecond();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    gap.stop();
    await tester.pump();
    // The stopwatch starts and stops a few ms off each tap (either way), so the tempo is close to 60 s over it.
    expect(s.project.bpm, inInclusiveRange(tempoOf(gap) * 0.8, tempoOf(gap) * 1.25));
    await tester.tap(find.byKey(const ValueKey('transport-bpm')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '128');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(s.project.bpm, 128);
    expect(find.text('128 BPM'), findsOneWidget);
    await tester.longPress(find.byKey(const ValueKey('transport-bpm')));
    await tester.pumpAndSettle();
    expect(find.text('Tap tempo'), findsOneWidget);
    // On a phone the pad is a bottom sheet, within thumb reach.
    expect(find.ancestor(of: find.byKey(const ValueKey('tap-pad')), matching: find.byType(BottomSheet)), findsOneWidget);
    // Over two seconds (real time) since the T taps, so the pad starts a new measurement.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2500)));
    await tester.tap(find.byKey(const ValueKey('tap-pad')));
    gap..reset()..start();
    await halfASecond();
    await tester.tap(find.byKey(const ValueKey('tap-pad')));
    gap.stop();
    await tester.pump();
    expect(s.project.bpm, inInclusiveRange(tempoOf(gap) * 0.8, tempoOf(gap) * 1.25));
    // On a keyboard, T taps on the open pad too (it is outside the key router).
    final before = s.project.bpm;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2500)));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await halfASecond();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();
    expect(s.project.bpm, isNot(before));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Tap tempo'), findsNothing);
    s.dispose();
  }, skip: skip);

  testWidgets('Settings › Layout switches the frame while running; desktop on a phone takes a mouse and keys',
      (tester) async {
    final s = await startState(tester);
    s.history.reset(jsonEncode(s.project.toJson()));
    await pumpGolden(tester, Shell(state: s), goldenSizes['phone']!);
    expect(find.byType(SectionBar), findsOneWidget, reason: 'Auto on a phone: the phone frame');
    expect(find.byType(DockView), findsNothing);

    s.settings.layoutMode = LayoutMode.desktop;
    s.settings.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(DockView), findsOneWidget, reason: 'Desktop: docking panels on the phone');
    expect(find.byType(SectionBar), findsNothing);
    expect(find.byType(SectionRail), findsOneWidget);
    expect(find.byKey(const ValueKey('arrange-toolbar')), findsOneWidget, reason: 'Arrange stays in front');
    expect(tester.takeException(), isNull, reason: 'the transport bar fits a phone width');

    // A mouse: hovering shows a tooltip, a right-click opens a track's menu.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byTooltip('Play (Space)')));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Play (Space)'), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    final header = find.byKey(ValueKey('track-header-${s.project.layers.first.id}'));
    await tester.tapAt(tester.getCenter(header), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget, reason: "a right-click opens the track's menu");
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsNothing);

    // Keys: Ctrl+Z undoes.
    final bpm = s.project.bpm;
    s.editProject((p) => p.bpm = bpm + 10);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(s.project.bpm, bpm);

    // Back to the phone frame while running, on the same section; landscape too.
    s.settings.layoutMode = LayoutMode.phone;
    s.settings.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(SectionBar), findsOneWidget);
    expect(find.byKey(const ValueKey('arrange-toolbar')), findsOneWidget);
    tester.view.physicalSize = goldenSizes['landscape']!;
    s.settings.layoutMode = LayoutMode.desktop;
    s.settings.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(DockView), findsOneWidget);
    expect(tester.takeException(), isNull);
    s.settings.layoutMode = LayoutMode.auto;
    await tester.pump(const Duration(seconds: 1));
    s.dispose();
  }, skip: skip);

  testWidgets('the transport undoes and redoes project edits; Ctrl+Z does too', (tester) async {
    final s = await startState(tester);
    s.history.reset(jsonEncode(s.project.toJson()));
    await pumpGolden(tester, Shell(state: s), goldenSizes['phone']!);
    IconButton button(String key) => tester.widget<IconButton>(find.byKey(ValueKey(key)));
    expect(button('transport-undo').onPressed, isNull);
    final bpm = s.project.bpm;
    s.editProject((p) => p.bpm = bpm + 10);
    await tester.pump(const Duration(milliseconds: 700)); // the burst settles
    expect(button('transport-undo').onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('transport-undo')));
    await tester.pump();
    expect(s.project.bpm, bpm);
    expect(button('transport-redo').onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('transport-redo')));
    await tester.pump();
    expect(s.project.bpm, bpm + 10);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(s.project.bpm, bpm);
    await tester.pumpAndSettle();
    s.dispose();
  }, skip: skip);

  testWidgets('at launch the arrangement comes to the front, whatever the saved layout showed', (tester) async {
    final s = await startState(tester);
    s.settings.dockLayouts = {
      FormFactor.desktop.name: DockLayout.preset(FormFactor.desktop, DockPreset.mix).reveal(Panels.files).toJson(),
    };
    await pumpGolden(tester, Shell(state: s), goldenSizes['desktop']!);
    final dock = DockController.of(tester.element(find.byType(Scaffold).first));
    expect(dock.layout.visible, contains(Panels.arrangement));
    s.dispose();
  }, skip: skip);

  testWidgets('the mixer on a phone: upright strips with chain slots, pan, fader, meter, M and S', (tester) async {
    final s = await startState(tester);
    await pumpGolden(tester, Scaffold(body: MixerScreen(state: s, onOpenBuilder: () {})), goldenSizes['phone']!);
    expect(tester.takeException(), isNull);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/mixer_phone.png'));
    s.dispose();
  }, skip: skip);
}
