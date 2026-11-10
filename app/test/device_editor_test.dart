// Device editors: opening from the FX stack, tabs, the envelope's handles, mod sources dropped on knobs, the fallback
// page, undo, the mod matrix and shape maths, goldens of the flagship editor, and the fixture against the engine.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/component_info.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/flagship_shapes.dart';
import 'package:caw/model/mod_matrix.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/arrange/knob.dart' show Taper;
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/flagship/flagship_editor.dart' show flagshipComponentId;
import 'package:caw/ui/devices/visuals/envelope_view.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'flagship_fixture.dart';
import 'golden_util.dart';

const _unknown = NativeComponentInfo(id: 'local.fuzz.cpp1', name: 'Fuzz', role: 'effect', ports: [
  ComponentPortInfo(id: 'in', type: 'audio', input: true, layout: 'stereo', channels: 2),
  ComponentPortInfo(id: 'out', type: 'audio', input: false, layout: 'stereo', channels: 2),
], parameters: [
  ComponentParameterInfo(id: 'gain', name: 'Gain', defaultValue: 0.5, min: 0, max: 1),
]);

ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Devices', bpm: 120, modules: [], layers: [
      LayerDoc(id: 'a', name: 'Lead', color: 0),
    ]);

/// A widget test that lets the project's history timer run out before the tree goes.
void wtest(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 1));
    });

