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
import 'package:caw/ui/devices/device_controls.dart' show DeviceKnobPainter;
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/flagship/flagship_editor.dart' show flagshipComponentId;
import 'package:caw/ui/devices/visuals/envelope_view.dart';
import 'package:caw/ui/devices/visuals/mod_routing.dart' show stripSources;
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

  Finder synthScroll() =>
      find.descendant(of: find.byKey(const ValueKey('flagship-synth')), matching: find.byType(Scrollable)).first;

  /// Scrolls [scrollable] (by its position: its heroes take drags) until [target] is built and on screen.
  Future<void> reveal(WidgetTester tester, Finder target, [Finder? scrollable]) async {
    final state = tester.state<ScrollableState>(scrollable ?? synthScroll());
    for (var i = 0; i < 60 && target.evaluate().isEmpty; i++) {
      state.position.jumpTo((state.position.pixels + 150).clamp(0, state.position.maxScrollExtent));
      await tester.pump();
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  /// Scrolls the source strip until [source]'s chip is on screen; its centre.
  Future<Offset> chip(WidgetTester tester, String source) async {
    final f = find.byKey(ValueKey('modsrc-$source'));
    await tester.scrollUntilVisible(f, 60, scrollable: find.descendant(
        of: find.byKey(const ValueKey('mod-source-strip')), matching: find.byType(Scrollable)).first);
    await tester.pumpAndSettle();
    return tester.getCenter(f);
  }

  /// Scrolls the SYNTH page to section [id] and opens it.
  Future<void> openSection(WidgetTester tester, String id) async {
    final header = find.byKey(ValueKey('expand-$id'));
    await reveal(tester, header);
    await tester.tap(header);
    await tester.pumpAndSettle();
  }

  group('framework', () {
    wtest('the FX stack opens the instrument\'s editor full screen on a phone; close returns', (tester) async {
      await openSynth(tester);
      expect(find.byKey(const ValueKey('device-editor')), findsOneWidget);
      expect(find.text('Flagship'), findsWidgets);
      expect(find.byKey(const ValueKey('flagship-synth')), findsOneWidget);
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

    wtest('three tabs, as Vital: SYNTH, EFFECTS and MATRIX', (tester) async {
      await openSynth(tester);
      for (final (tab, page) in [('fx', 'flagship-fx'), ('matrix', 'flagship-matrix'), ('synth', 'flagship-synth')]) {
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
      await openSection(tester, 'flagship-envelopes');
      final view = find.byKey(const ValueKey('env-env1_'));
      await reveal(tester, view);
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
      final at = await chip(tester, 'lfo1');
      final knob = tester.getCenter(find.byKey(const ValueKey('dknob-osc1_level')));
      final g = await tester.startGesture(at);
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
      // The MATRIX page lists it and removes it.
      await tester.tap(find.byKey(const ValueKey('device-tab-matrix')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(ValueKey('modroute-remove-$slot')), 100,
          scrollable: find.descendant(of: find.byKey(const ValueKey('flagship-matrix')), matching: find.byType(Scrollable)).first);
      await tester.tap(find.byKey(ValueKey('modroute-remove-$slot')));
      await tester.pumpAndSettle();
      expect(ModMatrix(synth()).routesTo('osc1_level'), isEmpty);
      expect(synth().value('mod${slot}_src'), 0);
    });

    wtest('assign mode: tap a chip, then tap knobs to add and remove routes; Done ends it', (tester) async {
      await openSynth(tester);
      await tester.tapAt(await chip(tester, 'lfo2'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mod-assign-banner')), findsOneWidget);
      expect(find.textContaining('Tap knobs to route', findRichText: true), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dknob-osc1_level')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dknob-osc1_pan')));
      await tester.pumpAndSettle();
      var m = ModMatrix(synth());
      expect(m.routeOf(ModSource.lfo2, 'osc1_level'), isNotNull);
      expect(m.routeOf(ModSource.lfo2, 'osc1_pan'), isNotNull);
      expect(synth().value('osc1_level'), 0.7, reason: 'a tap in assign mode routes; it doesn\'t turn the knob');
      // A second tap removes it.
      await tester.tap(find.byKey(const ValueKey('dknob-osc1_level')));
      await tester.pumpAndSettle();
      m = ModMatrix(synth());
      expect(m.routeOf(ModSource.lfo2, 'osc1_level'), isNull);
      expect(m.routeOf(ModSource.lfo2, 'osc1_pan'), isNotNull);
      await tester.tap(find.byKey(const ValueKey('mod-assign-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mod-assign-banner')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('dknob-osc1_level')));
      await tester.pumpAndSettle();
      expect(ModMatrix(synth()).routeOf(ModSource.lfo2, 'osc1_level'), isNull, reason: 'out of assign mode a tap does nothing');
    });

    wtest('assign mode\'s Edit opens the source\'s section in place', (tester) async {
      await openSynth(tester);
      await tester.tapAt(await chip(tester, 'lfo1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mod-assign-edit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lfo-lfo1_rate')), findsOneWidget);
      expect(find.byKey(const ValueKey('mod-assign-banner')), findsNothing);
    });

    wtest('a finger that rests on a modulated knob\'s ring, then drags, still sets the amount (regression)', (tester) async {
      await openSynth(tester);
      final slot = ModMatrix(synth()).add(ModSource.lfo1, 'osc1_level')!;
      await tester.pump();
      final r = tester.getRect(find.byKey(const ValueKey('dknob-osc1_level')));
      final g = await tester.startGesture(Offset(r.center.dx, r.top + 3));
      await tester.pump(const Duration(milliseconds: 800)); // past the long-press time
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(0, -5));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('mod-sheet')), findsNothing);
      expect(synth().value('mod${slot}_amt'), greaterThan(0.3));
      expect(synth().value('osc1_level'), 0.7);
    });

    wtest('two fingers on a knob drag the selected route\'s amount', (tester) async {
      await openSynth(tester);
      final slot = ModMatrix(synth()).add(ModSource.env3, 'osc1_level')!;
      await tester.pump();
      final c = tester.getCenter(find.byKey(const ValueKey('dknob-osc1_level')));
      final a = await tester.startGesture(c + const Offset(-3, -6));
      final b = await tester.startGesture(c + const Offset(3, -6), pointer: 7);
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await a.moveBy(const Offset(0, -6));
        await b.moveBy(const Offset(0, -6));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(synth().value('mod${slot}_amt'), greaterThan(0.35));
      expect(synth().value('osc1_level'), 0.7);
    });

    wtest('the Modulation sheet: long-press a knob; its slider edits the amount every time; polarity, add, remove',
        (tester) async {
      await openSynth(tester);
      final slot = ModMatrix(synth()).add(ModSource.lfo1, 'osc1_level')!;
      await tester.pump();
      await tester.longPress(find.byKey(const ValueKey('dknob-osc1_level')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mod-sheet')), findsOneWidget);
      final slider = find.byKey(ValueKey('modamount-$slot'));
      expect(tester.getSize(slider).height, greaterThanOrEqualTo(44), reason: 'a big target');
      // Drag it right, then left, several times: each drag moves it (the bug was a drag that did nothing).
      var last = synth().value('mod${slot}_amt');
      for (final dx in [80.0, -40.0, 120.0, -160.0]) {
        await tester.drag(slider, Offset(dx, 0));
        await tester.pumpAndSettle();
        final now = synth().value('mod${slot}_amt');
        expect(dx > 0 ? now > last : now < last, isTrue, reason: 'drag $dx: $last -> $now');
        last = now;
      }
      await tester.tap(find.byKey(ValueKey('modroute-unipolar-$slot')));
      await tester.pumpAndSettle();
      expect(synth().value('mod${slot}_bipolar'), 0);
      await tester.tap(find.byKey(const ValueKey('mod-sheet-add-env3')));
      await tester.pumpAndSettle();
      expect(ModMatrix(synth()).routesTo('osc1_level'), hasLength(2));
      await tester.tap(find.byKey(ValueKey('modroute-remove-$slot')));
      await tester.pumpAndSettle();
      expect(ModMatrix(synth()).routesTo('osc1_level').single.source, ModSource.env3);
    });

    wtest('several routes on one knob draw one ring each and a count badge', (tester) async {
      await openSynth(tester);
      final m = ModMatrix(synth());
      for (final src in [ModSource.lfo1, ModSource.env2, ModSource.random]) {
        m.add(src, 'osc1_frame');
      }
      await tester.pump();
      final knob = find.byKey(const ValueKey('dknob-osc1_frame'));
      final paint = tester.widgetList<CustomPaint>(find.descendant(of: knob, matching: find.byType(CustomPaint)))
          .map((c) => c.painter).whereType<DeviceKnobPainter>().single;
      expect(paint.rings, hasLength(3));
      expect(find.descendant(of: find.byKey(const ValueKey('dknob-badge-osc1_frame')), matching: find.text('3')), findsOneWidget);
    });

    wtest('an oscillator\'s section opens in place; the filter curve edits its parameters', (tester) async {
      await openSynth(tester);
      await openSection(tester, 'flagship-osc-2');
      expect(find.byKey(const ValueKey('wt-osc2_')), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('dpower-osc2_on')));
      await tester.pumpAndSettle();
      expect(synth().value('osc2_on'), 1);
      final curve = find.byKey(const ValueKey('filter-flt1_'));
      await reveal(tester, curve);
      final before = synth().value('flt1_cutoff');
      await tester.drag(curve, const Offset(60, -30));
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

    test('the knob\'s modulated value follows the sources\' shapes (≈): an LFO swings it, an envelope lifts it', () {
      final t = synth();
      final m = ModMatrix(t);
      m.remove(1);
      m.add(ModSource.lfo1, 'osc1_level', amount: 0.2, bipolar: true); // 2 Hz sine
      final m2 = ModMatrix(t);
      final at = [for (var i = 0; i < 40; i++) m2.modulatedPosition('osc1_level', 0.5, i / 80)!];
      expect(at.reduce((a, b) => a < b ? a : b), closeTo(0.3, 0.02));
      expect(at.reduce((a, b) => a > b ? a : b), closeTo(0.7, 0.02));
      expect(m2.modulatedPosition('osc1_pan', 0.5, 0), isNull, reason: 'no route');
      // Velocity has no shape of its own: nothing to draw.
      ModMatrix(t).add(ModSource.velocity, 'osc1_pan');
      expect(ModMatrix(t).modulatedPosition('osc1_pan', 0.5, 0), isNull);
      // The envelope: up after the attack, down to the sustain, released in the second beat.
      final beat = 0.5;
      double env(double s) => ModPreview.envelopeAt(s, attack: 0.1, decay: 0.1, sustain: 0.5, release: 0.1, beat: beat);
      expect(env(0.05), closeTo(0.5, 1e-9));
      expect(env(0.3), closeTo(0.5, 1e-9));
      expect(env(0.99), lessThan(0.01));
      // Several slots can aim at one knob (all 16).
      final full = ModMatrix(t);
      for (final r in full.routes) {
        full.remove(r.slot);
      }
      for (final src in stripSources) {
        expect(ModMatrix(t).add(src, 'flt1_cutoff'), isNotNull);
      }
      expect(ModMatrix(t).routesTo('flt1_cutoff').length, stripSources.length, reason: 'every source on one knob');
    });

    test('the via source scales a route; toggle adds and removes', () {
      final m = ModMatrix(synth());
      expect(m.hasVia, isTrue);
      final slot = m.toggle(ModSource.lfo1, 'osc1_pan')!;
      expect(slot, greaterThan(0));
      m.setVia(slot, ModSource.modWheel);
      expect(ModMatrix(synth()).route(slot)!.via, ModSource.modWheel);
      expect(ModMatrix(synth()).toggle(ModSource.lfo1, 'osc1_pan'), 0);
      expect(synth().value('mod${slot}_via'), 0);
      const r = ModRoute(slot: 1, source: ModSource.lfo1, paramId: 'x', amount: 0.5, bipolar: true);
      expect(r.offset(1), 0.5);
      expect(r.offset(0), -0.5);
      expect(r.offset(1, scale: 0.5), 0.25);
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

    wtest('the flagship editor\'s MATRIX page with routes, phone', (tester) async {
      ModMatrix(synth()).add(ModSource.env3, 'flt1_cutoff');
      ModMatrix(synth()).add(ModSource.lfo1, 'flt1_cutoff');
      late BuildContext ctx;
      await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      })), goldenSizes['phone']!);
      openDeviceEditor(ctx, s, s.project.layers.first, DeviceTarget.instrumentSlot);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('device-tab-matrix')));
      await tester.pumpAndSettle();
      await expectLater(goldenScreen, matchesGoldenFile('goldens/device_flagship_matrix_phone.png'));
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
    // The engine's presets reach the browser (DevicePresets.engine reads the descriptor's list).
    expect(real.presets.map((p) => p.name), ['Init', 'Morph pad', 'Mono bass', 'Acid 303', 'Basic']);
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
