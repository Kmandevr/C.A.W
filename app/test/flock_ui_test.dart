// Flock's editor (org.caw.flock): the sample in the instrument's state (and in the project's dependencies), the source tiles, a dropped or picked sample, the drag on the picture (position and spray), the grain cloud and readouts from the display data, the phone's three panels and the wide screen, goldens at phone and desktop size, and (with the engine) the fixture and its place in the instrument lists.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:caw/engine/component_info.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:caw/model/flock.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/project_dependencies.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/audio_waveform.dart';
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/flagship/flagship_tools.dart' show FlagshipKeys;
import 'package:caw/ui/devices/flock/flock_editor.dart';
import 'package:caw/ui/devices/sampler/sampler_editor.dart' show SamplerFiles;
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';
import 'device_ui_fixture.dart' show FakeDisplay;
import 'golden_util.dart';

NativeComponentInfo flockInfo() => NativeComponentInfo.listFromJson(
        jsonDecode(File('test/fixtures/builtin_components.json').readAsStringSync()) as Map<String, dynamic>)
    .firstWhere((c) => c.id == flockComponentId);

AppState flockState() {
  final s = AppState(settings: Settings())..starting = false; // as after a project opens: edits are undo steps
  s.project = ProjectDoc(id: 'p', name: 'Flock', bpm: 120, assets: [
    AudioAssetDoc(id: 'a1', path: '/abs/voice.wav', name: 'voice', seconds: 3),
  ], layers: [LayerDoc(id: 'a', name: 'Cloud', color: 5)]);
  s.componentCatalog.set([flockInfo()]);
  s.setNativeInstrument(s.project.layers.first, flockComponentId);
  return s;
}

/// A Flock display frame: [grains] as (position, window phase, pan, semitones, voice), the source (0 a sample, 1–4 a
/// built-in tone + 1), [voices] sounding, the overview a swell.
DeviceDisplayFrame flockFrame({List<List<double>> grains = const [], int source = 1, int voices = 2, int cap = 128,
    int dropped = 0, bool missing = false, double seconds = 2, double position = 0.3}) {
  final f = Float32List(44 + 5 * grains.length);
  f.setAll(0, [1, grains.length.toDouble(), cap.toDouble(), dropped.toDouble(), voices.toDouble(), source.toDouble(),
    missing ? 1 : 0, seconds, position, 90, -12, grains.length.toDouble()]);
  for (var b = 0; b < 32; b++) {
    f[12 + b] = (0.2 + 0.7 * (b < 6 ? b / 6 : 1 - (b - 6) / 40)).clamp(0, 1).toDouble();
  }
  for (var k = 0; k < grains.length; k++) {
    f.setAll(44 + 5 * k, grains[k]);
  }
  return DeviceDisplayFrame(raw: f.toList());
}

/// A cloud like the defaults' (about 14 grains) around 0.3 with a little pitch spread.
List<List<double>> cloud({int n = 14}) => [
      for (var k = 0; k < n; k++)
        [0.22 + 0.16 * ((k * 7) % 11) / 11, (k * 0.13) % 1, ((k % 5) - 2) / 2.5, ((k * 5) % 13) - 6.0, (k % 3).toDouble()],
    ];

