// The Tracks area on a phone: a card per track, a tap opens the track's panel, and Edit opens its sound in Sounds (needs CAW_LIB).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
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
    // The detailed timeline remains the default; select the compact track-card view for this test.
    await tester.ensureVisible(find.byTooltip('Track cards')); // the phone toolbar scrolls sideways
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Track cards'));
    await tester.pumpAndSettle();

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

  testWidgets('the arranger shows a song millions of bars long without building every bar (F7.2)', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    final pattern = s.project.modules.firstWhere((m) => s.isPattern(m.id));
    s.project.layers.first.clips.add(ClipDoc(id: 'far', patternId: pattern.id,
        startSteps: s.project.maxArrangementSteps - 16, lengthSteps: 16));  // the last bar the step count holds
    s.ready = true;
    s.starting = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ArrangerScreen(state: s))));
    await tester.pump();
    final timeline = find.descendant(of: find.byType(ArrangerScreen), matching: find.byType(Scrollable))
        .evaluate().map((e) => (e.widget as Scrollable)).where((w) => w.axisDirection == AxisDirection.right && w.controller != null); // the timeline, not the toolbar row
    expect(timeline, isNotEmpty);
    final controller = timeline.first.controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(tester.takeException(), isNull);
    s.dispose();
  }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('project settings show a meter the file brought, such as 12/4', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject()..beatsPerBar = 12;
    s.ready = true;
    s.starting = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ArrangerScreen(state: s))));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('12/4'), findsOneWidget);
    s.dispose();
  }, skip: skip);
}
