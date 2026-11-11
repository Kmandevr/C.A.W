// The Drums editor (org.caw.drums): pads and banks, a picked pad's layers, each card's ids, note learn, randomize and mutate, explode in one undo step, the sample picker, the Points editor, the inline view, goldens, and (with CAW_LIB) the real engine.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/drums.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/engine/component_info.dart';
import 'package:caw/ui/devices/device_controls.dart';
import 'package:caw/ui/devices/device_inline.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/drums/drums_hero.dart';
import 'package:caw/ui/devices/drums/drums_pads.dart';
import 'package:caw/ui/devices/drums/drums_samples.dart';
import 'package:caw/ui/devices/drums/drums_voice.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

const id = drumsComponentId;

/// A drums display frame: [peaks] by pad, a note received ([note], [count]), the shown pad's hit.
DrumsDisplayFrame drumsFrame({Map<int, double> peaks = const {}, int note = -1, int count = 0, int shown = 0,
    double seconds = 0.6}) {
  final mx = Float32List(256), mn = Float32List(256);
  for (var i = 0; i < 256; i++) {
    final env = (1 - i / 256) * (1 - i / 256);
    mx[i] = 0.9 * env;
    mn[i] = -0.85 * env;
  }
  return DrumsDisplayFrame(mode: 0, shownPad: shown, glueGr: 2, padGr: 0, waveSeconds: seconds, pitchSpan: 0,
    voices: 1, lastPad: shown, lastNote: note, lastChannel: 1, lastVelocity: 1, noteCount: count, penvMode: 0,
    peaks: Float32List.fromList([for (var i = 0; i < 64; i++) peaks[i] ?? 0]), waveMax: mx, waveMin: mn,
    pitch: Float32List(64));
}

/// Records the engine calls and answers with fixed values.
class FakeDrumsApi extends DrumsApi {
  final randomized = <(int type, double amount, int pad, Map<String, double>? current)>[];
  final exploded = <Map<String, dynamic>>[];
  Map<String, dynamic>? explodeResult;

  @override
  Map<String, double>? randomize(int type, int seed, double amount, int pad, Map<String, double>? current) {
    randomized.add((type, amount, pad, current));
    final p = padId(pad);
    return {'${p}_body_freq': 77, '${p}_body_decay': 0.33, '${p}_noise_on': 1, '${p}_note': 50, '${p}_level': -3};
  }

  @override
  Map<String, dynamic>? explode(Map<String, dynamic> entry) {
    exploded.add(entry);
    return explodeResult;
  }

  @override
  List<String>? builtinSamples() => ['808 Kick', 'Crash'];

  @override
  List<({String name, int type, Map<String, double> params})>? sounds() =>
      [(name: 'Crash', type: 7, params: {'type': 7, 'metal_on': 1})];
}

