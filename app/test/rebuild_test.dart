// Measures how many widgets rebuild per keystroke and per slider step in the real app shell (needs CAW_LIB).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as widgets;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  testWidgets('typing and dragging sliders rebuild only what shows them', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    s.selectedModuleId = s.project.modules.first.id;
    s.ready = true;
    s.starting = false;
    await tester.runAsync(() async => s.info = await s.engine!.setProject(s.project.toEngineJson()));
    await tester.pumpWidget(MaterialApp(home: Shell(state: s)));
    await tester.pump();
    var rebuilt = 0;
    widgets.debugOnRebuildDirtyWidget = (e, builtOnce) => rebuilt++;
    final kick = s.project.modules.first;
    // The first keystroke marks the module as edited, which the whole app shows; it isn't counted.
    s.editSource(kick.id, '${kick.source}\n//');
    await tester.pump();
    rebuilt = 0;
    for (var i = 0; i < 10; i++) {
      s.editSource(kick.id, '${kick.source}\n// $i');
      await tester.pump();
    }
    final perKey = rebuilt / 10;
    rebuilt = 0;
    final param = s.info[kick.id]!.params.first;
    for (var i = 0; i < 10; i++) {
      s.setParam(kick.id, param.name, param.min + (param.max - param.min) * i / 10);
      await tester.pump();
    }
    final perStep = rebuilt / 10;
    rebuilt = 0;
    for (var i = 0; i < 10; i++) {
      s.mixLayer(s.project.layers.first, volume: i / 10);
      await tester.pump();
    }
    final perVolume = rebuilt / 10;
    widgets.debugOnRebuildDirtyWidget = null;
    // ignore: avoid_print
    print('widgets rebuilt: per keystroke $perKey, per param step $perStep, per volume step $perVolume');
    // Before scoping these updates, each one rebuilt the whole app: about 3,500 widgets.
    expect(perKey, lessThan(50));
    expect(perStep, lessThan(300));
    expect(perVolume, lessThan(300));
    s.dispose();  // cancels the save timer and frees the engine
  }, skip: skip != null);
}
