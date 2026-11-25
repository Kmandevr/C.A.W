// Rook (org.caw.drums) 1.1.3 used like the owner: a new project, add Rook, open its page at phone size, the kit opens on the studio kit, the kind cards switch kinds, pads play, Randomness turns and Randomize reads it; the presets in categories, best first; goldens of the page at phone size; with CAW_LIB the same through the real engine's presets.
import 'dart:io';

import 'package:caw/engine/component_info.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/drums.dart';
import 'package:caw/model/drums_needs.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/ui/devices/drums/drums_pads.dart';
import 'package:caw/ui/devices/kit/presets.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

const id = drumsComponentId;

/// Records Randomize's calls and answers as the engine does for a Simulated pad: its piece's tuning moved.
class RecordingDrumsApi extends DrumsApi {
  final calls = <(int type, double amount, int pad, Map<String, double>? current)>[];

  @override
  Map<String, double>? randomize(int type, int seed, double amount, int pad, Map<String, double>? current) {
    calls.add((type, amount, pad, current));
    final piece = (current?['acou_piece'] ?? 0).round() + 1;
    return {'${padId(pad)}_rnd_pos': 0.3, 'pc${piece}_tune': (current?['pc${piece}_tune'] ?? 0) + 2 * amount};
  }

  @override
  Map<String, dynamic>? explode(Map<String, dynamic> entry) => null;

  @override
  List<String>? builtinSamples() => const [];

  @override
  List<({String name, int type, Map<String, double> params})>? sounds() => null;

  @override
  Map<String, List<String>>? builders() => {
        'synth': ['808-style', '909-style'],
        'produced': ['House', 'Pop'],
        'acoustic': ['Jazz', 'Studio'],
        'maps': ['General MIDI'],
        'chains': ['Punch'],
      };
}

