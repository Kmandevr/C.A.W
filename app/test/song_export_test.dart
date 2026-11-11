// The Export sheet: options to the engine request, file-name previews, the persistent queue (order, cancel, failure,
// restart), the sheet's controls on a phone, and (with CAW_LIB) a real render of the mix and stems.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/song_export.dart';
import 'package:caw/ui/export_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A render the test finishes by hand.
class _FakeRender implements SongRenderHandle {
  _FakeRender(this.project, this.request);
  final String project;
  final Map<String, dynamic> request;
  final done = Completer<String?>();
  bool cancelled = false;
  @override
  double progress = 0;
  @override
  void cancel() {
    cancelled = true;
    if (!done.isCompleted) done.complete('cancelled');
  }

  @override
  Future<String?> get result => done.future;

  void succeed(List<String> names) {
    final dir = request['out_dir'] as String;
    final files = [
      for (final n in names) {'path': '$dir/$n', 'name': n, 'kind': 'mix', 'layer': '', 'region': '', 'frames': 10,
        'gain_db': 0, 'peak_db': -3, 'lufs': -14},
    ];
    for (final f in files) {
      File(f['path'] as String).writeAsStringSync('RIFF');
    }
    done.complete(jsonEncode({'ok': true, 'error': '', 'files': files}));
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

/// Waits (up to 5 s) for [ready].
Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 250 && !ready(); i++) {
    await _settle();
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('caw_song_export_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('options make the engine request: stems, regions, loudness, tail, dither only at 16-bit', () {
    final o = SongExportOptions(source: ExportSource.mixAndStems, stems: StemSet.both, range: ExportRange.regions,
        bitDepth: 16, loudness: ExportLoudness.lufs, lufsTarget: -16, ceiling: -1.5, tail: ExportTail.seconds,
        tailSeconds: 3);
    final r = songRenderRequest(o, project: 'Song', spans: const [ExportSpan(0, 16, 'Verse'), ExportSpan(16, 48, 'Chorus')]);
    expect(r['mix'], isTrue);
    expect(r['tracks'], isTrue);
    expect(r['buses'], isTrue);
    expect(r['bounds'], 'regions');
    expect((r['regions'] as List).last, {'name': 'Chorus', 'start_steps': 16, 'end_steps': 48});
    expect(r['bit_depth'], 16);
    expect(r['dither'], isTrue);
    expect(r['normalize'], 'lufs');
    expect(r['target'], -16);
    expect(r['ceiling'], -1.5);
    expect(r['tail'], 'seconds');
    expect(r['tail_seconds'], 3);

    final plain = songRenderRequest(SongExportOptions(bitDepth: 24, tail: ExportTail.none), project: 'S',
        spans: const [ExportSpan(4, 20)]);
    expect(plain['bounds'], 'selection');
    expect(plain['start_steps'], 4);
    expect(plain['dither'], isFalse);
    expect(plain['normalize'], 'none');
    expect(plain['tracks'], isFalse);
    expect(songRenderRequest(SongExportOptions(), project: 'S')['bounds'], 'song');
    // The options survive a round trip, and junk falls back to the defaults.
    expect(SongExportOptions.fromJson(o.toJson()).toJson(), o.toJson());
    expect(SongExportOptions.fromJson({'bit_depth': 20, 'sample_rate': 1}).bitDepth, 24);
  });

  test('file names follow the engine\'s rule: empty tokens collapse, repeats are numbered', () {
    final o = SongExportOptions(source: ExportSource.mixAndStems);
    final names = previewNames(o, project: 'My Song', stems: const [(name: 'Bass', kind: 'track'), (name: 'Bass', kind: 'track')],
        regions: const ['', ]);
    expect(names, ['My_Song.wav', 'My_Song_Bass.wav', 'My_Song_Bass_2.wav']);
    expect(previewNames(o, project: 'S', stems: const [(name: 'Drums', kind: 'bus')], regions: const ['Verse', 'Verse']),
        ['S_Verse.wav', 'S_Verse_Drums.wav', 'S_Verse_2.wav', 'S_Verse_Drums_2.wav']);
  });