void main() {
  late AppState s;
  late DeviceDisplaySource source;
  late FakeDisplay display;
  late FakeAudioIo io;
  final states = <AppState>[];
  setUp(() {
    s = flockState();
    states.add(s);
    io = FakeAudioIo()..seconds['/abs/voice.wav'] = 3;
    s.audioIo = io;
    WaveformCache.instance.clear();
    Motion.setting = MotionLevel.off;
    source = DeviceDisplaySource.current;
    display = FakeDisplay();
    DeviceDisplaySource.current = display;
  });
  tearDown(() => DeviceDisplaySource.current = source);
  tearDownAll(() {
    for (final x in states) {
      x.dispose();
    }
  });

  LayerDoc layer() => s.project.layers.first;
  DeviceTarget target() => DeviceTarget(s, 'a', DeviceTarget.instrumentSlot);

  Future<void> open(WidgetTester tester, {Size size = const Size(390, 844), bool drag = false}) async {
    final editor = DeviceEditor(target: target(), onClose: () {});
    await pumpGolden(tester, Scaffold(body: drag
        ? Column(children: [
            const Draggable<AssetDrag>(data: AssetDrag(AssetKind.audioFile, 'a1', 'voice'),
                feedback: SizedBox(width: 8, height: 8), child: Text('drag voice')),
            Expanded(child: editor),
          ])
        : editor), size);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  test('the registry opens Flock\'s own page; its knobs are the engine\'s', () {
    final e = DeviceEditors.custom(flockComponentId, flockInfo());
    expect(e, isNotNull);
    expect(e!.sections(target()).single.stripAtBottom, isTrue, reason: 'the mod-source strip pinned at the bottom');
    final info = flockInfo();
    for (final id in [...flockGrainKnobs, ...flockGrainChoices, ...flockPlayKnobs, ...flockEnvelopeKnobs,
        ...flockFilterKnobs, 'freeze', 'filter', 'builtin']) {
      expect(info.param(id), isNotNull, reason: 'Flock lacks $id');
    }
    // Every parameter has a place on the page.
    final placed = {...flockGrainKnobs, ...flockGrainChoices, ...flockPlayKnobs, ...flockEnvelopeKnobs,
        ...flockFilterKnobs, 'freeze', 'filter', 'builtin'};
    expect([for (final p in info.parameters) if (!placed.contains(p.id)) p.id], isEmpty);
    expect(info.param('builtin')!.choices, flockTones);
    expect(info.presets.length, 12);
  });

  test('the sample is the state {"path"}: it round trips, and the project lists, relinks and quarantines it', () {
    expect(s.flockSample(layer()), isNull);
    expect(s.setFlockSample(layer(), '/abs/grains.wav'), isTrue);
    final use = layer().instrument!;
    expect(jsonDecode(utf8.decode(base64Decode(use.state!))), {'path': '/abs/grains.wav'});
    expect(use.stateVersion, 1);
    expect(s.flockSample(layer()), '/abs/grains.wav');
    final deps = scanProjectDependencies(s.project);
    expect(deps.where((d) => d.path == '/abs/grains.wav' && d.kind == DependencyKind.sample && d.usedBy.contains('Cloud')),
        hasLength(1));
    expect(relinkProjectPath(s.project, '/abs/grains.wav', '/abs/moved.wav'), 1);
    expect(s.flockSample(layer()), '/abs/moved.wav');
    // A downloaded project naming a device path never reaches the engine.
    layer().instrument!.state = flockStateFor('/dev/zero');
    quarantineUnsafePaths(s.project, '/tmp/missing');
    expect(s.flockSample(layer()), '/tmp/missing${Platform.pathSeparator}zero');
    // None: {} (the built-in tone plays); a path past the engine's limit is refused.
    expect(s.setFlockSample(layer(), null), isTrue);
    expect(utf8.decode(base64Decode(layer().instrument!.state!)), '{}');
    expect(s.setFlockSample(layer(), '/${'a' * 5000}'), isFalse);
    expect(flockSampleOf(ComponentUseDoc(flockComponentId)..state = 'not json'), isNull);
  });

  testWidgets('phone: the tiles and the picture on top, three panels swiped under them', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('flock-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('flock-visual')), findsOneWidget);
    for (var k = 0; k < 5; k++) {
      expect(find.byKey(ValueKey('flock-source-$k')), findsOneWidget);
    }
    expect(tester.widget<Text>(find.byKey(const ValueKey('flock-panel-name'))).data, 'GRAINS');
    for (final id in ['position', 'spray', 'size', 'density', 'pitch', 'spread']) {
      expect(find.byKey(ValueKey('dknob-$id')), findsOneWidget, reason: id);
    }
    await tester.tap(find.byKey(const ValueKey('flagship-dot-1')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('flock-panel-name'))).data, 'PLAY');
    expect(find.byKey(const ValueKey('dknob-scan')), findsOneWidget);
    expect(find.byKey(const ValueKey('dknob-glide')), findsOneWidget);
    expect(find.byKey(const ValueKey('dknob-keytrack')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('toggle-freeze')));
    await tester.pumpAndSettle();
    expect(target().value('freeze'), 1);
    await tester.drag(find.byKey(const ValueKey('flock-pages')), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('flock-panel-name'))).data, 'SHAPE');
    expect(find.byKey(const ValueKey('dknob-release')), findsOneWidget);
    expect(find.byKey(const ValueKey('dknob-filter_env')), findsOneWidget);
    // The keys strip shows and hides.
    await tester.tap(find.byKey(const ValueKey('flock-keys-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(FlagshipKeys), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flock-keys-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(FlagshipKeys), findsNothing);
    await close(tester);
  });

  testWidgets('wide: one screen with the grain knobs under the picture and play, envelope and filter below',
      (tester) async {
    await open(tester, size: const Size(1280, 800));
    expect(find.byKey(const ValueKey('flock-wide')), findsOneWidget);
    expect(find.byKey(const ValueKey('flock-pages')), findsNothing);
    for (final k in ['flock-play', 'flock-envelope', 'flock-filter']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget);
    }
    expect(find.descendant(of: find.byKey(const ValueKey('flock-centrepiece')), matching: find.byKey(const ValueKey('dknob-spray'))),
        findsOneWidget);
    await close(tester);
  });

  testWidgets('the picture takes drags: sideways moves the position, up adds spray; a double tap resets both',
      (tester) async {
    await open(tester, size: const Size(1280, 800));
    final p0 = target().value('position'), s0 = target().value('spray');
    final r = tester.getRect(find.byKey(const ValueKey('flock-grab')));
    await tester.dragFrom(r.center, Offset(r.width * 0.2, 0));
    await tester.pumpAndSettle();
    expect(target().value('position'), closeTo(p0 + 0.2, 0.03));
    expect(target().value('spray'), closeTo(s0, 1));
    await tester.dragFrom(r.center, Offset(0, -r.height * 0.2));
    await tester.pumpAndSettle();
    expect(target().value('spray'), greaterThan(s0 + 50));
    await tester.tap(find.byKey(const ValueKey('flock-grab')));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.byKey(const ValueKey('flock-grab')));
    await tester.pumpAndSettle();
    expect(target().value('position'), closeTo(0.3, 1e-9));
    await close(tester);
  });

  testWidgets('a sample dropped on the picture is what the grains read; a tone tile lets it go in one step',
      (tester) async {
    await open(tester, drag: true);
    expect(find.text('Drop a sample'), findsOneWidget);
    final g = await tester.startGesture(tester.getCenter(find.text('drag voice')));
    final to = tester.getCenter(find.byKey(const ValueKey('flock-visual')));
    await g.moveTo(to);
    await tester.pump();
    await g.moveTo(to + const Offset(1, 0));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(s.flockSample(layer()), '/abs/voice.wav');
    expect(find.text('voice.wav'), findsOneWidget, reason: 'the sample tile names it');
    expect(find.byKey(const ValueKey('flock-wave')), findsOneWidget, reason: 'its waveform under the flock');
    expect(io.loaded, contains('/abs/voice.wav'));
    // Glass: the sample goes and the tone is picked, as one undo step.
    await tester.tap(find.byKey(const ValueKey('flock-source-2')));
    await tester.pumpAndSettle();
    expect(s.flockSample(layer()), isNull);
    expect(target().value('builtin'), 1);
    expect(s.undo(), isTrue);
    await tester.pumpAndSettle();
    expect(s.flockSample(layer()), '/abs/voice.wav');
    expect(target().value('builtin'), 0);
    // The toolbar lets it go too.
    await tester.tap(find.byKey(const ValueKey('flock-clear')));
    await tester.pumpAndSettle();
    expect(s.flockSample(layer()), isNull);
    await close(tester);
  });

  testWidgets('a sample picked from the toolbar or the sample tile is copied in and used', (tester) async {
    final keep = SamplerFiles.pickSamples;
    addTearDown(() => SamplerFiles.pickSamples = keep);
    SamplerFiles.pickSamples = (_) async => ['/abs/picked.wav', '/abs/other.wav'];
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('flock-add')));
    await tester.pumpAndSettle();
    expect(s.flockSample(layer()), '/abs/picked.wav', reason: 'the first of several');
    s.setFlockSample(layer(), null);
    SamplerFiles.pickSamples = (_) async => ['/abs/tile.wav'];
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('flock-source-0')));
    await tester.pumpAndSettle();
    expect(s.flockSample(layer()), '/abs/tile.wav');
    await close(tester);
  });

  testWidgets('the cloud and readouts follow the display: grains against the pool, a missing sample named',
      (tester) async {
    await open(tester, size: const Size(1280, 800));
    expect(tester.widget<Text>(find.byKey(const ValueKey('flock-grains-readout'))).data, 'Not playing');
    display.frame.value = flockFrame(grains: cloud(), cap: 64);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('flock-grains-readout'))).data, '14 / 64 grains');
    expect(tester.widget<Text>(find.byKey(const ValueKey('flock-status'))).data, '2 voices');
    display.frame.value = flockFrame(grains: cloud(n: 128), dropped: 3, source: 1, missing: true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.widget<Text>(find.byKey(const ValueKey('flock-grains-readout'))).data, '128 / 128 grains · full');
    expect(tester.widget<Text>(find.byKey(const ValueKey('flock-status'))).data, 'NOT FOUND · STRINGS');
    // A frame cut short draws only the grains it holds.
    display.frame.value = DeviceDisplayFrame(raw: [1, 50, 128, 0, 1, 1, 0, 2, 0.3, 90, -12, 50, ...List.filled(40, 0.5)]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(FlockFrame(display.frame.value).shown, 1);
    await close(tester);
  });

  test('the window levels the birds are sized by stay in 0..1 and peak where the window does', () {
    for (var w = 0; w < 5; w++) {
      for (var i = 0; i <= 20; i++) {
        final v = flockWindowLevel(w, i / 20);
        expect(v, inInclusiveRange(0, 1), reason: 'window $w at ${i / 20}');
      }
    }
    expect(flockWindowLevel(0, 0.5), closeTo(1, 1e-9));
    expect(flockWindowLevel(0, 0), closeTo(0, 1e-9));
    expect(flockWindowLevel(3, 0.1), greaterThan(flockWindowLevel(3, 0.9)), reason: 'Expodec decays');
    expect(flockWindowLevel(4, 0.9), greaterThan(flockWindowLevel(4, 0.1)), reason: 'Rexpodec swells');
  });

  group('goldens', () {
    for (final e in {'phone': const Size(390, 844), 'desktop': const Size(1280, 800)}.entries) {
      testWidgets(e.key, (tester) async {
        await open(tester, size: e.value);
        display.frame.value = flockFrame(grains: cloud());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(goldenScreen, matchesGoldenFile('goldens/audio/flock_page_${e.key}.png'));
        await close(tester);
      });
    }
  });

  group('with the engine', () {
    test('the Flock descriptor fixture matches the engine, and Flock is an instrument the browser and Library list',
        () async {
      final e = Engine.create();
      final list = await e.nativeComponents();
      e.dispose();
      final want = list.firstWhere((c) => c.id == flockComponentId), have = flockInfo();
      List<Object> shape(NativeComponentInfo i) =>
          [for (final p in i.parameters) (p.id, p.min, p.max, p.defaultValue, p.choices.join('|'))];
      expect(shape(have), shape(want), reason: 'refresh test/fixtures/builtin_components.json');
      expect(have.presets.map((p) => p.name), want.presets.map((p) => p.name));
      final st = AppState(settings: Settings());
      states.add(st);
      st.project = ProjectDoc(id: 'p', name: 'x', bpm: 120, layers: []);
      st.componentCatalog.set(list);
      expect(st.nativeInstruments.map((c) => c.id), contains(flockComponentId), reason: 'the instrument browser');
      st.nativeCatalog = list;
      expect(st.builtinAssets.where((a) => a.native?.id == flockComponentId && a.isInstrument), hasLength(1),
          reason: 'the Library');
    });
  }, skip: (Platform.environment['CAW_LIB'] ?? '').isEmpty ? 'set CAW_LIB to the built engine library' : null);
}
