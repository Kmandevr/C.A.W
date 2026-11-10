// Counting helpers for the widget benchmarks: frames asked for, widgets rebuilt and render objects painted.
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' as w;
import 'package:flutter_test/flutter_test.dart';

class FrameCount {
  int frames = 0, builds = 0, painted = 0;
  @override
  String toString() => '$frames frames, $builds builds, $painted repainted';
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
      await tester.pump(step);
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
