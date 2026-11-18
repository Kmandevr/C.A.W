// Settings › Sound › Recording and metronome (#244): the click (when, sound, volume), count-in, the record mode, punch, pre-roll, a new audio track's monitoring and the take format; and the MIDI note offset row for Latency and Bluetooth.
import 'package:flutter/material.dart';

import '../../model/settings.dart';
import 'settings_deps.dart';
import 'settings_registry.dart';
import 'settings_widgets.dart';

/// The MIDI note offset (Settings.recordOffsetMs), under Latency and Bluetooth's More beside the audio take offset:
/// the one place for recording offsets (#244).
Widget midiNoteOffset(Settings s) => settingSlider('recording.offset', s,
    value: s.recordOffsetMs, min: 0, max: Settings.maxRecordOffsetMs, divisions: 50, icon: Icons.av_timer,
    show: (v) => '${v.round()} ms', set: (x, v) => x.recordOffsetMs = v.roundToDouble(), reset: 0,
    subtitle: 'MIDI notes are written this much earlier than played, for the output\'s delay (Audio devices › '
        'Device now shows the buffer\'s); 0 writes them as heard');

class RecordingCard extends StatelessWidget {
  const RecordingCard({super.key, required this.deps, required this.input});
  final SettingsDeps deps;

  /// The audio input's rows by id (audio_input_settings.dart).
  final Widget Function(Set<String> ids) input;

  @override
  Widget build(BuildContext context) {
    final s = deps.settings;
    String bars(int n) => n == 0 ? 'None' : n == 1 ? '1 bar' : '$n bars';
    return SettingsCardView(card: SettingsCard.recording, rows: [
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
      settingDropdown<int>('recording.countIn', s.countInBars, [for (var n = 0; n <= 4; n++) (n, bars(n))],
          (v) => s.update((x) => x.countInBars = v),
          icon: Icons.looks_4_outlined),
      settingChoice<MidiRecordMode>('recording.mode', s.midiRecordMode,
          const [(MidiRecordMode.takes, 'Takes'), (MidiRecordMode.overdub, 'Overdub'), (MidiRecordMode.replace, 'Replace')],
          (v) => s.update((x) => x.midiRecordMode = v),
          icon: Icons.layers_outlined,
          subtitle: switch (s.midiRecordMode) {
            MidiRecordMode.takes => 'A new clip, each loop pass a take; Record\'s long-press changes it too',
            MidiRecordMode.overdub => 'Notes are added into the clips already there',
            MidiRecordMode.replace => 'The notes there are replaced over the time recorded',
          }),
      input(const {'audio.punch'}),
    ], more: [
      settingChoice<ClickSound>('recording.clickSound', s.clickSound, [for (final c in ClickSound.values) (c, c.label)],
          (v) => s.update((x) => x.clickSound = v),
          icon: Icons.music_note_outlined),
      settingSlider('recording.clickVolume', s,
          value: s.clickVolume, min: 0, max: 1, divisions: 20, icon: Icons.volume_up_outlined,
          show: (v) => v == 0 ? 'Silent' : '${(v * 100).round()}%', set: (x, v) => x.clickVolume = v, reset: 1),
      settingDropdown<int>('recording.preRoll', s.preRollBars, [for (var n = 0; n <= 4; n++) (n, bars(n))],
          (v) => s.update((x) => x.preRollBars = v),
          icon: Icons.fast_rewind_outlined),
      settingChoice<String>('recording.monitor', s.newTrackMonitor, const [('off', 'Off'), ('auto', 'Auto'), ('on', 'On')],
          (v) => s.update((x) => x.newTrackMonitor = v),
          icon: Icons.headphones_outlined,
          subtitle: switch (s.newTrackMonitor) {
            'off' => 'A new audio track doesn\'t play its input; each track\'s own button still can',
            'on' => 'A new audio track always plays its input',
            _ => 'A new audio track plays its input while armed (Auto)',
          }),
      input(const {'audio.recordFormat'}),
    ]);
  }
}
