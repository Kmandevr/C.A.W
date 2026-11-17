// Comping and Consolidate (1.0.5, #209): the comp's parts (swipe, whole take, a moved join), a MIDI comp's pattern,
// an audio comp's parts with crossfades in the engine JSON, Flatten and undo, the take lanes' swipe and hold menu,
// Consolidate of MIDI and audio clips; with CAW_LIB a comp renders exactly its takes outside the crossfades and a
// consolidated clip renders as the clips did.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_edit.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/comping.dart';
import 'package:caw/model/freeze.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/song_export.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';


const _names = {60: 'C4', 64: 'E4', 67: 'G4'};
String _take(int pitch) => '---\nkind: pattern\nlength: 16\n---\n'
    '0 ${_names[pitch]} 2 1\n4 ${_names[pitch]} 2 1\n8 ${_names[pitch]} 2 1\n12 ${_names[pitch]} 2 1\n';

ProjectDoc _midiProject() => ProjectDoc(id: 'pcomp', name: 'Comp', bpm: 120, loopBars: 1,
    modules: [
      ModuleDoc(id: 't1', name: 'Take 1', source: _take(60)),
      ModuleDoc(id: 't2', name: 'Take 2', source: _take(64)),
      ModuleDoc(id: 't3', name: 'Take 3', source: _take(67)),
    ],
    layers: [
      LayerDoc(id: 'k', name: 'Keys', color: 1, instrument: ComponentUseDoc('org.caw.synth.flagship'), clips: [
        ClipDoc(id: 'c1', patternId: 't3', startSteps: 16, lengthSteps: 16, takes: ['t1', 't2', 't3']),
      ]),
    ]);

ProjectDoc _audioProject() => ProjectDoc(id: 'pcompa', name: 'Comp audio', bpm: 120,
    assets: [
      AudioAssetDoc(id: 'a1', path: '/abs/a1.wav', name: 'Vox take 1', seconds: 2, channels: 1, sourceRate: 48000),
      AudioAssetDoc(id: 'a2', path: '/abs/a2.wav', name: 'Vox take 2', seconds: 2, channels: 1, sourceRate: 48000),
    ],
    layers: [
      LayerDoc(id: 'v', name: 'Vox', color: 2, input: AudioInputDoc(), audioClips: [
        AudioClipDoc(id: 'ac', assetId: 'a2', startSteps: 8, lengthSeconds: 1, fadeIn: 0.02, fadeOut: 0.05,
            takes: ['a1', 'a2']),
      ]),
    ]);

/// A render that writes a small file where the request says and reports it, as the engine does.
class _FakeRender implements SongRenderHandle {
  _FakeRender(String requestJson) {
    request = jsonDecode(requestJson) as Map<String, dynamic>;
    path = '${request['out_dir']}/${request['pattern']}.wav';
    scheduleMicrotask(() {
      File(path).writeAsBytesSync(Uint8List(64));
      _done.complete(jsonEncode({'ok': true, 'error': '', 'files': [
        {'path': path, 'name': 'x.wav', 'kind': 'track', 'layer': 'v', 'region': '', 'frames': 48000}]}));
    });
  }
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

/// A mono float WAV of [seconds] of a sine at [hz] and [amp], at 48 kHz.
File _wav(String path, {required double hz, required double amp, double seconds = 2}) {
  const rate = 48000;
  final frames = (seconds * rate).round();
  final b = ByteData(44 + frames * 4);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }
  tag(0, 'RIFF');
  b.setUint32(4, 36 + frames * 4, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 3, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * 4, Endian.little)
    ..setUint16(32, 4, Endian.little)
    ..setUint16(34, 32, Endian.little);
  tag(36, 'data');
  b.setUint32(40, frames * 4, Endian.little);
  for (var i = 0; i < frames; i++) {
    b.setFloat32(44 + i * 4, amp * math.sin(2 * math.pi * hz * i / rate), Endian.little);
  }
  return File(path)..writeAsBytesSync(b.buffer.asUint8List());
}

