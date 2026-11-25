// The device library (1.1.0): crow-family names from one table for every built-in, search by plain names and tags,
// purpose chips and chain templates in the effect browser, the purpose project templates, the "?" field guide and
// Happy accident.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:caw/engine/component_info.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/chain_templates.dart';
import 'package:caw/model/cpp_reference.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_names.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/field_guides.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/templates.dart';
import 'package:caw/model/track_defaults.dart';
import 'package:caw/ui/devices/effects/effect_catalog.dart';
import 'package:caw/ui/devices/kit/device_menu.dart';
import 'package:caw/ui/devices/kit/hero.dart' show MotionClock;
import 'package:caw/ui/files/asset_picker.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';

Map<String, dynamic> fixtureJson() =>
    jsonDecode(File('test/fixtures/builtin_components.json').readAsStringSync()) as Map<String, dynamic>;

/// The fixture's presets by component id (the engine's own lists).
Map<String, Set<String>> fixturePresets() => {
      for (final c in builtinInfos()) c.id: {for (final p in c.presets) p.name},
    };

void main() {
  group('names', () {
    test('the table names every built-in in the fixture and the C++ Library', () {
      final ids = {
        for (final c in (fixtureJson()['components'] as List)) (c as Map<String, dynamic>)['id'] as String,
        for (final b in cppBuiltins) if (!ComponentUseDoc.retiredInstruments.contains(b.id)) b.id,
      };
      for (final id in ids) {
        final n = DeviceNames.of(id);
        expect(n, isNotNull, reason: '$id has no name in DeviceNames.table');
        expect(n!.name, isNotEmpty);
        expect(n.plain, isNotEmpty);
      }
      // Every name is one device's (two components never share a crow name).
      final names = [for (final n in DeviceNames.table.values) n.name];
      expect(names.toSet().length, names.length);
    });

    test('the title is the name and the plain subtitle; ids and saved projects stay as they are', () {
      expect(DeviceNames.title('org.caw.compressor', 'Compressor'), 'Talon · Compressor');
      expect(DeviceNames.title('org.caw.eq', 'EQ'), 'Plume · EQ');
      expect(DeviceNames.title('org.caw.mod.macros', 'Macros'), 'Macros', reason: 'no "Macros · Macros"');
      expect(DeviceNames.title('cpp.mine', 'My fuzz'), 'My fuzz', reason: 'a project\'s own code keeps its name');
      // A retired id is never shown (an old project is converted when it opens): it keeps its own name.
      expect(DeviceNames.title('org.caw.drum.kit', 'Drum kit'), 'Drum kit');
      const info = NativeComponentInfo(id: 'org.caw.compressor', name: 'Compressor');
      expect(info.label, 'Talon · Compressor');
      expect(info.shortLabel, 'Talon');
      expect(builtinComponentName('org.caw.reverb'), 'Roost · Reverb');
      final p = ProjectDoc(id: 'p', name: 'n', layers: [
        LayerDoc(id: 'a', name: 'A', color: 0, components: [ComponentUseDoc('org.caw.compressor')]),
      ]);
      expect(jsonEncode(p.toJson()), contains('"org.caw.compressor"'));
      expect(jsonEncode(p.toJson()), isNot(contains('Talon')));
    });

    test('a new track and a new modulator take the short name', () {
      final s = AppState(settings: Settings()..trackNaming = TrackNaming.byInstrument);
      addTearDown(s.dispose);
      s.project = ProjectDoc(id: 'p', name: 'n', layers: []);
      s.componentCatalog.set(builtinInfos());
      expect(s.newTrackName('Track 1', instrumentId: 'org.caw.drums'), 'Rook 1');
    });
  });

  group('search', () {
    String best(String q) {
      final ranked = [
        for (final id in DeviceNames.table.keys)
          if (DeviceNames.rank(id, q) case final r?) (r, id),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      return DeviceNames.of(ranked.first.$2)!.name;
    }

    test('a plain search finds the device, an exact tag first', () {
      expect(best('EQ'), 'Plume');
      expect(best('eq'), 'Plume');
      expect(best('equalizer'), 'Plume');
      expect(best('compressor'), 'Talon');
      expect(best('reverb'), 'Roost');
      expect(best('autotune'), 'Chirp');
      expect(best('delay'), 'Relay');
      expect(best('distortion'), 'Ember');
      expect(best('utility'), 'Wingspan', reason: 'an old name');
      expect(best('bit distortion'), 'Grit', reason: 'an old name');
      expect(best('limiter'), 'Hover');
      expect(best('de-esser'), 'Quell');
      expect(best('tuner'), 'Spot');
      expect(best('arpeggiator'), 'Hop');
      expect(best('lfo'), 'Orbit');
      expect(best('talon'), 'Talon');
      expect(DeviceNames.rank('org.caw.compressor', 'bus'), 0, reason: 'its modes are tags');
    });

    test('searching Timber (removed in 1.1.3) finds the instruments it was split into', () {
      expect(DeviceNames.of('org.caw.timber'), isNull);
      for (final id in ['org.caw.starling', 'org.caw.nightingale', 'org.caw.curlew', 'org.caw.bittern',
          'org.caw.woodpecker', 'org.caw.synth.flagship']) {
        expect(DeviceNames.rank(id, 'timber'), isNotNull, reason: '$id: an old name');
      }
    });

    test('the browser\'s entries rank by the same table', () {
      final eq = EffectCatalog.of('org.caw.eq')!;
      expect(eq.rank('EQ', 'Plume · EQ'), 0);
      expect(EffectCatalog.of('org.caw.compressor')!.matches('glue', 'Talon · Compressor'), isTrue);
      expect(EffectCatalog.of('org.caw.compressor')!.matches('reverb', 'Talon · Compressor'), isFalse);
    });

    test('every purpose has devices', () {
      for (final p in DevicePurpose.values) {
        expect(DeviceNames.table.values.where((n) => n.purposes.contains(p)), isNotEmpty, reason: p.label);
      }
    });
  });

  group('the effect browser', () {
    late AppState s;
    setUp(() {
      Motion.setting = MotionLevel.off;
      s = AppState(settings: Settings());
      s.project = ProjectDoc(id: 'p', name: 'n', layers: [LayerDoc(id: 'a', name: 'Track', color: 0)]);
      s.componentCatalog.set(builtinInfos());
      s.nativeCatalog = builtinInfos();
    });
    tearDown(() => s.dispose());

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(640, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: AssetPickerSheet(state: s,
          kinds: const {AssetKind.nativeEffect}, title: 'Add FX'))));
      await tester.pump();
    }

    testWidgets('searching "EQ" lists Plume first, by its crow name and plain subtitle', (tester) async {
      await pump(tester);
      await tester.enterText(find.byKey(const ValueKey('fx-browser-search')), 'EQ');
      await tester.pump();
      final rows = find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('fx-browser-') &&
          (w.key! as ValueKey<String>).value.contains('org.caw.'));
      expect(rows, findsWidgets);
      expect((tester.widget(rows.first).key! as ValueKey<String>).value, endsWith('org.caw.eq'));
      expect(find.text('Plume · EQ'), findsOneWidget);
    });

    testWidgets('a purpose chip lists its chain templates, then its devices; a template adds its chain', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('fx-purpose-guitar')));
      await tester.pump();
      for (final id in ['chain:guitar-clean', 'chain:guitar-crunch', 'chain:guitar-lead']) {
        expect(find.byKey(ValueKey('fx-template-$id')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('fx-template-chain:vocal')), findsNothing);
      expect(find.text('Hatch · Gate'), findsOneWidget, reason: 'a guitar device');
      expect(find.text('Chirp · Pitch correction'), findsNothing, reason: 'not a guitar device');
    });

    test('every chain template\'s presets are the engine\'s, and one applies as one undo step', () {
      final presets = fixturePresets();
      for (final t in ChainTemplates.all) {
        expect(t.steps, isNotEmpty);
        for (final step in t.steps) {
          expect(DeviceNames.of(step.componentId), isNotNull, reason: '${t.name}: ${step.componentId}');
          if (step.preset case final name?) {
            expect(presets[step.componentId], contains(name), reason: '${t.name}: ${step.componentId} "$name"');
          }
        }
      }
      for (final name in ['Guitar clean', 'Guitar crunch', 'Guitar lead', 'Vocal', 'Podcast voice', 'Drum bus', 'Master']) {
        expect(ChainTemplates.all.where((t) => t.name == name), hasLength(1), reason: name);
      }
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
      final layer = s.project.layers.first;
      final vocal = ChainTemplates.byId('chain:vocal')!;
      expect(s.dropAsset(layer, AssetDrag(AssetKind.chainTemplate, vocal.id, vocal.name)), isTrue);
      expect(layer.components.map((c) => c.id), [for (final st in vocal.steps) st.componentId]);
      expect(layer.components[1].params['variant'], isNotNull, reason: 'Plume starts from "Vocal presence"');
      expect(s.undo(), isTrue);
      expect(s.project.layers.first.components, isEmpty, reason: 'one undo step');
    });
  });

  group('project templates', () {
    test('Guitar recording, Podcast, Beat and Sound design load as projects', () {
      final s = AppState(settings: Settings());
      addTearDown(s.dispose);
      s.project = ProjectDoc(id: 'p', name: 'n', layers: []);
      s.componentCatalog.set(builtinInfos());
      final names = s.projectTemplates.map((t) => t.name).toList();
      expect(names, containsAll(['Guitar recording', 'Podcast', 'Beat', 'Sound design']));
      for (final id in ['builtin:guitar-recording', 'builtin:podcast', 'builtin:beat', 'builtin:sound-design']) {
        final t = s.templateById(id)!;
        expect(templateLabel(id), t.name);
        final p = s.projectFromTemplate(t);
        expect(p.layers, isNotEmpty, reason: id);
        expect(p.masterComponents, isNotEmpty, reason: id);
        // It round-trips as a file would.
        final again = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
        expect(again.layers.length, p.layers.length);
        s.settings.newProjectTemplate = id;
        expect(s.newProjectDoc().name, t.name);
      }
      final podcast = s.projectFromTemplate(s.templateById('builtin:podcast')!);
      expect(podcast.layers.every((l) => l.input != null), isTrue, reason: 'voice tracks record audio');
      final beat = s.projectFromTemplate(s.templateById('builtin:beat')!);
      expect(beat.layers.first.instrument?.id, 'org.caw.drums');
    });
  });

  group('the field guide and Happy accident', () {
    late AppState s;
    late DeviceDisplaySource display;
    setUp(() {
      display = DeviceDisplaySource.current;
      DeviceDisplaySource.current = DeviceDisplaySource.none;
      Motion.setting = MotionLevel.off;
      MotionClock.hold = true;
      s = AppState(settings: Settings());
      s.project = ProjectDoc(id: 'p', name: 'n', bpm: 120, modules: [], layers: [LayerDoc(id: 'a', name: 'Lead', color: 2)]);
      s.componentCatalog.set(builtinInfos());
      s.setNativeInstrument(s.project.layers.first, 'org.caw.synth.flagship');
      addBuiltinEffect(s, s.project.layers.first, 'org.caw.compressor');
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
    });
    tearDown(() {
      DeviceDisplaySource.current = display;
      MotionClock.hold = false;
      s.dispose();
    });

    test('every named effect and instrument has its own guide with three knobs; its preset is the engine\'s', () {
      final presets = fixturePresets();
      for (final e in DeviceNames.table.entries) {
        final g = fieldGuides[e.key];
        expect(g, isNotNull, reason: '${e.value.name} has no field guide');
        expect(g!.knobs, hasLength(3), reason: e.value.name);
        expect(g.what, startsWith(e.value.name), reason: 'it says what ${e.value.name} does');
        final have = presets[e.key];
        if (g.preset != null && have != null && have.isNotEmpty) expect(have, contains(g.preset), reason: '${e.value.name}: "${g.preset}"');
      }
    });

    testWidgets('"?" in the header opens the guide; Load it is one undo step', (tester) async {
      tester.view.physicalSize = const Size(412, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
          builder: (_, _) => FxStack(state: s, layer: s.project.layers.first)))));
      await tester.pump();
      final guide = find.descendant(of: find.byKey(const ValueKey('fx-device-0')),
          matching: find.byKey(const ValueKey('device-guide')));
      expect(guide, findsOneWidget);
      await tester.tap(guide);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('device-guide-sheet')), findsOneWidget);
      expect(find.textContaining('Talon evens out'), findsOneWidget);
      expect(find.text('Gentle glue'), findsWidgets);
      final t = DeviceTarget(s, 'a', 0);
      final before = t.value('threshold');
      await tester.tap(find.byKey(const ValueKey('device-guide-load')));
      await tester.pumpAndSettle();
      expect(t.value('threshold'), isNot(before));
      expect(s.undo(), isTrue);
      expect(DeviceTarget(s, 'a', 0).value('threshold'), before);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    test('Happy accident nudges an effect a small step, as one undo step', () {
      final t = DeviceTarget(s, 'a', 0);
      final before = {for (final p in t.info!.parameters) p.id: t.value(p.id)};
      happyAccident(t, random: math.Random(4));
      final after = {for (final p in t.info!.parameters) p.id: t.value(p.id)};
      expect(after, isNot(before), reason: 'the sound moved');
      expect(s.undo(), isTrue);
      final undone = DeviceTarget(s, 'a', 0);
      expect({for (final p in undone.info!.parameters) p.id: undone.value(p.id)}, before, reason: 'one undo step');
    });

    test('Happy accident works on an instrument too', () {
      final t = DeviceTarget(s, 'a', DeviceTarget.instrumentSlot);
      final cutoff = t.value('flt1_cutoff');
      final before = {for (final p in t.info!.parameters) p.id: t.value(p.id)};
      happyAccident(t, random: math.Random(9));
      expect({for (final p in t.info!.parameters) p.id: t.value(p.id)}, isNot(before));
      expect(s.undo(), isTrue);
      expect(DeviceTarget(s, 'a', DeviceTarget.instrumentSlot).value('flt1_cutoff'), cutoff);
    });

    testWidgets('⋯ lists Happy accident', (tester) async {
      tester.view.physicalSize = const Size(412, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
          builder: (_, _) => FxStack(state: s, layer: s.project.layers.first)))));
      await tester.pump();
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('fx-device-0')),
          matching: find.byKey(const ValueKey('device-more'))));
      await tester.pumpAndSettle();
      expect(find.text('Happy accident'), findsOneWidget);
      await tester.tap(find.text('Happy accident'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Undo puts it back'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });
  });

  test('with the engine: every built-in it lists is named, and every guide and chain preset exists (needs CAW_LIB)',
      () async {
    final engine = Engine.create();
    addTearDown(engine.dispose);
    final infos = await engine.nativeComponents();
    final byId = {for (final c in infos) c.id: c};
    for (final c in infos.where((c) => c.builtin)) {
      expect(DeviceNames.of(c.id), isNotNull, reason: '${c.id} has no name');
    }
    for (final e in fieldGuides.entries) {
      final info = byId[e.key];
      if (info == null || e.value.preset == null) continue;
      expect(info.presets.map((p) => p.name), contains(e.value.preset), reason: '${e.key}: "${e.value.preset}"');
    }
    for (final t in ChainTemplates.all) {
      for (final step in t.steps) {
        if (step.preset case final name?) {
          expect(byId[step.componentId]?.presets.map((p) => p.name), contains(name), reason: '${t.name}: $name');
        }
      }
    }
  }, skip: Platform.environment['CAW_LIB']?.isNotEmpty != true);
}
