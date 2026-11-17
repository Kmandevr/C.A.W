// Freeze and bounce to audio (1.0.5, #209): the project fields, the engine JSON a frozen track sends (no instrument
// or effects), freeze, unfreeze and bounce as one undo step each, the "Unfreeze to edit?" prompt, and with CAW_LIB a
// frozen track rendering the same as the live one.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/freeze.dart';
import 'package:caw/model/modulation.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/routing.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/song_export.dart';
import 'package:caw/ui/arrange/freeze_ui.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

const _riff = '---\nkind: pattern\nlength: 16\n---\n0 A2 2 1\n4 C3 1 0.8\n8 E3 2 0.6\n';

ProjectDoc _project() => ProjectDoc(id: 'pfreeze', name: 'Freeze', bpm: 120, loopBars: 2,
    modules: [ModuleDoc(id: 'riff', name: 'Riff', source: _riff)],
    layers: [
      LayerDoc(id: 'a', name: 'Synth', color: 1, volume: 0.6, pan: 0.3,
          instrument: ComponentUseDoc('org.caw.synth.flagship'),
          components: [ComponentUseDoc('org.caw.delay.pro')],
          clips: [ClipDoc(id: 'c1', patternId: 'riff', startSteps: 0, lengthSteps: 16),
            ClipDoc(id: 'c2', patternId: 'riff', startSteps: 16, lengthSteps: 8)]),
      LayerDoc(id: 'b', name: 'Other', color: 2, instrument: ComponentUseDoc('org.caw.synth.flagship'),
          clips: [ClipDoc(id: 'c3', patternId: 'riff', startSteps: 0, lengthSteps: 32)]),
    ]);

/// A render that writes a small file where the request says and reports it, as the engine does.
class _FakeRender implements SongRenderHandle {
  _FakeRender(String requestJson, {this.fail}) {
    request = jsonDecode(requestJson) as Map<String, dynamic>;
    path = '${request['out_dir']}/${request['pattern']}.wav';
    scheduleMicrotask(() {
      if (fail != null) return _done.complete(jsonEncode({'ok': false, 'error': fail, 'files': []}));
      File(path).writeAsBytesSync(Uint8List(64));
      _done.complete(jsonEncode({'ok': true, 'error': '', 'files': [
        {'path': path, 'name': 'x.wav', 'kind': 'track', 'layer': 'a', 'region': '', 'frames': 96000}]}));
    });
  }
  final String? fail;
  late final Map<String, dynamic> request;
  late final String path;
  final _done = Completer<String?>();
  @override
  double get progress => 0.5;
  @override
  void cancel() {}
  @override
  Future<String?> get result => _done.future;
}

