// The sampler's editor (org.caw.sampler): drop and play (the whole keyboard at the detected root), the zone map's
// drags, the inspector with stretch, round robins, loop markers, slicing to keys and Drums pads, multisample
// recording, SFZ import and export, the phone's three panels and the wide screen, and goldens at phone and desktop size.
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
import 'package:caw/model/sampler_tools.dart';
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

  Future<void> dropOn(WidgetTester tester, Finder target, {Offset at = Offset.zero}) async {
    final r = tester.getRect(target);
    final g = await tester.startGesture(tester.getCenter(find.text('drag c4')));
    await g.moveTo(r.center + at);
    await tester.pump();
    await g.moveTo(r.center + at + const Offset(1, 0));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
  }

  Future<void> openWithDrag(WidgetTester tester) async {
    await loadAppFonts(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      const Draggable<AssetDrag>(data: AssetDrag(AssetKind.audioFile, 'a1', 'c4'),
          feedback: SizedBox(width: 8, height: 8), child: Text('drag c4')),
      Expanded(child: DeviceEditor(target: DeviceTarget(s, 'a', DeviceTarget.instrumentSlot), onClose: () {})),
    ]))));
    await tester.pumpAndSettle();
  }

  testWidgets('drop and play: a dropped sample covers every key at its detected root and plays', (tester) async {
    io.samplerTools = (tool, req) => {
      'ok': true, 'mode': 'root',
      'samples': [{'path': '/abs/c4.wav', 'sure': true, 'root': 57}],
      'state': {'zones': [{'path': '/abs/c4.wav', 'lokey': 0, 'hikey': 127, 'pitch_keycenter': 57, 'tune': -4}]},
    };
    await openWithDrag(tester);
    expect(find.byKey(const ValueKey('sampler-empty')), findsOneWidget, reason: 'the empty map says what a drop does');
    await dropOn(tester, find.byKey(const ValueKey('sampler-zone-map')));
    expect(io.samplerRequests.single.$1, 'map');
    expect(io.samplerRequests.single.$2['mode'], 'auto');
    final z = zones().zones.single;
    expect((z.loKey, z.hiKey, z.root), (0, 127, 57));
    expect(find.textContaining('on every key, root A3'), findsOneWidget);
    // The keys play it at once (the preview goes to this track).
    final keys = tester.getRect(find.byKey(const ValueKey('sampler-keyboard')));
    final g = await tester.startGesture(keys.centerLeft + const Offset(4, 0));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    // Its top edge down: the high velocity drops.
    final map = tester.getRect(find.byKey(const ValueKey('sampler-zone-map')));
    await tester.dragFrom(Offset(map.center.dx, map.top + 3), Offset(0, map.height / 2));
    await tester.pumpAndSettle();
    expect(zones().zones.single.hiVel, lessThan(80));
    await close(tester);
  });

  testWidgets('drop and play without the engine still fits the keyboard; One key each lands on the key', (tester) async {
    await openWithDrag(tester);
    await dropOn(tester, find.byKey(const ValueKey('sampler-keyboard')));
    expect((zones().zones.single.loKey, zones().zones.single.hiKey, zones().zones.single.root), (0, 127, 60));
    await tester.tap(find.byKey(const ValueKey('sampler-mapping')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sampler-mapping-keys')).last);
    await tester.pumpAndSettle();
    await dropOn(tester, find.byKey(const ValueKey('sampler-keyboard')));
    expect(zones().zones, hasLength(2), reason: 'One key each adds beside the map');
    final k = zones().zones.last;
    expect(k.loKey, k.hiKey);
    expect(k.root, k.loKey);
    await close(tester);
  });

  testWidgets('several picked samples map by root across the keyboard', (tester) async {
    SamplerFiles.pickSamples = (_) async => ['/abs/c3.wav', '/abs/c5.wav'];
    io.samplerTools = (tool, req) => {
      'ok': true, 'mode': 'root', 'samples': [],
      'state': {'zones': [
        {'path': '/abs/c3.wav', 'lokey': 0, 'hikey': 59, 'pitch_keycenter': 48},
        {'path': '/abs/c5.wav', 'lokey': 60, 'hikey': 127, 'pitch_keycenter': 72},
      ]},
    };
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('sampler-add')));
    await tester.pumpAndSettle();
    expect([for (final z in zones().zones) (z.loKey, z.hiKey)], [(0, 59), (60, 127)]);
    expect(find.textContaining('2 samples across the keyboard by root'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the inspector, round robin, stretch and the loop markers', (tester) async {
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
    await tester.tapAt(map.topLeft + const Offset(2, 2));
    await tester.pumpAndSettle();
    await tester.tapAt(at);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Delete zone'), findsOneWidget, reason: 'one zone selected');
    final page = find.descendant(of: find.byKey(const ValueKey('sampler-panel-zone')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('zone-root-up')), 100, scrollable: page);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('zone-root-up')));
    await tester.pumpAndSettle();
    expect(zones().zones.where((z) => z.root == 61), hasLength(1));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('zone-stretch')), 100, scrollable: page);
    await tester.tap(find.byKey(const ValueKey('zone-stretch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('zone-bpm-up')));
    await tester.pumpAndSettle();
    final stretched = zones().zones.firstWhere((z) => z.root == 61);
    expect((stretched.stretch, stretched.stretchBpm), (true, 120.0));
    expect(stretched.toJson()['stretch_bpm'], 120.0);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('sampler-marker-end')), -100, scrollable: page);
    await tester.pumpAndSettle();
    final wave = tester.getRect(find.byKey(const ValueKey('sampler-wave')));
    await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('sampler-marker-end'))), Offset(-wave.width / 2, 0));
    await tester.pumpAndSettle();
    final edited = zones().zones.firstWhere((z) => z.root == 61);
    expect(edited.end, closeTo(22050, 1200), reason: 'half of a 1 s file at 44.1 kHz');
    await close(tester);
  });

  testWidgets('the phone swipes three panels under the map; wide shows every section at once', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('sampler-centrepiece')), findsOneWidget);
    expect(find.byKey(const ValueKey('sampler-panel-zone')), findsOneWidget);
    expect(find.text('ZONE'), findsWidgets);
    await tester.fling(find.byKey(const ValueKey('sampler-pages')), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sampler-panel-sound')), findsOneWidget);
    expect(find.text('Attack'), findsWidgets);
    expect(find.text('Cutoff'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('flagship-dot-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sampler-slice')), findsOneWidget);
    expect(find.byKey(const ValueKey('sampler-record-panel')), findsOneWidget);
    await close(tester);
    await open(tester, size: const Size(1280, 800));
    expect(find.byKey(const ValueKey('sampler-wide')), findsOneWidget);
    for (final k in ['sampler-centrepiece', 'sampler-zone-panel', 'sampler-amp', 'sampler-filter', 'sampler-slice',
        'sampler-record-panel']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.byKey(const ValueKey('sampler-pages')), findsNothing);
    await close(tester);
  });

  testWidgets('slicing: a loop to keys, or to a new Drums track\'s pads', (tester) async {
    s.setSamplerState(layer(), SamplerState([SamplerZone(path: '/abs/c4.wav')]));
    io.samplerTools = (tool, req) => {
      'ok': true, 'frames': 48000, 'seconds': 1,
      'slices': [{'start': 0, 'end': 12000, 'key': 36}, {'start': 12000, 'end': 30000, 'key': 37},
        {'start': 30000, 'end': 48000, 'key': 38}],
      'state': {'zones': [
        for (final (i, (a, b)) in [(0, 11999), (12000, 29999), (30000, 47999)].indexed)
          {'path': '/abs/c4.wav', 'lokey': 36 + i, 'hikey': 36 + i, 'pitch_keycenter': 36 + i, 'offset': a, 'end': b,
            'loop_mode': 'one_shot'},
      ]},
    };
    await open(tester, size: const Size(1280, 800));
    await tester.ensureVisible(find.byKey(const ValueKey('sampler-slice-drums')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sampler-slice-by-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sampler-divisions-up')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sampler-slice-keys')));
    await tester.pumpAndSettle();
    final req = io.samplerRequests.last;
    expect(req.$1, 'slice');
    expect((req.$2['path'], req.$2['by'], req.$2['divisions']), ('/abs/c4.wav', 'grid', 20));
    expect([for (final z in zones().zones) (z.loKey, z.offset, z.playedLoopMode)],
        [(36, 0, 'one_shot'), (37, 12000, 'one_shot'), (38, 30000, 'one_shot')]);
    final tracks = s.project.layers.length;
    await tester.tap(find.byKey(const ValueKey('sampler-slice-drums')));
    await tester.pumpAndSettle();
    expect(s.project.layers, hasLength(tracks + 1));
    final drums = s.project.layers[1];
    expect(drums.instrument?.id, 'org.caw.drums');
    expect(drums.instrument!.samples.map((x) => x.slot), [0, 1, 2]);
    expect(drums.instrument!.params['a1_smp_on'], 1);
    expect(drums.instrument!.params['a2_smp_start'], closeTo(0.25, 1e-9));
    expect(drums.instrument!.params['a3_smp_end'], 1.0);
    await close(tester);
  });

  testWidgets('multisample recording: prompts each note, cuts the take into zones', (tester) async {
    io.stopTakes = [const RecordedAudioTake(layer: 'a', path: '/abs/take.wav', seconds: 9)];
    io.samplerTools = (tool, req) => {
      'ok': true,
      'notes': [for (final n in req['notes'] as List) {'key': n['key'], 'found': n['key'] != 54, 'in_tune': true}],
      'state': {'zones': [
        {'path': '/abs/take.wav', 'lokey': 0, 'hikey': 50, 'pitch_keycenter': 48, 'offset': 100, 'end': 90000},
        {'path': '/abs/take.wav', 'lokey': 51, 'hikey': 127, 'pitch_keycenter': 51, 'offset': 150000, 'end': 230000},
      ]},
    };
    await open(tester, size: const Size(1280, 800));
    await tester.ensureVisible(find.byKey(const ValueKey('sampler-record')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 18; i++) {
      await tester.tap(find.byKey(const ValueKey('sampler-rec-high-down')));
    }
    await tester.pumpAndSettle();
    expect(find.text('3 notes · 11 s'), findsOneWidget, reason: 'C3, D#3 and F#3, 2 s each and 1 s apart, after 2 s');
    await tester.tap(find.byKey(const ValueKey('sampler-record')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rec-start')));
    // The recordings folder is real I/O: wait for the request (up to 5 s; a busy CI runner can take more than 100 ms).
    for (var i = 0; i < 50 && io.lastRecordRequest == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(io.lastRecordRequest?['tracks'], [{'layer': 'a', 'channel': 0, 'channels': 1}]);
    expect(find.text('NEXT'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2500));
    expect(find.text('PLAY'), findsOneWidget);
    expect(find.byKey(const ValueKey('rec-prompt-48-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rec-cancel')));
    await tester.pumpAndSettle();
    final take = io.samplerRequests.last;
    expect(take.$1, 'take');
    expect([for (final n in take.$2['notes'] as List) n['key']], [48, 51, 54]);
    expect(find.textContaining('2 zones made · 1 note not heard'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rec-use')));
    await tester.pumpAndSettle();
    expect([for (final z in zones().zones) z.root], [48, 51]);
    await close(tester);
  });

  test('the recording plan: notes in order, velocity layers, each prompt\'s search window', () {
    final p = MultisamplePlan(lowKey: 60, highKey: 66, step: 3, layers: 2, noteSeconds: 1, gapSeconds: 0.5, leadSeconds: 1);
    expect([for (final n in p.notes) (n.key, n.loVel, n.hiVel)], [(60, 1, 63), (60, 64, 127), (63, 1, 63), (63, 64, 127),
      (66, 1, 63), (66, 64, 127)]);
    expect(p.notes[1].start, 2.5);
    expect(p.seconds, 10.0);
    expect(p.notes.first.request(0.5), {'key': 60, 'start_seconds': 0.7, 'end_seconds': 2.4, 'lovel': 1, 'hivel': 63});
    expect(fallbackMapping(['/a', '/b', '/c', '/d'], DropMapping.auto, 36).map((z) => (z.loKey, z.hiKey)),
        [(0, 31), (32, 63), (64, 95), (96, 127)]);
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
        await expectLater(goldenScreen, matchesGoldenFile('goldens/audio/sampler_page_${e.key}.png'));
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
