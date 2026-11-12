// The fx-space reverbs' plugin UIs: the convolver (its impulse response's envelope on a decay x size pad) and the shimmer (rising octave layers).
import '../../kit/repaint.dart';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../model/arrange_fx.dart';
import '../../../haptics.dart';
import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';
import 'space_fx.dart';

/// The convolver: the impulse response's envelope (the engine's, once built; else drawn from the knobs ≈) on a pad of
/// decay (sideways) and size (up), the impulse picker, reverse, then pre-delay, damping, length, tone, width and mix.
class ConvolverPage extends StatelessWidget {
  const ConvolverPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final file = t.value('source').round() == 9;
    return effectPage('convolver', [
      HeroWithMeters(height: 200, gr: false, hero: DeviceDisplay(builder: (context, f) => XYPad(
        xParam: 'decay', yParam: 'size', height: 200, caption: 'IMPULSE',
        painter: (dot) => _IrPainter(values: f?.values, decay: t.value('decay'), size: t.value('size'),
            reverse: t.value('reverse') >= 0.5, length: t.value('length'), source: t.value('source').round(),
            color: scope.accent, second: scope.secondary)))),
      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        spaceLabel('IMPULSE'),
        const DeviceChoice('source', maxSegments: 0),
        const DeviceToggle('reverse', label: 'Reverse', icon: Icons.swap_horiz),
        const LoadImpulseButton(),
      ]),
      if (file) DeviceDisplay(builder: (context, f) => Padding(padding: const EdgeInsets.only(top: 6), child: Text(
          (f?.values['file'] ?? 0) > 0.5 ? 'A WAV impulse is loaded.' : 'No WAV loaded: the wet is silent until one is.',
          style: const TextStyle(fontSize: 11, color: Neon.dim)))),
      const KnobRow(['predelay', 'damping', 'length', 'mix'], size: 52),
      const KnobRow(['low_cut', 'high_cut', 'width'], size: 46),
      DeviceDisplay(builder: (context, f) => Text(
          'latency ${(f?.values['latency_ms'] ?? 10.7).toStringAsFixed(1)} ms · impulse '
          '${(f?.values['ir_s'] ?? 0).toStringAsFixed(2)} s${(f?.values['built'] ?? 1) < 1 ? ' · building…' : ''}',
          style: Neon.code(size: 10, color: Neon.dim))),
    ]);
  }
}

/// The largest WAV impulse the convolver takes (kMaxIrFileBytes in engine/src/builtin_fx_space.h).
const maxImpulseBytes = 16 * 1024 * 1024;

/// Picks a WAV file for the convolver: its bytes, or null when cancelled (tests replace it). A file over
/// [maxImpulseBytes] is refused before it is read.
Future<Uint8List?> Function() pickImpulseWav = defaultPickImpulseWav;

/// The system file picker, for WAV files.
Future<Uint8List?> defaultPickImpulseWav() async {
  final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['wav']);
  if (file == null) return null;
  if (await file.xFile.length() > maxImpulseBytes) throw const FormatException('That file is over 16 MB.');
  return file.xFile.readAsBytes();
}

/// Load WAV…: the user's own impulse response. The engine checks the file (it is untrusted), rebuilds the effect
/// with it off the UI thread, and the impulse picker moves to Loaded file.
class LoadImpulseButton extends StatefulWidget {
  const LoadImpulseButton({super.key});

  @override
  State<LoadImpulseButton> createState() => _LoadImpulseButtonState();
}

class _LoadImpulseButtonState extends State<LoadImpulseButton> {
  bool _busy = false;

  void _say(String text, {bool error = false}) {
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(text, style: TextStyle(color: error ? Neon.pink : null)),
        duration: const Duration(seconds: 4)));
  }

  Future<void> _load() async {
    DeviceFeel.tap();
    final t = DeviceScope.of(context).target;
    final layer = t.layer;
    if (layer == null || t.isInstrument) return;
    setState(() => _busy = true);
    try {
      final bytes = await pickImpulseWav();
      if (bytes == null || !mounted) return;
      final ok = await t.state.loadNativeEffectState(layer, t.slot, bytes);
      if (!mounted) return;
      if (ok) {
        t.set('source', 9);
        _say('Impulse loaded');
      } else {
        Haptics.error();
        _say('Not loaded: the convolver takes a PCM or float WAV of up to 10 s.', error: true);
      }
    } on FormatException catch (e) {
      Haptics.error();
      if (mounted) _say('Not loaded: ${e.message}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
        key: const ValueKey('convolver-load'),
        style: TextButton.styleFrom(foregroundColor: DeviceScope.of(context).accent),
        onPressed: _busy ? null : _load,
        icon: _busy
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.file_open, size: 16),
        label: const Text('Load WAV…', style: TextStyle(fontSize: 12)),
      );
}

