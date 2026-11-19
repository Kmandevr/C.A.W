// The device shell: FX chain rows that fold (kept per slot in the settings) with Collapse all, the header (power,
// preset ‹ › ★, A/B with hold to copy, ⋯: copy, paste, randomize, undo history, reset), the knob's hold menu (type,
// reset, React to…), the footer and auto gain through DeviceSlotAudio, and the preset browser's live Preview.
import 'dart:convert';
import 'dart:math' as math;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_history.dart';
import 'package:caw/model/device_slot_audio.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/modulation.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/react_to.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/user_presets.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/flagship/flagship_editor.dart' show flagshipComponentId;
import 'package:caw/ui/devices/flagship/flagship_tools.dart';
import 'package:caw/ui/devices/kit/device_menu.dart';
import 'package:caw/ui/devices/kit/preset_preview.dart';
import 'package:caw/ui/devices/kit/presets.dart';
import 'package:caw/ui/devices/kit/hero.dart' show MotionClock;
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';

/// Per-slot meters and auto gain as the engine will give them.
class FakeSlotAudio extends DeviceSlotAudio {
  final on = <String>{};
  double peak = 0.5;
  int reads = 0;
  @override
  bool get hasMeter => true;
  @override
  bool get hasAutoGain => true;
  @override
  double? outputPeak(DeviceTarget t) {
    reads++;
    return peak;
  }

  @override
  bool autoGain(DeviceTarget t) => on.contains('${t.layerId}/${t.slot}');
  @override
  void setAutoGain(DeviceTarget t, bool v) => v ? on.add('${t.layerId}/${t.slot}') : on.remove('${t.layerId}/${t.slot}');
  @override
  double? autoGainTrimDb(DeviceTarget t) => autoGain(t) ? -2.4 : null;
}

