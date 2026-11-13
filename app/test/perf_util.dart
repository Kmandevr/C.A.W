// Counting helpers for the widget benchmarks: frames asked for, widgets rebuilt, render objects painted, and the
// time a frame's build, layout and paint take and a frame's layer tree takes to raster.
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' as w;
import 'package:flutter_test/flutter_test.dart';

class FrameCount {
  int frames = 0, builds = 0, painted = 0;

  /// Wall time of the pumped frames' build, layout, paint and compositing (the UI thread's share of a frame), in
  /// microseconds: the sum over every frame pumped, and the slowest one.
  int pumpUs = 0, worstUs = 0, pumped = 0;

  /// The mean UI-thread time a pumped frame took, in milliseconds.
  double get frameMs => pumped == 0 ? 0 : pumpUs / pumped / 1000;
  double get worstMs => worstUs / 1000;

  @override
  String toString() => '$frames frames, $builds builds, $painted repainted, '
      '${frameMs.toStringAsFixed(2)} ms a frame (worst ${worstMs.toStringAsFixed(2)})';
}

/// The time the screen as it is now takes to raster from its layer tree, in milliseconds (the median of [runs]):
/// the GPU thread's share of a frame, drawn from scratch (no raster cache), in the test's software renderer.
Future<double> rasterMs(WidgetTester tester, {int runs = 5}) async {
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final times = <int>[];
  await tester.runAsync(() async {
    for (var i = 0; i < runs; i++) {
      final watch = Stopwatch()..start();
      final image = await layer.toImage(Offset.zero & view.size, pixelRatio: view.flutterView.devicePixelRatio);
      watch.stop();
      image.dispose();
      times.add(watch.elapsedMicroseconds);
    }
  });
  times.sort();
  return times[runs ~/ 2] / 1000;
}

/// Runs [count] frames of [step] each; [onFrame] runs before each (it may move a finger or set data). A frame counts
/// when something asked for it (built, painted, or the frame before wanted the next, as a running Ticker does);
/// repaints are the render objects painted (Flutter's paint profiling).
Future<FrameCount> countFrames(WidgetTester tester, int count,
    {Duration step = const Duration(microseconds: 8333), Future<void> Function(int frame)? onFrame}) async {
  final b = FrameCount();
  w.debugOnRebuildDirtyWidget = (_, _) => b.builds++;
  debugProfilePaintsEnabled = true;
  FlutterTimeline.debugCollectionEnabled = true;
  FlutterTimeline.debugReset();
  var wanted = false;
  try {
    for (var i = 0; i < count; i++) {
      await onFrame?.call(i);
      final built = b.builds;
      final watch = Stopwatch()..start();
      await tester.pump(step);
      watch.stop();
      b.pumpUs += watch.elapsedMicroseconds;
      b.pumped++;
      if (watch.elapsedMicroseconds > b.worstUs) b.worstUs = watch.elapsedMicroseconds;
      var painted = 0;
      for (final t in FlutterTimeline.debugCollect().timedBlocks) {
        if (t.name.startsWith('Render')) painted++;
      }
      FlutterTimeline.debugReset();
      if (wanted || painted > 0 || b.builds > built) b.frames++;
      wanted = SchedulerBinding.instance.hasScheduledFrame;
      b.painted += painted;
    }
  } finally {
    FlutterTimeline.debugCollectionEnabled = false;
    debugProfilePaintsEnabled = false;
    w.debugOnRebuildDirtyWidget = null;
  }
  return b;
}
