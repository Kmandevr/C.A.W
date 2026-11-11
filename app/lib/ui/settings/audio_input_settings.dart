// Settings › Audio's input part: audio input on or off (the microphone permission first), the input device and its
// channels, the recording latency (measured with a warned noise ping, or typed in), punch in/out and the take format.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../engine/audio_engine.dart';
import '../../model/audio_record.dart';
import '../haptics.dart';
import '../theme.dart';
import 'settings_widgets.dart';

class AudioInputSettings extends StatefulWidget {
  const AudioInputSettings({super.key, required this.recorder});
  final AudioRecorder recorder;

  @override
  State<AudioInputSettings> createState() => _AudioInputSettingsState();
}

class _AudioInputSettingsState extends State<AudioInputSettings> {
  List<InputDeviceInfo>? _devices;
  bool _pinging = false;
  PingResult? _ping;

  AudioRecorder get r => widget.recorder;

  @override
  void initState() {
    super.initState();
    // The list opens the backend: off the UI isolate.
    r.io.inputDevices().then((d) {
      if (mounted) setState(() => _devices = d);
    }).catchError((Object _) {});
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _toggle(bool on) async {
    Haptics.tap();
    if (on) {
      if (!await r.openInput()) {
        Haptics.error();
        _say(r.message.value ?? 'Audio input did not open.');
      }
    } else {
      await r.closeInput();
    }
    if (mounted) setState(() {});
  }

  /// The ping plays a noise burst at -12 dBFS: the user is told and agrees first (every time until they tick it).
  Future<void> _measure() async {
    if (!r.prefs.pingWarned) {
      var remember = false;
      final ok = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          key: const ValueKey('latency-warning'),
          title: const Text('Measure the latency'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('C.A.W plays a short burst of noise (−12 dBFS) and listens for it. Turn the volume down and '
                'take headphones off. Hold the phone\'s speaker near its microphone in a quiet room, or connect the '
                'interface\'s output to its input with a cable.'),
            CheckboxListTile(contentPadding: EdgeInsets.zero, dense: true, value: remember,
                title: const Text('Don\'t ask again'), onChanged: (v) => set(() => remember = v ?? false)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('latency-go'), onPressed: () {
              if (remember) {
                r.prefs.pingWarned = true;
                unawaited(r.prefs.save());
              }
              Navigator.of(context).pop(true);
            }, child: const Text('Play the ping')),
          ],
        )));
      if (ok != true || !mounted) return;
    }
    setState(() { _pinging = true; _ping = null; });
    final result = await r.ping();
    if (!mounted) return;
    setState(() { _pinging = false; _ping = result; });
    if (result == null) {
      Haptics.error();
      _say(r.message.value ?? 'The ping could not start: turn audio input on first.');
    } else if (result.ok) {
      Haptics.drop();
      _say('Round trip ${result.ms.toStringAsFixed(1)} ms: takes are placed by it');
    } else {
      Haptics.error();
      _say('The ping was not heard clearly: try again, louder, or type the offset in.');
    }
  }

  Future<void> _typeOffset() async {
    final controller = TextEditingController(
        text: r.prefs.latencyOverride < 0 ? '' : r.latency.ms.toStringAsFixed(1));
    final v = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Recording offset'),
      content: TextField(key: const ValueKey('latency-offset-field'), controller: controller, autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(suffixText: 'ms', helperText: 'Empty: the measured latency, else the device\'s')),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Set')),
      ],
    ));
    controller.dispose();
    if (v == null) return;
    final ms = double.tryParse(v.trim().replaceAll(',', '.'));
    r.setLatencyMs(v.trim().isEmpty || ms == null ? null : ms.clamp(0, 2000).toDouble());
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: r, builder: (context, _) {
    final p = r.prefs;
    final list = _devices ?? const <InputDeviceInfo>[];
    String key(InputDeviceInfo d) => d.id.isNotEmpty ? 'id:${d.id}' : 'name:${d.name}';
    final saved = (p.deviceId.isNotEmpty ? list.where((d) => d.id == p.deviceId).firstOrNull : null) ??
        (p.deviceName.isNotEmpty ? list.where((d) => d.name == p.deviceName).firstOrNull : null);
    final current = saved != null ? key(saved) : '';
    final lat = r.latency;
    final source = switch (lat.source) { 'override' => 'typed in', 'measured' => 'measured', _ => 'the device\'s estimate' };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      settingHeading('Input and recording'),
      settingSwitch('audio.input', p.enabled && r.inputOpen, _toggle, icon: Icons.mic_none,
          subtitle: r.inputOpen
              ? 'On: armed audio tracks record and monitor'
              : p.enabled ? 'Chosen, but not open (no permission or no microphone)' : 'Off: arming a track turns it on'),
      settingDropdown<String>('audio.inputDevice', current, [
        ('', 'System default'),
        for (final d in list)
          if (d.name.isNotEmpty) (key(d), '${d.name.length > 25 ? '${d.name.substring(0, 24)}…' : d.name}'
              '${d.channels > 0 ? ' · ${d.channels} ch' : ''}'),
      ], (v) {
        final d = list.where((d) => key(d) == v).firstOrNull;
        r.chooseInput(deviceId: d?.id ?? '', deviceName: d?.name ?? '');
      }, icon: Icons.settings_input_component,
          subtitle: _devices == null ? 'Where audio tracks record from'
              : 'Android routes its default to the built-in or a headset or USB microphone by itself'),
      settingChoice<int>('audio.inputChannels', p.channels.clamp(1, 2) == p.channels ? p.channels : 2,
          [(1, 'Mono'), (2, 'Stereo')], (v) => r.chooseInput(channels: v), icon: Icons.surround_sound_outlined),
      settingAction('audio.latency', icon: Icons.av_timer,
          subtitle: _pinging ? 'Listening…'
              : 'Now ${lat.ms.toStringAsFixed(1)} ms ($source)'
                  '${_ping != null && !_ping!.ok ? ' · the last ping was not heard' : ''}',
          trailing: FilledButton.tonal(key: const ValueKey('latency-measure'), onPressed: _pinging ? null : _measure,
              child: _pinging
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Measure'))),
      settingAction('audio.latencyOffset', icon: Icons.tune,
          subtitle: p.latencyOverride < 0 ? 'Not set: the measured or device latency is used'
              : '${lat.ms.toStringAsFixed(1)} ms, typed in (tap to change or clear)',
          onTap: _typeOffset),
      settingChoice<PunchMode>('audio.punch', p.punch, const [
        (PunchMode.off, 'Off'), (PunchMode.loop, 'Loop range'), (PunchMode.selection, 'Selection'),
      ], (v) {
        p.punch = v;
        unawaited(p.save());
        setState(() {});
      }, icon: Icons.content_cut),
      settingChoice<int>('audio.recordFormat', p.bits, const [(32, '32-bit float'), (24, '24-bit')], (v) {
        p.bits = v;
        unawaited(p.save());
        setState(() {});
      }, icon: Icons.save_alt),
      Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 8), child: Text(
          'Takes are saved in the project\'s folder; a take cut short by a crash is offered back when the project opens.',
          style: const TextStyle(color: Neon.dim, fontSize: 11))),
    ]);
  });
}

/// The same rows, unavailable: shown where no recorder runs (no sound engine), so search still finds them.
class AudioInputSettingsOff extends StatelessWidget {
  const AudioInputSettingsOff({super.key});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        settingHeading('Input and recording'),
        for (final (id, icon) in const [
          ('audio.input', Icons.mic_none), ('audio.inputDevice', Icons.settings_input_component),
          ('audio.inputChannels', Icons.surround_sound_outlined), ('audio.latency', Icons.av_timer),
          ('audio.latencyOffset', Icons.tune), ('audio.punch', Icons.content_cut), ('audio.recordFormat', Icons.save_alt),
        ])
          settingAction(id, icon: icon, iconColor: Neon.dim, subtitle: 'Needs the sound engine, which is not running here'),
      ]);
}
