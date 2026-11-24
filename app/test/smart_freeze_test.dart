// Smart freeze and the heat line (1.1.0): the suggestion comes only after the CPU stays near the limit while playing,
// names the heaviest track (measured, else by cost hints), shows once and freezes only on a tap; serious thermal
// status shows a warn-only line that changes no setting.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:caw/engine/execution.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/freeze.dart';
import 'package:caw/model/freeze_hint.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/song_export.dart';
import 'package:caw/ui/frame/headroom_notices.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart' show builtinInfos;

const _riff = '---\nkind: pattern\nlength: 16\n---\n0 A2 2 1\n';

ProjectDoc _project() => ProjectDoc(id: 'pheavy', name: 'Heavy', bpm: 120, loopBars: 1,
    modules: [ModuleDoc(id: 'riff', name: 'Riff', source: _riff)],
    layers: [
      LayerDoc(id: 'a', name: 'Pad', color: 1, instrument: ComponentUseDoc('org.caw.synth.flagship'),
          components: [ComponentUseDoc('org.caw.reverb.pro')],
          clips: [ClipDoc(id: 'c1', patternId: 'riff', startSteps: 0, lengthSteps: 16)]),
      LayerDoc(id: 'b', name: 'Bass', color: 2, instrument: ComponentUseDoc('org.caw.synth.flagship'),
          clips: [ClipDoc(id: 'c2', patternId: 'riff', startSteps: 0, lengthSteps: 16)]),
    ]);

/// A render that writes a small file where the request says and reports it, as the engine does.
class _FakeRender implements SongRenderHandle {
  _FakeRender(String requestJson) {
    final request = jsonDecode(requestJson) as Map<String, dynamic>;
    final path = '${request['out_dir']}/${request['pattern']}.wav';
    scheduleMicrotask(() {
      File(path).writeAsBytesSync(Uint8List(64));
      _done.complete(jsonEncode({'ok': true, 'error': '', 'files': [
        {'path': path, 'name': 'x.wav', 'kind': 'track', 'layer': 'a', 'region': '', 'frames': 48000}]}));
    });
  }
  final _done = Completer<String?>();
  @override
  double get progress => 0.5;
  @override
  void cancel() {}
  @override
  Future<String?> get result => _done.future;
}

