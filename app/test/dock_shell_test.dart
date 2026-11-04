// Tests the docking shell: the controller's saved layouts, reveal, focus and screen shapes, and the shell at phone,
// landscape and desktop sizes with every panel shown in turn (no overflow), plus goldens (the shell needs CAW_LIB).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/dock/dock_controller.dart';
import 'package:caw/ui/dock/layout.dart';
import 'package:caw/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

void main() {
  group('controller', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('caw_dock'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('each screen shape starts from its preset and keeps its own layout', () {
      final c = DockController(Settings());
      for (final f in FormFactor.values) {
        c.form = f;
        expect(c.layout.toJson(), DockLayout.preset(f).toJson());
      }
      c.form = FormFactor.desktop;
      c.reveal(Panels.mixer);
      c.form = FormFactor.phonePortrait;
      expect(c.layout.visible, isNot(contains(Panels.mixer)));
      c.form = FormFactor.desktop;
      expect(c.layout.visible, contains(Panels.mixer));
      c.dispose();
    });

    test('layouts are saved after a pause and read back; a damaged one falls back to the preset', () async {
      final s = await Settings.open(base: dir);
      final c = DockController(s)..form = FormFactor.phonePortrait;
      c.set(c.layout.dock(Panels.files, target: Panels.arrangement, edge: DockEdge.right));
      await c.flush();
      final back = await Settings.open(base: dir);
      final c2 = DockController(back)..form = FormFactor.phonePortrait;
      expect(c2.layout.toJson(), c.layout.toJson());
      back.dockLayouts['desktop'] = {'split': 'diagonal'};
      final c3 = DockController(back)..form = FormFactor.desktop;
      expect(c3.layout.toJson(), DockLayout.preset(FormFactor.desktop).toJson());
      final damaged = Settings()..fromJson({'dock_layouts': 'nope'});
      expect(damaged.dockLayouts, isEmpty);
      for (final c in [c, c2, c3]) {
        c.dispose();
      }
    });

    test('a new controller on the same settings sees a change not yet written to disk (the theme remount)', () {
      final s = Settings();
      final old = DockController(s)..form = FormFactor.desktop;
      old.reveal(Panels.mixer);
      final fresh = DockController(s)..form = FormFactor.desktop;
      expect(fresh.layout.toJson(), old.layout.toJson());
      old.dispose();
      fresh.dispose();
    });

    test('the key panel is the one touched last while it is on screen, else the first on screen', () {
      final c = DockController(Settings())..form = FormFactor.desktop;
      expect(c.keyPanel, Panels.arrangement);
      c.touch(Panels.builder);
      expect(c.keyPanel, Panels.builder);
      c.set(c.layout.activate(Panels.mixer));
      expect(c.keyPanel, Panels.arrangement, reason: 'the builder tab is hidden now');
      c.reveal(Panels.files);
      expect(c.keyPanel, Panels.files);
      c.dispose();
    });

    test('the shell picks the screen shape from its size', () {
      expect(formFactorFor(const Size(390, 780)), FormFactor.phonePortrait);
      expect(formFactorFor(const Size(844, 330)), FormFactor.phoneLandscape);
      expect(formFactorFor(const Size(1280, 800)), FormFactor.desktop);
    });
  });

  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  Future<AppState> startState(WidgetTester tester) async {
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    s.selectedModuleId = s.project.modules.first.id;
    s.ready = true;
    s.starting = false;
    await tester.runAsync(() async => s.info = await s.engine!.setProject(s.project.toEngineJson()));
    return s;
  }

  for (final size in goldenSizes.entries) {
    testWidgets('the shell at ${size.key} size shows every panel without overflow', (tester) async {
      final s = await startState(tester);
      await pumpGolden(tester, Shell(state: s), size.value);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(Shell), matchesGoldenFile('goldens/shell_${size.key}.png'));
      final dock = DockController.of(tester.element(find.byType(Scaffold).first));
      for (final id in Panels.all) {
        dock.reveal(id);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$id at ${size.key}');
        expect(dock.layout.visible, contains(id));
      }
      s.dispose();
    }, skip: skip);
  }
}
