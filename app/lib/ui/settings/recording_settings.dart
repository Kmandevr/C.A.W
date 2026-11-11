// Settings › Metronome and recording: the click (when, sound, volume), count-in, pre-roll, offset, automation mode.
import 'package:flutter/material.dart';

import '../../model/settings.dart';
import 'settings_deps.dart';
import 'settings_widgets.dart';

class RecordingSettings extends StatelessWidget {
  const RecordingSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final s = deps.settings;
    String bars(int n) => n == 0 ? 'None' : n == 1 ? '1 bar' : '$n bars';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      settingChoice<Metronome>(
        'recording.metronome',
        s.metronome,
        const [(Metronome.off, 'Off'), (Metronome.recording, 'Recording'), (Metronome.always, 'Always')],
        (v) => s.update((x) => x.metronome = v),
        icon: Icons.timer_outlined,
        subtitle: switch (s.metronome) {
          Metronome.off => 'No click (the count-in still clicks)',
          Metronome.recording => 'Clicks while recording and its count-in',
          Metronome.always => 'Clicks whenever the song plays',
        },
      ),
      settingChoice<ClickSound>('recording.clickSound', s.clickSound, [for (final c in ClickSound.values) (c, c.label)],
          (v) => s.update((x) => x.clickSound = v),
          icon: Icons.music_note_outlined),
      settingSlider('recording.clickVolume', s,
          value: s.clickVolume, min: 0, max: 1, divisions: 20, icon: Icons.volume_up_outlined,
          show: (v) => v == 0 ? 'Silent' : '${(v * 100).round()}%', set: (x, v) => x.clickVolume = v, reset: 1),
      settingDropdown<int>('recording.countIn', s.countInBars, [for (var n = 0; n <= 4; n++) (n, bars(n))],
          (v) => s.update((x) => x.countInBars = v),
          icon: Icons.looks_4_outlined),
      settingDropdown<int>('recording.preRoll', s.preRollBars, [for (var n = 0; n <= 4; n++) (n, bars(n))],
          (v) => s.update((x) => x.preRollBars = v),
          icon: Icons.fast_rewind_outlined),
      settingSlider('recording.offset', s,
          value: s.recordOffsetMs, min: 0, max: Settings.maxRecordOffsetMs, divisions: 50, icon: Icons.av_timer,
          show: (v) => '${v.round()} ms', set: (x, v) => x.recordOffsetMs = v.roundToDouble(), reset: 0,
          subtitle: 'Notes are written this much earlier than played, for the output\'s delay (Audio › Device now '
              'shows the buffer\'s); 0 writes them as heard'),
      settingChoice<String>(
        'recording.automation',
        s.automationMode,
        const [('touch', 'Touch'), ('latch', 'Latch'), ('write', 'Write'), ('read', 'Read')],
        (v) => s.update((x) => x.automationMode = v),
        icon: Icons.timeline,
      ),
    ]);
  }
}