void main() {
  group('FreezeHint', () {
    final a = LayerDoc(id: 'a', name: 'Pad', color: 0), b = LayerDoc(id: 'b', name: 'Bass', color: 1);
    var reads = 0;
    // [dropAt]: the dropout count at each poll time (ms -> total so far), else the last.
    void run(FreezeHint h, {required int fromMs, required int toMs, bool playing = true, bool overloaded = false,
        int Function(int ms)? drops, Map<String, double?> shares = const {}, Map<String, double> hints = const {}}) {
      for (var ms = fromMs; ms <= toMs; ms += 33) {
        h.poll(ms * 1000, playing: playing, dropouts: drops?.call(ms) ?? 0, overloaded: overloaded,
            tracks: () => [a, b],
            share: (l) {
              reads++;
              return shares[l.id];
            },
            hint: (l) => hints[l.id] ?? 0);
      }
    }

    setUp(() => reads = 0);

    test('nothing without dropouts, stopped, or on one glitch; repeated dropouts: the measured heaviest, once', () {
      final h = FreezeHint();
      // 1.1.2 (the owner: it came at about 40 % with no dropout): the CPU figure is not an input at all; no dropout,
      // nothing, however long.
      run(h, fromMs: 0, toMs: 10000);
      run(h, fromMs: 10000, toMs: 20000, playing: false, drops: (ms) => ms ~/ 100);
      expect(h.suggestion.value, isNull);
      expect(reads, 0, reason: 'no engine reads without trouble');
      // One glitch (three dropouts at one moment), then quiet: nothing.
      run(h, fromMs: 20000, toMs: 35000, drops: (ms) => ms >= 21000 ? 3 : 0);
      expect(h.suggestion.value, isNull);
      expect(reads, 0);
      // Two dropouts, far apart (more than the window): nothing.
      run(h, fromMs: 35000, toMs: 60000, drops: (ms) => 3 + (ms >= 36000 ? 1 : 0) + (ms >= 50000 ? 1 : 0));
      expect(h.suggestion.value, isNull);
      expect(reads, 0);
      // Repeated dropouts within 10 s: measured, then the heaviest named.
      run(h, fromMs: 60000, toMs: 70000, drops: (ms) => 5 + (ms - 60000) ~/ 2000, shares: {'a': 0.08, 'b': 0.21});
      expect(reads, greaterThan(0));
      expect(h.suggestion.value?.layerId, 'b');
      expect(h.suggestion.value?.share, 0.21);
      // Dismissed: never again this run.
      h.dismiss();
      expect(h.done, isTrue);
      run(h, fromMs: 70000, toMs: 90000, drops: (ms) => ms ~/ 500, shares: {'a': 0.5});
      expect(h.suggestion.value, isNull);
    });

    test('shedding held for a while counts; a moment of it does not; without measurements the hints rank', () {
      final h = FreezeHint();
      run(h, fromMs: 0, toMs: 1000, overloaded: true, hints: {'a': 12, 'b': 3});
      run(h, fromMs: 1000, toMs: 9000, hints: {'a': 12, 'b': 3});
      expect(h.suggestion.value, isNull, reason: 'a track shed for a second is not trouble yet');
      run(h, fromMs: 9000, toMs: 17000, overloaded: true, hints: {'a': 12, 'b': 3});
      expect(h.suggestion.value?.layerId, 'a');
      expect(h.suggestion.value?.share, isNull);
    });
  });

  group('DropoutWatch', () {
    test('sums the platform\'s underruns once a second while playing, across new streams', () {
      final w = DropoutWatch();
      var x = 0, reads = 0;
      int read() {
        reads++;
        return x;
      }
      w.poll(0, playing: true, read: read);
      x = 2;
      w.poll(500000, playing: true, read: read);  // under a second: not read
      expect(reads, 1);
      w.poll(1000000, playing: true, read: read);
      expect(w.count, 2);
      x = 1;  // a reopened stream counts from 0 again
      w.poll(2000000, playing: true, read: read);
      x = 4;
      w.poll(3000000, playing: true, read: read);
      expect(w.count, 5);
      w.poll(4000000, playing: false, read: read);
      expect(reads, 4);
      x = -1;  // unknown: nothing
      w.poll(5000000, playing: true, read: read);
      expect(w.count, 5);
    });
  });

  test('a track\'s hinted cost adds its instrument\'s and effects\' hints', () {
    final s = AppState(settings: Settings());
    s.componentCatalog.set(builtinInfos());
    s.project = _project();
    final pad = s.project.layers.first, bass = s.project.layers.last;
    expect(hintedTrackCost(s, pad), greaterThan(hintedTrackCost(s, bass)));
    expect(freezeCandidates(s).map((l) => l.id), ['a', 'b']);
    s.dispose();
  });

  group('the notices', () {
    late AppState s;
    late Directory dir;
    setUp(() {
      Motion.setting = MotionLevel.off;
      dir = Directory.systemTemp.createTempSync('caw_smart_freeze');
      trackRenderStarter = (projectJson, requestJson) => _FakeRender(requestJson);
      s = AppState(settings: Settings());
      s.project = _project();
      s.starting = false;
    });
    tearDown(() {
      trackRenderStarter = startNativeSongRender;
      s.dispose();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<void> pump(WidgetTester tester) => tester.pumpWidget(MaterialApp(home: Scaffold(
        body: Column(children: [HeadroomNotices(state: s), const Expanded(child: SizedBox())]))));

    testWidgets('the suggestion names the track, freezes it only on a tap, and goes', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('freeze-suggestion')), findsNothing);
      s.freezeHint.suggestion.value = const FreezeSuggestion(layerId: 'a', name: 'Pad', share: 0.18);
      await tester.pumpAndSettle();
      expect(find.textContaining('Pad is the heaviest track (18% of a core)'), findsOneWidget);
      expect(s.project.layers.first.frozen, isFalse, reason: 'shown, never applied');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('freeze-suggestion-freeze')));
        for (var k = 0; k < 20 && !s.project.layers.first.frozen; k++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(s.project.layers.first.frozen, isTrue);
      expect(s.freezeHint.done, isTrue);
      expect(find.byKey(const ValueKey('freeze-suggestion')), findsNothing);
    });

    testWidgets('dismissed, it goes without freezing', (tester) async {
      await pump(tester);
      s.freezeHint.suggestion.value = const FreezeSuggestion(layerId: 'b', name: 'Bass');
      await tester.pumpAndSettle();
      expect(find.textContaining('Bass is the heaviest track:'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('freeze-suggestion-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('freeze-suggestion')), findsNothing);
      expect(s.project.layers.every((l) => !l.frozen), isTrue);
      expect(s.freezeHint.done, isTrue);
    });

    testWidgets('serious heat shows a warn-only line; closed, it returns only after the phone cools', (tester) async {
      final before = jsonEncode(s.settings.toJson());
      await pump(tester);
      s.pressure.value = EnginePressure.thermalWarm;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('heat-banner')), findsNothing, reason: 'moderate is not serious');
      s.pressure.value = EnginePressure.thermalHot;
      await tester.pumpAndSettle();
      expect(find.text(HeadroomNotices.heatText), findsOneWidget);
      expect(jsonEncode(s.settings.toJson()), before, reason: 'it never changes a setting');
      await tester.tap(find.byKey(const ValueKey('heat-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('heat-banner')), findsNothing);
      s.pressure.value = EnginePressure.thermalCritical;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('heat-banner')), findsNothing, reason: 'still hot: it stays closed');
      s.pressure.value = EnginePressure.normal;
      await tester.pumpAndSettle();
      s.pressure.value = EnginePressure.thermalHot;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('heat-banner')), findsOneWidget);
      expect(seriousHeat(EnginePressure.batterySaver), isFalse);
    });
  });
}
