// fx-racks: the rack model (hashes, the expanded parameters, slot edits and routes), the effect browser (tabs, search,
// favourites, recents), the rack UIs (goldens, adding an effect, routing a modulator) and, with CAW_LIB, the engine.
import 'dart:io';
import 'dart:typed_data';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/effect_recents.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:caw/model/mod_matrix.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/racks.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/effects/creative/creative_catalog.dart' show creativeCatalog;
import 'package:caw/ui/devices/effects/dynamics/catalog.dart' show fxDynamicsCatalog;
import 'package:caw/ui/devices/effects/effect_catalog.dart';
import 'package:caw/ui/devices/effects/filters/filters_shared.dart' show filtersBrowserEntries;
import 'package:caw/model/fx_space_display.dart' show fxSpaceBrowser;
import 'package:caw/ui/devices/effects/space/space_fx.dart' show fxSpaceIcons;
import 'package:caw/ui/files/asset_picker.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/devices/visuals/filter_curve.dart' show freqToX;
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

void main() {
  var motion = MotionLevel.full;
  late DeviceDisplaySource source;
  late FakeDisplay display;
  final states = <AppState>[];

  setUp(() {
    motion = Motion.setting;
    Motion.setting = MotionLevel.off;
    source = DeviceDisplaySource.current;
    display = FakeDisplay();
    DeviceDisplaySource.current = display;
  });
  tearDown(() {
    Motion.setting = motion;
    DeviceDisplaySource.current = source;
    for (final s in states) {
      s.dispose();
    }
    states.clear();
  });

  AppState state(String id, [Map<String, double> values = const {}]) {
    final s = stateWith(id, make: PreviewState.new);
    s.nativeCatalog = builtinInfos();
    Motion.setting = MotionLevel.off;
    if (values.isNotEmpty) s.project.layers.first.components.first.params.addAll(values);
    states.add(s);
    return s;
  }

  DeviceTarget rack(AppState s) => DeviceTarget(s, 'a', 0);
  double h(String id) => rackChildHash(id).toDouble();
  int indexOf(DeviceTarget t, String id) => t.info!.parameters.indexWhere((p) => p.id == id);

  group('model', () {
    test('child hashes are the engine\'s (pinned in engine/tests/fx_racks_test.cpp)', () {
      expect(rackChildHash('org.caw.filter'), 3477098);
      expect(rackChildHash('org.caw.utility'), 4302427);
      final seen = <int>{};
      for (final c in builtinInfos()) {
        expect(seen.add(rackChildHash(c.id)), isTrue, reason: c.id);
      }
    });

    test('a rack lists its children\'s knobs after its own and before the routes', () {
      final s = state(fxRackId, {'s1_fx': h('org.caw.filter'), 's3_fx': h('org.caw.utility')});
      final t = rack(s);
      final ids = [for (final p in t.info!.parameters) p.id];
      expect(ids, containsAll(['s1.cutoff', 's3.gain', 'mod1_dst']));
      expect(ids.indexOf('s1.cutoff'), lessThan(ids.indexOf('s3.gain')));
      expect(ids.indexOf('s3.gain'), lessThan(ids.indexOf('mod1_src')));
      expect(t.param('s1.cutoff')!.label, 'S1 Cutoff');
      final dst = t.param('mod1_dst')!;
      expect(dst.choices.length, ids.indexOf('mod1_src') + 1, reason: 'None, then every knob before the routes');
      expect(rackChildren(t).map((e) => e.$2).take(3), ['org.caw.filter', null, 'org.caw.utility']);
    });

    test('a slot edit keeps routes on their knobs; moving a child moves its values and routes', () {
      final s = state(fxRackId, {'s2_fx': h('org.caw.utility')});
      final t = rack(s);
      final m = ModMatrix(t);
      expect(m.add(ModSource.macro1, 's2.gain', amount: -0.5), 1);
      expect(t.value('mod1_src'), 10, reason: 'Macro 1 is the rack\'s 10th source');
      t.set('s2.gain', -6);
      setRackValues(t, rackValuesWithSlot(t, rackSlots(fxRackId)[0], 'org.caw.filter'));
      expect(ModMatrix(t).route(1)!.paramId, 's2.gain', reason: 'the filter went in front, the route followed the gain');
      expect(t.value('s2.gain'), -6);
      setRackValues(t, rackValuesMoved(t, rackSlots(fxRackId)[1], rackSlots(fxRackId)[0]));
      expect(rackChildren(t).map((e) => e.$2).take(2), ['org.caw.utility', 'org.caw.filter']);
      expect(t.value('s1.gain'), -6);
      expect(ModMatrix(t).route(1)!.paramId, 's1.gain');
      setRackValues(t, rackValuesWithSlot(t, rackSlots(fxRackId)[0], null));
      expect(ModMatrix(t).route(1), isNull, reason: 'its knob went: the route is cleared');
      expect(t.use!.params.keys.where((k) => k.startsWith('s1.')), isEmpty);
    });

    test('a child is a device of its own: its ids reach the rack\'s, its switch is the slot\'s', () {
      final s = state(fxRackId, {'s1_fx': h('org.caw.filter')});
      final t = rack(s);
      final c = RackChildTarget(t, rackSlots(fxRackId)[0], 'org.caw.filter');
      expect(c.info!.id, 'org.caw.filter');
      c.set('cutoff', 500);
      expect(t.value('s1.cutoff'), 500);
      expect(c.value('cutoff'), 500);
      c.setBypass(true);
      expect(t.value('s1_on'), 0);
      expect(c.displayChild, 1);
      final m = ModMatrix(t, prefix: 's1.');
      expect(m.add(ModSource.lfo2, 'cutoff'), 1);
      expect(m.routesTo('cutoff'), hasLength(1));
      expect(ModMatrix(t).routesTo('s1.cutoff'), hasLength(1));
      expect(m.sources, contains(ModSource.follow1));
      expect(m.sources, isNot(contains(ModSource.velocity)), reason: 'the rack has no note velocity source');
    });

    test('the flagship\'s matrix still maps its own sources', () {
      final s = state('org.caw.synth.flagship');
      final m = ModMatrix(DeviceTarget(s, 'a', DeviceTarget.instrumentSlot));
      expect(m.sourceValue(ModSource.lfo1), ModSource.lfo1.value);
      expect(m.sourceValue(ModSource.macro1), 0);
    });

    test('every built-in effect has a browser entry', () {
      for (final id in [...builtinEffects, fxRackId, multibandRackId]) {
        expect(EffectCatalog.of(id), isNotNull, reason: id);
        expect(EffectCatalog.of(id)!.description, isNotEmpty);
      }
      expect(EffectCatalog.of(fxRackId)!.category, EffectCategory.racks);
    });

    test('the groups\' catalogs fill the browser: their tab, description and icon, the base keywords kept', () {
      for (final e in [...fxDynamicsCatalog.map((e) => (e.id, e.category, e.description, e.icon)),
          ...creativeCatalog.map((e) => (e.id, e.category, e.description, e.icon)),
          ...filtersBrowserEntries.map((e) => (e.id, e.category, e.description, e.icon)),
          ...fxSpaceBrowser.entries.map((e) => (e.key, e.value.category, e.value.description, fxSpaceIcons[e.key]!))]) {
        final entry = EffectCatalog.of(e.$1);
        expect(entry, isNotNull, reason: e.$1);
        expect(entry!.category, EffectCategory.byLabel(e.$2), reason: e.$1);
        expect(entry.description, e.$3);
        expect(entry.icon, e.$4);
      }
      expect(EffectCatalog.of('org.caw.multiband')!.category, EffectCategory.dynamics);
      expect(EffectCatalog.of('org.caw.tapestop')!.category, EffectCategory.pitchTime);
      expect(EffectCatalog.of('org.caw.bitcrush')!.category, EffectCategory.creative);
      expect(EffectCatalog.of('org.caw.ladder')!.category, EffectCategory.eqFilter);
      expect(EffectCatalog.of('org.caw.compressor')!.keywords, contains('glue'));
      expect(EffectCatalog.of('org.caw.stutter')!.matches('beat repeat', 'Stutter'), isTrue);
      expect(EffectCategory.byLabel('EQ & Filter'), EffectCategory.eqFilter);
      expect(EffectCategory.byLabel('Nope'), isNull);
    });
  });

  group('browser', () {
    Future<AssetDrag?> Function() openBrowser(WidgetTester tester, AppState s, {bool rackChild = false}) {
      AssetDrag? picked;
      return () async {
        await pumpGolden(tester, Scaffold(body: Builder(builder: (context) => TextButton(
          onPressed: () async => picked = await showAssetPicker(context, s, kinds: {AssetKind.nativeEffect}, rackChild: rackChild),
          child: const Text('open')))), const Size(390, 844));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        return picked;
      };
    }

    Future<void> tab(WidgetTester tester, String name) async {
      final f = find.byKey(ValueKey('fx-tab-$name'));
      await tester.scrollUntilVisible(f, name == 'all' ? -80 : 80, scrollable: find.descendant(
          of: find.byKey(const ValueKey('fx-browser-tabs')), matching: find.byType(Scrollable)).first);
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    testWidgets('tabs, search, favourites and recents', (tester) async {
      final s = state('org.caw.eq');
      await openBrowser(tester, s)();
      expect(find.byKey(const ValueKey('fx-browser-tabs')), findsOneWidget);
      expect(find.text('DYNAMICS'), findsOneWidget);
      expect(find.text(EffectCatalog.of('org.caw.compressor')!.description), findsOneWidget);
      await tab(tester, 'racks');
      expect(find.text('FX rack'), findsOneWidget);
      expect(find.text('Compressor'), findsNothing);
      await tab(tester, 'all');
      // Search reaches descriptions and keywords.
      await tester.enterText(find.byKey(const ValueKey('fx-browser-search')), 'multipass');
      await tester.pump();
      expect(find.text('Multiband rack'), findsOneWidget);
      expect(find.text('EQ'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('fx-browser-search')), '');
      await tester.pump();
      // A star puts it in Favourites at the top.
      await tester.tap(find.byKey(const ValueKey('fx-fav-org.caw.compressor')));
      await tester.pumpAndSettle();
      expect(find.text('FAVOURITES'), findsOneWidget);
      expect(find.byKey(const ValueKey('fx-browser-Favourites-org.caw.compressor')), findsOneWidget);
      // A pick goes first in Recently used.
      await tester.scrollUntilVisible(find.byKey(const ValueKey('fx-browser-Dynamics-org.caw.gate')), 120,
          scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fx-browser-Dynamics-org.caw.gate')));
      await tester.pumpAndSettle();
      expect(s.effectRecents.ids.first, 'org.caw.gate');
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('RECENTLY USED'), findsOneWidget);
      expect(find.byKey(const ValueKey('fx-browser-Recently used-org.caw.gate')), findsOneWidget);
      expect(s.isFavourite(s.builtinAssets.firstWhere((a) => a.native!.id == 'org.caw.compressor')), isTrue);
    });

    testWidgets('a rack\'s slot lists no racks and no instruments', (tester) async {
      final s = state('org.caw.eq');
      await openBrowser(tester, s, rackChild: true)();
      expect(find.text('INSTRUMENTS'), findsNothing);
      await tab(tester, 'racks');
      expect(find.text('FX rack'), findsNothing);
      expect(find.text('No Racks effects yet.'), findsOneWidget);
    });
  });

  group('rack UIs', () {
    Future<void> open(WidgetTester tester, AppState s, String id, {Size size = const Size(390, 844)}) async {
      display.frame.value = null;
      late BuildContext ctx;
      await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      })), size);
      openDevice(ctx, s, id);
      await tester.pumpAndSettle();
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('both racks open their own UI, also on a landscape phone', (tester) async {
      for (final id in [fxRackId, multibandRackId]) {
        expect(DeviceEditors.custom(id, builtinInfo(id)), isNotNull);
        for (final size in const [Size(390, 844), Size(844, 390), Size(360, 740)]) {
          await open(tester, state(id, id == fxRackId ? {'s1_fx': h('org.caw.filter')} : {'b1s1_fx': h('org.caw.compressor')}), id, size: size);
          expect(find.byKey(const ValueKey('device-fallback')), findsNothing);
          expect(tester.takeException(), isNull);
          await close(tester);
        }
      }
    });

    testWidgets('golden: the multiband rack', (tester) async {
      final s = state(multibandRackId, {'bands': 4, 'b2s1_fx': h('org.caw.compressor'), 'band3_mute': 1});
      await open(tester, s, multibandRackId);
      display.frame.value = DeviceDisplayFrame(inputDb: -8, outputDb: -9,
          spectrum: [for (var i = 0; i < 64; i++) (0.8 - i / 64 * 0.5).clamp(0.0, 1.0)],
          values: {'bands': 4, 'band1_db': -12, 'band2_db': -9, 'band3_db': -60, 'band4_db': -20});
      await tester.tap(find.text('BAND 2'));
      await tester.pumpAndSettle();
      await expectLater(goldenScreen, matchesGoldenFile('goldens/devices/rack_multiband_phone.png'));
      await close(tester);
    });

    testWidgets('golden: the FX rack', (tester) async {
      final s = state(fxRackId, {'s1_fx': h('org.caw.filter'), 's2_fx': h('org.caw.utility'), 'lfo1_shape': 7});
      await open(tester, s, fxRackId);
      await tester.tap(find.byKey(const ValueKey('rack-focus-lfo1')));
      await tester.pumpAndSettle();
      await expectLater(goldenScreen, matchesGoldenFile('goldens/devices/rack_fx_phone.png'));
      await close(tester);
    });

    testWidgets('the band strips and crossovers edit the multiband rack', (tester) async {
      final s = state(multibandRackId);
      final t = rack(s);
      await open(tester, s, multibandRackId);
      await tester.tap(find.byKey(const ValueKey('mb-bands-4')));
      await tester.pumpAndSettle();
      expect(t.value('bands'), 4);
      await tester.tap(find.byKey(const ValueKey('mb-solo-2')));
      await tester.pumpAndSettle();
      expect(t.value('band2_solo'), 1);
      final before = t.value('xover1');
      final hero = tester.getRect(find.byKey(const ValueKey('mb-hero')));
      // Grab the first crossover where the hero draws it (the kit's log axis) and drag it right.
      await tester.dragFrom(Offset(hero.left + freqToX(before, hero.width), hero.center.dy), const Offset(60, 0));
      await tester.pumpAndSettle();
      expect(t.value('xover1'), greaterThan(before));
      await close(tester);
    });

    testWidgets('an effect added to an empty rack, then a modulator routed to its knob by assign mode', (tester) async {
      final s = state(fxRackId);
      final t = rack(s);
      await open(tester, s, fxRackId);
      await tester.ensureVisible(find.byKey(const ValueKey('rack-add-0')));
      await tester.tap(find.byKey(const ValueKey('rack-add-0')));
      await tester.pumpAndSettle();
      expect(find.text('Add to rack'), findsOneWidget);
      // The groups' catalogs make the list long: search narrows it to the filter.
      await tester.enterText(find.byKey(const ValueKey('fx-browser-search')), 'filter');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('fx-browser-EQ & Filter-org.caw.filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fx-browser-EQ & Filter-org.caw.filter')));
      await tester.pumpAndSettle();
      expect(rackChildren(t).first.$2, 'org.caw.filter');
      expect(find.byKey(const ValueKey('rack-child-s1')), findsOneWidget);
      // LFO 2's chip, then the filter's cutoff knob: a route from LFO 2 to s1.cutoff.
      await tester.tap(find.byKey(const ValueKey('modsrc-lfo2')));
      await tester.pumpAndSettle();
      final knob = find.byKey(const ValueKey('dknob-cutoff'));
      await tester.ensureVisible(knob.first);
      await tester.pumpAndSettle();
      await tester.tap(knob.first);
      await tester.pumpAndSettle();
      final routes = ModMatrix(t).routes;
      expect(routes, hasLength(1));
      expect(routes.first.source, ModSource.lfo2);
      expect(routes.first.paramId, 's1.cutoff');
      expect(t.value('mod1_dst'), indexOf(t, 's1.cutoff') + 1);
      await close(tester);
    });
  });

  test('the engine takes a rack the app wrote: children, values and a route', () async {
    final e = Engine.create();
    final engine = {for (final c in await e.nativeComponents()) c.id: c};
    expect(engine[fxRackId], isNotNull);
    expect(engine[multibandRackId], isNotNull);
    final s = state(fxRackId, {'s1_fx': h('org.caw.filter'), 's1.cutoff': 900, 's2_fx': h('org.caw.utility')});
    final t = rack(s);
    ModMatrix(t).add(ModSource.lfo1, 's1.cutoff');
    s.project.modules.add(ModuleDoc(id: 'm', name: 'Tone', source: 'sin(2*pi*220*t)'));
    s.project.layers.first.generatorId = 'm';
    await e.setProject(s.project.toEngineJson());
    expect(e.lastProjectWarnings.where((w) => w.contains('rack') || w.contains('native component')), isEmpty);
    // A child's live display is read through the rack's index (nothing published before it plays: 0).
    expect(e.componentDisplay('a', 0 + 65536, Float32List(Engine.maxDisplayFloats)), greaterThanOrEqualTo(0));
    expect(e.componentDisplay('a', 0 + 5 * 65536, Float32List(Engine.maxDisplayFloats)), 0, reason: 'an empty slot');
    e.dispose();
  }, skip: (Platform.environment['CAW_LIB'] ?? '').isEmpty ? 'set CAW_LIB to the built engine library' : null);
}
