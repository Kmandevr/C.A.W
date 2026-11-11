// Settings › Audio › Latency: how late the output (Bluetooth, USB, HDMI) and the input are, each device's offset
// (preset by its kind, typed in, tapped along to the click, or found by the loopback ping), the switch that
// compensates them, and the badge the transport row shows while the output adds more than 50 ms.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/audio_record.dart';
import '../../model/latency_comp.dart';
import '../../model/settings.dart' show Metronome;
import '../../platform/audio_route.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import '../widgets.dart' show typeValue;
import 'settings_widgets.dart';

String _ms(double v) => '${v.toStringAsFixed(v < 10 ? 1 : 0)} ms';

String _sourceLabel(OffsetSource s) => switch (s) {
      OffsetSource.preset => 'preset',
      OffsetSource.typed => 'typed in',
      OffsetSource.tapped => 'tapped along',
      OffsetSource.loopback => 'loopback ping',
    };

String _platformLabel(String source) => switch (source) {
      'timestamp' => 'the system\'s timestamps',
      'buffers' => 'the buffers',
      _ => 'not known',
    };

/// The row in Settings › Audio that opens the Latency page.
class LatencySettingsRow extends StatelessWidget {
  const LatencySettingsRow({super.key, required this.state});
  final AppState? state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    if (s == null) {
      return settingAction('audio.outputLatency', icon: Icons.bluetooth_audio, iconColor: Neon.dim,
          subtitle: 'Needs the sound engine, which is not running here');
    }
    return ListenableBuilder(
      listenable: s.latency,
      builder: (context, _) {
        final l = s.latency;
        return settingAction('audio.outputLatency', icon: Icons.bluetooth_audio,
            subtitle: l.enabled
                ? 'Output ${_ms(l.outputMs)} · input ${_ms(l.inputMs)} · ${l.routeInfo.output.label}'
                : 'Off: the playhead and meters show what was just rendered',
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LatencyPage(state: s))));
      },
    );
  }
}

class LatencyPage extends StatefulWidget {
  const LatencyPage({super.key, required this.state});
  final AppState state;

  @override
  State<LatencyPage> createState() => _LatencyPageState();
}

class _LatencyPageState extends State<LatencyPage> {
  bool _pinging = false;

  LatencyComp get l => widget.state.latency;

  @override
  void initState() {
    super.initState();
    unawaited(l.refresh());
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _type({required bool output}) => typeValue(context,
      title: output ? 'Output latency in all (ms)' : 'Input latency in all (ms)',
      initial: (output ? l.outputMs : l.inputMs).toStringAsFixed(0),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      parse: (v) {
        final ms = double.tryParse(v.trim().replaceAll(',', '.'));
        return ms == null || ms < 0 || ms > 2000 ? null : ms;
      },
      apply: (ms) {
        Haptics.tap();
        output ? l.setOutputTotalMs(ms) : l.setInputTotalMs(ms);
      });

  Future<void> _tapAlong() async {
    final ms = await showDialog<double>(context: context, builder: (_) => TapAlongDialog(state: widget.state));
    if (ms == null || !mounted) return;
    l.setOutputTotalMs(ms, source: OffsetSource.tapped);
    Haptics.drop();
    _say('Output latency ${_ms(ms)}, from your taps');
  }

  Future<void> _ping() async {
    final rec = AudioRecorder.current;
    if (rec == null) return;
    final ok = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Loopback measurement'),
      content: const Text('C.A.W plays a short burst of noise (−12 dBFS) and listens for it. Turn the volume down; '
          'hold the speaker near the microphone in a quiet room, or connect the output to the input with a cable. '
          'What the output\'s latency does not explain is the input\'s.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('latency-loopback-go'), onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Play the ping')),
      ],
    ));
    if (ok != true || !mounted) return;
    setState(() => _pinging = true);
    final r = await rec.ping();
    if (!mounted) return;
    setState(() => _pinging = false);
    if (r == null || !r.ok) {
      Haptics.error();
      _say(r == null ? (rec.message.value ?? 'The ping could not start: turn audio input on first.')
          : 'The ping was not heard clearly: try again, louder.');
    } else {
      Haptics.drop();
      _say('Round trip ${_ms(r.ms)}: input ${_ms(l.inputMs)}');
    }
  }

  Widget _side({required bool output}) {
    final dev = output ? l.routeInfo.output : l.routeInfo.input;
    final platform = output ? l.platformOutputMs : l.platformInputMs;
    final source = output ? l.device.output.source : l.device.input.source;
    final off = output ? l.outputOffset : l.inputOffset;
    final total = output ? l.outputMs : l.inputMs;
    final hasInput = AudioRecorder.current?.inputOpen ?? false;
    final level = Motion.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      settingHeading(output ? 'Output' : 'Input'),
      settingAction(output ? 'audio.latencyOutputDevice' : 'audio.latencyInputDevice',
          icon: dev.kind.isBluetooth ? Icons.bluetooth : output ? Icons.speaker_outlined : Icons.mic_none,
          subtitle: '${dev.label} · system ${_ms(platform)} (${_platformLabel(source)})',
          trailing: AnimatedSwitcher(
            duration: Motion.fade(Motion.standard, level),
            child: Text(_ms(total), key: ValueKey(total.round()),
                style: Neon.code(size: 14, color: total > 50 ? Neon.yellow : Neon.text)),
          )),
      settingAction(output ? 'audio.latencyOutputOffset' : 'audio.latencyInputOffset', icon: Icons.tune,
          subtitle: '+${_ms(off.extraMs)} for this device (${_sourceLabel(off.source)}); tap to type the total',
          onTap: () => _type(output: output),
          trailing: off.source == OffsetSource.preset ? null : TextButton(
              key: ValueKey(output ? 'latency-output-reset' : 'latency-input-reset'),
              onPressed: () => output ? l.resetOutput() : l.resetInput(), child: const Text('Preset'))),
      if (output)
        settingAction('audio.latencyTap', icon: Icons.touch_app_outlined,
            subtitle: 'Plays the click; tap on every click you hear (8 taps)',
            trailing: FilledButton.tonal(key: const ValueKey('latency-tap'), onPressed: _tapAlong, child: const Text('Tap'))),
      if (!output)
        settingAction('audio.latencyLoopback', icon: Icons.av_timer,
            subtitle: hasInput ? 'A noise ping from the output into the input splits the round trip'
                : 'Turn audio input on (below in Audio) to measure',
            trailing: FilledButton.tonal(key: const ValueKey('latency-loopback'),
                onPressed: hasInput && !_pinging ? _ping : null,
                child: _pinging
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Measure'))),
    ]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Latency')),
        body: ListenableBuilder(
          listenable: l,
          builder: (context, _) => ListView(padding: const EdgeInsets.all(8), children: [
            settingSwitch('audio.latencyCompensate', l.enabled, (v) {
              Haptics.tap();
              l.enabled = v;
            }, icon: Icons.sync_alt,
                subtitle: 'The playhead, meters and note highlights show what you hear; takes land where you played'),
            AnimatedSize(
              duration: Motion.move(Motion.panel, Motion.of(context)),
              child: !l.enabled ? const SizedBox(width: double.infinity) : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _side(output: true),
                  _side(output: false),
                  Padding(padding: const EdgeInsets.fromLTRB(8, 8, 8, 16), child: Text(
                      'Recordings are placed by output + input: ${_ms(l.roundTripMs)}. Presets are typical figures '
                      '(Bluetooth about 200 ms); tap along or measure for this device. Offsets are kept per device.',
                      style: const TextStyle(color: Neon.dim, fontSize: 11))),
                ],
              ),
            ),
          ]),
        ),
      );
}