void main() {
  late AppState s;
  late DeviceDisplaySource display;

  setUp(() {
    display = DeviceDisplaySource.current;
    DeviceDisplaySource.current = DeviceDisplaySource.none;
    Motion.setting = MotionLevel.off;
    MotionClock.hold = true;
    DeviceClipboard.clear();
    s = AppState(settings: Settings());
    s.project = ProjectDoc(id: 'p', name: 'Shell', bpm: 120, modules: [], layers: [
      LayerDoc(id: 'a', name: 'Lead', color: 2),
      LayerDoc(id: 'k', name: 'Kick', color: 0),
    ]);
    s.componentCatalog.set(builtinInfos());
    s.setNativeInstrument(s.project.layers.first, 'org.caw.synth.flagship');
    addBuiltinEffect(s, s.project.layers.first, 'org.caw.chorus');
    addBuiltinEffect(s, s.project.layers.first, 'org.caw.chorus');
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
  });
  tearDown(() {
    DeviceSlotAudio.current = null;
    DeviceDisplaySource.current = display;
    MotionClock.hold = false;
    s.dispose();
  });

  LayerDoc layer() => s.project.layers.first;
  DeviceTarget chorus([int i = 0]) => DeviceTarget(s, 'a', i);

  Future<void> pumpStack(WidgetTester tester, {Size size = const Size(412, 2400)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
        builder: (_, _) => FxStack(state: s, layer: layer())))));
    await tester.pump();
  }

  /// Pumps a while (the meters' tickers keep running, so pumpAndSettle would not end with a meter on screen).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Finder inDevice(String device, String key) =>
      find.descendant(of: find.byKey(ValueKey('fx-device-$device')), matching: find.byKey(ValueKey(key)));

  group('FX chain rows', () {
    testWidgets('a row folds to power, name, a live visual and Mix; open again; kept per slot in the settings',
        (tester) async {
      await pumpStack(tester);
      expect(find.byKey(const ValueKey('fx-page-chorus')), findsNWidgets(2), reason: 'rows start open');
      await tester.tap(find.byKey(const ValueKey('fx-fold-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fx-row-0')), findsOneWidget);
      expect(inDevice('0', 'device-mini'), findsOneWidget);
      expect(inDevice('0', 'row-knob-mix'), findsOneWidget);
      expect(inDevice('0', 'fx-bypass-0'), findsOneWidget, reason: 'its power works folded');
      expect(find.byKey(const ValueKey('fx-page-chorus')), findsOneWidget, reason: 'the other stays open');
      expect(s.settings.fxRowOpen('p', 'a/0/${chorus().componentId}'), isFalse);
      expect(jsonEncode(s.settings.toJson()), contains('fx_collapsed'));
      // Every control works in place: power and Mix on the folded row.
      await tester.tap(inDevice('0', 'fx-bypass-0'));
      await tester.pump();
      expect(layer().components.first.bypass, isTrue);
      final before = chorus().value('mix');
      await tester.drag(inDevice('0', 'row-knob-mix'), const Offset(0, 40));
      await tester.pumpAndSettle();
      expect(chorus().value('mix'), lessThan(before));
      // A tap on its name opens it again.
      await tester.tap(find.byKey(const ValueKey('fx-native-title-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fx-row-0')), findsNothing);
      expect(s.settings.fxRowOpen('p', 'a/0/${chorus().componentId}'), isTrue);
      await done(tester);
    });

    testWidgets('Collapse all folds every row; then Open all opens them', (tester) async {
      await pumpStack(tester);
      await tester.tap(find.byKey(const ValueKey('fx-collapse-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fx-row-instrument')), findsOneWidget);
      expect(find.byKey(const ValueKey('fx-row-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('fx-row-1')), findsOneWidget);
      expect(find.text('Open all'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fx-collapse-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fx-row-0')), findsNothing);
      expect(find.text('Collapse all'), findsOneWidget);
      await done(tester);
    });

    test('the folded rows survive a settings round trip, and the list stays bounded', () {
      final a = Settings();
      a.setFxRowOpen('p', 'a/0/x', false);
      a.setFxRowOpen('q', 'b/-1/y', false);
      final b = Settings()..fromJson(jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
      expect(b.fxRowOpen('p', 'a/0/x'), isFalse);
      expect(b.fxRowOpen('q', 'b/-1/y'), isFalse);
      expect(b.fxRowOpen('p', 'a/1/x'), isTrue);
      for (var i = 0; i < Settings.maxProjectViews + 5; i++) {
        a.setFxRowOpen('p$i', 'k', false);
      }
      expect(a.fxCollapsed.length, Settings.maxProjectViews);
    });
  });

  group('header', () {
    testWidgets('power, ‹ › stepping presets, ★ favourite, the name opening the browser at its search', (tester) async {
      final t = chorus();
      for (final n in ['Wide', 'Subtle']) {
        s.userPresets.put(UserPreset(id: s.userPresets.newId(), kind: UserPresetKind.device, name: n,
            device: s.captureDevice(t), modified: DateTime(2026, 11, 18)));
      }
      await pumpStack(tester);
      await tester.tap(inDevice('0', 'fx-bypass-0'));
      await tester.pump();
      expect(t.bypass, isTrue);
      final names = DevicePresets.of(t).map((p) => p.name).toList();
      await tester.tap(inDevice('0', 'device-preset-next'));
      await tester.pumpAndSettle();
      expect(DevicePresets.current(t)!.name, names[1]);
      await tester.tap(inDevice('0', 'device-preset-prev'));
      await tester.pumpAndSettle();
      expect(DevicePresets.current(t)!.name, names[0]);
      await tester.tap(inDevice('0', 'device-preset-prev'));
      await tester.pumpAndSettle();
      expect(DevicePresets.current(t)!.name, names.last, reason: 'it wraps round');
      await tester.tap(inDevice('0', 'device-preset-fav'));
      await tester.pump();
      expect(s.userPresets.isFavourite(DevicePresets.current(t)!.favouriteKey(t.componentId!)), isTrue);
      await tester.tap(inDevice('0', 'fx-presets-0'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('preset-browser')), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(const ValueKey('preset-search')));
      expect(field.autofocus, isTrue, reason: 'a tap on the name goes to search');
      await done(tester);
    });

    testWidgets('A/B: a tap switches; a hold copies A to B', (tester) async {
      final t = chorus();
      await pumpStack(tester);
      t.set('depth', 0.2);
      await tester.tap(inDevice('0', 'device-ab-b'));
      await tester.pump();
      t.set('depth', 0.8);
      await tester.tap(inDevice('0', 'device-ab-a'));
      await tester.pump();
      expect(t.value('depth'), closeTo(0.2, 1e-9));
      // Hold on A: B becomes a copy of A.
      await tester.longPress(inDevice('0', 'device-ab'));
      await tester.pumpAndSettle();
      expect(find.text('Copied A to B'), findsOneWidget);
      await tester.tap(inDevice('0', 'device-ab-b'));
      await tester.pump();
      expect(t.value('depth'), closeTo(0.2, 1e-9));
      // Hold on B: A's values load into B.
      t.set('depth', 0.6);
      DeviceAB.select(t, false);
      t.set('depth', 0.3);
      DeviceAB.select(t, true);
      DeviceAB.copyAToB(t);
      expect(t.value('depth'), closeTo(0.3, 1e-9));
      await done(tester);
    });

    testWidgets('⋯: copy and paste settings, reset; paste needs the same device', (tester) async {
      await pumpStack(tester);
      chorus().set('depth', 0.77);
      await tester.tap(inDevice('0', 'device-more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy settings'));
      await tester.pumpAndSettle();
      expect(DeviceClipboard.whyNoPaste(chorus(1)), isNull);
      expect(DeviceClipboard.whyNoPaste(DeviceTarget(s, 'a', DeviceTarget.instrumentSlot)), isNotNull);
      await tester.tap(inDevice('1', 'device-more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste settings'));
      await tester.pumpAndSettle();
      expect(chorus(1).value('depth'), closeTo(0.77, 1e-9));
      await tester.tap(inDevice('1', 'device-more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(chorus(1).value('depth'), chorus(1).param('depth')!.defaultValue);
      await done(tester);
    });

    testWidgets('⋯ › Randomize… rolls the knobs by the amount, each roll one undo step', (tester) async {
      await pumpStack(tester);
      final before = {for (final p in chorus().info!.parameters) p.id: chorus().value(p.id)};
      await tester.tap(inDevice('0', 'device-more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Randomize…'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('device-randomize')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('device-randomize-go')));
      await tester.pumpAndSettle();
      final after = {for (final p in chorus().info!.parameters) p.id: chorus().value(p.id)};
      expect(after, isNot(equals(before)));
      expect(after['variant'], before['variant'], reason: 'the variant stays');
      expect(s.undo(), isTrue);
      expect({for (final p in chorus().info!.parameters) p.id: chorus().value(p.id)}, before);
      await done(tester);
    });

    test('randomize moves each knob at most the amount of its travel', () {
      final t = chorus();
      final p = t.param('depth')!;
      t.set('depth', 0.5);
      randomizeDevice(t, 0.1, random: math.Random(3));
      expect((t.value('depth') - 0.5).abs(), lessThanOrEqualTo(0.1 * (p.max - p.min) + 1e-9));
    });

    testWidgets('⋯ › Undo history… lists this device\'s steps; a tap brings it back to before one', (tester) async {
      final t = chorus();
      t.set('depth', 0.3);
      s.endUndoStep();
      s.setNativeBypass(s.project.layers[0], 1, true);  // another device's step: not listed
      s.endUndoStep();
      t.set('depth', 0.9);
      s.endUndoStep();
      final steps = deviceHistory(t);
      expect(steps.length, 2);
      expect(steps.first.changed, ['depth']);
      expect(steps.first.values['depth'], closeTo(0.3, 1e-9));
      await pumpStack(tester);
      await tester.tap(inDevice('0', 'device-more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo history…'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('device-history')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('device-history-0')));
      await tester.pumpAndSettle();
      expect(t.value('depth'), closeTo(0.3, 1e-9));
      expect(layer().components[1].bypass, isTrue, reason: 'the rest of the project stays');
      await done(tester);
    });
  });

  group('knob', () {
    testWidgets('a hold opens its menu: type a value, reset', (tester) async {
      await pumpStack(tester);
      final knob = inDevice('0', 'dknob-depth');
      await tester.longPress(knob);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('knob-menu')), findsOneWidget);
      for (final k in ['dknob-type', 'automate-param', 'knob-menu-react', 'knob-menu-midi', 'knob-menu-reset']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      await tester.enterText(find.byKey(const ValueKey('dknob-type')), '0.42');
      await tester.tap(find.byKey(const ValueKey('dknob-set')));
      await tester.pumpAndSettle();
      expect(chorus().value('depth'), closeTo(0.42, 1e-9));
      await tester.longPress(knob);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('knob-menu-reset')));
      await tester.pumpAndSettle();
      expect(chorus().value('depth'), chorus().param('depth')!.defaultValue);
      await done(tester);
    });

    testWidgets('React to… › a track › Loudness links a follower hearing that track, as one undo step',
        (tester) async {
      await pumpStack(tester);
      await tester.longPress(inDevice('0', 'dknob-depth'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('knob-menu-react')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kick'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Loudness'));
      await tester.pumpAndSettle();
      final m = s.project.modulators.single;
      expect((m.componentId, m.inputId, m.hears, m.layerId), (ModulatorKinds.follower, 'k', 'audio', 'a'));
      final link = s.project.modLinks.single;
      expect(link.target, ModTarget.ofDevice(chorus(), 'depth'));
      expect(find.textContaining('reacts to Kick'), findsOneWidget);
      expect(s.undo(), isTrue);
      expect(s.project.modulators, isEmpty);
      expect(s.project.modLinks, isEmpty);
      await done(tester);
    });

    test('Notes makes an envelope; a second knob shares the modulator; a track\'s own loudness is refused', () {
      final a = s.reactTo(chorus(), 'depth', 'k', ReactKind.notes);
      expect(a.link, isNotNull);
      expect(s.project.modulators.single.componentId, ModulatorKinds.envelope);
      final b = s.reactTo(chorus(), 'rate', 'k', ReactKind.notes);
      expect(b.link, isNotNull);
      expect(s.project.modulators, hasLength(1), reason: 'shared');
      expect(s.project.modLinks, hasLength(2));
      final own = s.reactTo(chorus(), 'depth', 'a', ReactKind.loudness);
      expect(own.link, isNull);
      expect(own.why, contains('loop'));
      expect(s.project.modulators, hasLength(1), reason: 'the refused one is not left behind');
      expect(s.reactSources(ReactKind.notes).map((l) => l.id), ['a', 'k']);
    });
  });

  group('footer and auto gain', () {
    testWidgets('without the engine\'s slot meters: Mix only, no meter, no ear', (tester) async {
      await pumpStack(tester);
      expect(inDevice('0', 'device-footer'), findsOneWidget);
      expect(inDevice('0', 'footer-knob-mix'), findsOneWidget);
      expect(inDevice('0', 'device-meter'), findsNothing);
      expect(inDevice('0', 'device-autogain'), findsNothing);
      expect(find.byKey(const ValueKey('device-footer')), findsNWidgets(2), reason: 'the instrument has no mix');
      await done(tester);
    });

    testWidgets('with them: the meter reads while on screen, the clip light latches until tapped, the ear switches',
        (tester) async {
      final audio = FakeSlotAudio()..peak = 0.5;
      DeviceSlotAudio.current = audio;
      await pumpStack(tester);
      await settle(tester);
      expect(inDevice('0', 'device-meter'), findsOneWidget);
      expect(audio.reads, greaterThan(0));
      bool lit() => (tester.widget<AnimatedContainer>(find.descendant(of: inDevice('0', 'device-clip'),
          matching: find.byType(AnimatedContainer))).decoration as BoxDecoration).boxShadow != null;
      expect(lit(), isFalse);
      audio.peak = 1.2;
      await settle(tester);
      audio.peak = 0.1;
      await settle(tester);
      expect(lit(), isTrue, reason: 'it stays lit after the peak');
      await tester.tap(inDevice('0', 'device-clip'));
      await settle(tester);
      expect(lit(), isFalse);
      // The ear: off, then on with its trim shown.
      expect(inDevice('0', 'device-autogain-trim'), findsNothing);
      await tester.tap(inDevice('0', 'device-autogain'));
      await settle(tester);
      expect(audio.autoGain(chorus()), isTrue);
      expect(tester.widget<Text>(inDevice('0', 'device-autogain-trim')).data, '−2.4 dB');
      // And from the ⋯ menu.
      await tester.tap(inDevice('0', 'device-more'));
      await settle(tester);
      await tester.tap(find.text('Auto gain'));
      await settle(tester);
      expect(audio.autoGain(chorus()), isFalse);
      await done(tester);
    });

    test('Settings › Sound keeps "Auto gain on new devices"', () {
      final a = Settings()..autoGainNewDevices = true;
      final b = Settings()..fromJson(jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
      expect(b.autoGainNewDevices, isTrue);
      expect(Settings().autoGainNewDevices, isFalse);
    });
  });

  testWidgets('a section can pin the mod-source strip at the bottom of the full editor', (tester) async {
    // A two-section test editor on a device with a mod matrix: one page pins the strip at the bottom, one doesn't.
    final t = DeviceTarget(s, 'a', DeviceTarget.instrumentSlot);
    final original = DeviceEditors.custom(flagshipComponentId, t.info)!;
    addTearDown(() => DeviceEditors.register(flagshipComponentId, original));
    DeviceEditors.register(flagshipComponentId, DeviceEditorEntry((target) => [
      DeviceSection('pinned', 'Pinned', Icons.tune, (_) => const SizedBox.expand(), stripAtBottom: true),
      DeviceSection('top', 'Top', Icons.tune, (_) => const SizedBox.expand()),
    ]));
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DeviceEditor(target: t, onClose: () {}))));
    await tester.pumpAndSettle();
    final bottom = find.byKey(const ValueKey('device-strip-bottom'));
    expect(find.descendant(of: bottom, matching: find.byKey(const ValueKey('mod-source-strip'))), findsOneWidget);
    expect(tester.getTopLeft(bottom).dy, greaterThan(600), reason: 'under the page');
    await tester.tap(find.byKey(const ValueKey('device-tab-top')));
    await tester.pumpAndSettle();
    expect(bottom, findsNothing, reason: 'other sections keep it on top');
    expect(find.byKey(const ValueKey('mod-source-strip')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('mod-source-strip'))).dy, lessThan(400));
    await done(tester);
  });

  group('preset preview', () {
    void userPresets() {
      final t = chorus();
      for (final (i, n) in ['Slow', 'Fast'].indexed) {
        t.set('rate', 0.2 + i);
        s.userPresets.put(UserPreset(id: s.userPresets.newId(), kind: UserPresetKind.device, name: n,
            device: s.captureDevice(t), modified: DateTime(2026, 11, 18)));
      }
      t.set('rate', 0.6);
      s.endUndoStep();
      s.history.reset(jsonEncode(s.project.toJson()));
    }

    testWidgets('a tapped preset plays live and the sheet stays; Cancel puts it back with no undo step', (tester) async {
      userPresets();
      await pumpStack(tester);
      await tester.tap(inDevice('0', 'fx-presets-0'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('preset-preview')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('preset-user-Fast')));
      await tester.pumpAndSettle();
      expect(chorus().value('rate'), closeTo(1.2, 1e-9));
      expect(find.byKey(const ValueKey('preset-browser')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('preset-user-Slow')));
      await tester.pumpAndSettle();
      expect(chorus().value('rate'), closeTo(0.2, 1e-9));
      await tester.tap(find.byKey(const ValueKey('preset-preview-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('preset-browser')), findsNothing);
      expect(chorus().value('rate'), closeTo(0.6, 1e-9));
      await tester.pump(const Duration(seconds: 1));
      expect(s.canUndo, isFalse, reason: 'a cancelled preview leaves no step');
      await done(tester);
    });

    testWidgets('OK keeps the preset as one undo step; the clip under the track is looped, then put back',
        (tester) async {
      userPresets();
      layer().clips.add(ClipDoc(id: 'c', patternId: 'x', startSteps: 32, lengthSteps: 16));
      await pumpStack(tester);
      await tester.tap(inDevice('0', 'fx-presets-0'));
      await tester.pumpAndSettle();
      expect(find.text('Loops the clip on Lead while you try presets'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('preset-preview')));
      await tester.pumpAndSettle();
      expect((s.project.loopRange, s.project.loopStartSteps, s.project.loopEndSteps), (true, 32, 48));
      await tester.tap(find.byKey(const ValueKey('preset-user-Fast')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('preset-user-Slow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('preset-preview-ok')));
      await tester.pumpAndSettle();
      expect(chorus().value('rate'), closeTo(0.2, 1e-9));
      expect((s.project.loopRange, s.project.loopStartSteps, s.project.loopEndSteps), (false, 0, 0));
      await tester.pump(const Duration(seconds: 1));
      expect(s.undo(), isTrue);
      expect(chorus().value('rate'), closeTo(0.6, 1e-9), reason: 'one step back to before the preview');
      await done(tester);
    });

    testWidgets('closing the browser with Preview on (a tap outside, Back) cancels it, outside any build',
        (tester) async {
      userPresets();
      await pumpStack(tester);
      for (final close in [() => tester.tapAt(const Offset(200, 20)), () => tester.binding.handlePopRoute()]) {
        await tester.tap(inDevice('0', 'fx-presets-0'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('preset-preview')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('preset-user-Fast')));
        await tester.pumpAndSettle();
        expect(chorus().value('rate'), closeTo(1.2, 1e-9));
        await close();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('preset-browser')), findsNothing);
        expect(chorus().value('rate'), closeTo(0.6, 1e-9));
      }
      await tester.pump(const Duration(seconds: 1));
      expect(s.canUndo, isFalse);
      await done(tester);
    });

    testWidgets('Cancel and OK put the playhead back where it was before the preview looped the clip',
        (tester) async {
      userPresets();
      layer().clips.add(ClipDoc(id: 'c', patternId: 'x', startSteps: 32, lengthSteps: 16));
      await pumpStack(tester);
      for (final end in ['preset-preview-cancel', 'preset-preview-ok']) {
        s.seekTo(5);
        await tester.tap(inDevice('0', 'fx-presets-0'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('preset-preview')));
        await tester.pumpAndSettle();
        expect(s.pausedStep, 32, reason: 'it plays from the clip');
        await tester.tap(find.byKey(ValueKey(end)));
        await tester.pumpAndSettle();
        expect(s.pausedStep, 5, reason: end);
      }
      await done(tester);
    });

    test('a preview and an automation take hold the history together: either can end first', () async {
      final t = chorus();
      // The take ends inside the preview.
      final p = PresetPreview.start(t);
      s.holdHistory(true);
      t.set('depth', 0.4);
      s.holdHistory(false);
      t.set('depth', 0.5);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(s.history.open, isTrue, reason: 'the preview still holds it');
      p.keep();
      expect(s.history.open, isFalse);
      // The preview ends inside the take.
      s.holdHistory(true);
      final q = PresetPreview.start(t);
      t.set('depth', 0.6);
      q.keep();
      t.set('depth', 0.7);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(s.history.open, isTrue, reason: 'the take still holds it');
      s.holdHistory(false);
      expect(s.history.open, isFalse);
      expect(s.undo(), isTrue);
      expect(t.value('depth'), closeTo(0.5, 1e-9), reason: 'the take and the preview inside it: one step');
    });
  });

  group('undo history (review)', () {
    test('decodes each snapshot once: a second look and a new step reuse what it read', () {
      final t = chorus();
      for (var i = 1; i <= 5; i++) {
        t.set('depth', i / 10);
        s.endUndoStep();
      }
      final first = deviceHistoryDecodes;
      expect(deviceHistory(t), hasLength(5));
      expect(deviceHistoryDecodes - first, 5);
      expect(deviceHistory(t), hasLength(5));
      expect(deviceHistoryDecodes - first, 5, reason: 'cached');
      t.set('depth', 0.9);
      s.endUndoStep();
      expect(deviceHistory(t), hasLength(6));
      expect(deviceHistoryDecodes - first, 6, reason: 'only the new step');
    });

    testWidgets('an edit still settling is its own step: "Before the last change" is before it', (tester) async {
      final t = chorus();
      await pumpStack(tester);
      await tester.tap(inDevice('0', 'device-more'));
      await tester.pumpAndSettle();
      t.set('depth', 0.3);
      s.endUndoStep();
      t.set('depth', 0.9);  // under 600 ms ago: the burst is still open
      await tester.tap(find.text('Undo history…'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.textContaining('1 step back'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('device-history-0')));
      await tester.pumpAndSettle();
      expect(t.value('depth'), closeTo(0.3, 1e-9));
      await done(tester);
    });

    test('a rack lists no change it did not have (its saved layout is not a knob)', () {
      addBuiltinEffect(s, layer(), 'org.caw.rack.fx');
      s.endUndoStep();
      final rack = DeviceTarget(s, 'a', layer().components.length - 1);
      chorus().set('depth', 0.4);
      s.endUndoStep();
      expect(deviceHistory(rack), isEmpty);
    });

    test('two of the same device swapped: the list stops at the move, not showing the other one\'s steps', () {
      chorus(0).set('depth', 0.2);
      s.endUndoStep();
      chorus(1).set('depth', 0.8);
      s.endUndoStep();
      s.moveNativeEffect(layer(), 1, 0);
      s.endUndoStep();
      expect(chorus(0).value('depth'), closeTo(0.8, 1e-9));
      expect(deviceHistory(chorus(0)), isEmpty, reason: 'its steps before the move are at the other slot');
      chorus(0).set('depth', 0.5);
      s.endUndoStep();
      final steps = deviceHistory(chorus(0));
      expect(steps, hasLength(1));
      expect(steps.single.values['depth'], closeTo(0.8, 1e-9));
    });
  });

  group('FX row state (review)', () {
    test('collapsing past the bound drops the oldest key instead of refusing', () {
      final a = Settings();
      for (var i = 0; i <= Settings.maxFxCollapsed; i++) {
        expect(a.setFxRowOpen('p', 'a/$i/x', false), isTrue);
      }
      expect(a.fxRowOpen('p', 'a/${Settings.maxFxCollapsed}/x'), isFalse);
      expect(a.fxRowOpen('p', 'a/0/x'), isTrue, reason: 'the oldest went');
      expect(a.fxCollapsed['p'], hasLength(Settings.maxFxCollapsed));
    });

    testWidgets('a removed device\'s key goes when the rows are next saved', (tester) async {
      await pumpStack(tester);
      await tester.tap(find.byKey(const ValueKey('fx-fold-1')));
      await tester.pumpAndSettle();
      s.removeNativeEffect(layer(), 1);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fx-fold-0')));
      await tester.pumpAndSettle();
      expect(s.settings.fxCollapsed['p'], {'a/0/${chorus().componentId}'});
      await done(tester);
    });
  });

  group('Flagship in the shell (review)', () {
    DeviceTarget synth() => DeviceTarget(s, 'a', DeviceTarget.instrumentSlot);

    test('⋯ › Randomize keeps what Flagship\'s Random patch keeps', () {
      final t = synth();
      final keep = ['volume', 'velocity', 'bend_range', 'voice_mode', 'glide', 'osc2_on', 'fx_dist_on', 'mod1_amt',
        'mod1_dst', 'mod2_src'];
      final before = {for (final id in keep) id: t.value(id)};
      randomizeDevice(t, 1, random: math.Random(5));
      expect({for (final id in keep) id: t.value(id)}, before);
      expect(t.value('flt1_cutoff'), isNot(2400), reason: 'the sound still moves');
    });

    test('⋯ › Reset on Flagship is its Init', () {
      final t = synth();
      t.use!.preset = 'Mono bass';
      t.set('osc1_level', 0.2);
      resetDevice(t);
      expect(t.value('osc1_level'), 0.7);
      expect(DevicePresets.label(t), 'Init');
    });

    test('a random patch and an oscillator paste are undo steps of their own', () {
      final t = synth();
      t.set('flt1_cutoff', 300);  // still settling
      randomizeFlagship(t, 1, random: math.Random(2));
      expect(s.undo(), isTrue);
      expect(t.value('flt1_cutoff'), 300, reason: 'only the random patch went');
      t.set('osc1_detune', 60);
      s.endUndoStep();
      copyOscillator(t, 1);
      t.set('osc2_level', 0.3);  // still settling
      expect(pasteOscillator(t, 2), isTrue);
      expect(s.undo(), isTrue);
      expect(t.value('osc2_level'), closeTo(0.3, 1e-9), reason: 'only the paste went');
      expect(t.value('osc2_detune'), isNot(60));
    });
  });

  group('knob and header (review)', () {
    testWidgets('React to…\'s Undo takes back the link only, not an edit made since', (tester) async {
      await pumpStack(tester);
      await tester.longPress(inDevice('0', 'dknob-depth'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('knob-menu-react')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kick'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Loudness'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      chorus(1).set('depth', 0.66);  // another edit inside the toast's 3 s
      await tester.pump();
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await tester.pumpAndSettle();
      expect(s.project.modLinks, isEmpty);
      expect(s.project.modulators, isEmpty, reason: 'it was made for the link');
      expect(chorus(1).value('depth'), closeTo(0.66, 1e-9), reason: 'the later edit stays');
      await done(tester);
    });

    testWidgets('A/B and the folded row\'s preset name follow changes made elsewhere', (tester) async {
      final t = chorus();
      DeviceAB.select(t, false);  // the switch's state is app-wide: an earlier test may have left B on
      t.set('rate', 1.4);
      s.userPresets.put(UserPreset(id: 'u1', kind: UserPresetKind.device, name: 'Wide',
          device: s.captureDevice(t), modified: DateTime(2026, 11, 18)));
      await pumpStack(tester);
      Color? sideColor(String side) => (tester.widget<AnimatedContainer>(find.descendant(
          of: inDevice('0', 'device-ab-$side'), matching: find.byType(AnimatedContainer))).decoration as BoxDecoration).color;
      expect(sideColor('b'), Colors.transparent);
      DeviceAB.select(t, true);  // as from the full editor's header
      await tester.pump();
      expect(sideColor('b'), isNot(Colors.transparent));
      DeviceAB.select(t, false);
      await tester.tap(find.byKey(const ValueKey('fx-fold-0')));
      await tester.pumpAndSettle();
      DevicePresets.apply(t, DevicePresets.user(t).single);
      await tester.pump();
      expect(find.descendant(of: find.byKey(const ValueKey('fx-row-0')), matching: find.text('Wide')), findsOneWidget);
      s.userPresets.rename('u1', 'Wider');  // the library, from another view
      await tester.pump();
      expect(find.descendant(of: find.byKey(const ValueKey('fx-row-0')), matching: find.text('Wider')), findsOneWidget);
      await done(tester);
    });
  });
}
