// Settings › Performance: the performance profile, Lightweight on overload, the frame rate, the Benchmark, and the
// engine's hardware profile and plan.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../model/settings.dart';
import '../benchmark/benchmark_screen.dart';
import '../frame_rate.dart';
import '../theme.dart';
import 'settings_deps.dart';
import 'settings_widgets.dart';

class PerformanceSettings extends StatelessWidget {
  const PerformanceSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final s = deps.settings;
    final hw = deps.engineProfile, plan = deps.executionPlan;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      settingDropdown<PerformanceMode>('performance.profile', s.performanceMode,
          [for (final m in PerformanceMode.values) (m, m.label)], (v) => s.update((x) => x
            ..performanceMode = v
            ..lightBySelf = false),
          icon: Icons.speed, subtitle: s.performanceMode.description),
      settingSwitch('performance.lightAuto', s.lightAuto, (v) => s.update((x) => x.lightAuto = v),
          icon: Icons.auto_mode, subtitle: 'Keeps the interface responsive while reducing the voice budget'),
      FrameRateRow(settings: s, controller: FrameRateController.current),
      Builder(
          builder: (context) => settingAction('performance.benchmark',
              icon: Icons.insights, iconColor: Neon.violet, onTap: () => showBenchmark(context, host: deps.state))),
      settingAction('performance.hardware',
          icon: Icons.memory, iconColor: Neon.green,
          subtitle: hw == null
              ? 'Unavailable: the native engine did not load'
              : '${hw.logicalCores} logical cores · ${hw.memoryBudgetMiB} MiB work budget · '
                  'SIMD ${hw.supportsSimd ? 'available' : 'unavailable'} · '
                  'GPU compute ${hw.supportsGpuCompute ? 'available' : 'unavailable'}'),
      settingAction('performance.plan',
          icon: Icons.tune,
          subtitle: plan == null
              ? 'Unavailable: the native engine did not load'
              : '${plan.workerThreads} worker(s) · ${plan.maxConcurrentJobs} concurrent job(s) · '
                  '${plan.preferredBatchFrames} preferred batch frames · '
                  '${plan.latencySensitive ? 'latency-sensitive' : 'throughput-oriented'}'),
    ]);
  }
}

/// Frame rate: Auto and the caps the screen has ([FrameRateController.choices]); it follows the screen's rates once
/// [controller] has read them. Without a controller, or where the platform can't ask (Windows), Auto alone. It says
/// the rate in force and why it is below the screen's best ([FrameRateStatus]), and reads the screen again shortly
/// after it shows, so what it says is the phone's state now (battery saver, Motion smoothness).
class FrameRateRow extends StatefulWidget {
  const FrameRateRow({
    super.key,
    required this.settings,
    this.controller,
    this.refreshAfter = const Duration(milliseconds: 700),
  });
  final Settings settings;
  final FrameRateController? controller;

  /// How long after showing it reads the screen again: past the page's own transition, whose frames ask for the
  /// top rate, so the rate read is the one the system settled on.
  final Duration refreshAfter;

  @override
  State<FrameRateRow> createState() => _FrameRateRowState();
}

class _FrameRateRowState extends State<FrameRateRow> {
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    if (c != null && c.device.canRequest) _refresh = Timer(widget.refreshAfter, () => unawaited(c.refresh()));
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, settings = widget.settings;
    Widget row() {
      final choices = c?.choices ?? const [FrameRateController.auto];
      final status =
          c?.status(profile: settings.performanceMode.label, profileBySelf: settings.lightBySelf) ??
          const FrameRateStatus(
            autoLabel: 'Auto',
            subtitle: 'Follows the screen\'s own rate; a cap isn\'t available here',
          );
      return settingDropdown<int>(
        'performance.frameRate',
        settings.frameRate,
        [for (final v in choices) (v, v == FrameRateController.auto ? status.autoLabel : FrameRateController.label(v))],
        (v) => settings.update((x) => x.frameRate = v),
        icon: Icons.slow_motion_video,
        subtitle: status.subtitle,
      );
    }

    return c == null ? row() : ListenableBuilder(listenable: c, builder: (_, _) => row());
  }
}
