// The FX tab's inline plugin UIs: built-ins show theirs and others the knob card, inline controls edit, ⤢ opens full
// screen, off-screen devices neither animate nor poll, and goldens of the starter's Pad track at phone and landscape size.
import 'package:caw/engine/component_info.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/mod_matrix.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/devices/device_inline.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

/// A third-party component with no plugin UI of its own.
const _fuzz = NativeComponentInfo(id: 'com.example.fuzz', name: 'Fuzz', role: 'effect', ports: [
  ComponentPortInfo(id: 'in', type: 'audio', input: true, layout: 'stereo', channels: 2),
  ComponentPortInfo(id: 'out', type: 'audio', input: false, layout: 'stereo', channels: 2),
], parameters: [
  ComponentParameterInfo(id: 'gain', name: 'Gain', defaultValue: 0.5, min: 0, max: 1),
]);

/// Counts who listens to each device's frames, as the engine's poller would (it polls only while someone listens).
class CountingDisplay extends DeviceDisplaySource {
  final Map<String, CountedNotifier> polls = {};
  @override
  ValueListenable<DeviceDisplayFrame?> frames(DeviceTarget target) =>
      polls.putIfAbsent('${target.componentId}', CountedNotifier.new);
  int listeners(String id) => polls[id]?.count ?? 0;
}

class CountedNotifier extends ValueNotifier<DeviceDisplayFrame?> {
  CountedNotifier() : super(null);
  int count = 0;
  @override
  void addListener(VoidCallback l) {
    count++;
    super.addListener(l);
  }

  @override
  void removeListener(VoidCallback l) {
    count--;
    super.removeListener(l);
  }
}

