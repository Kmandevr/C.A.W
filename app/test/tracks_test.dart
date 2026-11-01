// The Tracks area on a phone: a card per track, a tap opens the track's panel, and Edit opens its sound in Sounds (needs CAW_LIB).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  testWidgets('track cards open a panel, and Edit opens the sound', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    s.selectedModuleId = s.project.modules.last.id;
    s.ready = true;
    s.starting = false;
    await tester.runAsync(() async => s.info = await s.engine!.setProject(s.project.toEngineJson()));
    await tester.pumpWidget(MaterialApp(home: Shell(state: s)));
    await tester.pump();

    final kick = s.project.layers.first;
    expect(find.text(kick.name), findsWidgets);
    final tracksScroll = find.descendant(
      of: find.byType(ArrangerScreen),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.text('Add track'), 300, scrollable: tracksScroll.first);
    expect(find.text('Add track'), findsOneWidget);
    await tester.drag(tracksScroll.first, const Offset(0, 3000));
    await tester.pumpAndSettle();

    await tester.tap(find.text(kick.name).first);
    await tester.pumpAndSettle();
    expect(find.text('SOUND'), findsOneWidget);
    expect(find.text('MIX'), findsOneWidget);

    await tester.tap(find.text('Edit').first);
    await tester.pumpAndSettle();
    expect(s.selectedModuleId, kick.generatorId);
    expect(find.text('Controls'), findsOneWidget);
    s.dispose();
  }, skip: skip);
}
