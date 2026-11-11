// The sampler's editor (org.caw.sampler): zones made from dropped audio, the zone map's move and edge drags, the
// inspector, round robins, loop markers on the waveform, SFZ import and export through the engine's API, the SOUND
// knobs, and goldens of ZONES at phone and desktop size.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/audio_engine.dart';
import 'package:caw/engine/component_info.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/sampler.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/audio_waveform.dart';
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/devices/sampler/sampler_editor.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';
import 'golden_util.dart';

NativeComponentInfo samplerInfo() => NativeComponentInfo.listFromJson(
    jsonDecode(File('test/fixtures/sampler_component.json').readAsStringSync()) as Map<String, dynamic>).single;

AppState samplerState() {
  final s = AppState(settings: Settings());
  s.project = ProjectDoc(id: 'p', name: 'Sampler', bpm: 120, assets: [
    AudioAssetDoc(id: 'a1', path: '/abs/c4.wav', name: 'c4', seconds: 1),
  ], layers: [LayerDoc(id: 'a', name: 'Keys', color: 3)]);
  s.componentCatalog.set([samplerInfo()]);
  s.setNativeInstrument(s.project.layers.first, samplerComponentId);
  return s;
}

void main() {
  late AppState s;
  late FakeAudioIo io;
  final states = <AppState>[];
  setUp(() {
    s = samplerState();
    states.add(s);
    io = FakeAudioIo()..seconds['/abs/c4.wav'] = 1;
    s.audioIo = io;
    WaveformCache.instance.clear();
    Motion.setting = MotionLevel.off;
  });
  tearDownAll(() {
    for (final x in states) {
      x.dispose();
    }
  });

  LayerDoc layer() => s.project.layers.first;
  SamplerState zones() => s.samplerState(layer());

  Future<void> open(WidgetTester tester, {Size size = const Size(390, 844)}) async {
    late BuildContext ctx;
    await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    })), size);
    openDeviceEditor(ctx, s, layer(), -1);
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  test('the zone state round trips and its edits keep the engine\'s rules', () {
    final st = SamplerState([SamplerZone(path: '/a.wav', loKey: 60, hiKey: 64, root: 62, loopStart: 10, loopEnd: 500)]);
    final again = SamplerState.fromBase64(st.toBase64());
    expect(jsonEncode(again.toJson()), jsonEncode(st.toJson()));
    expect(again.zones.single.playedLoopMode, 'loop_continuous', reason: 'loop points without a mode loop (SFZ)');
    st.moveZone(0, 100, 0);
    expect(st.zones.single.hiKey, 127, reason: 'stays on the keyboard');
    expect(st.zones.single.loKey, 123);
    final made = st.addFiles(['/b.wav', '/c.wav', '/d.wav'], 36);
    expect([for (final i in made) st.zones[i].root], [36, 37, 38]);
    st.roundRobin(made);
    expect([for (final i in made) (st.zones[i].seqPosition, st.zones[i].seqLength)], [(1, 3), (2, 3), (3, 3)]);
    expect(st.zonesAt(37, 100), [made[1]]);
    expect(SamplerZone.fromJson({'path': '/x', 'lokey': 70, 'hikey': 60})!.loKey, 60, reason: 'bounds put in order');
    expect(noteName(60), 'C4');
  });

  testWidgets('a sample dropped on a key makes a zone there; the map moves and resizes it', (tester) async {
    await loadAppFonts(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Drop an audio file from Files on the keys.
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      const Draggable<AssetDrag>(data: AssetDrag(AssetKind.audioFile, 'a1', 'c4'),
          feedback: SizedBox(width: 8, height: 8), child: Text('drag c4')),
      Expanded(child: DeviceEditor(target: DeviceTarget(s, 'a', DeviceTarget.instrumentSlot), onClose: () {})),
    ]))));
    await tester.pumpAndSettle();
    final keys = tester.getRect(find.byKey(const ValueKey('sampler-keyboard')));
    final g = await tester.startGesture(tester.getCenter(find.text('drag c4')));
    await g.moveTo(keys.center);
    await tester.pump();
    await g.moveTo(keys.center + const Offset(1, 0));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(zones().zones, hasLength(1));
    final z = zones().zones.single;
    expect(z.path, '/abs/c4.wav');
    expect(z.loKey, z.hiKey);
    expect(z.root, z.loKey);
    final key = z.loKey;
    // Drag the zone's body 3 keys right.
    final map = tester.getRect(find.byKey(const ValueKey('sampler-zone-map')));
    final (lo, hi) = ZoneMap.keySpan(zones());
    final kw = map.width / (hi - lo + 1);
    final at = Offset(map.left + (key - lo + 0.5) * kw, map.center.dy);
    await tester.dragFrom(at, Offset(kw * 3, 0));
    await tester.pumpAndSettle();
    expect(zones().zones.single.loKey, key + 3);
    expect(zones().zones.single.root, key + 3);
    // Its top edge down: the high velocity drops.
    final (lo2, hi2) = ZoneMap.keySpan(zones());
    final kw2 = map.width / (hi2 - lo2 + 1);
    final top = Offset(map.left + (key + 3 - lo2 + 0.5) * kw2, map.top + 3);
    await tester.dragFrom(top, Offset(0, map.height / 2));
    await tester.pumpAndSettle();
    expect(zones().zones.single.hiVel, lessThan(80));
    await close(tester);
  });

  testWidgets('the inspector, round robin and the loop markers', (tester) async {
    final st = SamplerState([
      SamplerZone(path: '/abs/c4.wav', loKey: 60, hiKey: 60, root: 60),
      SamplerZone(path: '/abs/c4.wav', loKey: 60, hiKey: 60, root: 60),
    ]);
    s.setSamplerState(layer(), st);
    await open(tester);
    final map = tester.getRect(find.byKey(const ValueKey('sampler-zone-map')));
    final (lo, hi) = ZoneMap.keySpan(zones());
    final kw = map.width / (hi - lo + 1);
    final at = Offset(map.left + (60 - lo + 0.5) * kw, map.center.dy);
    await tester.tapAt(at);
    await tester.pumpAndSettle();
    await tester.longPressAt(at);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sampler-round-robin')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sampler-round-robin')));
    await tester.pumpAndSettle();
    expect([for (final z in zones().zones) z.seqPosition], [1, 2]);
    // One zone: the inspector's root and the loop (the toolbar grew, so the map moved down).
    final map2 = tester.getRect(find.byKey(const ValueKey('sampler-zone-map')));
    await tester.tapAt(map2.topLeft + const Offset(2, 2));
    await tester.pumpAndSettle();
    await tester.tapAt(Offset(at.dx, map2.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('Delete zone'), findsOneWidget, reason: 'one zone selected');
    final page = find.descendant(of: find.byKey(const ValueKey('sampler-zones')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('zone-root-up')), 100, scrollable: page);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('zone-root-up')));
    await tester.pumpAndSettle();
    expect(zones().zones.where((z) => z.root == 61), hasLength(1));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('sampler-marker-end')), -100, scrollable: page);
    await tester.pumpAndSettle();
    final wave = tester.getRect(find.byKey(const ValueKey('sampler-wave')));
    await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('sampler-marker-end'))), Offset(-wave.width / 2, 0));
    await tester.pumpAndSettle();
    final edited = zones().zones.firstWhere((z) => z.root == 61);
    expect(edited.end, closeTo(22050, 1200), reason: 'half of a 1 s file at 44.1 kHz');
    await close(tester);
  });

  testWidgets('SFZ import fills the zones and says what was left out; export copies samples', (tester) async {
    io.sfz = const SfzImportResult(ok: true, zones: 1, warnings: ['3 regions with trigger=release'],
        state: {'zones': [{'path': '/abs/c4.wav', 'lokey': 40, 'hikey': 50, 'pitch_keycenter': 45}]});
    SamplerFiles.pickSfz = () async => '/abs/kit.sfz';
    SamplerFiles.exportPath = (name) async => '/abs/out/$name.sfz';
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('sampler-import-sfz')));
    await tester.pumpAndSettle();
    expect(zones().zones.single.loKey, 40);
    expect(find.textContaining('trigger=release'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sampler-export-sfz')));
    await tester.pumpAndSettle();
    expect(io.sfzExports.single.$2, '/abs/out/Keys.sfz');
    expect(io.sfzExports.single.$3, isTrue);
    expect(jsonDecode(io.sfzExports.single.$1)['zones'][0]['lokey'], 40);
    await close(tester);
  });

  testWidgets('SOUND: the envelope and filter knobs', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('device-tab-sound')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sampler-sound')), findsOneWidget);
    expect(find.text('Attack'), findsWidgets);
    expect(find.text('Cutoff'), findsWidgets);
    await close(tester);
  });

  group('goldens', () {
    for (final e in {'phone': goldenSizes['phone']!, 'desktop': goldenSizes['desktop']!}.entries) {
      testWidgets(e.key, (tester) async {
        s.setSamplerState(layer(), SamplerState([
          SamplerZone(path: '/abs/c4.wav', loKey: 48, hiKey: 59, root: 55, hiVel: 90),
          SamplerZone(path: '/abs/c4.wav', loKey: 48, hiKey: 59, root: 55, loVel: 91),
          SamplerZone(path: '/abs/c4.wav', loKey: 60, hiKey: 71, root: 64, seqLength: 2, seqPosition: 1),
          SamplerZone(path: '/abs/c4.wav', loKey: 60, hiKey: 71, root: 64, seqLength: 2, seqPosition: 2,
              loopStart: 4000, loopEnd: 30000),
        ]));
        await open(tester, size: e.value);
        final map = tester.getRect(find.byKey(const ValueKey('sampler-zone-map')));
        final (lo, hi) = ZoneMap.keySpan(zones());
        final kw = map.width / (hi - lo + 1);
        await tester.tapAt(Offset(map.left + (66 - lo) * kw, map.top + map.height * 0.2));
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(goldenScreen, matchesGoldenFile('goldens/audio/sampler_zones_${e.key}.png'));
        await close(tester);
      });
    }
  });

  test('the sampler descriptor fixture matches the engine', () async {
    final e = Engine.create();
    final engine = {for (final c in await e.nativeComponents()) c.id: c};
    e.dispose();
    final want = engine[samplerComponentId]!, have = samplerInfo();
    expect([for (final p in have.parameters) (p.id, p.min, p.max, p.defaultValue)],
        [for (final p in want.parameters) (p.id, p.min, p.max, p.defaultValue)],
        reason: 'refresh test/fixtures/sampler_component.json');
  }, skip: (Platform.environment['CAW_LIB'] ?? '').isEmpty ? 'set CAW_LIB to the built engine library' : null);
}