  test('the queue runs renders one after another, cancels, reports failures and survives a restart', () async {
    final started = <_FakeRender>[];
    final q = ExportQueue(tmp, starter: (p, r) {
      final f = _FakeRender(p, jsonDecode(r) as Map<String, dynamic>);
      started.add(f);
      return f;
    });
    await q.load();
    final finished = <ExportJobState>[];
    q.onFinished = (j) => finished.add(j.state);
    expect(q.add(title: 'one', projectJson: '{}', request: {'project': 'A'}), isTrue);
    expect(q.add(title: 'two', projectJson: '{}', request: {'project': 'B'}), isTrue);
    expect(q.add(title: 'three', projectJson: '{}', request: {'project': 'C'}), isTrue);
    await _settle();
    expect(started.length, 1, reason: 'one render at a time');
    expect(q.jobs[0].state, ExportJobState.running);
    expect(Directory(started[0].request['out_dir'] as String).existsSync(), isTrue);
    q.cancel(q.jobs[2]);  // still queued
    expect(q.jobs[2].state, ExportJobState.cancelled);
    started[0].succeed(['A.wav', 'A_Bass.wav']);
    await _until(() => started.length == 2);
    expect(q.jobs[0].state, ExportJobState.done);
    expect(q.jobs[0].files.map((f) => f.name), ['A.wav', 'A_Bass.wav']);
    expect(started.length, 2);
    started[1].done.complete('the output folder doesn\'t exist');
    await _until(() => finished.length == 2);
    expect(q.jobs[1].state, ExportJobState.failed);
    expect(q.jobs[1].error, contains('folder'));
    expect(finished, [ExportJobState.done, ExportJobState.failed]);
    expect(started.length, 2, reason: 'the cancelled one never starts');

    // Queued work and finished files come back after a restart; a render cut off by it starts again.
    q.retry(q.jobs[2]);
    await _until(() => started.length == 3);
    expect(q.jobs[2].state, ExportJobState.running);
    await q.remember(SongExportOptions(bitDepth: 16));
    final again = ExportQueue(tmp, starter: (p, r) => _FakeRender(p, jsonDecode(r) as Map<String, dynamic>));
    await again.load();
    expect(again.hasLast, isTrue);
    expect(again.last.bitDepth, 16);
    expect(again.jobs.length, 3);
    expect(again.jobs[0].files.length, 2);
    expect(again.jobs[2].state, ExportJobState.running, reason: 'restarted at load');
    // Removing a finished render deletes its files.
    final folder = File(again.jobs[0].files.first.path).parent;
    await again.remove(again.jobs[0]);
    expect(folder.existsSync(), isFalse);
    started[2].cancel();
    await _until(() => !q.busy);
  });

  testWidgets('the sheet on a phone: source, stems, range and format choices, then Render queues it', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    s.project = ProjectDoc(id: 'p', name: 'Song', bpm: 120, layers: [
      LayerDoc(id: 'a', name: 'Bass', color: 0, instrument: ComponentUseDoc('org.caw.synth.flagship')),
      LayerDoc(id: 'b', name: 'Keys', color: 1, instrument: ComponentUseDoc('org.caw.synth.flagship'), parentId: 'bus'),
      LayerDoc(id: 'bus', name: 'Verb', color: 2, isFolder: true),
    ]);
    s.project.markers.add(MarkerDoc(id: 'r', name: 'Verse', startSteps: 0, endSteps: 16));
    final requests = <Map<String, dynamic>>[];
    final q = ExportQueue(tmp, starter: (p, r) {
      requests.add(jsonDecode(r) as Map<String, dynamic>);
      return _FakeRender(p, requests.last);
    });
    await tester.runAsync(q.load);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SongExportPanel(state: s, queue: q))));
    expect(find.text('Render 1 file'), findsOneWidget);
    // Selection has none drawn: its tile is off.
    await tester.tap(find.byKey(const ValueKey('range-selection')));
    await tester.pump();
    expect(find.textContaining('The whole song'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('source-mixAndStems')));
    await tester.pump();
    expect(find.text('BOTH · 3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stems-both')));
    await tester.pump();
    expect(find.text('Render 4 files'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('range-regions')));
    await tester.pump();
    expect(find.textContaining('1 region'), findsOneWidget);
    await tester.tap(find.textContaining('FORMAT'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('bits-16')));
    await tester.pump();
    expect(find.byKey(const ValueKey('export-dither')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('export-render')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const ValueKey('export-render')));
    for (var i = 0; i < 100 && requests.isEmpty; i++) {
      await tester.runAsync(_settle);
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump();
    expect(q.jobs.length, 1);
    expect(requests.single['bounds'], 'regions');
    expect(requests.single['bit_depth'], 16);
    expect(requests.single['tracks'], isTrue);
    expect(requests.single['buses'], isTrue);
    expect(q.last.bitDepth, 16, reason: 'the next sheet opens with these');
    await tester.scrollUntilVisible(find.textContaining('Rendering'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Rendering'), findsOneWidget);
    q.cancel(q.jobs.single);
    for (var i = 0; i < 100 && q.busy; i++) {
      await tester.runAsync(_settle);
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump();
    expect(find.text('Cancelled'), findsOneWidget);
  });

  test('with the engine: the queue renders the mix and stems to aligned WAV files (needs CAW_LIB)', () async {
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    s.project = s.starterProject();
    final q = ExportQueue(tmp);
    await q.load();
    final done = Completer<ExportJob>();
    q.onFinished = done.complete;
    final o = SongExportOptions(source: ExportSource.mixAndStems, stems: StemSet.tracks, tail: ExportTail.none,
        bitDepth: 16);
    q.add(title: 'song', projectJson: s.project.toEngineJson(), request: songRenderRequest(o, project: 'Starter',
        spans: const [ExportSpan(0, 16)]));
    final job = await done.future.timeout(const Duration(minutes: 2));
    expect(job.state, ExportJobState.done, reason: job.error);
    expect(job.files.length, greaterThan(1));
    expect(job.files.map((f) => f.frames).toSet().length, 1, reason: 'every stem as long as the mix');
    expect(job.files.first.name, 'Starter.wav');
    for (final f in job.files) {
      expect(File(f.path).lengthSync(), 44 + f.frames * 4);  // 16-bit stereo
    }
  }, skip: Platform.environment['CAW_LIB']?.isNotEmpty != true);
}