/// A float WAV's samples (the engine's 32-bit renders).
List<double> _floats(String path) {
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

void main() {
  late AppState s;
  final requests = <Map<String, dynamic>>[];
  final projects = <Map<String, dynamic>>[];

  void open(ProjectDoc p) {
    s.project = p;
    s.history.reset(jsonEncode(s.project.toJson()));
  }

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
    s.starting = false;
    open(_midiProject());
  });

  tearDown(() {
    trackRenderStarter = startNativeSongRender;
    s.dispose();
  });

  LayerDoc layer(String id) => s.project.layers.firstWhere((l) => l.id == id);
  List<double> pitches(String moduleId) =>
      [for (final n in PatternDoc.parse(s.project.module(moduleId)!.runSource).doc!.notes) n.pitch];

  group('the comp\'s parts', () {
    test('a swipe puts a take over a range; neighbours on one take merge; the first starts at 0', () {
      final one = [const CompPartDoc('a', 0)];
      final two = swipeComp(one, 'b', 4, 8);
      expect(two, [const CompPartDoc('a', 0), const CompPartDoc('b', 4), const CompPartDoc('a', 8)]);
      expect(swipeComp(two, 'a', 4, 8), one, reason: 'swiping the old take back merges');
      expect(swipeComp(two, 'c', 0, 6), [const CompPartDoc('c', 0), const CompPartDoc('b', 6), const CompPartDoc('a', 8)]);
      expect(swipeComp(two, 'c', 6, 6), two, reason: 'an empty swipe changes nothing');
      expect(normalizeComp([const CompPartDoc('b', 3), const CompPartDoc('a', 3)]), [const CompPartDoc('a', 0)]);
      expect(compTakeAt(two, 5), 'b');
      expect(compTakeAt(two, 8), 'a');
    });

    test('a comp read from a file names only its takes, in bounds, else is none', () {
      expect(compFromJson([{'take': 'a', 'from': 0}, {'take': 'b', 'from': 2.5}], ['a', 'b']),
          [const CompPartDoc('a', 0), const CompPartDoc('b', 2.5)]);
      expect(compFromJson([{'take': 'a', 'from': 0}, {'take': 'x', 'from': 2}], ['a', 'b']), isEmpty);
      expect(compFromJson([{'take': 'a', 'from': 0}, {'take': 'b', 'from': -1}], ['a', 'b']), isEmpty);
      expect(compFromJson([{'take': 'a', 'from': 0}], ['a', 'b']), isEmpty);
      expect(compFromJson([for (var i = 0; i <= kMaxCompParts; i++) {'take': i.isEven ? 'a' : 'b', 'from': i}],
          ['a', 'b']), isEmpty);
      expect(compFromJson('nope', ['a']), isEmpty);
    });

    test('the comp fields round trip (format v5), and a MIDI comp that names a take as its pattern is dropped', () {
      final clip = ClipDoc(id: 'c', patternId: 'cp', takes: ['t1', 't2'],
          comp: [const CompPartDoc('t1', 0), const CompPartDoc('t2', 4)]);
      final back = ClipDoc.fromJson(jsonDecode(jsonEncode(clip.toJson())) as Map<String, dynamic>);
      expect(back.comp, clip.comp);
      expect(ClipDoc.fromJson({...clip.toJson(), 'pattern': 't1'}).comp, isEmpty);
      final a = AudioClipDoc(id: 'x', assetId: 'a1', takes: ['a1', 'a2'],
          comp: [const CompPartDoc('a1', 0), const CompPartDoc('a2', 0.75)]);
      expect(AudioClipDoc.fromJson(jsonDecode(jsonEncode(a.toJson())))!.comp, a.comp);
      final l = LayerDoc(id: 'l', name: 'L', color: 0, showTakes: true);
      expect(LayerDoc.fromJson(jsonDecode(jsonEncode(l.toJson())) as Map<String, dynamic>).showTakes, isTrue);
      expect(LayerDoc(id: 'l', name: 'L', color: 0).toJson().containsKey('show_takes'), isFalse);
      expect(ProjectDoc.fileVersion, 5);
    });
  });

  group('MIDI', () {
    test('a swipe plays that take there: a comp pattern of its own, one undo step', () {
      final k = layer('k');
      final c = k.clips.single;
      expect(s.swipeTake(k, TakeClip.midi(c), 't2', 16 + 4, 16 + 9.6), isTrue);
      expect(c.comp, [const CompPartDoc('t3', 0), const CompPartDoc('t2', 4), const CompPartDoc('t3', 10)]);
      expect(c.takes, ['t1', 't2', 't3']);
      expect(c.takes, isNot(contains(c.patternId)));
      expect(s.project.module(c.patternId)!.name, 'Comp');
      // Steps 0 and 12 from take 3, 4 and 8 from take 2 (a whole step: 9.6 rounds to 10).
      expect(pitches(c.patternId), [67, 64, 64, 67]);
      // The engine plays the comp pattern.
      final sent = (((jsonDecode(s.project.toEngineJson()) as Map)['layers'] as List).first as Map)['clips'] as List;
      expect((sent.single as Map)['pattern'], c.patternId);
      // Another swipe changes the same pattern.
      final comp = c.patternId;
      expect(s.swipeTake(k, TakeClip.midi(c), 't1', 16 + 12, 16 + 16), isTrue);
      expect(c.patternId, comp);
      expect(pitches(comp), [67, 64, 64, 60]);
      expect(s.undo(), isTrue);
      expect(pitches(layer('k').clips.single.patternId), [67, 64, 64, 67]);
      expect(s.undo(), isTrue);
      expect(layer('k').clips.single.comp, isEmpty);
      expect(layer('k').clips.single.patternId, 't3');
    });

    test('a note is cut at its part\'s end; a whole take ends the comp and its pattern goes', () {
      final k = layer('k');
      final c = k.clips.single;
      s.project.module('t2')!
        ..source = '---\nkind: pattern\nlength: 16\n---\n2 E4 8 1\n'
        ..runSource = '---\nkind: pattern\nlength: 16\n---\n2 E4 8 1\n';
      final e4 = pitches('t2').single;
      expect(s.swipeTake(k, TakeClip.midi(c), 't2', 16, 16 + 6), isTrue);
      final notes = PatternDoc.parse(s.project.module(c.patternId)!.runSource).doc!.notes;
      final e = notes.firstWhere((n) => n.pitch == e4);
      expect((e.at, e.len), (Steps(2), Steps(4)), reason: 'cut where take 3 takes over');
      final comp = c.patternId;
      expect(s.useWholeTake(k, TakeClip.midi(c), 't1'), isTrue);
      expect(c.comp, isEmpty);
      expect(c.patternId, 't1');
      expect(s.project.module(comp), isNull);
    });

    test('a join moves between its neighbours', () {
      final k = layer('k');
      final c = k.clips.single;
      s.swipeTake(k, TakeClip.midi(c), 't1', 16 + 4, 16 + 8);
      expect(s.moveCompJoin(k, TakeClip.midi(c), 1, 16 + 6), isTrue);
      expect(c.comp[1].from, 6);
      expect(s.moveCompJoin(k, TakeClip.midi(c), 1, 16 + 9), isFalse, reason: 'past the next join');
      expect(TakeClip.midi(c).joins(s.project), [22, 24]);
    });

    test('Flatten keeps what plays as an ordinary clip and drops the unused takes, one undo step', () {
      final k = layer('k');
      final c = k.clips.single;
      s.swipeTake(k, TakeClip.midi(c), 't2', 16 + 4, 16 + 8);
      final comp = c.patternId;
      expect(s.flattenTakes(k, takeClips(k)), isTrue);
      expect(c.takes, isEmpty);
      expect(c.comp, isEmpty);
      expect(c.patternId, comp);
      expect([for (final m in s.project.modules) m.id], [comp]);
      expect(pitches(comp), [67, 64, 67, 67]);
      expect(s.undo(), isTrue);
      expect(layer('k').clips.single.takes, ['t1', 't2', 't3']);
      expect(s.project.module('t1'), isNotNull);
    });

    test('a frozen track asks before a comp changes', () {
      final k = layer('k');
      s.project.assets.add(AudioAssetDoc(id: 'fz', path: '/abs/fz.wav', name: 'F', seconds: 2));
      k
        ..frozenAsset = 'fz'
        ..frozenContext = s.project.freezeContext;
      final asked = <LayerDoc>[];
      s.onFrozenEdit = asked.add;
      expect(s.swipeTake(k, TakeClip.midi(k.clips.single), 't2', 20, 24), isFalse);
      expect(asked, [k]);
      expect(k.clips.single.comp, isEmpty);
    });

    test('Consolidate joins the selected MIDI clips into one clip of their notes, one undo step', () {
      final k = layer('k');
      k.clips
        ..clear()
        ..addAll([
          ClipDoc(id: 'x1', patternId: 't1', startSteps: 0, lengthSteps: 8),
          ClipDoc(id: 'x2', patternId: 't2', startSteps: 16, lengthSteps: 8),
        ]);
      s.history.reset(jsonEncode(s.project.toJson()));
      expect(s.consolidateMidiClips(k, [...k.clips]), isTrue);
      final one = k.clips.single;
      expect((one.startSteps, one.lengthSteps), (0, 24));
      expect(pitches(one.patternId), [60, 60, 64, 64]);
      expect(s.undo(), isTrue);
      expect(layer('k').clips.map((c) => c.id), ['x1', 'x2']);
      expect(s.consolidateMidiClips(k, [k.clips.first]), isFalse, reason: 'one clip has nothing to join');
    });
  });

  group('audio', () {
    setUp(() => open(_audioProject()));

    test('a comp goes to the engine as its parts, crossfaded at the joins with equal power', () {
      final v = layer('v');
      final c = v.audioClips.single;
      // Steps 8..16 are the clip's second (120 BPM): take 1 swiped over steps 10..12, 0.25..0.5 s of the file.
      expect(s.swipeTake(v, TakeClip.audio(c), 'a1', 10, 12), isTrue);
      expect(c.comp, [const CompPartDoc('a2', 0), const CompPartDoc('a1', 0.25), const CompPartDoc('a2', 0.5)]);
      final clips = ((((jsonDecode(s.project.toEngineJson()) as Map)['layers'] as List).first as Map)['audio_clips']
          as List).cast<Map<String, dynamic>>();
      expect(clips.map((x) => x['id']), ['ac~0', 'ac~1', 'ac~2']);
      expect(clips.map((x) => x['asset']), ['a2', 'a1', 'a2']);
      const h = kCompCrossfadeSeconds / 2;
      expect(clips[0]['start_steps'], 8);
      expect(clips[0]['offset_seconds'], 0);
      expect(clips[0]['length_steps'], closeTo((0.25 + h) * 8, 1e-9));
      expect(clips[0]['fade_in_seconds'], 0.02, reason: 'the clip\'s own fade in');
      expect(clips[0]['fade_out_seconds'], closeTo(2 * h, 1e-12));
      expect(clips[0]['fade_out_curve'], 'equal_power');
      expect(clips[1]['start_steps'], closeTo(10 - h * 8, 1e-9));
      expect(clips[1]['offset_seconds'], closeTo(0.25 - h, 1e-12));
      expect(clips[1]['fade_in_curve'], 'equal_power');
      expect(clips[2]['offset_seconds'], closeTo(0.5 - h, 1e-12));
      expect(clips[2]['fade_out_seconds'], 0.05, reason: 'the clip\'s own fade out');
      expect(clips[2]['length_steps'], closeTo((0.5 + h) * 8, 1e-9));
      // The parts meet in the middle of each crossfade.
      expect((clips[0]['start_steps'] as num) + (clips[0]['length_steps'] as num), closeTo(10 + h * 8, 1e-9));
    });

    test('a trim, a split and a reverse keep each part on its audio', () {
      final v = layer('v');
      final c = v.audioClips.single;
      s.swipeTake(v, TakeClip.audio(c), 'a1', 12, 16);  // the second half from take 1
      trimAudioStart(c, 10, bpm: 120);
      expect(c.offsetSeconds, 0.25);
      expect(TakeClip.audio(c).joins(s.project).single, closeTo(12, 1e-9));
      final right = splitAudioClip(c, 14, 'r', bpm: 120)!;
      expect(right.comp, c.comp);
      expect(TakeClip.audio(right).joins(s.project), isEmpty, reason: 'the join is in the left part');
      expect(compTakeAt(right.comp, right.offsetSeconds), 'a1');
      reverseAudioClip(c, 2, bpm: 120);
      // The left part (0.25..0.75 s, take 1 from 0.5 s) read backwards: take 1 first now, until 0.25 s in.
      expect(compTakeAt(c.comp, c.offsetSeconds + 0.1), 'a1');
      expect(TakeClip.audio(c).joins(s.project).single, closeTo(10 + 2, 1e-9));
    });

    test('Flatten makes a clip per part (crossfades as fades) and drops the unused takes, one undo step', () {
      final v = layer('v');
      final c = v.audioClips.single;
      s.swipeTake(v, TakeClip.audio(c), 'a1', 10, 12);
      final parts = compAudioParts(s.project, c);
      expect(s.flattenTakes(v, takeClips(v)), isTrue);
      expect(v.audioClips, hasLength(3));
      for (final (i, x) in v.audioClips.indexed) {
        expect(x.takes, isEmpty);
        expect(x.comp, isEmpty);
        expect(x.toEngineJson(120)..remove('id'), parts[i].toEngineJson(120)..remove('id'));
      }
      expect(s.project.assets.map((a) => a.id), ['a1', 'a2'], reason: 'both still play');
      expect(s.undo(), isTrue);
      expect(layer('v').audioClips.single.comp, hasLength(3));
    });

    test('Flatten of a clip playing one take drops the other', () {
      final v = layer('v');
      expect(s.flattenTakes(v, takeClips(v)), isTrue);
      expect(v.audioClips.single.takes, isEmpty);
      expect(s.project.assets.map((a) => a.id), ['a2']);
    });

    test('picking a whole take by the chip ends the comp', () {
      final v = layer('v');
      final c = v.audioClips.single;
      s.swipeTake(v, TakeClip.audio(c), 'a1', 10, 12);
      s.selectAudioTake(v, c, 0);
      expect(c.comp, isEmpty);
      expect(c.assetId, 'a1');
    });

    test('Consolidate renders the selected clips before the fader, through no devices, into one clip', () async {
      final v = layer('v');
      v.audioClips.add(AudioClipDoc(id: 'ac2', assetId: 'a1', startSteps: 20.5, lengthSeconds: 0.5));
      v.components.add(ComponentUseDoc('org.caw.delay.pro'));
      s.history.reset(jsonEncode(s.project.toJson()));
      expect(await s.consolidateAudioClips(v, [...v.audioClips]).done, isNull);
      final r = requests.single;
      expect(r['stem_tap'], 'pre');
      expect(r['tail'], 'none');
      expect(r['bounds'], 'selection');
      expect((r['start_steps'], r['end_steps']), (8, 25));
      final sent = (projects.single['layers'] as List).cast<Map<String, dynamic>>().single;
      expect(sent.containsKey('components'), isFalse);
      expect((sent['audio_clips'] as List).map((c) => c['id']), ['ac', 'ac2']);
      final one = v.audioClips.single;
      expect(one.startSteps, 8);
      expect(one.lengthSeconds, 1.0);
      expect(s.project.asset(one.assetId)!.name, 'Vox take 2 (consolidated)');
      expect(s.undo(), isTrue);
      expect(layer('v').audioClips.map((c) => c.id), ['ac', 'ac2']);
    });
  });

  testWidgets('take lanes: a swipe picks, a double tap plays a take whole, the hold menu flattens', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    layer('k').showTakes = true;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
        builder: (_, _) => ArrangerScreen(state: s)))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('take-header-k-2')), findsOneWidget);
    final lane = find.byKey(const ValueKey('take-lane-c1-0'));
    expect(lane, findsOneWidget);
    final box = tester.getRect(lane);
    final stepW = box.width / 16;
    // Swipe take 1 across steps 4..8 of the clip.
    final g = await tester.startGesture(Offset(box.left + 4.2 * stepW, box.center.dy));
    for (var i = 1; i <= 8; i++) {
      await g.moveBy(Offset(stepW / 2, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    final c = layer('k').clips.single;
    expect(c.comp, [const CompPartDoc('t3', 0), const CompPartDoc('t1', 4), const CompPartDoc('t3', 8)]);
    expect(find.byKey(const ValueKey('clip-comp-joins-c1')), findsOneWidget);
    // A double tap on take 2: it plays whole.
    final two = find.byKey(const ValueKey('take-lane-c1-1'));
    await tester.tap(two);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(two);
    await tester.pumpAndSettle();
    expect(c.comp, isEmpty);
    expect(c.patternId, 't2');
    // The hold menu: Flatten.
    await tester.longPress(find.byKey(const ValueKey('take-lane-c1-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Flatten'));
    await tester.pumpAndSettle();
    expect(layer('k').clips.single.takes, isEmpty);
    expect(find.byKey(const ValueKey('take-header-k-0')), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the clip menu opens the take lanes and offers Consolidate for a selection', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final k = layer('k');
    k.clips.add(ClipDoc(id: 'c2', patternId: 't1', startSteps: 34, lengthSteps: 8));
    s.selectClipsInBox([(layer: k, clip: k.clips[0]), (layer: k, clip: k.clips[1])]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
        builder: (_, _) => ArrangerScreen(state: s)))));
    await tester.pumpAndSettle();
    Future<void> reach(String label) =>
        tester.scrollUntilVisible(find.text(label), 120, scrollable: find.descendant(
            of: find.byKey(const ValueKey('long-press-menu')), matching: find.byType(Scrollable)).first);
    await tester.longPress(find.byKey(const ValueKey('clip-c2')));
    await tester.pumpAndSettle();
    await reach('Consolidate 2 clips');
    await tester.tap(find.text('Consolidate 2 clips'));
    await tester.pumpAndSettle();
    expect(layer('k').clips, hasLength(1));
    expect(layer('k').clips.single.takes, isEmpty, reason: 'consolidated clips are plain');
    expect(s.undo(), isTrue);
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('clip-c1')));
    await tester.pumpAndSettle();
    await reach('Take lanes');
    await tester.tap(find.text('Take lanes'));
    await tester.pumpAndSettle();
    expect(layer('k').showTakes, isTrue);
    expect(find.byKey(const ValueKey('take-header-k-0')), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  // ---------- with the engine (CAW_LIB) ----------

  group('with the engine (needs CAW_LIB)', () {
    late Directory dir;
    setUp(() async {
      trackRenderStarter = startNativeSongRender;
      dir = await Directory.systemTemp.createTemp('caw-comp');
      s.settings.sampleRate = 48000;
    });
    tearDown(() => dir.delete(recursive: true));

    /// Track [id]'s audio before its fader, as the engine renders it (stereo, interleaved).
    Future<List<double>> stem(String name, {String id = 'v'}) async {
      final r = startNativeSongRender(s.project.toEngineJson(), jsonEncode({'out_dir': dir.path, 'pattern': name,
        'bit_depth': 32, 'sample_rate': 48000, 'mix': false, 'layers': [id], 'stem_tap': 'pre',
        'stems_through_master': false, 'tail': 'none'}));
      final out = jsonDecode((await r.result)!) as Map<String, dynamic>;
      expect(out['ok'], isTrue, reason: '${out['error']}');
      return _floats((out['files'] as List).first['path'] as String);
    }

    ProjectDoc project() => ProjectDoc(id: 'pc', name: 'Comp', bpm: 120, loopBars: 1, assets: [
          AudioAssetDoc(id: 'a1', path: _wav('${dir.path}/a1.wav', hz: 440, amp: 0.5).path, name: 'A', seconds: 2,
              channels: 1, sourceRate: 48000),
          AudioAssetDoc(id: 'a2', path: _wav('${dir.path}/a2.wav', hz: 330, amp: 0.3).path, name: 'B', seconds: 2,
              channels: 1, sourceRate: 48000),
        ], layers: [
          LayerDoc(id: 'v', name: 'Vox', color: 0, volume: 1, audioClips: [
            AudioClipDoc(id: 'ac', assetId: 'a1', startSteps: 0, lengthSeconds: 1, takes: ['a1', 'a2']),
          ]),
        ]);

    test('a comp plays each take exactly outside the crossfades, and their equal-power sum in them', () async {
      open(project());
      final c = layer('v').audioClips.single;
      final a = await stem('a');
      s.selectAudioTake(layer('v'), c, 1);
      final b = await stem('b');
      s.useWholeTake(layer('v'), TakeClip.audio(c), 'a1');
      expect(s.swipeTake(layer('v'), TakeClip.audio(c), 'a2', 4, 8), isTrue);  // 0.5 s on: take 2
      final comp = await stem('comp');
      expect(comp.length, a.length);
      const join = 24000, half = 240;  // 10 ms crossfades at 48 kHz
      var exactA = true, exactB = true;
      for (var n = 0; n < join - half - 1; n++) {
        exactA = exactA && comp[2 * n] == a[2 * n];
      }
      for (var n = join + half + 1; n < 48000; n++) {
        exactB = exactB && comp[2 * n] == b[2 * n];
      }
      expect(exactA, isTrue, reason: 'take 1 before the crossfade');
      expect(exactB, isTrue, reason: 'take 2 after it');
      for (final n in [join - half ~/ 2, join, join + half ~/ 2]) {
        final u = (n - (join - half)) / (2 * half);
        final want = a[2 * n] * math.cos(u * math.pi / 2) + b[2 * n] * math.sin(u * math.pi / 2);
        expect(comp[2 * n], closeTo(want, 2e-3), reason: 'sample $n');
      }
      // Flatten plays the same.
      s.flattenTakes(layer('v'), takeClips(layer('v')));
      final flat = await stem('flat');
      var same = flat.length == comp.length;
      for (var i = 0; i < flat.length && same; i++) {
        same = flat[i] == comp[i];
      }
      expect(same, isTrue);
    }, skip: Platform.environment['CAW_LIB']?.isNotEmpty != true);

    test('a consolidated clip renders as the clips it replaced', () async {
      open(project());
      final v = layer('v');
      v.audioClips
        ..clear()
        ..addAll([
          AudioClipDoc(id: 'x1', assetId: 'a1', startSteps: 0, lengthSeconds: 0.5, fadeOut: 0.01),
          AudioClipDoc(id: 'x2', assetId: 'a2', startSteps: 6, lengthSeconds: 0.25, offsetSeconds: 0.1),
        ]);
      final before = await stem('before');
      expect(await s.consolidateAudioClips(v, [...v.audioClips]).done, isNull);
      expect(v.audioClips, hasLength(1));
      final after = await stem('after');
      expect(after.length, before.length);
      var worst = 0.0;
      for (var i = 0; i < before.length; i++) {
        worst = math.max(worst, (after[i] - before[i]).abs());
      }
      expect(worst, lessThan(1e-6));
      expect(before.any((x) => x.abs() > 0.1), isTrue);
    }, skip: Platform.environment['CAW_LIB']?.isNotEmpty != true);
  });
}
