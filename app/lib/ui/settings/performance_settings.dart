// Settings › Performance: the performance profile, Lightweight on overload, and the engine's hardware profile and plan.
import 'package:flutter/material.dart';

import '../../model/settings.dart';
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
          [for (final m in PerformanceMode.values) (m, m.label)], (v) => s.update((x) => x.performanceMode = v),
          icon: Icons.speed, subtitle: s.performanceMode.description),
      settingSwitch('performance.lightAuto', s.lightAuto, (v) => s.update((x) => x.lightAuto = v),
          icon: Icons.auto_mode, subtitle: 'Keeps the interface responsive while reducing the voice budget'),
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