class _IrPainter extends CustomPainter {
  _IrPainter({required this.values, required this.decay, required this.size, required this.reverse, required this.length,
    required this.source, required this.color, required this.second});
  final Map<String, double>? values;
  final double decay, size, length;
  final bool reverse;
  final int source;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    // The envelope in dB (0 at the top, −60 at the bottom) over the response's length.
    final points = <double>[];
    final engine = values;
    if (engine != null && (engine['env0'] != null)) {
      for (var j = 0; j < 64; j++) {
        points.add(engine['env$j'] ?? -120);
      }
    } else {
      // ≈ from the knobs: a decay of −60 dB at `decay` seconds, rising over the size's onset.
      for (var j = 0; j < 64; j++) {
        final x = j / 63, tSec = x * decay * length;
        final onset = 1 - math.exp(-tSec / (0.005 + 0.05 * size));
        points.add(-60 * tSec / decay + 20 * math.log(math.max(1e-4, onset)) / math.ln10);
      }
      if (reverse) points.setAll(0, points.reversed.toList());
    }
    final top = points.reduce(math.max);
    double y(double db) => 22 + (h - 30) * (1 - ((db - top + 60) / 60).clamp(0.0, 1.0));
    final p = Path();
    for (var j = 0; j < points.length; j++) {
      final x = 8 + (w - 16) * j / (points.length - 1);
      j == 0 ? p.moveTo(x, y(points[j])) : p.lineTo(x, y(points[j]));
    }
    fillFade(canvas, p, h, s, color, alpha: 0.3);
    strokeGlow(canvas, p, color, width: 2);
    final irS = values?['ir_s'];
    paintLabel(canvas, irS == null ? '≈ ${(decay * length).toStringAsFixed(1)} s' : '${irS.toStringAsFixed(2)} s',
        Offset(w - 8, h - 10), second, size: 9, align: 1, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant _IrPainter o) =>
      paintInputsChanged([o.values, o.decay, o.size, o.length, o.reverse, o.source, o.color, o.second], [values, decay, size, length, reverse, source, color, second]);
}

/// The shimmer: each round of the tail drawn as a layer a shift higher (an octave or a fifth), fading by the
/// shimmer amount, on a pad of decay (sideways) and shimmer (up); the shift, then size, pre-delay, tone and mix.
class ShimmerPage extends StatelessWidget {
  const ShimmerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return effectPage('shimmer', [
      HeroWithMeters(height: 200, gr: false, hero: DevicePhase(builder: (context, secs) => XYPad(
        xParam: 'decay', yParam: 'amount', height: 200, caption: 'SHIMMER',
        painter: (dot) => _ShimmerPainter(secs: secs, amount: t.value('amount'), decay: t.value('decay'),
            shift: formatParamValue(t.param('shift'), t.value('shift')), color: scope.accent, second: scope.secondary)))),
      spaceRow('SHIFT', const DeviceChoice('shift', maxSegments: 6)),
      const KnobRow(['size', 'predelay', 'damping', 'mix'], size: 52),
      const KnobRow(['tone', 'low_cut', 'mod', 'width'], size: 46),
    ]);
  }
}

class _ShimmerPainter extends CustomPainter {
  _ShimmerPainter({required this.secs, required this.amount, required this.decay, required this.shift, required this.color,
    required this.second});
  final double secs, amount, decay;
  final String shift;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final semis = int.tryParse(shift.replaceAll('+', '')) ?? 12;
    // Five rounds: each a wave a shift higher, quieter by the loop gain, drifting up the canvas.
    for (var k = 0; k < 5; k++) {
      final level = math.pow(0.15 + 0.8 * amount, k).toDouble();
      final base = h - 18 - (h - 40) * (k / 4) * (semis.sign >= 0 ? 1 : 0.6);
      final freq = 2 * math.pow(2, k * semis / 12).toDouble().clamp(0.25, 24.0);
      final p = Path();
      for (var i = 0; i <= 120; i++) {
        final x = w * i / 120;
        final fade = math.exp(-i / 120 * 6 / math.max(0.5, decay / 4));
        final yy = base - 10 * level * fade * math.sin(2 * math.pi * (x / w * freq - secs * 0.3 * (k + 1)));
        i == 0 ? p.moveTo(x, yy) : p.lineTo(x, yy);
      }
      strokeGlow(canvas, p, Color.lerp(color, second, k / 4)!.withValues(alpha: (0.25 + 0.75 * level).clamp(0.0, 1.0)),
          width: 1.6, glow: k == 0);
    }
    paintLabel(canvas, '$shift st / round', Offset(w - 8, h - 10), second, size: 9, align: 1, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant _ShimmerPainter o) =>
      paintInputsChanged([o.secs, o.amount, o.decay, o.shift, o.color, o.second], [secs, amount, decay, shift, color, second]);
}