void main() {
  var motion = MotionLevel.full;
  late DeviceDisplaySource source;
  late DrumsApi api;
  late RecordingDrumsApi fake;
  final states = <PreviewState>[];

  setUp(() {
    motion = Motion.setting;
    source = DeviceDisplaySource.current;
    DeviceDisplaySource.current = FakeDisplay();
    api = DrumsApi.current;
    fake = RecordingDrumsApi();
    DrumsApi.current = fake;
    DrumsSelection.reset();
  });
  tearDown(() {
    Motion.setting = motion;
    DeviceDisplaySource.current = source;
    DrumsApi.current = api;
    for (final s in states) {
      s.dispose();
    }
    states.clear();
  });

  /// A new project with one empty track, and Rook added to it as the app's instrument picker does.
  PreviewState newProjectWithRook({List<NativeComponentInfo>? infos}) {
    final s = PreviewState();
    states.add(s);
    s.project = ProjectDoc(id: 'p', name: 'New', bpm: 120, modules: [], layers: [LayerDoc(id: 'a', name: 'Track', color: 2)]);
    s.componentCatalog.set(infos ?? builtinInfos());
    s.setNativeInstrument(s.project.layers.first, id);
    DevicePresets.restoreRemembered(targetOf(s, id), null);  // no preset remembered from an earlier test's track
    return s;
  }

  Future<void> openPage(WidgetTester tester, PreviewState s, {Size size = const Size(390, 844), bool motionOn = false}) async {
    Motion.setting = motionOn ? MotionLevel.full : MotionLevel.off;
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

  Map<String, double> presetValues(DeviceTarget t, String name) =>
      DevicePresets.factory(t).firstWhere((p) => p.name == name).values;

  testWidgets('a new Rook opens on the studio kit; the kind cards switch kinds; pads play; Randomness drives Randomize',
      (tester) async {
    final s = newProjectWithRook();
    final t = targetOf(s, id);
    // The new instrument starts from the realistic kit's values, so its knobs and the engine get them.
    final studio = presetValues(t, 'Acoustic kit: Studio');
    expect(studio, isNotEmpty);
    for (final e in studio.entries) {
      expect(t.value(e.key), e.value, reason: e.key);
    }
    expect(drumKindOf(t), 2, reason: 'Acoustic');
    await openPage(tester, s, size: const Size(360, 800));
    expect(tester.takeException(), isNull);
    for (var k = 0; k < 3; k++) {
      expect(find.byKey(ValueKey('drum-kind-$k')), findsOneWidget);
    }
    expect(tester.getTopLeft(find.byKey(const ValueKey('drum-kinds'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('drum-grid'))).dy), reason: 'the kinds sit over the pads');
    expect(find.text('Studio'), findsOneWidget, reason: 'the playing kind names its kit');
    expect(find.byKey(const ValueKey('drum-build-card')), findsNothing, reason: 'the kind cards replace Build a kit');
    // A pad plays its note: the studio kit's kick is on GM 36.
    Future<void> tapPad(int pad) async {
      final g = await tester.startGesture(tester.getCenter(find.byKey(ValueKey('drum-pad-$pad'))));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
    }
    await tapPad(0);
    expect(s.played.last.$1, 36);
    // Synth: one tap switches the whole kit to the kind's best kit, one undo step.
    for (final (kind, name) in drumKindDefaults.indexed) {
      await tester.tap(find.byKey(ValueKey('drum-kind-$kind')));
      await tester.pumpAndSettle();
      if (kind == 2) break;  // already Acoustic: the tap opened its kits (checked below)
      expect(drumKindOf(t), kind, reason: name);
      for (final e in presetValues(t, name).entries) {
        expect(t.value(e.key), e.value, reason: '$name: ${e.key}');
      }
      await tapPad(1);
      expect(s.played, isNotEmpty);
    }
    // Back on Acoustic (the Studio kit), a second tap lists the kind's kits.
    expect(drumKindOf(t), 2);
    await tester.tap(find.byKey(const ValueKey('drum-kind-2')));
    await tester.pumpAndSettle();
    expect(find.text('ACOUSTIC KITS'), findsOneWidget);
    expect(find.text('Jazz'), findsOneWidget);
    await tester.tap(find.text('Jazz'));
    await tester.pumpAndSettle();
    for (final e in presetValues(t, 'Acoustic kit: Jazz').entries) {
      expect(t.value(e.key), e.value, reason: 'Jazz: ${e.key}');
    }
    loadDrumKindForTest(t, 2);
    await tester.pumpAndSettle();
    // Randomness: a deliberate drag turns it, and Randomize sends it as its amount, the pad's piece with it.
    final knob = find.byKey(const ValueKey('dknob-randomness'));
    expect(knob, findsOneWidget);
    final before = t.value('randomness');
    await restDrag(tester, tester.getCenter(knob), const Offset(0, -60));
    await tester.pumpAndSettle();
    final after = t.value('randomness');
    expect(after, greaterThan(before));
    await tapPad(3);  // the snare (GM 38: the map's fourth pad, after two kicks and the cross-stick)
    final tuneWas = t.value('pc2_tune');
    await tester.tap(find.byKey(const ValueKey('drum-randomize')));
    await tester.pumpAndSettle();
    expect(fake.calls.last.$2, closeTo(after, 1e-9));
    expect(fake.calls.last.$4!['engine'], 1, reason: 'a Simulated pad sends its values');
    expect(fake.calls.last.$4!.keys, contains('pc2_tune'), reason: '... and its piece\'s');
    expect(t.value('pc2_tune'), closeTo(tuneWas + 2 * after, 1e-9), reason: 'the piece took the result');
    await close(tester);
  });

  test('a Simulated pad\'s synth-only settings say what turns them on', () {
    final s = newProjectWithRook();
    final t = targetOf(s, id);
    final layout = DrumsLayout.of(t.info!);
    expect(t.value('a1_engine'), 1, reason: 'the studio kit\'s kick is Simulated');
    for (final suffix in ['body_decay', 'pan', 'tune', 'drive', 'eq_low', 'punch', 'vel_level']) {
      final n = drumUnmetNeed(t, layout, 0, suffix);
      expect(n, isNotNull, reason: suffix);
      expect(drumNeedText(t, layout, 0, n!), 'Synthesized pads only: set Engine to Synthesized', reason: suffix);
    }
    // What a Simulated pad does hear is not dimmed.
    for (final suffix in ['level', 'rnd_pos', 'acou_artic']) {
      expect(drumUnmetNeed(t, layout, 0, suffix), isNull, reason: suffix);
    }
    // A Synthesized pad's layer settings need their layer, as before.
    t.set('a1_engine', 0);
    expect(drumNeedText(t, layout, 0, drumUnmetNeed(t, layout, 0, 'noise_decay')!), 'Turn Noise on');
  });

  testWidgets('switching kinds animates the cards (motion on) and fits a 360 dp phone and its side', (tester) async {
    final s = newProjectWithRook();
    await openPage(tester, s, size: const Size(360, 740), motionOn: true);
    await tester.tap(find.byKey(const ValueKey('drum-kind-0')));
    await tester.pump(const Duration(milliseconds: 40));
    // Mid-way the cards are still moving: an AnimatedContainer between its colours.
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await close(tester);
    final side = newProjectWithRook();
    await openPage(tester, side, size: const Size(800, 390));
    expect(find.byKey(const ValueKey('drum-kinds')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  test('presets come in categories, the three kinds\' best kits first', () {
    final s = newProjectWithRook();
    final t = targetOf(s, id);
    final list = DevicePresets.fromDescriptor(t);
    expect(list.length, greaterThan(100));
    expect([for (final p in list.take(3)) p.name], ['Acoustic kit: Studio', 'Produced kit: Pop', 'Synth kit: 808-style']);
    final categories = <String>[];
    for (final p in list) {
      if (categories.isEmpty || categories.last != p.category) categories.add(p.category);
    }
    expect(categories.toSet().length, categories.length, reason: 'each category in one run');
    expect(categories.take(4), ['Best kits', 'Acoustic kits', 'Produced kits', 'Synth kits']);
    expect(categories, containsAll(['Classic kits', 'Kicks & bass', 'Snares & claps', 'Hi-hats', 'Toms', 'Cymbals']));
    expect(list.where((p) => p.category == 'Factory'), isEmpty);
  });

  group('goldens', () {
    for (final e in {'phone': const Size(390, 844), 'phone_small': const Size(360, 800)}.entries) {
      testWidgets(e.key, (tester) async {
        final s = newProjectWithRook();
        await openPage(tester, s, size: e.value);
        expect(tester.takeException(), isNull);
        await expectLater(goldenScreen, matchesGoldenFile('goldens/rook/new_rook_${e.key}.png'));
        await tester.tap(find.byKey(const ValueKey('drum-kind-0')));
        await tester.pumpAndSettle();
        await expectLater(goldenScreen, matchesGoldenFile('goldens/rook/synth_${e.key}.png'));
        await close(tester);
      });
    }
  });

  group('with the engine library (CAW_LIB)', () {
    final skip = (Platform.environment['CAW_LIB'] ?? '').isEmpty;

    testWidgets('a new Rook, its kinds and Randomize through the real engine', (tester) async {
      DrumsApi.current = const EngineDrumsApi();
      late List<NativeComponentInfo> infos;
      await tester.runAsync(() async {
        final e = Engine.create();
        infos = await e.nativeComponents();
        e.dispose();
      });
      final s = newProjectWithRook(infos: infos);
      final t = targetOf(s, id);
      expect(drumKindOf(t), 2);
      expect(t.value('pc1_rec'), 1, reason: 'the studio kit plays its recordings');
      expect(t.value('acou_mics'), 1, reason: 'close mics and overheads');
      expect(t.value('acou_room'), lessThan(0.2), reason: 'almost dry');
      for (final name in drumKindDefaults) {
        expect(DevicePresets.factory(t).where((p) => p.name == name), hasLength(1), reason: name);
      }
      await openPage(tester, s, size: const Size(360, 800));
      await tester.tap(find.byKey(const ValueKey('drum-kind-1')));
      await tester.pumpAndSettle();
      expect(drumKindOf(t), 1);
      await tester.tap(find.byKey(const ValueKey('drum-kind-2')));
      await tester.pumpAndSettle();
      // The snare's piece varies through the engine's Randomize, by Randomness.
      t.set('randomness', 0.9);
      final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('drum-pad-3'))));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      final was = {for (final k in ['pc2_tune', 'pc2_damp', 'pc2_size', 'pc2_decay']) k: t.value(k)};
      await tester.tap(find.byKey(const ValueKey('drum-randomize')));
      await tester.pumpAndSettle();
      expect(was.entries.any((e) => t.value(e.key) != e.value), isTrue);
      expect(t.value('pc2_kind'), 2, reason: 'a snare stays a snare');
      await close(tester);
    }, skip: skip);
  });
}

/// Loads a kind's best kit (the kind card's action) without the page.
void loadDrumKindForTest(DeviceTarget t, int kind) {
  final p = DevicePresets.factory(t).firstWhere((p) => p.name == drumKindDefaults[kind]);
  DevicePresets.apply(t, p);
}
