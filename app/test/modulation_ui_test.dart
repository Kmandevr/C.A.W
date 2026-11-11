// Project modulation's UI (#161): a modulator's card, assign by tap and by drag onto any device's knob, rings, drawing an
// LFO's shape and steps, the link sheet, and the routing view's chips.
import 'package:caw/model/app_state.dart';
import 'package:caw/model/mod_matrix.dart';
import 'package:caw/model/modulation.dart';
import 'package:caw/ui/devices/device_controls.dart';
import 'package:caw/ui/devices/device_scope.dart';
import 'package:caw/ui/devices/modulators/modulator_devices.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/routing_view.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

/// A track with a filter, its Modulators lane, and the filter's cutoff knob under it.
Future<AppState> _pump(WidgetTester tester, String kind) async {
  Motion.setting = MotionLevel.off;
  final s = stateWith('org.caw.filter');
  s.addModulator(kind, layerId: 'a');
  final layer = s.project.layers.first;
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [
    ModulatorsSection(state: s, layer: layer),
    DeviceScope(
      target: targetOf(s, 'org.caw.filter'), matrix: null, dragging: ValueNotifier<ModSource?>(null), accent: Neon.blue,
      focusSource: ValueNotifier(ModSource.none),
      child: const Center(child: DeviceKnob('cutoff', size: 50))),
  ]))));
  await tester.pumpAndSettle();
  return s;
}

Future<void> _end(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));  // the project's save and undo timers
  await tester.binding.setSurfaceSize(null);
}

const _cutoff = ModTarget.component('a', 0, 'cutoff');

void main() {
  tearDown(() => Motion.setting = MotionLevel.full);

  testWidgets('tap an output, then tap a knob: a link; tap again: gone', (tester) async {
    final s = await _pump(tester, ModulatorKinds.lfo);
    final id = s.project.modulators.single.id;
    await tester.tap(find.byKey(ValueKey('modout-$id-0')));
    await tester.pump();
    expect(s.assigningModulation.value, ModSourceRef(id, 0));
    expect(find.text('Tap knobs for LFO to move'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dknob-cutoff')));
    await tester.pump();
    expect(s.project.linksTo(_cutoff).single.source, id);
    expect(find.byKey(const ValueKey('dknob-badge-cutoff')), findsOneWidget);
    // The link shows on the modulator's card, with its amount.
    expect(find.byKey(ValueKey('modlink-${s.project.modLinks.single.id}')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dknob-cutoff')));
    await tester.pump();
    expect(s.project.modLinks, isEmpty);
    await tester.tap(find.byKey(const ValueKey('modulators-assign-done')));
    await tester.pump();
    expect(s.assigningModulation.value, isNull);
    await _end(tester);
  });

  testWidgets('hold an output and drop it on a knob: a link, its ring drag sets the amount', (tester) async {
    final s = await _pump(tester, ModulatorKinds.macros);
    final id = s.project.modulators.single.id;
    final chip = tester.getCenter(find.byKey(ValueKey('modout-$id-2')));
    final knob = tester.getCenter(find.byKey(const ValueKey('dknob-cutoff')));
    final g = await tester.startGesture(chip);
    await tester.pump(const Duration(milliseconds: 400));
    await g.moveTo(chip + const Offset(0, 30));
    await tester.pump();
    await g.moveTo(knob);
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    final link = s.project.linksTo(_cutoff).single;
    expect(link.output, 2);
    expect(link.bipolar, isFalse);  // macros move one way
    // A drag starting on the knob's rim sets the link's amount, not the knob.
    final before = s.project.layers.first.components.first.params['cutoff'];
    final box = tester.getRect(find.byKey(const ValueKey('dknob-cutoff')));
    await tester.dragFrom(Offset(box.center.dx, box.top + 6), const Offset(0, -40));
    await tester.pumpAndSettle();
    expect(s.modLink(link.id)!.amount, greaterThan(0.25));
    expect(s.project.layers.first.components.first.params['cutoff'], before);
    await _end(tester);
  });

  testWidgets('draw an LFO: it turns Custom and takes the points; steps take their bars', (tester) async {
    final s = await _pump(tester, ModulatorKinds.lfo);
    final m = s.project.modulators.single;
    final draw = tester.getRect(find.byKey(const ValueKey('lfo-draw')));
    await tester.dragFrom(draw.topLeft + const Offset(4, 4), Offset(draw.width * 0.3, 0));
    await tester.pumpAndSettle();
    expect(m.params['shape'], 7);
    expect([for (var i = 1; i <= 16; i++) m.params['p$i']!].where((v) => v > 0.9).length, greaterThan(2), reason: '${m.params} ${draw.width}');

    s.addModulator(ModulatorKinds.steps, layerId: 'a');
    await tester.pumpAndSettle();
    final steps = s.project.modulators.last;
    final bars = tester.getRect(find.byKey(const ValueKey('steps-draw')));
    await tester.tapAt(Offset(bars.left + bars.width / 32, bars.bottom - 2));
    await tester.pumpAndSettle();
    expect(steps.params['s1']!, lessThan(0.1));
    await _end(tester);
  });

  testWidgets('the link sheet and the routing view show the link', (tester) async {
    final s = await _pump(tester, ModulatorKinds.random);
    final id = s.project.modulators.single.id;
    s.addModLink(ModSourceRef(id, 0), _cutoff);
    s.addModLink(ModSourceRef(id, 0), const ModTarget.volume('a'));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('dknob-cutoff')));
    await tester.pumpAndSettle();
    expect(find.textContaining('MODULATION · Track'), findsOneWidget);
    final link = s.project.linksTo(_cutoff).single;
    await tester.tap(find.byKey(ValueKey('modlink-polarity-${link.id}')).last);
    await tester.pumpAndSettle();
    expect(s.modLink(link.id)!.bipolar, isFalse);  // random starts both ways; one tap makes it one way
    await tester.tap(find.byKey(ValueKey('modlink-remove-${link.id}')).last);
    await tester.pumpAndSettle();
    expect(s.project.linksTo(_cutoff), isEmpty);
    Navigator.of(tester.element(find.byType(ListView).first)).pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RoutingView(state: s))));
    await tester.pumpAndSettle();
    expect(find.text('Random → Volume'), findsOneWidget);
    await _end(tester);
  });

  testWidgets('golden: a track\'s Modulators lane and a knob with two links (for the owner\'s look)', (tester) async {
    Motion.setting = MotionLevel.off;
    final s = stateWith('org.caw.filter');
    final lfo = s.addModulator(ModulatorKinds.lfo, layerId: 'a')!;
    final steps = s.addModulator(ModulatorKinds.steps, layerId: 'a')!;
    s.addModulator(ModulatorKinds.macros, layerId: 'a');
    s.addModLink(ModSourceRef(lfo.id, 0), _cutoff, amount: 0.3);
    s.addModLink(ModSourceRef(steps.id, 0), _cutoff, amount: -0.2);
    await pumpGolden(tester, Scaffold(body: ListView(padding: const EdgeInsets.all(8), children: [
      DeviceScope(
        target: targetOf(s, 'org.caw.filter'), matrix: null, dragging: ValueNotifier<ModSource?>(null), accent: Neon.green,
        focusSource: ValueNotifier(ModSource.none),
        child: const Center(child: DeviceKnob('cutoff', size: 56))),
      ModulatorsSection(state: s, layer: s.project.layers.first),
    ])), const Size(390, 1600));
    await expectLater(goldenScreen, matchesGoldenFile('goldens/modulators_lane_phone.png'));
    await _end(tester);
  });
}