void main() {
  var motion = MotionLevel.full;
  late DeviceDisplaySource source;
  late AppState s;

  setUp(() {
    motion = Motion.setting;
    source = DeviceDisplaySource.current;
    DeviceDisplaySource.current = DeviceDisplaySource.none;
    s = AppState(settings: Settings());
    Motion.setting = MotionLevel.off;
    s.project = ProjectDoc(id: 'p', name: 'Devices', bpm: 120, modules: [], layers: [LayerDoc(id: 'a', name: 'Pad', color: 2)]);
    s.componentCatalog.set([...builtinInfos(), _fuzz]);
    s.setNativeInstrument(s.project.layers.first, 'org.caw.synth.flagship');
    s.addNativeEffect(s.project.layers.first, 'org.caw.chorus');
  });
  tearDown(() {
    Motion.setting = motion;
    DeviceDisplaySource.current = source;
    s.dispose();
  });

  LayerDoc layer() => s.project.layers.first;

  Future<void> pumpStack(WidgetTester tester, {Size size = const Size(390, 844)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(height: size.height,
        child: ListenableBuilder(listenable: s, builder: (_, _) => FxStack(state: s, layer: layer()))))));
    await tester.pump();
  }

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('built-ins show their plugin UI inline; a component without one keeps the knob card', (tester) async {
    s.project.layers.first.components.add(ComponentUseDoc('com.example.fuzz'));
    await pumpStack(tester, size: const Size(390, 2400));
    expect(find.byKey(const ValueKey('fx-inline-instrument')), findsOneWidget);
    expect(find.byKey(const ValueKey('flagship-inline')), findsOneWidget);
    expect(find.byKey(const ValueKey('fx-inline-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('fx-page-chorus')), findsOneWidget);
    // The fuzz has no UI: its knob card, with its knob.
    expect(find.byKey(const ValueKey('fx-inline-1')), findsNothing);
    expect(find.byKey(const ValueKey('knob-com.example.fuzz-gain')), findsOneWidget);
    // The stack's actions stay on the inline header.
    for (final k in ['fx-instrument-open', 'fx-instrument-bypass', 'fx-open-0', 'fx-bypass-0', 'fx-presets-instrument',
        'fx-presets-0']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2), reason: 'both effects reorder by drag');
    await tester.tap(find.byKey(const ValueKey('fx-bypass-0')));
    await tester.pump();
    expect(layer().components.first.bypass, isTrue);
    await tester.tap(find.byTooltip('Remove Chorus'));
    await tester.pump();
    expect(layer().components.map((c) => c.id), ['com.example.fuzz']);
    expect(tester.takeException(), isNull);
    await done(tester);
  });

  for (final width in [390.0, 560.0, 1000.0]) {
    testWidgets('every built-in lays out inline at ${width.round()} dp wide', (tester) async {
      for (final inst in builtinInstruments) {
        s.setNativeInstrument(layer(), inst);
        layer().components.clear();
        for (final id in builtinEffects) {
          s.addNativeEffect(layer(), id);
        }
        await pumpStack(tester, size: Size(width, 9000));
        expect(find.byType(DeviceInline), findsNWidgets(builtinEffects.length + 1), reason: inst);
        expect(tester.takeException(), isNull, reason: '$inst at $width');
      }
      await done(tester);
    });
  }

  testWidgets('inline controls edit the device: the chorus pad and knobs, the flagship\'s chips and knobs', (tester) async {
    await pumpStack(tester, size: const Size(390, 1600));
    // The chorus: a knob up, then the pad across.
    final rate = find.descendant(of: find.byKey(const ValueKey('fx-inline-0')), matching: find.byKey(const ValueKey('dknob-rate')));
    final before = layer().components.first.params['rate'] ?? builtinInfo('org.caw.chorus').parameters
        .firstWhere((p) => p.id == 'rate').defaultValue;
    await tester.drag(rate, const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(layer().components.first.params['rate'], greaterThan(before));
    // The flagship: OSC 1's level knob, then FILTER's cutoff, then the AMP page's attack.
    final level = find.byKey(const ValueKey('dknob-osc1_level'));
    await tester.drag(level, const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(layer().instrument!.params['osc1_level'], lessThan(0.7));
    await tester.tap(find.byKey(const ValueKey('flagship-inline-pick-4')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('flagship-inline-filter')), findsOneWidget);
    await tester.drag(find.byKey(const ValueKey('dknob-flt1_cutoff')), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(layer().instrument!.params['flt1_cutoff'], greaterThan(2400));
    await tester.tap(find.byKey(const ValueKey('flagship-inline-pick-5')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('flagship-inline-amp')), findsOneWidget);
    await tester.drag(find.byKey(const ValueKey('dknob-env1_attack')), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(layer().instrument!.params['env1_attack'], greaterThan(0.01));
    expect(tester.takeException(), isNull);
    await done(tester);
  });

  testWidgets('inline covers modulation as the full editor does: assign mode, the Modulation sheet, the MOD section',
      (tester) async {
    await pumpStack(tester, size: const Size(390, 1600));
    final inst = find.byKey(const ValueKey('fx-inline-instrument'));
    Finder inInst(String key) => find.descendant(of: inst, matching: find.byKey(ValueKey(key)));
    expect(inInst('mod-source-strip'), findsOneWidget);
    // Assign mode: ENV 3 onto OSC 1's level.
    await tester.tap(inInst('modsrc-env3'));
    await tester.pumpAndSettle();
    expect(inInst('mod-assign-banner'), findsOneWidget);
    await tester.tap(inInst('dknob-osc1_level'));
    await tester.pumpAndSettle();
    await tester.tap(inInst('mod-assign-done'));
    await tester.pumpAndSettle();
    final m = ModMatrix(DeviceTarget(s, layer().id, DeviceTarget.instrumentSlot));
    final r = m.routeOf(ModSource.env3, 'osc1_level')!;
    // The knob's Modulation sheet, a bottom sheet over the stack (no new page): its slider moves the amount.
    await tester.longPress(inInst('dknob-osc1_level'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mod-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-editor')), findsNothing);
    final before = layer().instrument!.params['mod${r.slot}_amt']!;
    await tester.drag(find.byKey(ValueKey('modamount-${r.slot}')), const Offset(90, 0));
    await tester.pumpAndSettle();
    expect(layer().instrument!.params['mod${r.slot}_amt'], greaterThan(before));
    await tester.tapAt(const Offset(10, 10)); // closes the sheet
    await tester.pumpAndSettle();
    // The MOD section: one source's shape and the routes it makes, editable here.
    await tester.tap(inInst('flagship-inline-pick-6'));
    await tester.pumpAndSettle();
    expect(inInst('flagship-inline-mod'), findsOneWidget);
    await tester.tap(inInst('flagship-inline-src-env3'));
    await tester.pumpAndSettle();
    expect(inInst('modroute-${r.slot}'), findsOneWidget);
    // The full editor's MATRIX shows the same route.
    await tester.tap(find.byKey(const ValueKey('fx-instrument-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('device-tab-matrix')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('modroute-${r.slot}')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await done(tester);
  });

  testWidgets('⤢ and the name open the device full screen on a phone', (tester) async {
    await pumpStack(tester);
    await tester.tap(find.byKey(const ValueKey('fx-instrument-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-editor')), findsOneWidget);
    expect(find.byKey(const ValueKey('flagship-synth')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('device-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-editor')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('fx-native-title-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-editor')), findsOneWidget);
    expect(find.byKey(const ValueKey('fx-page-chorus')), findsOneWidget);
    await done(tester);
  });

  testWidgets('a device scrolled off screen neither animates nor polls; scrolled back, it does again', (tester) async {
    final display = CountingDisplay();
    DeviceDisplaySource.current = display;
    Motion.setting = MotionLevel.full;
    for (final id in ['org.caw.eq', 'org.caw.compressor', 'org.caw.reverb.pro', 'org.caw.delay.pro']) {
      s.addNativeEffect(layer(), id);
    }
    await pumpStack(tester);
    await tester.pump(const Duration(milliseconds: 100));
    bool onScreen(String key) => tester.state<OnScreenGateState>(find.descendant(
        of: find.byKey(ValueKey(key)), matching: find.byType(OnScreenGate), matchRoot: true).first).visible;
    TickerMode? ticker(String key) => tester.widget<TickerMode>(find.ancestor(
        of: find.byKey(ValueKey(key)), matching: find.byType(TickerMode)).first);
    // The flagship is at the top; the delay, last, is far below a phone's screen.
    expect(onScreen('fx-device-instrument'), isTrue);
    expect(onScreen('fx-device-4'), isFalse);
    expect(ticker('fx-inline-4')!.enabled, isFalse, reason: 'its motion stands still');
    expect(display.listeners('org.caw.delay.pro'), 0, reason: 'nothing polls it');
    expect(display.listeners('org.caw.chorus'), greaterThanOrEqualTo(0));
    // Scrolled to the end: the delay runs and polls; the flagship stops.
    final outer = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    outer.jumpTo(2400);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(onScreen('fx-device-4'), isTrue);
    expect(ticker('fx-inline-4')!.enabled, isTrue);
    expect(display.listeners('org.caw.delay.pro'), greaterThan(0));
    // The flagship, far above: the list let it go, or it stands still.
    final flagship = find.byKey(const ValueKey('fx-device-instrument'));
    if (flagship.evaluate().isNotEmpty) expect(onScreen('fx-device-instrument'), isFalse);
    expect(display.listeners('org.caw.synth.flagship'), 0);
    // And back to the top: the flagship runs again, the delay stops.
    outer.jumpTo(0);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(onScreen('fx-device-instrument'), isTrue);
    expect(ticker('fx-inline-instrument')!.enabled, isTrue);
    expect(onScreen('fx-device-4'), isFalse);
    expect(display.listeners('org.caw.delay.pro'), 0);
    Motion.setting = MotionLevel.off;
    await done(tester);
  });

  group('goldens: the starter\'s Pad track on the FX tab', () {
    for (final name in ['phone', 'landscape']) {
      testWidgets(name, (tester) async {
        final st = AppState();
        Motion.setting = MotionLevel.off;
        st.project = st.starterProject();
        st.componentCatalog.set(builtinInfos());
        st.selectedModuleId = st.project.modules.first.id;
        st.ready = true;
        st.starting = false;
        final pad = st.project.layers.firstWhere((l) => l.name == 'Pad');
        expect(pad.instrument!.id, 'org.caw.synth.flagship');
        expect(pad.components.map((c) => c.id), ['org.caw.chorus']);
        await pumpGolden(tester, Shell(state: st), goldenSizes[name]!);
        SectionController.of(tester.element(find.byType(Scaffold).first)).focusLayer(pad.id);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('flagship-inline')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(goldenScreen, matchesGoldenFile('goldens/fx_inline_$name.png'));
        // The heroes take drags, so scroll the stack itself (its thumb or a header would do it by hand).
        final list = tester.state<ScrollableState>(find.descendant(
            of: find.byKey(const ValueKey('fx-stack-list')), matching: find.byType(Scrollable), matchRoot: true).first).position;
        if (name == 'landscape') {
          // A short panel: scrolled to the flagship's own header, the whole device shows (hero beside the knobs).
          await Scrollable.ensureVisible(tester.element(find.byKey(const ValueKey('fx-inline-instrument'))));
          await tester.pumpAndSettle();
          await expectLater(goldenScreen, matchesGoldenFile('goldens/fx_inline_landscape_device.png'));
        }
        // The chorus follows the flagship, inline too.
        list.jumpTo(list.maxScrollExtent);
        await tester.pumpAndSettle();
        list.jumpTo(list.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('fx-inline-0')), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('dknob-rate')));
        await tester.pumpAndSettle();
        await tester.drag(find.byKey(const ValueKey('dknob-rate')), const Offset(0, -40));
        await tester.pumpAndSettle();
        expect(pad.components.first.params['rate'], isNotNull, reason: 'the inline knob edits the chorus');
        list.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('fx-instrument-open')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('device-editor')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        st.dispose();
      });
    }
  });
}