void main() {
  late AppState s;
  final requests = <Map<String, dynamic>>[];
  final projects = <Map<String, dynamic>>[];

  setUp(() {
    requests.clear();
    projects.clear();
    trackRenderStarter = (projectJson, requestJson) {
      final r = _FakeRender(requestJson);
      requests.add(r.request);
      projects.add(jsonDecode(projectJson) as Map<String, dynamic>);
      return r;
    };
    s = AppState(settings: Settings());
    s.project = _project();
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
  });

  tearDown(() {
    trackRenderStarter = startNativeSongRender;
    s.dispose();
  });

  LayerDoc layer(String id) => s.project.layers.firstWhere((l) => l.id == id);
  Map<String, dynamic> engineLayer(String id, [ProjectDoc? p]) => ((jsonDecode((p ?? s.project).toEngineJson())
      as Map<String, dynamic>)['layers'] as List).cast<Map<String, dynamic>>().firstWhere((l) => l['id'] == id);

  test('the frozen fields round trip, and an older project without them is not frozen', () {
    final l = LayerDoc(id: 'x', name: 'X', color: 0, frozenAsset: 'a1', frozenContext: 'ctx');
    final j = l.toJson();
    expect(j['frozen'], isTrue);
    expect(j['frozen_asset'], 'a1');
    final back = LayerDoc.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
    expect(back.frozenAsset, 'a1');
    expect(back.frozenContext, 'ctx');
    expect(LayerDoc.fromJson({'id': 'y', 'frozen_asset': 'a1'}).frozen, isFalse);  // needs "frozen": true
    expect(LayerDoc(id: 'z', name: 'Z', color: 0).toJson().containsKey('frozen'), isFalse);
  });

  test('freezing renders the track before its fader over the song with a tail, off the UI, as one undo step', () async {
    final a = layer('a');
    a.solo = false;
    layer('b').solo = true;  // soloed elsewhere and muted itself: the render still hears it
    a.mute = true;
    final job = s.freezeTrack(a);
    expect(await job.done, isNull);
    final r = requests.single;
    expect(r['stem_tap'], 'pre');
    expect(r['layers'], ['a']);
    expect(r['mix'], isFalse);
    expect(r['bounds'], 'song');
    expect(r['tail'], 'silence');
    expect(r['bit_depth'], 32);
    final rendered = (projects.single['layers'] as List).cast<Map<String, dynamic>>();
    expect(rendered.firstWhere((l) => l['id'] == 'a')['mute'], isFalse);
    expect(rendered.every((l) => l['solo'] == false), isTrue);
    expect(rendered.firstWhere((l) => l['id'] == 'a')['instrument'], isNotNull);

    expect(a.frozen, isTrue);
    expect(s.project.playsFrozen(a), isTrue);
    final asset = s.project.asset(a.frozenAsset)!;
    expect(asset.seconds, 2.0);  // 96000 frames at 48 kHz
    expect(File(asset.path).existsSync(), isTrue);

    // Undo is one step back to the live track; redo freezes it again.
    expect(s.undo(), isTrue);
    expect(layer('a').frozen, isFalse);
    expect(s.redo(), isTrue);
    expect(layer('a').frozen, isTrue);
  });

  test("a frozen track sends its audio instead of its instrument and effects, and their lanes and links", () async {
    final a = layer('a');
    a.noteComponents.add(ComponentUseDoc('org.caw.chorus'));
    s.project.automation.addAll([
      ProjectAutomationLaneDoc(targetType: 'instrument', target: 'cutoff', layerId: 'a',
          points: [AutomationPointDoc(step: 0, value: 0.5)]),
      ProjectAutomationLaneDoc(targetType: 'component', target: 'mix', layerId: 'a', component: 0,
          points: [AutomationPointDoc(step: 0, value: 0.5)]),
    ]);
    a.automation.add(AutomationLaneDoc(target: 'volume', points: [AutomationPointDoc(step: 0, value: 0.5)]));
    s.project.modulators.add(ModulatorDoc(id: 'lfo', name: 'LFO', componentId: 'org.caw.mod.lfo'));
    s.project.modLinks.addAll([
      ModLinkDoc(id: 1, source: 'lfo', target: const ModTarget.instrument('a', 'cutoff')),
      ModLinkDoc(id: 2, source: 'lfo', target: const ModTarget.volume('a')),
    ]);
    final live = engineLayer('a');
    expect(live['instrument'], isNotNull);
    expect(live['components'], isNotNull);

    expect(await s.freezeTrack(a).done, isNull);
    final frozen = engineLayer('a');
    expect(frozen.containsKey('instrument'), isFalse);  // the engine never builds them: none of them runs
    expect(frozen.containsKey('components'), isFalse);
    expect(frozen.containsKey('noteComponents'), isFalse);
    final clip = (frozen['audio_clips'] as List).single as Map<String, dynamic>;
    expect(clip['asset'], a.frozenAsset);
    expect(clip['start_steps'], 0);
    expect(clip['follows_tempo'], isFalse);
    expect(clip['lengthens_song'], isFalse);
    expect(clip['length_steps'], closeTo(16, 1e-9));  // 2 s at 120 BPM
    // Fader, pan, sends and the fader's lanes stay live; the notes still go (keys and modulators hear them).
    expect(frozen['volume'], 0.6);
    expect(frozen['pan'], 0.3);
    expect((frozen['automation'] as List).single['target'], 'volume');
    expect((frozen['clips'] as List), hasLength(2));
    final all = jsonDecode(s.project.toEngineJson()) as Map<String, dynamic>;
    expect((all['automation'] as List).where((l) => l['layer'] == 'a'), isEmpty);
    final links = (all['modulation'] as List?) ?? const [];
    expect(links.where((l) => (l['target'] as Map)['type'] == 'instrument'), isEmpty);
    expect(links.where((l) => (l['target'] as Map)['type'] == 'volume'), hasLength(1));
    // The other track is untouched.
    expect(engineLayer('b')['instrument'], isNotNull);

    // A tempo change: the frozen audio no longer fits, so the track plays live (and says so) until frozen again.
    s.project.bpm = 100;
    expect(s.project.playsFrozen(a), isFalse);
    expect(engineLayer('a')['instrument'], isNotNull);
  });

  test("a frozen track's saved component states are left alone", () async {
    final a = layer('a');
    expect(await s.freezeTrack(a).done, isNull);
    s.project.storeComponentStates((id) => id == 'a' ? {ProjectDoc.instrumentIndex: (state: 'QUJD', version: 1)} : {});
    expect(a.instrument!.state, isNull);  // the engine's clip player's state is not the synth's
  });

  test('unfreeze plays the instrument and effects again and lets go of the frozen file; undo brings it back', () async {
    final a = layer('a');
    expect(await s.freezeTrack(a).done, isNull);
    final id = a.frozenAsset!;
    s.unfreezeTrack(a);
    expect(a.frozen, isFalse);
    expect(s.project.asset(id), isNull);
    expect(engineLayer('a')['instrument'], isNotNull);
    expect(engineLayer('a')['components'], isNotNull);
    expect(s.undo(), isTrue);
    expect(layer('a').frozen, isTrue);
    expect(s.project.asset(id), isNotNull);
  });

  test('a file no longer named is deleted when the project opens; a freeze whose file is gone plays live', () async {
    final a = layer('a');
    expect(await s.freezeTrack(a).done, isNull);
    final path = s.project.asset(a.frozenAsset)!.path;
    s.unfreezeTrack(a);
    await s.purgeFrozenAudio();
    expect(File(path).existsSync(), isFalse);
    final restored = _project();
    restored.layers.first
      ..frozenAsset = 'gone'
      ..frozenContext = restored.freezeContext;
    s.dropMissingFreezes(restored);
    expect(restored.layers.first.frozen, isFalse);
  });

  test('a failed or cancelled render changes nothing', () async {
    trackRenderStarter = (p, r) => _FakeRender(r, fail: 'cancelled');
    expect(await s.freezeTrack(layer('a')).done, 'cancelled');
    expect(layer('a').frozen, isFalse);
    expect(s.project.assets, isEmpty);
  });

  test('bounce to audio of a track: a new audio track with one clip over its span, the original muted, one step',
      () async {
    final a = layer('a');
    a.clips.first.startSteps = 4;  // the span: steps 4..24
    a.sends.add(SendDoc('b', level: 0.5));
    expect(await s.bounceTrack(a).done, isNull);
    expect(requests.single['bounds'], 'selection');
    expect(requests.single['start_steps'], 4);
    expect(requests.single['end_steps'], 24);
    expect(requests.single['stem_tap'], 'pre');
    final layers = s.project.layers;
    final bounce = layers[layers.indexOf(a) + 1];
    expect(bounce.name, 'Synth (bounce)');
    expect(bounce.isAudio, isTrue);
    expect(bounce.instrument, isNull);
    expect(bounce.volume, 0.6);
    expect(bounce.pan, 0.3);
    expect(bounce.sends.single.to, 'b');
    final clip = bounce.audioClips.single;
    expect(clip.startSteps, 4);
    expect(clip.lengthSeconds, 2.0);
    expect(s.project.asset(clip.assetId), isNotNull);
    expect(a.mute, isTrue);
    expect(a.clips, hasLength(2));  // kept
    expect(s.undo(), isTrue);
    expect(s.project.layers, hasLength(2));
    expect(layer('a').mute, isFalse);
  });

  test("bounce to audio of clips: just those clips through the track, at their position, the clips muted", () async {
    final a = layer('a');
    expect(await s.bounceClips(a, [a.clips[1]]).done, isNull);
    final r = requests.single;
    expect(r['start_steps'], 16);
    expect(r['end_steps'], 24);
    final sent = (projects.single['layers'] as List).cast<Map<String, dynamic>>().firstWhere((l) => l['id'] == 'a');
    expect((sent['clips'] as List).map((c) => c['id']), ['c2']);
    final bounce = s.project.layers[1];
    expect(bounce.audioClips.single.startSteps, 16);
    expect(layer('a').mute, isFalse);
    expect(layer('a').clips[1].mute, isTrue);
    expect(layer('a').clips[0].mute, isFalse);
  });

  test("edits to a frozen track are held back and ask to unfreeze; its fader and pan stay live", () async {
    final a = layer('a');
    expect(await s.freezeTrack(a).done, isNull);
    final asked = <String>[];
    s.onFrozenEdit = (l) => asked.add(l.id);
    s.moveClip(a, a.clips.first, 8);
    expect(a.clips.first.startSteps, 0);
    s.setNativeParamLive(a, 0, 'mix', 0.9);
    expect(a.components.first.params.containsKey('mix'), isFalse);
    s.removeNativeEffect(a, 0);
    expect(a.components, hasLength(1));
    expect(asked, ['a', 'a', 'a']);
    s.mixLayer(a, volume: 0.4, pan: -0.2);
    expect(a.volume, 0.4);
    expect(asked, hasLength(3));
    // Once unfrozen, the same edit goes through.
    s.unfreezeTrack(a);
    s.moveClip(a, a.clips.first, 8);
    expect(a.clips.first.startSteps, 8);
  });

  testWidgets('the devices of a frozen track dim, and touching them asks "Unfreeze to edit?"', (tester) async {
    final a = layer('a');
    await tester.runAsync(() async => expect(await s.freezeTrack(a).done, isNull));
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) =>
        FrozenDevices(state: s, layer: a, child: Center(child: TextButton(onPressed: () => tapped++,
            child: const Text('knob'))))))));
    await tester.pumpAndSettle();
    final dim = tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('frozen-dim-a')));
    expect(dim.opacity, lessThan(0.5));
    await tester.tap(find.text('knob'), warnIfMissed: false);  // the guard takes the touch
    await tester.pumpAndSettle();
    expect(tapped, 0);  // the knob isn't reached
    expect(find.text('Unfreeze to edit?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('unfreeze-prompt-yes')));
    await tester.pumpAndSettle();
    expect(a.frozen, isFalse);
    expect(tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('frozen-dim-a'))).opacity, 1);
    await tester.tap(find.text('knob'));
    expect(tapped, 1);
    await tester.pump(const Duration(seconds: 1));
  });

  /// [a] frozen without a render: an asset and the context, as a freeze leaves them.
  void frozenWithoutRender(LayerDoc a) {
    s.project.assets.add(AudioAssetDoc(id: 'fz', path: '/abs/frozen_a.wav', name: 'Frozen · Synth', seconds: 4,
        channels: 2, sourceRate: 48000));
    a
      ..frozenAsset = 'fz'
      ..frozenContext = s.project.freezeContext;
  }

  testWidgets('golden: a frozen track shows a snowflake on its header, and its devices dim', (tester) async {
    frozenWithoutRender(layer('a'));
    final sections = SectionController();
    addTearDown(sections.dispose);
    await pumpGolden(tester, SectionScope(controller: sections,
        child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s)))),
        goldenSizes['phone']!);
    expect(find.byKey(const ValueKey('frozen-badge-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('frozen-badge-b')), findsNothing);
    expect(tester.takeException(), isNull);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/freeze_header_phone.png'));
    sections.focusLayer('a');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('frozen-devices-a')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(goldenScreen, matchesGoldenFile('goldens/freeze_devices_phone.png'));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the track hold menu offers Freeze, Unfreeze and Bounce to audio', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
        builder: (_, _) => ArrangerScreen(state: s)))));
    await tester.pump();
    Future<void> reach(String label) =>
        tester.scrollUntilVisible(find.text(label), 120, scrollable: find.descendant(
            of: find.byKey(const ValueKey('long-press-menu')), matching: find.byType(Scrollable)).first);
    await tester.longPress(find.byKey(const ValueKey('track-header-a')));
    await tester.pumpAndSettle();
    await reach('Bounce to audio');
    expect(find.text('Freeze'), findsOneWidget);
    expect(find.text('Bounce to audio'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    frozenWithoutRender(layer('a'));
    s.notifyListeners();
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('track-header-a')));
    await tester.pumpAndSettle();
    await reach('Unfreeze');
    await tester.tap(find.text('Unfreeze'));
    await tester.pumpAndSettle();
    expect(layer('a').frozen, isFalse);
    await tester.pump(const Duration(seconds: 1));
  });

  // ---------- with the engine (CAW_LIB) ----------

  /// A float WAV's samples (the engine's 32-bit renders).
  List<double> floats(String path) {
    final b = File(path).readAsBytesSync();
    final d = ByteData.sublistView(b);
    for (var at = 12; at + 8 <= b.length;) {
      final tag = String.fromCharCodes(b.sublist(at, at + 4));
      final size = d.getUint32(at + 4, Endian.little);
      if (tag == 'data') return [for (var i = at + 8; i + 4 <= at + 8 + size; i += 4) d.getFloat32(i, Endian.little)];
      at += 8 + size + (size & 1);
    }
    return const [];
  }

  test('with the engine: a frozen track renders the same as the live one, bit for bit (needs CAW_LIB)', () async {
    trackRenderStarter = startNativeSongRender;
    final a = layer('a');
    final dir = await Directory.systemTemp.createTemp('caw-freeze');
    addTearDown(() => dir.delete(recursive: true));
    Future<List<double>> mix(String name) async {
      final r = startNativeSongRender(s.project.toEngineJson(), jsonEncode({'out_dir': dir.path, 'pattern': name,
        'bit_depth': 32, 'tail': 'seconds', 'tail_seconds': 2}));
      final out = jsonDecode((await r.result)!) as Map<String, dynamic>;
      expect(out['ok'], isTrue, reason: '${out['error']}');
      return floats((out['files'] as List).first['path'] as String);
    }
    final live = await mix('live');
    expect(await s.freezeTrack(a).done, isNull);
    expect(s.project.playsFrozen(a), isTrue);
    final cold = await mix('frozen');
    expect(cold.length, live.length);
    var same = true;
    for (var i = 0; i < live.length && same; i++) {
      same = live[i] == cold[i];
    }
    expect(same, isTrue);
    expect(live.any((v) => v.abs() > 0.01), isTrue);
    await File(s.project.asset(a.frozenAsset)!.path).delete();
  }, skip: Platform.environment['CAW_LIB']?.isNotEmpty != true);
}