/// Tap-along: plays the song with the click, collects eight taps and answers their median lead past the beat in
/// ms (null when cancelled or the engine can't tell where it was).
class TapAlongDialog extends StatefulWidget {
  const TapAlongDialog({super.key, required this.state, this.taps = 8});
  final AppState state;
  final int taps;

  @override
  State<TapAlongDialog> createState() => _TapAlongDialogState();
}

class _TapAlongDialogState extends State<TapAlongDialog> {
  final List<double> _steps = [];
  bool _startedPlay = false;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    s.engine?.setMetronome(true);
    if (!s.transportOn) {
      s.togglePlay();
      _startedPlay = true;
    }
  }

  @override
  void dispose() {
    if (_startedPlay && s.transportOn) s.togglePlay();
    s.engine?.setMetronome(s.settings.metronome == Metronome.always); // back to Settings' choice
    super.dispose();
  }

  void _tap() {
    final e = s.engine;
    if (e == null) return;
    final step = s.renderStepAt(e.midiClockNs);
    if (step == null) return;
    Haptics.tick();
    setState(() => _steps.add(step));
    if (_steps.length >= widget.taps) {
      Navigator.of(context).pop(tapAlongMs(_steps, bpm: s.project.bpm));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Tap along'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Tap the pad on each click as you hear it.'),
          const SizedBox(height: 16),
          SizedBox(width: 160, height: 120, child: FilledButton(key: const ValueKey('latency-tap-pad'),
              onPressed: _tap, child: AnimatedSwitcher(
                duration: Motion.fade(Motion.small, Motion.of(context)),
                child: Text('${_steps.length} / ${widget.taps}', key: ValueKey(_steps.length),
                    style: const TextStyle(fontSize: 22))))),
        ]),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
      );
}

/// The transport row's badge while the output adds more than 50 ms (Bluetooth, say): a small chip whose tap says
/// that live playing and monitoring will feel late. Fades in and out with the route.
class LatencyBadge extends StatelessWidget {
  const LatencyBadge({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state.latency,
        builder: (context, _) {
          final tip = state.latencyTip;
          final l = state.latency;
          return AnimatedSwitcher(
            duration: Motion.fade(Motion.standard, Motion.of(context)),
            child: tip == null ? const SizedBox.shrink(key: ValueKey('no-latency-badge')) : Tooltip(
              key: const ValueKey('latency-badge'),
              message: tip,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tip))),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Neon.yellow.withValues(alpha: 0.7))),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(l.routeInfo.output.kind.isBluetooth ? Icons.bluetooth : Icons.timer_outlined,
                        size: 12, color: Neon.yellow),
                    const SizedBox(width: 2),
                    Text('+${l.outputMs.round()} ms', style: Neon.code(size: 11, color: Neon.yellow)),
                  ]),
                ),
              ),
            ),
          );
        },
      );
}
