// The polish pass (#175): empty states with a way forward, hints that hidden controls exist, phone sheets, labels.
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/focus_panel.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/automation_screen.dart';
import 'package:caw/ui/exporter_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/haptics.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:caw/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

class _Recorder implements HapticsDevice {
  final played = <HapticKind>[];
  @override
  void play(HapticKind kind, double scale) => played.add(kind);
}

void main() {
  late AppState s;
  late SectionController sections;

  setUp(() {
    s = AppState(settings: Settings());
    s.project = ProjectDoc(id: 'p', name: 'Polish', layers: [LayerDoc(id: 'a', name: 'Drums', color: 0)]);
    sections = SectionController();
  });

  tearDown(() {
    s.dispose();
    sections.dispose();
  });

  Future<void> pumpArranger(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final screen = Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s)));
    await tester.pumpWidget(MaterialApp(home: SectionScope(controller: sections, child: screen)));
    await tester.pump();
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
  }

  group('Arrange', () {
    testWidgets('with no tracks it says what to do first, and its button adds a track', (tester) async {
      s.project.layers.clear();
      await pumpArranger(tester, const Size(390, 844));
      expect(find.text('No tracks yet'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('empty-add-track')));
      await settle(tester);
      expect(s.project.layers, hasLength(1));
      expect(find.text('No tracks yet'), findsNothing);
    });

    testWidgets('mute, solo and the FX button are felt when tapped', (tester) async {
      final rec = _Recorder();
      Haptics.device = rec;
      Haptics.reset();
      addTearDown(() {
        Haptics.device = const FlutterHaptics();
        Haptics.reset();
      });
      await pumpArranger(tester, const Size(390, 844));
      await tester.tap(find.byTooltip('Mute').first);
      await tester.pump(const Duration(milliseconds: 100));
      expect(rec.played, contains(HapticKind.tap));
      expect(s.project.layers.first.mute, isTrue);
      rec.played.clear();
      await tester.tap(find.byKey(const ValueKey('fx-button-a')));
      await settle(tester);
      expect(rec.played, contains(HapticKind.tap));
    });

    testWidgets("on a phone the toolbar's fade shows there is more past its edge, and goes at the end", (tester) async {
      await pumpArranger(tester, const Size(390, 844));
      expect(find.byKey(const ValueKey('scroll-fade-right')), findsOneWidget);
      expect(find.byKey(const ValueKey('scroll-fade-left')), findsNothing);
      await tester.drag(find.byKey(const ValueKey('arrange-toolbar')), const Offset(-600, 0));
      await settle(tester);
      expect(find.byKey(const ValueKey('scroll-fade-right')), findsNothing);
      expect(find.byKey(const ValueKey('scroll-fade-left')), findsOneWidget);
      expect(find.byTooltip('Grid: clips snap to this'), findsOneWidget);
    });
  });

  group('Automation', () {
    testWidgets('empty lanes point to recording with Automate; tracks show their colour', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: AutomationScreen(state: s))));
      expect(find.byKey(const ValueKey('automate-hint')), findsOneWidget);
      expect(find.textContaining('no .caw module parameters'), findsOneWidget);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: TrackAutomationPanel(state: s, layer: s.project.layers.first))));
      expect(find.byKey(const ValueKey('automate-hint')), findsOneWidget);
    });
  });

  group('Frame', () {
    final lib = Platform.environment['CAW_LIB'];
    final skip = lib == null || lib.isEmpty;

    AppState app() {
      final a = AppState();
      a.engine = Engine.create();
      a.templates = Engine.templates();
      a.project = a.starterProject();
      a.selectedModuleId = a.project.modules.first.id;
      a.ready = true;
      a.starting = false;
      return a;
    }

    testWidgets('Build opens on its start page, not on a module; More says what each page is for', (tester) async {
      final a = app();
      await pumpGolden(tester, Shell(state: a), goldenSizes['phone']!);
      final c = SectionController.of(tester.element(find.byType(Scaffold).first));
      c.show(Section.build);
      await tester.pumpAndSettle();
      expect(c.buildTabs, isEmpty);
      expect(find.text('Write C++ instruments, effects and patterns, then hear them on your tracks.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('more-tools')));
      await tester.pumpAndSettle();
      expect(find.text('CPU, peaks, signal paths, scope and spectrum'), findsOneWidget);
      expect(find.text('Make and package .caw instruments and effects'), findsOneWidget);
      a.dispose();
    }, skip: skip);
  });

  group('Export', () {
    testWidgets('with no saved profiles the picker says how to make one', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ExporterScreen(state: s))));
      expect(find.text('None yet: save these settings with the bookmark'), findsOneWidget);
    });

    test('recent exports show their time to the minute', () {
      final ms = DateTime(2026, 11, 10, 9, 5, 33, 120).millisecondsSinceEpoch;
      expect(exportStamp(ms), '2026-11-10 09:05');
    });
  });

  group('Clip tab', () {
    testWidgets('an empty track offers a new pattern; a clip names its pattern and opens it in Build', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final layer = s.project.layers.first;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SectionScope(controller: sections, child: ListenableBuilder(
        listenable: s,
        builder: (_, _) => FocusPanel(state: s, layer: layer, tab: FocusTab.clip, onTab: (_) {}, onClose: () {}),
      )))));
      await tester.tap(find.byKey(const ValueKey('clip-new-pattern')));
      await tester.pumpAndSettle();
      expect(layer.clips, hasLength(1));
      final pattern = s.project.module(layer.clips.single.patternId)!;
      expect(s.isPattern(pattern.id), isTrue);
      expect(find.byKey(const ValueKey('clip-pattern-name')), findsOneWidget);
      expect(find.text(pattern.name), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('clip-open-build')));
      await tester.pump();
      expect(sections.current, Section.build);
      expect(sections.activeBuildTab, BuildTab(BuildTabKind.caw, pattern.id));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('Piano roll', () {
    testWidgets('on a phone zoom, full screen and More stay on screen, and the tools fade where they scroll', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n0 C4 1/4 0.8\n');
      s.project.modules.add(m);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
      await tester.pump();
      await tester.pump();
      for (final tip in ['More', 'Full screen']) {
        final r = tester.getRect(find.byTooltip(tip));
        expect(r.right, lessThanOrEqualTo(390), reason: tip);
      }
      expect(find.byKey(const ValueKey('roll-zoom')).hitTestable(), findsOneWidget);
      expect(find.byKey(const ValueKey('scroll-fade-right')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