void main() {
  var motion = MotionLevel.full;
  late DeviceDisplaySource source;
  late FakeDisplay display;
  late DrumsApi api;
  late FakeDrumsApi fake;
  final states = <AppState>[];

  setUp(() {
    motion = Motion.setting;
    Motion.setting = MotionLevel.off;
    source = DeviceDisplaySource.current;
    display = FakeDisplay();
    DeviceDisplaySource.current = display;
    api = DrumsApi.current;
    fake = FakeDrumsApi();
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

  Future<PreviewState> open(WidgetTester tester, {Size size = const Size(390, 844), PreviewState? state}) async {
    final s = state ?? stateWith(id, make: PreviewState.new) as PreviewState;
    Motion.setting = MotionLevel.off;
    states.add(s);
    late BuildContext ctx;
    await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    })), size);
    openDevice(ctx, s, id);
    await tester.pumpAndSettle();
    return s;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  DeviceTarget target(AppState s) => targetOf(s, id);

  Future<void> tapPad(WidgetTester tester, int pad) async {
    final g = await tester.startGesture(tester.getCenter(find.byKey(ValueKey('drum-pad-$pad'))));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
  }

  /// Scrolls [page]'s list from the top until [f] is built, then onto the screen.
  Future<void> scrollTo(WidgetTester tester, Finder f, {String page = 'drums-pads'}) async {
    final pos = tester.state<ScrollableState>(find.descendant(of: find.byKey(ValueKey(page)),
      matching: find.byType(Scrollable)).first).position;
    pos.jumpTo(0);
    await tester.pump();
    while (f.evaluate().isEmpty && pos.pixels < pos.maxScrollExtent) {
      pos.jumpTo(pos.pixels + 250);
      await tester.pump();
    }
    await tester.ensureVisible(f.first);
    await tester.pumpAndSettle();
  }

  testWidgets('the registry gives org.caw.drums its own editor with PADS and KIT', (tester) async {
    expect(DeviceEditors.custom(id, builtinInfo(id)), isNotNull);
    await open(tester);
    expect(find.byKey(const ValueKey('device-tab-pads')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-tab-kit')), findsOneWidget);
    expect(find.byKey(const ValueKey('drum-grid')), findsOneWidget);
    await close(tester);
  });

  testWidgets('pad grid and banks: 16 pads, pad 1 at the bottom left; a bank shows its pads; a tap plays its note', (tester) async {
    final s = await open(tester);
    for (var i = 0; i < 16; i++) {
      expect(find.byKey(ValueKey('drum-pad-$i')), findsOneWidget);
    }
    final a1 = tester.getCenter(find.byKey(const ValueKey('drum-pad-0')));
    final a13 = tester.getCenter(find.byKey(const ValueKey('drum-pad-12')));
    expect(a1.dy, greaterThan(a13.dy));
    await tapPad(tester, 2);
    expect(s.played.last.$1, 38); // A3 on Auto: 36 + 2
    expect(s.held, isEmpty);
    await tester.tap(find.byKey(const ValueKey('drum-bank-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('drum-pad-0')), findsNothing);
    expect(find.byKey(const ValueKey('drum-pad-16')), findsOneWidget);
    await tapPad(tester, 17);
    expect(s.played.last.$1, 53);
    expect(target(s).value('view_pad'), 18); // the engine shows B2
    // Single mode: only A1 sounds, on its root.
    target(s).set('mode', 1);
    await tester.tap(find.byKey(const ValueKey('drum-bank-0')));
    await tester.pumpAndSettle();
    final before = s.played.length;
    await tapPad(tester, 3);
    expect(s.played.length, before);
    await tapPad(tester, 0);
    expect(s.played.last.$1, 60);
    await close(tester);
  });

  testWidgets('pads light with their peak from the display data', (tester) async {
    await open(tester);
    display.frame.value = drumsFrame(peaks: {0: 0.9});
    await tester.pump();
    expect(tester.takeException(), isNull);
    await expectLater(find.byKey(const ValueKey('drum-grid')), matchesGoldenFile('goldens/drums/grid_lit.png'));
    await close(tester);
  });

  testWidgets('selecting a pad shows its voice and its layer cards', (tester) async {
    await open(tester);
    await tapPad(tester, 2);
    expect(find.descendant(of: find.byKey(const ValueKey('drum-voice-pad')), matching: find.text('A3')), findsNothing);
    expect((tester.widget(find.byKey(const ValueKey('drum-voice-pad'))) as Text).data, 'A3');
    expect(find.byKey(const ValueKey('drum-character')), findsOneWidget);
    for (final card in ['pad', 'body', 'penv', 'sub', 'click', 'noise', 'metal', 'res', 'smp', 'drive', 'filter', 'eq',
      'dyn', 'space', 'press', 'var']) {
      await scrollTo(tester, find.byKey(ValueKey('drum-card-$card')));
      expect(find.byKey(ValueKey('drum-card-$card')), findsOneWidget, reason: card);
    }
    await close(tester);
  });

  testWidgets('each layer card edits the right <pad>_<suffix> ids', (tester) async {
    final s = await open(tester);
    await tapPad(tester, 4); // A5
    final t = target(s);
    final layout = DrumsLayout.of(t.info!);
    for (final layer in [for (final c in drumCardOrder) layout.byId[c]!]) {
      final card = find.byKey(ValueKey('drum-card-${layer.id}'));
      await scrollTo(tester, card);
      final head = find.descendant(of: card, matching: find.byKey(ValueKey('expand-drums-layer-${layer.id}')));
      if (find.descendant(of: card, matching: find.byType(DeviceKnob)).evaluate().isEmpty) {
        await tester.ensureVisible(head);
        await tester.pumpAndSettle();
        await tester.tap(head);
        await tester.pumpAndSettle();
      }
      final knobs = find.descendant(of: card, matching: find.byType(DeviceKnob));
      expect(knobs, findsWidgets, reason: layer.id);
      for (final e in knobs.evaluate()) {
        final pid = (e.widget as DeviceKnob).paramId;
        expect(pid.startsWith('a5_'), isTrue, reason: '${layer.id}: $pid');
        expect(layer.suffixes, contains(pid.substring(3)), reason: '${layer.id}: $pid');
      }
      // Turning the card's first knob moves that id on A5 alone.
      final first = (knobs.evaluate().first.widget as DeviceKnob).paramId;
      final before = t.value(first), other = t.value('a1_${first.substring(3)}');
      await tester.ensureVisible(knobs.first);
      await tester.pumpAndSettle();
      await tester.drag(knobs.first, Offset(0, before >= t.param(first)!.max ? 60 : -60));
      await tester.pumpAndSettle();
      expect(t.value(first), isNot(before), reason: first);
      expect(t.value('a1_${first.substring(3)}'), other, reason: first);
      await tester.ensureVisible(head);
      await tester.pumpAndSettle();
      await tester.tap(head);
      await tester.pumpAndSettle();
    }
    await close(tester);
  });

  testWidgets('a layer\'s power turns it on and off; drive and filter come back to their last type', (tester) async {
    final s = await open(tester);
    final t = target(s);
    await scrollTo(tester, find.byKey(const ValueKey('dpower-a1_drive_type')));
    expect(t.value('a1_drive_type'), 1);
    t.set('a1_drive_type', 4);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dpower-a1_drive_type')));
    await tester.pumpAndSettle();
    expect(t.value('a1_drive_type'), 0);
    await tester.tap(find.byKey(const ValueKey('dpower-a1_drive_type')));
    await tester.pumpAndSettle();
    expect(t.value('a1_drive_type'), 4);
    await scrollTo(tester, find.byKey(const ValueKey('dpower-a1_noise_on')));
    await tester.tap(find.byKey(const ValueKey('dpower-a1_noise_on')));
    await tester.pumpAndSettle();
    expect(t.value('a1_noise_on'), 1);
    await close(tester);
  });

  testWidgets('note learn writes 3 + key into the pad\'s note when the next note arrives', (tester) async {
    final s = await open(tester);
    await tapPad(tester, 2);
    await scrollTo(tester, find.byKey(const ValueKey('expand-drums-layer-pad')));
    await tester.tap(find.byKey(const ValueKey('expand-drums-layer-pad')));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const ValueKey('drum-learn-2')));
    await tester.tap(find.byKey(const ValueKey('drum-learn-2')));
    await tester.pumpAndSettle();
    expect(DrumsSelection.of(target(s)).learning.value, 2);
    display.frame.value = drumsFrame(note: 38, count: 5); // the baseline: what was played before
    await tester.pump();
    expect(target(s).value('a3_note'), 0);
    display.frame.value = drumsFrame(note: 40, count: 6);
    await tester.pumpAndSettle();
    expect(target(s).value('a3_note'), 43);
    expect(DrumsSelection.of(target(s)).learning.value, isNull);
    await close(tester);
  });

  testWidgets('randomize and mutate call the engine, for the pad and for one layer', (tester) async {
    final s = await open(tester);
    final t = target(s);
    await tapPad(tester, 2);
    await tester.tap(find.byKey(const ValueKey('drum-randomize')));
    await tester.pumpAndSettle();
    expect(fake.randomized.last.$1, t.value('a3_type').round());
    expect(fake.randomized.last.$2, 1);
    expect(fake.randomized.last.$3, 2);
    expect(fake.randomized.last.$4, isNull);
    expect(t.value('a3_body_freq'), 77);
    expect(t.value('a3_note'), 0, reason: 'the note map stays');
    await tester.tap(find.byKey(const ValueKey('drum-mutate')));
    await tester.pumpAndSettle();
    expect(fake.randomized.last.$1, -1);
    expect(fake.randomized.last.$4!['body_freq'], 77);
    // One layer: only Body's knobs take the result.
    t.setAll({'a3_body_freq': 100, 'a3_noise_on': 0, 'a3_level': 0});
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const ValueKey('drum-layer-dice-body')));
    await tester.tap(find.byKey(const ValueKey('drum-layer-dice-body')));
    await tester.pumpAndSettle();
    expect(t.value('a3_body_freq'), 77);
    expect(t.value('a3_noise_on'), 0);
    expect(t.value('a3_level'), 0);
    // Undo takes the whole pad change back in one step.
    s.endUndoStep();
    await close(tester);
  });

  testWidgets('the pad menu: copy, paste, clear, choke and a library sound', (tester) async {
    final s = await open(tester);
    final t = target(s);
    final layout = DrumsLayout.of(t.info!);
    copyPad(t, layout, 0);
    expect(pastePad(t, layout, 20), isTrue);
    expect(t.value('b5_body_freq'), t.value('a1_body_freq'));
    expect(t.value('b5_note'), 0);
    clearPad(t, layout, 0);
    expect(DrumPadView(t, layout, 0).used, isFalse);
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('drum-pad-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('long-press-menu')), findsOneWidget);
    await tester.tap(find.text('Choke: Off'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Group 3'));
    await tester.pumpAndSettle();
    expect(t.value('a2_choke'), 3);
    await tester.longPress(find.byKey(const ValueKey('drum-pad-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load sound…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Crash').last);
    await tester.pumpAndSettle();
    expect(t.value('a2_type'), 7);
    expect(t.value('a2_metal_on'), 1);
    expect(t.value('a2_body_on'), 0, reason: 'a sound starts from an empty pad');
    await close(tester);
  });

  testWidgets('the sample picker: a built-in, a file from the device, and remove', (tester) async {
    final s = await open(tester);
    final t = target(s);
    await tapPad(tester, 2);
    await scrollTo(tester, find.byKey(const ValueKey('drum-card-smp')));
    await tester.tap(find.byKey(const ValueKey('expand-drums-layer-smp')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('drum-sample-load')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('drum-sample-picker')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('drum-sample-builtin-Crash')));
    await tester.pumpAndSettle();
    expect(t.use!.samples.single.toJson(), {'slot': 2, 'builtin': 'Crash'});
    expect(t.value('a3_smp_on'), 1);
    expect(t.use!.toJson(), containsPair('samples', [{'slot': 2, 'builtin': 'Crash'}]));
    // The project keeps it through a save and load (undo's round trip).
    final again = ComponentUseDoc.fromJson(t.use!.toJson())!;
    expect(again.samples.single.builtin, 'Crash');
    DrumSampleImport.pick = () async => '/data/drum_samples/my kick.wav';
    await tester.tap(find.byKey(const ValueKey('drum-sample-load')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Device'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('drum-sample-pick')));
    await tester.pumpAndSettle();
    expect(t.use!.samples.single.path, '/data/drum_samples/my kick.wav');
    await tester.tap(find.byKey(const ValueKey('drum-sample-load')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('drum-sample-remove')));
    await tester.pumpAndSettle();
    expect(t.use!.samples, isEmpty);
    expect(t.value('a3_smp_on'), 0);
    await close(tester);
  });

  testWidgets('the Points pitch editor: dragging a point on the hero moves its time and pitch', (tester) async {
    final s = await open(tester);
    final t = target(s);
    t.set('a1_penv_mode', 1);
    await tester.pumpAndSettle();
    final hero = find.byKey(const ValueKey('drums-hero'));
    final rect = tester.getRect(hero);
    final layout = DrumsLayout.of(t.info!);
    final shape = DrumPitchShape(DrumPadView(t, layout, 0));
    final at = rect.topLeft + drumHeroPoint(shape, 2, rect.size, drumHeroAxis(shape));
    final t2 = t.value('a1_penv_t2'), p2 = t.value('a1_penv_p2');
    await tester.dragFrom(at, const Offset(40, -30));
    await tester.pumpAndSettle();
    expect(t.value('a1_penv_t2'), greaterThan(t2));
    expect(t.value('a1_penv_p2'), greaterThan(p2));
    // The start point sets the depth.
    final start = rect.topLeft + drumHeroPoint(shape, 0, rect.size, drumHeroAxis(shape));
    final depth = t.value('a1_body_pitch');
    await tester.dragFrom(start + const Offset(-3, 0), const Offset(0, -30));
    await tester.pumpAndSettle();
    expect(t.value('a1_body_pitch'), greaterThan(depth));
    // Curve mode: the left quarter drags the sweep, the rest the decay.
    t.set('a1_penv_mode', 0);
    await tester.pumpAndSettle();
    final decay = t.value('a1_body_decay');
    await tester.dragFrom(rect.center, const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(t.value('a1_body_decay'), lessThan(decay));
    await close(tester);
  });

  testWidgets('explode creates a track per pad, moves the notes, and undoes in one step', (tester) async {
    final s = stateWith(id, make: PreviewState.new) as PreviewState;
    final layer = s.project.layers.first;
    final pattern = ModuleDoc(id: 'pat', name: 'Beat', source: '---\ncaw: 1\nkind: pattern\nname: Beat\nlength: 16\n---\n'
        '0 C2 1 1\n4 D2 1 1\n8 C2 1 1\n12 F#2 1 1\n');
    s.editProject((p) {
      p.modules.add(pattern);
      layer.clips.add(ClipDoc(id: 'c1', patternId: 'pat', startSteps: 16, lengthSteps: 16));
    });
    s.starting = false; // as after a project opens
    s.history.reset(jsonEncode(s.project.toJson()));
    fake.explodeResult = {
      'ok': true,
      'tracks': [
        {'pad': 'a1', 'name': 'A1 Kick', 'notes': [36], 'choke': 0, 'instrument': {'id': id, 'params': {'mode': 1, 'a1_body_freq': 50}}},
        {'pad': 'a3', 'name': 'A3 Snare', 'notes': [38], 'choke': 0, 'instrument': {'id': id, 'params': {'mode': 1}}},
      ],
      'kit': {},
    };
    final layers = s.project.layers.length;
    await open(tester, state: s);
    await tester.tap(find.byKey(const ValueKey('device-tab-kit')));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const ValueKey('drum-explode')), page: 'drums-kit');
    await tester.tap(find.byKey(const ValueKey('drum-explode')));
    await tester.pumpAndSettle();
    expect(fake.exploded.single['id'], id);
    expect(s.project.layers.length, layers + 2);
    final kick = s.project.layers[1], snare = s.project.layers[2];
    expect(kick.name, 'A1 Kick');
    expect(kick.instrument!.params['a1_body_freq'], 50);
    String notesOf(LayerDoc l) => l.clips.map((c) => s.project.module(c.patternId)!.source).join();
    expect(kick.clips.single.startSteps, 16);
    expect(RegExp(r'C2').allMatches(notesOf(kick)).length, 2);
    expect(notesOf(snare), contains('D2'));
    expect(notesOf(snare), isNot(contains('C2')));
    final rest = notesOf(s.project.layers.first);
    expect(rest, contains('F#2'));
    expect(rest, isNot(contains(RegExp(r'\bC2\b'))));
    expect(s.project.module('pat')!.source, contains('C2'), reason: 'the original pattern is left as it was');
    expect(s.undo(), isTrue);
    expect(s.project.layers.length, layers);
    expect(s.project.layers.first.clips.single.patternId, 'pat');
    await close(tester);
  });

  testWidgets('the inline view: grid, hero and Character in the FX stack; a pad plays', (tester) async {
    final s = stateWith(id, make: PreviewState.new) as PreviewState;
    states.add(s);
    final t = target(s);
    await pumpGolden(tester, Scaffold(body: SingleChildScrollView(child: DeviceInline(target: t))), const Size(390, 844));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('drums-inline')), findsOneWidget);
    expect(find.byKey(const ValueKey('drums-hero')), findsOneWidget);
    expect(find.byKey(const ValueKey('drum-character')), findsOneWidget);
    await tapPad(tester, 0);
    expect(s.played.last.$1, 36);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/drums/inline_phone.png'));
    await close(tester);
  });

  group('goldens', () {
    for (final e in goldenSizes.entries) {
      testWidgets(e.key, (tester) async {
        await open(tester, size: e.value);
        display.frame.value = drumsFrame(peaks: {0: 0.8, 6: 0.4});
        await tester.pump();
        expect(tester.takeException(), isNull);
        await expectLater(goldenScreen, matchesGoldenFile('goldens/drums/pads_${e.key}.png'));
        await tester.tap(find.byKey(const ValueKey('device-tab-kit')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(goldenScreen, matchesGoldenFile('goldens/drums/kit_${e.key}.png'));
        await close(tester);
      });
    }
  });

  testWidgets('a narrow phone (360 dp) fits the pads page without overflow', (tester) async {
    await open(tester, size: const Size(360, 740));
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  group('with the engine library (CAW_LIB)', () {
    final skip = (Platform.environment['CAW_LIB'] ?? '').isEmpty ? 'set CAW_LIB to the built engine library' : null;

    test('the layers from the descriptor match caw_drums_info', () async {
      DrumsApi.current = const EngineDrumsApi();
      final e = Engine.create();
      final drums = (await e.nativeComponents()).firstWhere((c) => c.id == id);
      e.dispose();
      final info = Engine.drumsInfo()!;
      final layout = DrumsLayout.of(drums);
      expect([for (final l in layout.layers) (l.id, l.name, l.suffixes)],
          [for (final l in info['layers'] as List) (l['id'], l['name'], [...(l['params'] as List)])]);
      expect([for (final g in layout.kitGroups.values) ...g], info['globals']);
      expect(info['display']['floats'], DrumsDisplayFrame.floats);
      expect(info['display']['version'], DrumsDisplayFrame.version);
      expect(drums.parameters.length, 10392);
      // Randomize and explode through the real engine.
      final r = const EngineDrumsApi().randomize(0, 3, 1, 5, null)!;
      expect(r.keys.where((k) => k.startsWith('a6_')).length, 162);
      final x = const EngineDrumsApi().explode({'id': id, 'params': <String, double>{}})!;
      expect((x['tracks'] as List).length, greaterThan(1));
      expect(const EngineDrumsApi().builtinSamples(), contains('808 Kick'));
    }, skip: skip);

    testWidgets('a project with the old drums migrates and opens in the new editor, on the real descriptor', (tester) async {
      DrumsApi.current = const EngineDrumsApi();
      late List<NativeComponentInfo> infos;
      await tester.runAsync(() async {
        final e = Engine.create();
        infos = await e.nativeComponents();
        e.dispose();
      });
      final s = PreviewState();
      states.add(s);
      s.project = ProjectDoc(id: 'p', name: 'Old', bpm: 120, modules: [], layers: [
        LayerDoc(id: 'a', name: 'Kit', color: 2, instrument: ComponentUseDoc('org.caw.drum.kit', {'kick_tune': 60}))]);
      s.componentCatalog.set(infos);
      expect(s.project.resolveInstruments(Engine.resolveInstrument), isTrue);
      expect(s.project.layers.first.instrument!.id, id);
      await open(tester, state: s);
      expect(find.byKey(const ValueKey('drums-pads')), findsOneWidget);
      expect(find.byKey(const ValueKey('device-fallback')), findsNothing);
      // Kit mode with the old kit's keys: A1 on C2.
      expect((tester.widget(find.byKey(const ValueKey('drum-voice-pad'))) as Text).data, 'A1');
      final t = target(s);
      expect(DrumPadView(t, DrumsLayout.of(t.info!), 0).used, isTrue);
      await tester.tap(find.byKey(const ValueKey('drum-randomize')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await close(tester);
    }, skip: skip != null);
  });

  test('drum knob labels drop the pad and the layer word', () {
    final t = DeviceTarget(stateWith(id, make: PreviewState.new), 'a', DeviceTarget.instrumentSlot);
    states.add(t.state);
    expect(drumKnobLabel(t.param('c4_body_decay')!), 'Decay');
    expect(drumKnobLabel(t.param('a1_press_damp')!), 'Damp');
    expect(drumKnobLabel(t.param('a1_level')!), 'Level');
    expect(noteName(36), 'C2');
    expect(noteValueFor(40), 43);
  });

  test('the pitch shape follows the engine\'s formulas', () {
    final s = stateWith(id, make: PreviewState.new);
    states.add(s);
    final t = target(s);
    final layout = DrumsLayout.of(t.info!);
    t.setAll({'a1_penv_mode': 1, 'a1_body_pitch': 24, 'a1_penv_t1': 0.01, 'a1_penv_p1': 12, 'a1_penv_c1': 0,
      'a1_penv_p4': 0, 'a1_tune': 0, 'a1_punch': 0, 'a1_pitch': 0});
    final shape = DrumPitchShape(DrumPadView(t, layout, 0));
    expect(shape.semitones(0), closeTo(24, 1e-9));
    expect(shape.semitones(0.005), closeTo(18, 1e-6)); // halfway along a straight segment
    expect(shape.semitones(10), 0);
    expect(DrumPitchShape.segmentCurve(0.5, 1), greaterThan(0.5));
    expect(DrumPitchShape.segmentCurve(0.5, -1), lessThan(0.5));
  });
}
