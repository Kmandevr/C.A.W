// No 64-track cap in the app (F7.3 part C): adds, drops below the last track and MIDI file parts go past 64, and the
// engine (needs CAW_LIB) takes a project of 80 tracks.
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = ProjectDoc(id: 'p', name: 'Caps', modules: [
      ModuleDoc(id: 'pat', name: 'Beat', source: '---\nkind: pattern\nlength: 16\n---\n0 C2 1 1\n'),
    ], layers: [
      LayerDoc(id: 'a', name: 'Drums', color: 0, clips: [ClipDoc(id: 'c1', patternId: 'pat', lengthSteps: 16)]),
    ]);
  });
  tearDown(() => s.dispose());

  test('tracks and folders are added past 64', () {
    for (var i = 0; i < 70; i++) {
      s.addLayer();
    }
    s.addFolder();
    s.addEmptyTrack();
    expect(s.project.layers.length, 73);
  });

  test('a clip dropped below the last track gets a new track past 64', () {
    for (var i = 0; i < 64; i++) {
      s.addLayer();
    }
    final from = s.project.layers.first;
    final placed = s.moveClipTo(from, from.clips.single, null, 0);
    expect(s.project.layers.length, 66);
    expect(s.project.layers.last.clips.single, same(placed));
  });

  test('with the engine: a project of 80 tracks loads (needs CAW_LIB)', () async {
    final e = Engine.create();
    addTearDown(e.dispose);
    for (var i = 0; i < 79; i++) {
      s.addLayer();
    }
    final info = await e.setProject(s.project.toEngineJson());
    expect(info, isNotNull);
    expect(s.project.layers.length, 80);
  }, skip: Platform.environment['CAW_LIB']?.isNotEmpty != true);
}
