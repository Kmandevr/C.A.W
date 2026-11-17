// Files › Samples (#229) on screen: link a folder, a tap previews (synced to the project tempo), a double tap adds to the smart target, arrows play the next, the volume, filters, and Find it on the missing-files banner.
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/music_key.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/sample_library.dart';
import 'package:caw/model/sample_names.dart';
import 'package:caw/model/sample_use.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/linked_folders.dart';
import 'package:caw/ui/file_manager_screen.dart';
import 'package:caw/ui/files/project_file_actions.dart';
import 'package:caw/ui/files/sample_browser.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';
import 'sample_fake.dart';

class _NoPathAccess extends FakeFolderAccess {
  @override
  Future<String?> readablePath(String location, ListedFile file) async => '$location/${file.rel}';
}

void main() {
  late AppState s;
  late FakePreview preview;
  late SampleLibrary lib;
  const lf = 'lfTest';

  SampleEntry e(String rel, {double? bpm, MusicalKey? key, SampleKind? kind, ValueSource from = ValueSource.name,
          SampleInstrument? inst}) =>
      SampleEntry(root: lf, rel: rel)
        ..bpm = bpm
        ..bpmFrom = bpm == null ? null : from
        ..key = key
        ..keyFrom = key == null ? null : from
        ..keyConfidence = from == ValueSource.detected ? 0.5 : null
        ..kind = kind
        ..instrument = inst
        ..seconds = 2;

  setUp(() {
    s = AppState(settings: Settings());
    s.audioIo = FakeAudioIo();
    preview = FakePreview();
    s.samplePreview = preview;
    lib = SampleLibrary(access: _NoPathAccess());
    s.sampleLibrary = lib;
    s.project = ProjectDoc(id: 'p', name: 'P', bpm: 120, layers: []);
  });
  tearDown(() => s.dispose());

  Finder row(String rel) => find.byKey(ValueKey('sample:$lf/$rel'));

  Future<void> pump(WidgetTester tester, {String folder = 'samples'}) async {
    await tester.pumpWidget(MaterialApp(home: SectionScope(controller: SectionController(),
        child: Scaffold(body: FileManagerScreen(state: s, folder: folder)))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('with no folder linked, it explains and offers Link folder…', (tester) async {
    lib.debugSet(LinkedFolder(id: lf, name: 'Lib', location: '/lib'), []);
    lib.folders.clear();
    await pump(tester);
    expect(find.byKey(const ValueKey('samples-link')), findsOneWidget);
    expect(find.textContaining('nothing is copied'), findsOneWidget);
  });

  testWidgets('rows show tempo and key, estimates marked; tap previews in sync; double tap adds; arrows play the next',
      (tester) async {
    lib.debugSet(LinkedFolder(id: lf, name: 'Lib', location: '/lib'), [
      e('Loops/Groove.wav', bpm: 90, key: const MusicalKey(9, minor: true), kind: SampleKind.loop),
      e('Loops/Pad.wav', key: const MusicalKey(0), from: ValueSource.detected, kind: SampleKind.loop),
      e('Hits/Kick.wav', kind: SampleKind.oneShot, inst: SampleInstrument.kick),
    ]);
    await pump(tester, folder: 'samples/$lf');
    // The tree shows the folder under Samples (wide enough for the tree at the default test size).
    expect(find.text('Groove'), findsOneWidget);
    expect(find.text('90'), findsOneWidget);
    expect(find.text('Am'), findsOneWidget);
    expect(find.text('~C'), findsOneWidget);  // an estimate
    await tester.tap(row('Loops/Groove.wav'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(preview.plays.single['path'], '/lib/Loops/Groove.wav');
    expect(preview.plays.single['ratio'], 0.75);  // 90 BPM played at the project's 120
    expect(preview.plays.single['loop'], isTrue);
    expect(preview.plays.single['sync'], 'now');  // the song isn't playing
    // A double tap adds it: nothing selected, so a new audio track.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(row('Hits/Kick.wav'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(row('Hits/Kick.wav'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(s.project.layers.single.audioClips, hasLength(1));
    expect(s.project.assets.single.link!.rel, 'Hits/Kick.wav');
    expect(find.textContaining('on a new track'), findsOneWidget);
    // Arrow keys play the next and the previous.
    final before = preview.plays.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 50));
    expect(preview.plays.length, before + 1);
    expect(preview.plays.last['path'], '/lib/Loops/Pad.wav');
    // The volume slider reaches the engine.
    await tester.drag(find.byKey(const ValueKey('samples-volume')), const Offset(-60, 0));
    await tester.pump();
    expect(preview.volume, lessThan(0.8));
    // Sync off: the loop plays at its own tempo.
    await tester.tap(find.byKey(const ValueKey('samples-sync')));
    await tester.pump();
    await tester.tap(row('Loops/Groove.wav'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(preview.plays.last['ratio'], 1.0);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('filters narrow the list and Clear brings it back', (tester) async {
    lib.debugSet(LinkedFolder(id: lf, name: 'Lib', location: '/lib'), [
      e('Loops/Groove.wav', bpm: 90, kind: SampleKind.loop),
      e('Hits/Kick.wav', kind: SampleKind.oneShot, inst: SampleInstrument.kick),
    ]);
    await pump(tester);
    await tester.enterText(find.byKey(const ValueKey('samples-search')), 'kick');
    await tester.pump();
    expect(find.text('Groove'), findsNothing);
    expect(find.text('Kick'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('samples-filter-clear')));
    await tester.tap(find.byKey(const ValueKey('samples-filter-clear')));
    await tester.pump();
    expect(find.text('Groove'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('samples-filter-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('samples-filter-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Loop'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Kick'), findsNothing);
    expect(find.text('Groove'), findsOneWidget);
  });

  testWidgets('a missing linked file offers Find it', (tester) async {
    s.project.assets.add(AudioAssetDoc(id: 'a', path: '/nowhere/x.wav', name: 'x', link: const LinkedRef('lfX', 'x.wav')));
    await tester.runAsync(s.checkMissingFiles);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MissingFilesBanner(state: s))));
    expect(find.byKey(const ValueKey('missing-find')), findsOneWidget);
    LinkedFolderPicker.pick = () async => null;
    await tester.tap(find.byKey(const ValueKey('missing-find')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find-file')), findsOneWidget);
    expect(find.byKey(const ValueKey('find-folder')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('find-folder')));
    await tester.pumpAndSettle();
    expect(s.missingLinkedAssets(), hasLength(1));
  });

  test('lengths read as seconds or minutes', () {
    expect(sampleLength(0.4213), '0.42 s');
    expect(sampleLength(75), '1:15');
    expect(sampleLength(2, approx: true), '~2.00 s');
    expect(sampleLength(null), '');
    expect(Directory.current.existsSync(), isTrue);
  });
}
