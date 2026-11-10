// Lightens the glass while the audio is under strain: recent overruns, or the device hot or saving power (owner,
// 2026-11-09). It sets Glass.strained and redraws the app when that changes, and clears it once things calm down.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../engine/execution.dart';
import '../../model/app_state.dart';
import '../glass.dart';

class GlassStrainWatcher extends StatefulWidget {
  const GlassStrainWatcher({super.key, required this.state, required this.child});
  final AppState state;
  final Widget child;

  /// How long after the last overrun the blur stays off.
  static const calm = Duration(seconds: 20);

  /// Whether glass should be lightened now, given the last overrun and the device's pressure signal.
  static bool strainedNow({DateTime? lastOverrun, required DateTime now, required EnginePressure pressure}) =>
      (lastOverrun != null && now.difference(lastOverrun) < calm) ||
      pressure == EnginePressure.batterySaver ||
      pressure == EnginePressure.thermalHot ||
      pressure == EnginePressure.thermalCritical;

  @override
  State<GlassStrainWatcher> createState() => _GlassStrainWatcherState();
}

class _GlassStrainWatcherState extends State<GlassStrainWatcher> {
  int _overruns = 0;
  DateTime? _lastOverrun;
  DateTime _lastCheck = DateTime.fromMillisecondsSinceEpoch(0);

  // The meters stop ticking when the app is idle, so the strain is also checked every few seconds: the blur comes
  // back after a calm spell, and heat or battery saver are noticed while stopped.
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _overruns = widget.state.meters.overloaded;
    widget.state.tick.addListener(_check);
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _check());
  }

  @override
  void didUpdateWidget(GlassStrainWatcher old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      old.state.tick.removeListener(_check);
      widget.state.tick.addListener(_check);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.state.tick.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final now = DateTime.now();
    final overruns = widget.state.meters.overloaded;
    if (overruns > _overruns) _lastOverrun = now;
    _overruns = overruns;
    // The meters tick often; once a second is plenty for this.
    if (now.difference(_lastCheck) < const Duration(seconds: 1)) return;
    _lastCheck = now;
    final strained = GlassStrainWatcher.strainedNow(
        lastOverrun: _lastOverrun, now: now, pressure: EngineExecutionPolicy.runtimePressure);
    if (strained == Glass.strained) return;
    Glass.strained = strained;
    // The glass reads Glass.blur when it builds: rebuild everything once so the change shows.
    void rebuild(Element e) {
      e.markNeedsBuild();
      e.visitChildren(rebuild);
    }

    if (mounted) (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
