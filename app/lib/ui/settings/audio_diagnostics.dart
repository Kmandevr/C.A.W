// Engine diagnostics' Audio clock block (#241): what each stream has really done (caw_audio_status "clock" and the input's counters), live and copyable.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/engine.dart';
import '../theme.dart';
import '../widgets.dart';

/// One read of the status, with when it was taken, so the next read can give the last second's rates.
class AudioClockSample {
  const AudioClockSample(this.status, this.atUs);
  final Map<String, dynamic> status;
  final int atUs;
}

String _rate(double v) => v.toStringAsFixed(1);
int _int(Object? v) => v is num ? v.toInt() : 0;
double _num(Object? v) => v is num ? v.toDouble() : 0;
String _xruns(Object? v) => v is num && v >= 0 ? '${v.toInt()}' : 'not reported';

/// The block's text: the engine's rate, the output stream's real rate since it opened (and over the last read
/// when [previous] is the read before), its callbacks and their sizes, late callbacks, xruns, the layers shed, the
/// input's real rate, fill, skipped frames and xruns, and each playback device's native rates where [devices] lists
/// them. Pure, for the widget and its test.
String audioClockReport(AudioClockSample now, {AudioClockSample? previous, AudioDeviceList? devices}) {
  final s = now.status;
  final lines = <String>[];
  final engineRate = _int(s['engine_sample_rate']);
  lines.add('Engine sample rate: ${engineRate > 0 ? '$engineRate Hz' : 'not reported'}');
  if (s['running'] != true) {
    lines.add('Output: not running');
  } else {
    lines.add('Output stream: ${_int(s['sample_rate'])} Hz (${s['backend'] ?? ''}${(s['device'] as String? ?? '').isEmpty ? '' : ', ${s['device']}'})');
    final c = s['clock'];
    if (c is! Map) {
      lines.add('Output clock: not reported by this engine');
    } else {
      final secs = _num(c['seconds']), frames = _num(c['frames']);
      var real = 'Output rate: ${secs > 0 ? _rate(frames / secs) : '-'} frames/s over ${secs.toStringAsFixed(1)} s';
      final pc = previous?.status['clock'];
      final dt = previous == null ? 0 : (now.atUs - previous.atUs) / 1e6;
      if (pc is Map && dt > 0 && frames >= _num(pc['frames'])) {
        real += ' (last ${dt.toStringAsFixed(1)} s: ${_rate((frames - _num(pc['frames'])) / dt)})';
      }
      lines
        ..add(real)
        ..add('Callbacks: ${_int(c['callbacks'])} · frames ${_int(c['min_frames'])}..${_int(c['max_frames'])}'
            ' · rendered ${_int(c['rendered_frames'])} of ${frames.toInt()}')
        ..add('Late callbacks: ${_int(c['late_callbacks'])} · xruns: ${_xruns(c['xruns'])}')
        ..add('Layers shed: ${_int(c['shed'])} · restored: ${_int(c['restored'])} · muted now: ${_int(c['muted_now'])}');
    }
  }
  final i = s['input'];
  if (i is Map && i['running'] == true) {
    final secs = _num(i['seconds']), pushed = _num(i['pushed_frames']);
    lines
      ..add('Input stream: ${_int(i['sample_rate'])} Hz${(i['device'] as String? ?? '').isEmpty ? '' : ' (${i['device']})'}')
      ..add('Input rate: ${secs > 0 ? _rate(pushed / secs) : '-'} frames/s over ${secs.toStringAsFixed(1)} s'
          ' · drift ${_int(i['drift_ppm'])} ppm')
      ..add('Input fill: ${_int(i['fill_frames'])} frames (starts at ${_int(i['duplex_buffer_frames'])})'
          ' · skipped ${_int(i['skipped_frames'])} · underruns ${_int(i['underruns'])} · xruns: ${_xruns(i['xruns'])}');
  } else {
    lines.add('Input: ${i is Map ? (i['state'] ?? 'off') : 'off'}');
  }
  if (devices != null && devices.devices.isNotEmpty) {
    lines.add('Native rates (${devices.backend}):');
    for (final d in devices.devices) {
      final known = d.rates.where((r) => r > 0).toList();
      lines.add('  ${d.name}${d.isDefault ? ' [default]' : ''}: '
          '${known.isEmpty ? 'not known' : known.map((r) => '$r Hz').join(', ')}');
    }
  }
  return lines.join('\n');
}

/// The Audio clock block: [audioClockReport] read about once a second while it shows, with a Copy button, as the
/// Display modes block is (#241: a device run shows where time goes missing between the streams and the speaker).
class AudioClockPanel extends StatefulWidget {
  const AudioClockPanel(
      {super.key, required this.read, this.devices, this.every = const Duration(seconds: 1), this.clockUs});

  /// The status as the engine writes it (Engine.audioStatusJson; empty without an engine).
  final Map<String, dynamic> Function() read;

  /// The playback devices with their native rates (Engine.audioDevices), read once; null: not listed.
  final Future<AudioDeviceList> Function()? devices;
  final Duration every;

  /// Microseconds now, for the last read's rates (the wall clock when null).
  final int Function()? clockUs;

  @override
  State<AudioClockPanel> createState() => _AudioClockPanelState();
}

class _AudioClockPanelState extends State<AudioClockPanel> {
  AudioClockSample? _now, _previous;
  AudioDeviceList? _devices;
  Timer? _timer;

  AudioClockSample _sample() => AudioClockSample(widget.read(), widget.clockUs?.call() ?? DateTime.now().microsecondsSinceEpoch);

  @override
  void initState() {
    super.initState();
    _now = _sample();
    widget.devices?.call().then((d) {
      if (mounted) setState(() => _devices = d);
    }).catchError((Object _) {});
    _timer = Timer.periodic(widget.every, (_) {
      if (!mounted) return;
      setState(() {
        _previous = _now;
        _now = _sample();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = audioClockReport(_now!, previous: _previous, devices: _devices);
    return NeonPanel(
      color: Neon.violet,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(child: Text('AUDIO CLOCK', style: TextStyle(color: Neon.violet, fontWeight: FontWeight.w800))),
          TextButton.icon(
            key: const ValueKey('audio-clock-copy'),
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Audio clock copied')));
            },
          ),
        ]),
        SelectableText(text, key: const ValueKey('audio-clock-text'), style: Neon.code(size: 12)),
      ]),
    );
  }
}
