// Settings › Performance: the performance profile, Lightweight on overload, the frame rate, and the engine's hardware
// profile and plan.
import 'package:flutter/material.dart';

import '../../model/settings.dart';
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
          [for (final m in PerformanceMode.values) (m, m.label)], (v) => s.update((x) => x.performanceMode = v),
          icon: Icons.speed, subtitle: s.performanceMode.description),
      settingSwitch('performance.lightAuto', s.lightAuto, (v) => s.update((x) => x.lightAuto = v),
          icon: Icons.auto_mode, subtitle: 'Keeps the interface responsive while reducing the voice budget'),
      FrameRateRow(settings: s, controller: FrameRateController.current),
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
/// [controller] has read them. Without a controller, or where the platform can't ask (Windows), Auto alone.
class FrameRateRow extends StatelessWidget {
  const FrameRateRow({super.key, required this.settings, this.controller});
  final Settings settings;
  final FrameRateController? controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    Widget row() {
      final choices = c?.choices ?? const [FrameRateController.auto];
      final rates = c?.rates ?? const <double>[];
      final screen = rates.isEmpty ? '' : ' (this screen: ${{for (final r in rates) r.round()}.join(', ')} Hz)';
      final subtitle = c == null || !c.device.canRequest
          ? 'Follows the screen\'s own rate$screen; a cap isn\'t available here'
          : settings.frameRate == FrameRateController.auto
              ? 'The highest rate while anything moves, the lowest when still$screen'
              : 'At most ${settings.frameRate} Hz everywhere, playback included$screen';
      // The profile's cap, when it is lower than the setting's (owner, 2026-11-12).
      final capped = c != null && c.device.canRequest && settings.profileFrameCap > 0 &&
          (settings.frameRate == FrameRateController.auto || settings.profileFrameCap < settings.frameRate);
      final profile = settings.performanceMode == PerformanceMode.minimal ? 'Minimal' : 'Lightweight';
      final note = capped ? '. $profile caps it at ${settings.profileFrameCap} Hz' : '';
      return settingDropdown<int>('performance.frameRate', settings.frameRate,
          [for (final v in choices) (v, FrameRateController.label(v))], (v) => settings.update((x) => x.frameRate = v),
          icon: Icons.slow_motion_video, subtitle: '$subtitle$note');
    }

    return c == null ? row() : ListenableBuilder(listenable: c, builder: (_, _) => row());
  }
}
