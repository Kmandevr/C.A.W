// Projects stay apart in the engine: a project the engine refuses never plays the previous project's audio.
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  test('opening a project the engine refuses clears the previous one instead of playing it', () async {
    final s = AppState();
    s.engine = Engine.create();
    s.ready = true;
    s.starting = false;
    s.useAudioDevice = false;
    addTearDown(s.dispose);
    await s.importProject(s.starterProject());
    expect(s.engineError, isNull);
    expect(s.info, isNotEmpty); // the starter's patterns are loaded

    // More native components than the engine runs (256 in a project; a track holds 64): refused as a whole.
    final tooBig = ProjectDoc(id: 'big', name: 'Too big');
    for (var t = 0; t < 5; t++) {
      tooBig.layers.add(LayerDoc(id: 'l$t', name: 'Many $t', color: 0,
          components: [for (var i = 0; i < 60; i++) ComponentUseDoc('org.caw.utility')]));
    }
    await s.importProject(tooBig);
    expect(s.engineError, contains('native components'));
    expect(s.info, isEmpty, reason: "the starter's patterns must not stay loaded under the refused project");
    expect(s.transportOn, isFalse);
    // Pressing play now must not bring back the starter's sound.
    s.engine!.play();
    final out = s.engine!.pullForTest(48000);
    expect(out.every((x) => x == 0), isTrue, reason: "the previous project's audio played under the refused one");
    s.engine!.stop();

    // An edit refused within the same project keeps that project's last good state (unchanged behaviour).
    await s.importProject(s.starterProject());
    expect(s.engineError, isNull);
    final loaded = Map.of(s.info);
    for (final l in s.project.layers.take(5)) {
      l.components.addAll([for (var i = 0; i < 60; i++) ComponentUseDoc('org.caw.utility')]);
    }
    s.resyncEngine();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(s.engineError, isNotNull);
    expect(s.info.keys, loaded.keys);
  }, skip: skip);
}
