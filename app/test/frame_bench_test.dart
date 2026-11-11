// Frame benchmark: how many widgets rebuild and render objects paint in the app frame (the shell with Arrange in
// front, as the app runs it under CawApp) for 60 playback meter ticks, 20 app-state changes and a 20-step settings
// slider drag, at phone portrait and landscape. Prints BENCH lines; needs CAW_LIB (the shell runs the engine).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/main.dart';
import 'package:caw/model/app_state.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart' as w;
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  for (final size in const {'phone': Size(390, 844), 'landscape': Size(844, 390)}.entries) {
    testWidgets('frame at ${size.key} size: meter ticks, app-state changes, a settings drag', (tester) async {
      await loadAppFonts(tester);
      tester.view.physicalSize = size.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = AppState();
      s.engine = Engine.create();
      s.project = s.starterProject();
      s.selectedModuleId = s.project.modules.first.id;
      s.ready = true;
      s.starting = false;
      await tester.runAsync(() async => s.info = await s.engine!.setProject(s.project.toEngineJson()));
      await tester.pumpWidget(CawApp(state: s));
      await tester.pumpAndSettle();

      var builds = 0, paints = 0;
      // BENCH_DETAIL=1 also prints what rebuilt and painted most in each part.
      final detail = Platform.environment['BENCH_DETAIL'] == '1';
      final built = <String, int>{}, painted = <String, int>{};
      w.debugOnRebuildDirtyWidget = (e, _) {
        builds++;
        if (detail) {
          built.update('${e.widget.runtimeType}', (n) => n + 1, ifAbsent: () => 1);
          // Which screen it belongs to.
          String? screen;
          e.visitAncestorElements((a) {
            final t = '${a.widget.runtimeType}';
            if (t.endsWith('Screen') || t == 'BuildSection' || t == 'BottomTransport' || t == 'SectionBar') {
              screen = t;
              return false;
            }
            return true;
          });
          built.update('in ${screen ?? 'frame'}', (n) => n + 1, ifAbsent: () => 1);
        }
      };
      debugOnProfilePaint = (r) {
        paints++;
        if (detail) {
          // The nearest repaint boundary's owner says which part of the screen repainted.
          RenderObject? b = r;
          while (b != null && !b.isRepaintBoundary) {
            b = b.parent;
          }
          final owner = b?.debugCreator?.toString().split(' ← ').take(3).join(' ← ') ?? '?';
          painted.update(owner, (n) => n + 1, ifAbsent: () => 1);
        }
      };
      Future<(int, int)> measure(Future<void> Function() run) async {
        builds = paints = 0;
        built.clear();
        painted.clear();
        await run();
        if (detail) {
          String top(Map<String, int> m) =>
              (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(12).map((e) => '  ${e.value} ${e.key}').join('\n');
          // ignore: avoid_print
          print('built:\n${top(built)}\npainted under:\n${top(painted)}');
        }
        return (builds, paints);
      }

      // Playing: the poller bumps the meter tick about 30 times a second.
      s.meters = const EngineMeters(playing: true, loopLength: 1000, cpu: 0.2, peakL: 0.5, peakR: 0.5);
      s.notifyListeners();
      await tester.pump();
      if (Platform.environment['BENCH_TRACE'] == '1') {
        debugPrintMarkNeedsPaintStacks = true;
        debugPrintMarkNeedsLayoutStacks = true;
        s.tick.value++;
        await tester.pump(const Duration(milliseconds: 33));
        debugPrintMarkNeedsPaintStacks = false;
        debugPrintMarkNeedsLayoutStacks = false;
      }
      final ticks = await measure(() async {
        for (var i = 0; i < 60; i++) {
          s.meters = EngineMeters(playing: true, loopLength: 1000, position: i * 16, cpu: 0.2 + i % 5 / 100,
              peakL: 0.5, peakR: 0.4);
          s.tick.value++;
          await tester.pump(const Duration(milliseconds: 33));
        }
      });

      // App-state changes that don't touch the frame's own controls (selecting tracks, as a tap on a header does).
      final layers = s.project.layers;
      final changes = await measure(() async {
        for (var i = 0; i < 20; i++) {
          s.selectLayer(layers[i % layers.length]);
          await tester.pump(const Duration(milliseconds: 16));
        }
      });

      // A settings slider dragged (Music-reactive glow): shown live with adjust, saved at the end.
      final roots = <String>[];
      if (detail) {
        final before = w.debugOnRebuildDirtyWidget;
        w.debugOnRebuildDirtyWidget = (e, b) {
          before?.call(e, b);
          if (roots.length < 400) roots.add('${e.widget.runtimeType}${e.dirty ? '' : ''} <- ${e.debugGetCreatorChain(4)}');
        };
      }
      final drag = await measure(() async {
        for (var i = 0; i < 20; i++) {
          s.settings.adjust((x) => x.reactiveGlow = i / 20);
          await tester.pump(const Duration(milliseconds: 16));
        }
      });

      if (detail) {
        // ignore: avoid_print
        print('first rebuilt in the drag:\n${roots.take(8).join('\n')}');
      }
      w.debugOnRebuildDirtyWidget = null;
      debugOnProfilePaint = null;
      // ignore: avoid_print
      print('BENCH ${size.key}: 60 meter ticks ${ticks.$1} builds / ${ticks.$2} paints; '
          '20 state changes ${changes.$1} / ${changes.$2}; 20-step settings drag ${drag.$1} / ${drag.$2}');
      s.meters = const EngineMeters();
      await tester.pumpWidget(const w.SizedBox());
      await tester.pump(const Duration(seconds: 2));
      s.dispose();
    }, skip: skip);
  }
}
