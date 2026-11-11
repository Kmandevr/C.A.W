// Arrange's edit animations (owner, 2026-11-11): deleted clips shrink out, new clips grow in, rows glide when tracks
// are added, reordered or nested, and with edit animations off nothing animates.
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc project() => ProjectDoc(id: 'p', name: 'Motion test', modules: [
      ModuleDoc(id: 'pat', name: 'Beat', source: '---\nkind: pattern\nlength: 16\n---\n0 C2 1 1\n'),
    ], layers: [
      LayerDoc(id: 'a', name: 'Drums', color: 0, clips: [ClipDoc(id: 'c1', patternId: 'pat', startSteps: 0, lengthSteps: 16)]),
      LayerDoc(id: 'b', name: 'Bass', color: 2),
      LayerDoc(id: 'c', name: 'Lead', color: 3),
    ]);

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
  });
  tearDown(() {
    EditMotion.kinds = {...EditMotionKind.values};
    s.dispose();
  });

  LayerDoc layer(String id) => s.project.layers.firstWhere((l) => l.id == id);

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
        builder: (_, _) => ArrangerScreen(state: s)))));
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
  }

  double rowShift(WidgetTester tester, String id) => tester.widget<Transform>(find.descendant(
      of: find.byKey(ValueKey('row-h-$id')), matching: find.byType(Transform)).first).transform.getTranslation().y;

  testWidgets('a deleted clip shrinks out where it was; a new one grows in', (tester) async {
    await pump(tester);
    s.removeClip(layer('a'), layer('a').clips.single);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(const ValueKey('clip-leaving')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('clip-leaving')), findsNothing, reason: 'gone once it has left');

    s.addEmptyClip(layer('b'), 0, 16);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final fade = tester.widget<FadeTransition>(find.ancestor(of: find.byKey(ValueKey('clip-${layer('b').clips.single.id}')),
        matching: find.byType(FadeTransition)).first);
    expect(fade.opacity.value, lessThan(1));
    await settle(tester);
  });

  testWidgets('rows glide when a track moves above them, and settle in place', (tester) async {
    await pump(tester);
    s.moveTrack(layer('c'), layer('a'), TrackDrop.above);
    await tester.pump();
    await tester.pump(); // the rows measure where they went
    await tester.pump(const Duration(milliseconds: 40));
    expect(rowShift(tester, 'a'), lessThan(0), reason: 'Drums glides down from where it was');
    expect(rowShift(tester, 'c'), greaterThan(0), reason: 'Lead glides up');
    await settle(tester);
    expect(rowShift(tester, 'a'), 0);
  });

  testWidgets('with edit animations off nothing animates', (tester) async {
    EditMotion.kinds = {};
    await pump(tester);
    s.removeClip(layer('a'), layer('a').clips.single);
    s.moveTrack(layer('c'), layer('a'), TrackDrop.above);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byKey(const ValueKey('clip-leaving')), findsNothing);
    expect(rowShift(tester, 'a'), 0);
    await settle(tester);
  });
}
