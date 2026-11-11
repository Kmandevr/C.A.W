// Settings › Audio: the output device, sample rate, buffer size and mode, exclusive mode, sound quality, a test tone.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../engine/engine.dart';
import '../../model/settings.dart';
import '../theme.dart';
import 'settings_deps.dart';
import 'settings_registry.dart';
import 'settings_widgets.dart';

class AudioSettings extends StatefulWidget {
  const AudioSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  State<AudioSettings> createState() => _AudioSettingsState();
}

class _AudioSettingsState extends State<AudioSettings> {
  AudioDeviceList? _devices;
  AudioStatus? _status;
  Timer? _poll;

  Settings get s => widget.deps.settings;

  @override
  void initState() {
    super.initState();
    final state = widget.deps.state;
    if (state?.engine == null) return;
    // The list opens the backend, off the UI isolate; the status is re-read while the page shows (a reopen, a route
    // change by the system).
    Engine.audioDevices().then((d) {
      if (mounted) setState(() => _devices = d);
    }).catchError((Object _) {});
    _status = state!.audioStatus;
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _status = widget.deps.state?.audioStatus);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// The rate the engine runs at now (fixed at its start), else the chosen one.
  int get _runningRate => widget.deps.state?.engine?.sampleRate ?? s.sampleRate;

  String _ms(int frames, int rate) => (frames * 1000 / rate).toStringAsFixed(frames * 1000 / rate < 10 ? 1 : 0);

  @override
  Widget build(BuildContext context) {
    final st = _status;
    final devices = _devices;
    final names = [for (final d in devices?.devices ?? const <AudioDeviceInfo>[]) d.name];
    final chosen = devices?.devices.where((d) => d.name == s.audioDevice).firstOrNull ??
        devices?.devices.where((d) => d.isDefault).firstOrNull;
    final nativeRates = [...?chosen?.rates.where((r) => r > 0)];
    final exclusiveOffered = devices?.exclusive ?? true;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      settingAction('audio.status',
          icon: Icons.graphic_eq,
          iconColor: st?.running == true ? Neon.green : Neon.dim,
          subtitle: widget.deps.state?.engine == null
              ? 'The sound engine is not running here'
              : st == null || !st.running
                  ? 'Closed: it opens when something plays${widget.deps.state?.audioError == null ? '' : ' (${widget.deps.state!.audioError})'}'
                  : '${st.backend} · ${st.device} · ${(st.sampleRate / 1000).toStringAsFixed(1)} kHz · '
                      '${st.periodFrames} frames × ${st.periods} = ${st.bufferMs.toStringAsFixed(1)} ms'
                      '${st.exclusive ? ' · exclusive' : ''}${st.lowLatency ? ' · low-latency path' : ''}'),
      settingDropdown<String>(
        'audio.device',
        s.audioDevice,
        [
          ('', 'System default'),
          for (final n in names)
            if (n.isNotEmpty) (n, n.length > 28 ? '${n.substring(0, 27)}…' : n),
          if (s.audioDevice.isNotEmpty && !names.contains(s.audioDevice)) (s.audioDevice, '${s.audioDevice} (not found)'),
        ],
        (v) => s.update((x) => x.audioDevice = v),
        icon: Icons.speaker,
        subtitle: devices == null
            ? 'Where the sound plays'
            : devices.backend == 'AAudio'
                ? 'Android routes AAudio\'s default to the speaker, headphones or a USB interface by itself'
                : '${devices.devices.length} on ${devices.backend}; a device that is gone falls back to the default',
      ),
      settingChoice<int>(
        'audio.rate',
        s.sampleRate,
        [for (final r in Settings.sampleRates) (r, r % 1000 == 0 ? '${r ~/ 1000}k' : '${(r / 1000).toStringAsFixed(1)}k')],
        (v) => s.update((x) => x.sampleRate = v),
        icon: Icons.waves,
        subtitle: [
          if (s.sampleRate != _runningRate) 'Applies the next time C.A.W starts (now ${_runningRate ~/ 1000} kHz)'
          else 'The rate the engine runs at; set when C.A.W starts',
          if (nativeRates.isNotEmpty) 'the device\'s own: ${nativeRates.map((r) => '${r / 1000}').join(', ')} kHz',
        ].join('; '),
      ),
      settingDropdown<int>(
        'audio.buffer',
        s.bufferFrames,
        [
          for (final f in Settings.bufferSizes)
            (f, f == 0 ? 'Auto (the mode)' : '$f · ${_ms(f, _runningRate)} ms'),
        ],
        (v) => s.update((x) => x.bufferFrames = v),
        icon: Icons.timer_outlined,
        subtitle: s.bufferFrames == 0
            ? 'Chosen by Buffer mode below; Device now shows what the device gave'
            : 'Asked for ${s.bufferFrames} frames (${_ms(s.bufferFrames, _runningRate)} ms); the device may round it',
      ),
      settingChoice<AudioBuffer>(
        'audio.mode',
        s.audioBuffer,
        [for (final b in AudioBuffer.values) (b, b.label)],
        (v) => s.update((x) => x.audioBuffer = v),
        icon: Icons.battery_charging_full,
        subtitle: switch (s.audioBuffer) {
          AudioBuffer.auto => 'Larger while not recording, smallest while recording; the low-latency path',
          AudioBuffer.lowLatency => 'Always the smallest the device allows, on the low-latency path',
          AudioBuffer.battery => 'Always larger and the power-saving path: fewer wake-ups, more delay',
        } + (s.bufferFrames == 0 ? '' : ' (the size is set above; the mode keeps the path)'),
      ),
      settingSwitch(
        'audio.exclusive',
        s.exclusiveAudio,
        exclusiveOffered ? (v) => s.update((x) => x.exclusiveAudio = v) : null,
        icon: Icons.lock_outline,
        subtitle: !exclusiveOffered
            ? '${devices?.backend} takes no exclusive request here'
            : 'The device for C.A.W alone (AAudio exclusive, WASAPI exclusive) for the least delay; other apps go quiet. '
                'Falls back to shared if the device refuses',
      ),
      settingChoice<SoundQuality>(
        'audio.quality',
        s.soundQuality,
        [for (final q in SoundQuality.values) (q, q.label)],
        (v) => s.update((x) => x.soundQuality = v),
        icon: Icons.high_quality_outlined,
        subtitle: switch (s.soundQuality) {
          SoundQuality.eco => 'Less oversampling, at most 4 unison copies, lighter reverbs: saves battery',
          SoundQuality.normal => 'The full sound',
          SoundQuality.high => 'More oversampling on the saturator',
        },
      ),
      settingAction(
        'audio.test',
        icon: Icons.volume_up_outlined,
        trailing: FilledButton.tonal(
          key: const ValueKey('test-tone'),
          onPressed: widget.deps.state == null
              ? null
              : () {
                  final error = widget.deps.state!.playTestTone();
                  if (error != null) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No sound: $error')));
                  }
                },
          child: const Text('Play'),
        ),
      ),
    ]);
  }
}

