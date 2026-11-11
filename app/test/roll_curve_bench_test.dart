// Frame benchmark for dragging a pitch point with the Curve tool: how many times the editor rebuilds and the roll and
// its live curve repaint over a 60-event drag. Needs CAW_LIB (the editor runs the pattern).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as w;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  testWidgets('a 60-event pitch-point drag', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = AppState();
    s.engine = Engine.create();
    s.project = s.starterProject();
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n0 C3 8 1 bend 0:0 0.5:2 1:0\n4 E3 4\n');
    s.project.modules.add(m);
    s.ready = true;
    s.starting = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
    await tester.tap(find.byTooltip('Curve tool'));
    await tester.pump();
    var editorBuilds = 0, elementBuilds = 0;
    w.debugOnRebuildDirtyWidget = (e, _) {
      elementBuilds++;
      if (e.widget is PatternEditor) { editorBuilds++; }
    };
    RollPaintStats.reset();
    // E3's row middle is at y = 140, C3's 4 rows lower at 204. C3's point at half the note (step 4, +2 st):
    // x = 44 + 4 * 28, y = 204 - 2 * 16.
    final g = await tester.startGesture(const Offset(44 + 4 * 28.0, 204 - 32));
    await tester.pump();
    for (var i = 0; i < 60; i++) {
      await g.moveBy(const Offset(0.5, -0.8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
    w.debugOnRebuildDirtyWidget = null;
    // ignore: avoid_print
    print('BENCH editor builds $editorBuilds, element rebuilds $elementBuilds, '
        'roll paints ${RollPaintStats.roll}, live paints ${RollPaintStats.live}');
    await tester.pump(const Duration(milliseconds: 300));
    s.dispose();
  }, skip: skip);
}
