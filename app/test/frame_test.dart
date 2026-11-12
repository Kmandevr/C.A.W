// Tests the frame: the section controller, the bottom section bar, the bottom transport's scrub and the glass
// strain rule.
import 'package:caw/engine/execution.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/ui/frame/frame_widgets.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/frame/strain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Build tabs open, switch and close; opening brings Build to the front', () {
    final c = SectionController();
    expect(c.current, Section.arrange);
    const a = BuildTab(BuildTabKind.cpp, 'org.me.drive');
    const b = BuildTab(BuildTabKind.pattern, 'm1');
    c.addBuild(b);
    expect(c.current, Section.arrange, reason: 'adding a tab does not switch sections');
    c.openBuild(a);
    expect(c.current, Section.build);
    expect(c.buildTabs, [b, a]);
    expect(c.activeBuildTab, a);
    c.activateBuild(b);
    expect(c.activeBuildTab, b);
    c.closeBuild(b);
    expect(c.activeBuildTab, a);
    c.pruneBuild((t) => t.id != 'org.me.drive');
    expect(c.buildTabs, isEmpty);
    c.focusLayer('L1');
    expect((c.current, c.focusedLayer), (Section.arrange, 'L1'));
  });

  testWidgets('the section bar switches sections', (tester) async {
    final c = SectionController();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ListenableBuilder(listenable: c, builder: (_, _) => SectionBar(sections: c)))));
    await tester.tap(find.byKey(const ValueKey('section-files')));
    expect(c.current, Section.files);
    await tester.tap(find.byKey(const ValueKey('section-build')));
    expect(c.current, Section.build);
  });

  testWidgets('dragging the bottom transport scrubs by whole bars; stopped, play resumes there', (tester) async {
    final s = AppState();
    s.project = s.demoProject();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(
        alignment: Alignment.bottomCenter, child: SizedBox(width: 390, child: BottomTransport(state: s))))));
    // 48 px a bar: two bars to the right.
    await tester.drag(find.byType(BottomTransport), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(s.pausedStep, 2.0 * s.project.stepsPerBar);
    expect(find.byKey(const ValueKey('transport-record')), findsOneWidget);
  });

  test('glass lightens after an overrun or under heat or battery saver, and recovers', () {
    final now = DateTime(2026, 11, 9, 12);
    expect(GlassStrainWatcher.strainedNow(now: now, pressure: EnginePressure.normal), isFalse);
    expect(GlassStrainWatcher.strainedNow(now: now, pressure: EnginePressure.unknown), isFalse);
    expect(GlassStrainWatcher.strainedNow(now: now, pressure: EnginePressure.thermalHot), isTrue);
    expect(GlassStrainWatcher.strainedNow(now: now, pressure: EnginePressure.batterySaver), isTrue);
    expect(GlassStrainWatcher.strainedNow(
        lastOverrun: now.subtract(const Duration(seconds: 5)), now: now, pressure: EnginePressure.normal), isTrue);
    expect(GlassStrainWatcher.strainedNow(
        lastOverrun: now.subtract(const Duration(seconds: 30)), now: now, pressure: EnginePressure.normal), isFalse);
  });
}
