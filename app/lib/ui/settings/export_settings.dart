// Settings › Export: what the exporter opens with (kind, sample rate, bit depth, free length) and how files are named.
import 'package:flutter/material.dart';

import '../../model/settings.dart';
import 'settings_deps.dart';
import 'settings_registry.dart';
import 'settings_widgets.dart';

class ExportSettings extends StatelessWidget {
  const ExportSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final s = deps.settings;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      settingDropdown<String>('export.kind', s.exportKind,
          [for (final k in const ['loop', 'free', 'oneShot', 'wavetable', 'midi']) (k, exportKindLabel(k))],
          (v) => s.update((x) => x.exportKind = v),
          icon: Icons.ios_share),
      settingChoice<int>('export.rate', s.exportSampleRate, const [(44100, '44.1 kHz'), (48000, '48 kHz')],
          (v) => s.update((x) => x.exportSampleRate = v),
          icon: Icons.waves),
      settingChoice<bool>('export.depth', s.exportFloat32, const [(false, '24-bit PCM'), (true, '32-bit float')],
          (v) => s.update((x) => x.exportFloat32 = v),
          icon: Icons.data_array, subtitle: 'Wavetables are always 32-bit float'),
      settingSlider('export.seconds', s,
          value: s.exportSeconds, min: 1, max: 120, divisions: 119, icon: Icons.timer_outlined,
          show: (v) => '${v.round()} s', set: (x, v) => x.exportSeconds = v.roundToDouble(), reset: 8),
      settingChoice<ExportNaming>('export.naming', s.exportNaming, [for (final n in ExportNaming.values) (n, n.label)],
          (v) => s.update((x) => x.exportNaming = v),
          icon: Icons.drive_file_rename_outline,
          subtitle: switch (s.exportNaming) {
            ExportNaming.detailed => 'e.g. Song_140bpm_8bars.wav',
            ExportNaming.project => 'e.g. Song.wav',
            ExportNaming.dated => 'e.g. Song_2026-11-11_2130.wav',
          }),
    ]);
  }
}