void main() {
  late AppState s;
  late LayerDoc layer;
  final flagship = flagshipFixture();
  var motion = MotionLevel.full;

  setUp(() {
    motion = Motion.setting;
    s = AppState(settings: Settings());
    Motion.setting = MotionLevel.off; // the LFO dot runs on a ticker; settled pumps need it still
    s.project = _project();
    s.componentCatalog.set([flagship, _unknown]);
    layer = s.project.layers.first;
    s.setNativeInstrument(layer, flagshipComponentId);
    s.addNativeEffect(layer, 'local.fuzz.cpp1');
  });
  tearDown(() {
    Motion.setting = motion;
    s.dispose();
  });

  DeviceTarget synth() => DeviceTarget(s, 'a', DeviceTarget.instrumentSlot);

  Future<void> pumpStack(WidgetTester tester, {Size size = const Size(412, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(height: size.height,
        child: ListenableBuilder(listenable: s, builder: (_, _) => FxStack(state: s, layer: s.project.layers.first))))));
    await tester.pump();
  }

  Future<void> openSynth(WidgetTester tester) async {
    await pumpStack(tester);
    await tester.tap(find.byKey(const ValueKey('fx-instrument-open')));
    await tester.pumpAndSettle();
  }

  group('framework', () {
    wtest('the FX stack opens the instrument\'s editor full screen on a phone; close returns', (tester) async {
      await openSynth(tester);
      expect(find.byKey(const ValueKey('device-editor')), findsOneWidget);
      expect(find.text('Flagship'), findsWidgets);
      expect(find.byKey(const ValueKey('flagship-osc')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('device-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('device-editor')), findsNothing);
      // The title opens it too (a built-in has no source to open).
      await tester.tap(find.byKey(const ValueKey('fx-instrument-title')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('device-editor')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    wtest('a wide screen gets a floating window', (tester) async {
      await pumpStack(tester, size: const Size(1280, 800));
      await tester.tap(find.byKey(const ValueKey('fx-instrument-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('device-editor')), findsOneWidget);
      expect(find.byType(GlassOverlay), findsWidgets);
      expect(find.byIcon(Icons.close), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    wtest('tabs switch between OSC, FILTER, MOD and FX', (tester) async {
      await openSynth(tester);
      for (final (tab, page) in [('filter', 'flagship-filter'), ('mod', 'flagship-mod'), ('fx', 'flagship-fx'),
          ('osc', 'flagship-osc')]) {
        await tester.tap(find.byKey(ValueKey('device-tab-$tab')));
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey(page)), findsOneWidget, reason: tab);
      }
      expect(tester.takeException(), isNull);
    });

    wtest('an unknown component gets the fallback knob page', (tester) async {
      s.setNativeInstrument(s.project.layers.first, null); // the synth's card is long: the effect's comes first now
      await pumpStack(tester);
      expect(DeviceEditors.custom('local.fuzz.cpp1', _unknown), isNull);
      await tester.tap(find.byKey(const ValueKey('fx-open-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('device-fallback')), findsOneWidget);
      final knob = find.byKey(const ValueKey('knob-local.fuzz.cpp1-gain'));
      expect(knob, findsOneWidget);
      await tester.drag(knob, const Offset(0, -50));
      await tester.pumpAndSettle();
      expect(s.project.layers.first.components.first.params['gain'], greaterThan(0.5));
      expect(find.byKey(const ValueKey('device-tab-controls')), findsNothing, reason: 'one page needs no tabs');
    });

    wtest('bypass in the header bypasses the device; a knob edit undoes as one step', (tester) async {
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
      await openSynth(tester);
      await tester.tap(find.byKey(const ValueKey('device-bypass')));
      await tester.pumpAndSettle();
      expect(s.project.layers.first.instrument!.bypass, isTrue);
      await tester.tap(find.byKey(const ValueKey('device-bypass')));
      await tester.pump(const Duration(seconds: 1));
      final before = synth().value('osc1_level');
      await tester.drag(find.byKey(const ValueKey('dknob-osc1_level')), const Offset(0, -40));
      await tester.pump(const Duration(seconds: 1));
      expect(synth().value('osc1_level'), greaterThan(before));
      s.undo();
      await tester.pumpAndSettle();
      expect(synth().value('osc1_level'), closeTo(before, 1e-9), reason: 'the editor follows the restored project');
      expect(find.byKey(const ValueKey('device-editor')), findsOneWidget);
    });

    wtest('double-tap on a knob resets it', (tester) async {
      await openSynth(tester);
      synth().set('osc1_level', 0.2);
      await tester.pump();
      final knob = find.byKey(const ValueKey('dknob-osc1_level'));
      await tester.tap(knob);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(knob);
      await tester.pumpAndSettle();
      expect(synth().value('osc1_level'), 0.7);
    });
  });

  group('flagship', () {
    wtest('dragging the attack handle changes env 1\'s attack', (tester) async {
      await openSynth(tester);
      await tester.tap(find.byKey(const ValueKey('device-tab-mod')));
      await tester.pumpAndSettle();
      final view = find.byKey(const ValueKey('env-env1_'));
      expect(view, findsOneWidget);
      final rect = tester.getRect(view);
      final t = synth();
      Taper taper(String id) => Taper(t.param(id)!.min, t.param(id)!.max, exponential: true);
      final g = EnvelopeGeometry(rect.size, taper('env1_attack').position(t.value('env1_attack')),
          taper('env1_decay').position(t.value('env1_decay')), t.value('env1_sustain'),
          taper('env1_release').position(t.value('env1_release')));
      final before = t.value('env1_attack');
      await tester.dragFrom(rect.topLeft + g.attack, const Offset(40, 0));
      await tester.pumpAndSettle();
      expect(t.value('env1_attack'), greaterThan(before));
      // The decay handle sets the sustain level too: dragging it down lowers it.
      final sus = t.value('env1_sustain');
      final g2 = EnvelopeGeometry(rect.size, taper('env1_attack').position(t.value('env1_attack')),
          taper('env1_decay').position(t.value('env1_decay')), sus, taper('env1_release').position(t.value('env1_release')));
      await tester.dragFrom(rect.topLeft + g2.decay, const Offset(0, 20));
      await tester.pumpAndSettle();
      expect(t.value('env1_sustain'), lessThan(sus));
    });

    wtest('dropping a source chip on a knob creates a route in the mod parameters', (tester) async {
      await openSynth(tester);
      final m = ModMatrix(synth());
      expect(m.routes.length, 1, reason: 'slot 1 starts as env 2 to filter 1');
      final chip = tester.getCenter(find.byKey(const ValueKey('modsrc-lfo1')));
      final knob = tester.getCenter(find.byKey(const ValueKey('dknob-osc1_level')));
      final g = await tester.startGesture(chip);
      await tester.pump();
      await g.moveBy(const Offset(0, 20));
      await tester.pump();
      await g.moveTo(knob);
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      final routes = ModMatrix(synth()).routesTo('osc1_level');
      expect(routes, hasLength(1));
      expect(routes.single.source, ModSource.lfo1);
      expect(routes.single.bipolar, isTrue, reason: 'an LFO swings both ways');
      final slot = routes.single.slot;
      expect(synth().value('mod${slot}_src'), ModSource.lfo1.value);
      expect(synth().value('mod${slot}_dst'), flagship.parameters.indexWhere((p) => p.id == 'osc1_level') + 1);
      expect(synth().value('mod${slot}_amt'), 0.25);
      // The ring: a drag starting on the knob's outer edge sets the route's amount, not the knob.
      final level = synth().value('osc1_level');
      final r = tester.getRect(find.byKey(const ValueKey('dknob-osc1_level')));
      await tester.dragFrom(Offset(r.center.dx, r.top + 2), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(synth().value('mod${slot}_amt'), greaterThan(0.25));
      expect(synth().value('osc1_level'), level);
      // The MOD page lists it and removes it.
      await tester.tap(find.byKey(const ValueKey('device-tab-mod')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(ValueKey('modroute-remove-$slot')), 100,
          scrollable: find.descendant(of: find.byKey(const ValueKey('flagship-mod')), matching: find.byType(Scrollable)).first);
      await tester.tap(find.byKey(ValueKey('modroute-remove-$slot')));
      await tester.pumpAndSettle();
      expect(ModMatrix(synth()).routesTo('osc1_level'), isEmpty);
      expect(synth().value('mod${slot}_src'), 0);
    });

    wtest('a source chip on another tab opens its MOD page', (tester) async {
      await openSynth(tester);
      await tester.tap(find.byKey(const ValueKey('modsrc-lfo1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('flagship-mod')), findsOneWidget);
      expect(find.byKey(const ValueKey('lfo-lfo1_rate')), findsOneWidget);
    });

    wtest('the oscillator picker and the filter curve edit their parameters', (tester) async {
      await openSynth(tester);
      await tester.tap(find.byKey(const ValueKey('osc-pick-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('osc-2')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dpower-osc2_on')));
      await tester.pumpAndSettle();
      expect(synth().value('osc2_on'), 1);
      await tester.tap(find.byKey(const ValueKey('device-tab-filter')));
      await tester.pumpAndSettle();
      final before = synth().value('flt1_cutoff');
      await tester.drag(find.byKey(const ValueKey('filter-flt1_')), const Offset(60, -30));
      await tester.pumpAndSettle();
      expect(synth().value('flt1_cutoff'), greaterThan(before));
      expect(synth().value('flt1_resonance'), greaterThan(0.15));
    });
  });

  group('models', () {
    test('the mod matrix reads, adds, refuses and removes routes', () {
      final m = ModMatrix(synth());
      expect(m.slotCount, 16);
      expect(m.destinations.length, 127, reason: 'every parameter before the slots');
      expect(m.routes.single.paramId, 'flt1_cutoff');
      expect(m.add(ModSource.env3, 'mod2_amt'), isNull, reason: 'a slot is not a destination');
      final a = m.add(ModSource.env3, 'osc2_pan')!;
      expect(m.add(ModSource.env3, 'osc2_pan'), a, reason: 'the same pair is one route');
      expect(ModMatrix(synth()).routesTo('osc2_pan').single.bipolar, isFalse);
      m.remove(a);
      expect(ModMatrix(synth()).routesTo('osc2_pan'), isEmpty);
      for (var i = 0; i < 15; i++) {
        expect(ModMatrix(synth()).add(ModSource.lfo3, m.destinations[i + 2]), isNotNull);
      }
      expect(ModMatrix(synth()).add(ModSource.lfo3, 'volume'), isNull, reason: 'all 16 in use');
    });

    test('the route span is clamped and bipolar spans both ways', () {
      const r = ModRoute(slot: 1, source: ModSource.lfo1, paramId: 'x', amount: 0.3, bipolar: true);
      expect(r.span(0.5), (0.2, 0.8));
      const u = ModRoute(slot: 1, source: ModSource.env1, paramId: 'x', amount: 0.8, bipolar: false);
      expect(u.span(0.5), (0.5, 1.0));
    });

    test('the unison layout matches the engine\'s rules', () {
      final c = unisonLayout(7, 0.25, 0, 0.8, 0.5, 0);
      expect(c.first.semitones, closeTo(-0.25, 1e-12));
      expect(c.last.semitones, closeTo(0.25, 1e-12));
      expect(c[3].pan, 0);
      expect(c.fold<double>(0, (s, x) => s + x.gain * x.gain), closeTo(1, 1e-9));
      expect(unisonLayout(7, 0.25, 0, 0, 0.5, 0).every((x) => x.pan == 0), isTrue, reason: 'spread 0 is mono');
      expect(c.first.pan, -c.last.pan, reason: 'mirror pairs on opposite sides');
    });

    test('wavetable frames: the Basic table\'s sine and saw, and warps keep the phase in range', () {
      final sine = wavetableFrame(0, 0, points: 64);
      expect(sine[16], closeTo(1, 1e-6));
      expect(sine[0], closeTo(0, 1e-6));
      final saw = oscillatorCycle(0, 1 / 3, Warp.none, 0, points: 64);
      expect(saw[32].abs(), lessThan(0.05), reason: 'a saw from -1 to +1 shifted half a cycle crosses zero there');
      for (final w in Warp.values) {
        for (var i = 0; i < 100; i++) {
          final p = warpPhase(i / 100, w, 0.7);
          expect(p, inInclusiveRange(0, 1), reason: '$w');
        }
      }
    });

    test('the approximate filter curve passes below the cutoff and cuts above it', () {
      double db(double hz) => filterResponseDb(hz, type: 0, cutoff: 1000, resonance: 0);
      expect(db(50).abs(), lessThan(1));
      expect(db(8000), lessThan(-30));
      expect(filterResponseDb(1000, type: 0, cutoff: 1000, resonance: 0.9), greaterThan(db(1000)));
      expect(filterResponseDb(50, type: 4, cutoff: 1000, resonance: 0), lessThan(-30), reason: 'a high-pass');
    });
  });

  group('goldens', () {
    for (final (name, size) in [('phone', goldenSizes['phone']!), ('desktop', goldenSizes['desktop']!)]) {
      wtest('the flagship editor, $name', (tester) async {
        late BuildContext ctx;
        await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.expand();
        })), size);
        openDeviceEditor(ctx, s, s.project.layers.first, DeviceTarget.instrumentSlot);
        await tester.pumpAndSettle();
        await expectLater(goldenScreen, matchesGoldenFile('goldens/device_flagship_$name.png'));
      });
    }

    wtest('the flagship editor\'s MOD page with a route, phone', (tester) async {
      ModMatrix(synth()).add(ModSource.lfo1, 'flt1_cutoff');
      late BuildContext ctx;
      await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      })), goldenSizes['phone']!);
      openDeviceEditor(ctx, s, s.project.layers.first, DeviceTarget.instrumentSlot);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('device-tab-mod')));
      await tester.pumpAndSettle();
      await expectLater(goldenScreen, matchesGoldenFile('goldens/device_flagship_mod_phone.png'));
    });

    wtest('the flagship editor\'s FILTER and FX pages, desktop', (tester) async {
      late BuildContext ctx;
      await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      })), goldenSizes['desktop']!);
      openDeviceEditor(ctx, s, s.project.layers.first, DeviceTarget.instrumentSlot);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('device-tab-fx')));
      await tester.pumpAndSettle();
      await expectLater(goldenScreen, matchesGoldenFile('goldens/device_flagship_fx_desktop.png'));
    });
  });

  final lib = Platform.environment['CAW_LIB'];
  test('the fixture matches the engine\'s flagship descriptor', () async {
    final e = Engine.create();
    final real = (await e.nativeComponents()).firstWhere((c) => c.id == flagshipComponentId);
    expect(real.parameters.length, 209);
    expect([for (final p in real.parameters) p.id], [for (final p in flagship.parameters) p.id]);
    for (var i = 0; i < real.parameters.length; i++) {
      final a = real.parameters[i], b = flagship.parameters[i];
      expect((a.name, a.unit, a.min, a.max, a.step, a.exponential), (b.name, b.unit, b.min, b.max, b.step, b.exponential),
          reason: a.id);
      expect(a.choices, b.choices, reason: a.id);
      expect(a.defaultValue, closeTo(b.defaultValue, 1e-6), reason: a.id);
    }
    e.dispose();
  }, skip: lib == null || lib.isEmpty);
}
