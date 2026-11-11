// Settings › MIDI and input: the keyboard and channel read, the velocity curve, MIDI thru and the on-screen keys.
import 'package:flutter/material.dart';

import '../../model/live_midi.dart';
import '../../model/settings.dart';
import '../frame/live_keys.dart' show noteName;
import 'settings_deps.dart';
import 'settings_widgets.dart';

class MidiSettings extends StatelessWidget {
  const MidiSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final s = deps.settings;
    final midi = LiveMidi.current;
    final connected = midi?.devices ?? const <String>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      settingDropdown<String>(
        'midi.device',
        s.midiDevice,
        [
          ('', 'Every keyboard'),
          for (final n in connected) (n, n.length > 26 ? '${n.substring(0, 25)}…' : n),
          if (s.midiDevice.isNotEmpty && !connected.contains(s.midiDevice)) (s.midiDevice, '${s.midiDevice} (not connected)'),
        ],
        (v) => s.update((x) => x.midiDevice = v),
        icon: Icons.usb,
        subtitle: midi?.input == null
            ? 'This platform reads no MIDI keyboards yet; the on-screen keys play'
            : connected.isEmpty
                ? 'None connected: plug in a USB keyboard or pair a Bluetooth one in Android'
                : '${connected.length} connected',
      ),
      settingDropdown<int>(
        'midi.channel',
        s.midiChannel,
        [(0, 'All'), for (var c = 1; c <= 16; c++) (c, '$c')],
        (v) => s.update((x) => x.midiChannel = v),
        icon: Icons.alt_route,
      ),
      settingChoice<VelocityCurve>(
        'midi.velocity',
        s.velocityCurve,
        [for (final c in VelocityCurve.values) (c, c.label)],
        (v) => s.update((x) => x.velocityCurve = v),
        icon: Icons.show_chart,
        subtitle: switch (s.velocityCurve) {
          VelocityCurve.linear => 'As played',
          VelocityCurve.soft => 'Light playing comes out louder',
          VelocityCurve.hard => 'It takes a harder touch to get loud',
          VelocityCurve.fixed => 'Every note at ${(s.midiFixedVelocity * 100).round()}%',
        },
      ),
      settingSlider('midi.fixedVelocity', s,
          value: s.midiFixedVelocity, min: 0.05, max: 1, divisions: 19, enabled: s.velocityCurve == VelocityCurve.fixed,
          show: (v) => '${(v * 100).round()}%', set: (x, v) => x.midiFixedVelocity = v, reset: 0.8,
          subtitle: s.velocityCurve == VelocityCurve.fixed ? null : 'Used with the Fixed curve'),
      settingSwitch('midi.thru', s.midiThru, (v) => s.update((x) => x.midiThru = v),
          icon: Icons.call_split,
          subtitle: s.midiThru
              ? 'A keyboard plays the armed track, else the selected one'
              : 'A keyboard sounds only on a track being recorded'),
      settingSwitch('midi.keysVelocity', s.keysVelocity == 0, (v) => s.update((x) => x.keysVelocity = v ? 0 : 0.8),
          icon: Icons.touch_app_outlined,
          subtitle: s.keysVelocity == 0
              ? 'By touch: softer near the top of a key, louder at the bottom'
              : 'Off: every key and pad at ${(s.keysVelocity * 100).round()}%'),
      settingSlider('midi.keysFixedVelocity', s,
          value: s.keysVelocity == 0 ? 0.8 : s.keysVelocity, min: 0.05, max: 1, divisions: 19, enabled: s.keysVelocity > 0,
          show: (v) => '${(v * 100).round()}%', set: (x, v) => x.keysVelocity = v,
          subtitle: s.keysVelocity > 0 ? null : 'Used when velocity by touch is off'),
      settingDropdown<int>(
        'midi.keysOctave',
        s.keysOctave,
        [for (var o = 1; o <= 6; o++) (o, noteName(12 * (o + 1)))],
        (v) => s.update((x) => x.keysOctave = v),
        icon: Icons.piano,
      ),
    ]);
  }
}
