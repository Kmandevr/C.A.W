// The drums' card pictures: each layer and kit effect drawn from its knobs (a pitch-envelope curve, decay shapes, a noise colour bar, partials, a drive curve, the groove's grid…), redrawn as they move.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../device_scope.dart';
import '../kit/param_watch.dart';
import 'drums_pads.dart';

/// The picture of one card: [kind] is a pad layer's id (`body`, `noise`, `groove`…) or a kit effect's (`kit_glue`,
/// `kit_room`, `kit_echo`…); [pad] the pad shown (null for the kit's).
class DrumVisual extends StatelessWidget {
  const DrumVisual({super.key, required this.kind, this.pad, this.height = 56, this.color});
  final String kind;
  final int? pad;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) => watchDevice(context, (context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final layout = drumsLayout(t);
    final values = <String, double>{};
    final p = pad;
    for (final s in _reads[kind] ?? const <String>[]) {
      values[s] = s.startsWith('kit:') ? t.value(s.substring(4)) : (p == null ? 0 : t.value(layout.id(p, s)));
    }
    return SizedBox(height: height, child: RepaintBoundary(child: CustomPaint(
      key: ValueKey('drum-visual-$kind'),
      painter: DrumVisualPainter(kind, values, color ?? scope.accent),
      size: Size.infinite)));
  });

  /// What each picture reads (pad suffixes; `kit:` a kit-wide id).
  static const Map<String, List<String>> _reads = {
    'body': ['body_freq', 'body_pitch', 'body_ptime', 'body_pcurve', 'body_attack', 'body_hold', 'body_decay',
      'body_dcurve', 'penv_mode', 'penv_t1', 'penv_p1', 'penv_t2', 'penv_p2', 'penv_t3', 'penv_p3', 'penv_t4', 'penv_p4',
      'tune', 'body_wave'],
    'sub': ['sub_attack', 'sub_hold', 'sub_decay', 'sub_dcurve', 'sub_wave', 'sub_oct', 'sub_drive'],
    'click': ['click_type', 'click_length', 'click_tone', 'click_level'],
    'noise': ['noise_mode', 'noise_color', 'noise_filter', 'noise_freq', 'noise_res', 'noise_attack', 'noise_decay',
      'noise_dcurve', 'noise_bursts', 'noise_spacing'],
    'metal': ['metal_set', 'metal_freq', 'metal_spread', 'metal_tone', 'metal_decay', 'metal_open', 'metal_noise'],
    'res': ['res_model', 'res_freq', 'res_decay', 'res_damp', 'res_bright', 'res_inharm'],
    'fm': ['fm_freq', 'fm_ratio', 'fm_index', 'fm_idecay', 'fm_decay', 'fm_dcurve', 'fm_attack', 'fm_feedback'],
    'phys': ['phys_model', 'phys_freq', 'phys_decay', 'phys_damp', 'phys_pick'],
    'tex': ['tex_mode', 'tex_freq', 'tex_spread', 'tex_res', 'tex_tilt', 'tex_density', 'tex_attack', 'tex_decay',
      'tex_dcurve'],
    'smp': ['smp_start', 'smp_end', 'smp_reverse', 'smp_attack', 'smp_hold', 'smp_decay', 'smp_dcurve', 'smp_pitch'],
    'drive': ['drive_type', 'drive', 'drive_mix'],
    'filter': ['flt', 'cutoff', 'flt_res', 'flt_env'],
    'eq': ['eq_low', 'eq_low_freq', 'eq_mid', 'eq_freq', 'eq_q', 'eq_high', 'eq_high_freq'],
    'dyn': ['comp', 'tr_attack', 'tr_sustain', 'clip', 'clip_gain'],
    'space': ['width', 'width_hz', 'room_send', 'pan'],
    'fx': ['ring_mix', 'ring_freq', 'echo_send', 'bus_send', 'room_send'],
    'groove': ['swing', 'swing_grid', 'humanize', 'accent', 'accent_on', 'flam', 'flam_time', 'groove', 'groove_amt'],
    'var': ['vel_level', 'vel_pitch', 'vel_decay', 'vel_tone', 'rnd_pitch', 'rnd_decay', 'rnd_tone', 'rnd_pan',
      'rnd_level'],
    'press': ['press_damp', 'press_choke', 'press_tone', 'press_pitch', 'press_level', 'press_drive'],
    'pad': ['level', 'pan', 'tune', 'trig', 'release', 'poly', 'choke'],
    'kit_glue': ['kit:glue', 'kit:glue_threshold', 'kit:glue_ratio'],
    'kit_drive': ['kit:kit_drive_type', 'kit:kit_drive', 'kit:kit_drive_mix'],
    'kit_room': ['kit:room', 'kit:room_size', 'kit:room_decay', 'kit:room_predelay'],
    'kit_echo': ['kit:echo', 'kit:echo_time', 'kit:echo_sync', 'kit:echo_feedback', 'kit:echo_spread'],
    'kit_eq': ['kit:kit_low', 'kit:kit_high'],
    'kit_clip': ['kit:kit_clip', 'kit:kit_clip_gain'],
  };
}

/// The groove steps the engine plays (builtin_drums.cpp, `grooveSteps`): how late each 16th comes (in 16ths) and its
/// velocity's scale, for Shuffle, Laid back, Gallop, Broken and Half-time.
const drumGrooveSteps = <List<(double, double)>>[
  [],
  [(0, 1), (0.33, 0.78), (0, 0.92), (0.33, 0.78), (0, 1), (0.33, 0.78), (0, 0.92), (0.33, 0.78),
   (0, 1), (0.33, 0.78), (0, 0.92), (0.33, 0.78), (0, 1), (0.33, 0.78), (0, 0.92), (0.33, 0.78)],
  [(0, 1), (0.08, 0.85), (0.04, 0.9), (0.08, 0.85), (0.25, 1), (0.08, 0.85), (0.04, 0.9), (0.08, 0.85),
   (0, 1), (0.08, 0.85), (0.04, 0.9), (0.08, 0.85), (0.25, 1), (0.08, 0.85), (0.04, 0.9), (0.08, 0.85)],
  [(0, 1), (0.33, 0.7), (0.15, 0.85), (0, 0.75), (0, 1), (0.33, 0.7), (0.15, 0.85), (0, 0.75),
   (0, 1), (0.33, 0.7), (0.15, 0.85), (0, 0.75), (0, 1), (0.33, 0.7), (0.15, 0.85), (0, 0.75)],
  [(0, 1), (0.1, 0.7), (0, 0.9), (0.3, 0.8), (0, 0.95), (0.05, 0.65), (0.2, 0.85), (0, 0.7),
   (0, 1), (0.25, 0.75), (0, 0.85), (0.1, 0.7), (0, 0.95), (0, 0.6), (0.3, 0.9), (0.1, 0.7)],
  [(0, 1), (0.05, 0.7), (0, 0.8), (0.05, 0.7), (0, 0.75), (0.05, 0.7), (0, 0.8), (0.05, 0.7),
   (0, 1.15), (0.05, 0.7), (0, 0.8), (0.05, 0.7), (0, 0.75), (0.05, 0.7), (0, 0.8), (0.05, 0.7)],
];

/// The metal sets' six ratios (builtin_drums.cpp, `kMetalSets`).
const _metalRatios = [
  [1.0, 1.48271, 1.80029, 2.54603, 2.63030, 3.89674], [1.0, 1.342, 1.759, 2.107, 2.533, 3.191],
  [1.0, 1.215, 1.797, 2.341, 3.106, 4.207], [1.0, 1.48148], [1.0, 1.5, 2.08, 2.84, 3.6, 4.42],
  [1.0, 2.0, 2.76, 3.0, 5.4, 6.0], [1.0, 2.0, 3.0, 4.0, 5.0, 6.0],
];

/// Approximate mode ratios of the resonator's models, for the picture only (membrane, plate, bar, tube, bell, cymbal).
const _modeRatios = [
  [1.0, 1.59, 2.14, 2.30, 2.65, 2.92, 3.16, 3.50], [1.0, 2.5, 4.0, 5.1, 6.5, 8.0, 9.6, 11.0],
  [1.0, 2.76, 5.40, 8.93, 13.3], [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0], [0.5, 1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 4.0],
  [1.0, 1.42, 1.83, 2.31, 2.66, 3.02, 3.48, 3.91],
];

class DrumVisualPainter extends CustomPainter {
  DrumVisualPainter(this.kind, this.v, this.color);
  final String kind;
  final Map<String, double> v;
  final Color color;

  double g(String s, [double d = 0]) => v[s] ?? d;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(8)), Paint()..color = Neon.ink.withValues(alpha: 0.04));
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(r, const Radius.circular(8)));
    switch (kind) {
      case 'body': _body(canvas, size);
      case 'sub': _env(canvas, size, g('sub_attack'), g('sub_hold'), g('sub_decay'), g('sub_dcurve'), wave: true);
      case 'click': _click(canvas, size);
      case 'noise': _noise(canvas, size);
      case 'metal': _metal(canvas, size);
      case 'res': _res(canvas, size);
      case 'fm': _fm(canvas, size);
      case 'phys': _phys(canvas, size);
      case 'tex': _tex(canvas, size);
      case 'smp': _smp(canvas, size);
      case 'drive' || 'kit_drive' || 'dyn' || 'kit_clip' || 'kit_glue': _transfer(canvas, size);
      case 'filter': _filter(canvas, size);
      case 'eq' || 'kit_eq': _eq(canvas, size);
      case 'space': _space(canvas, size);
      case 'fx': _bars(canvas, size, [('Ring', g('ring_mix')), ('Echo', g('echo_send')), ('Kit bus', g('bus_send')),
        ('Room', g('room_send'))]);
      case 'groove': _groove(canvas, size);
      case 'var': _var(canvas, size);
      case 'press': _bars(canvas, size, [('Damp', g('press_damp')), ('Tone', g('press_tone').abs()),
        ('Pitch', g('press_pitch').abs() / 12), ('Level', g('press_level').abs()), ('Drive', g('press_drive')),
        ('Choke', g('press_choke'))]);
      case 'pad': _pad(canvas, size);
      case 'kit_room': _room(canvas, size);
      case 'kit_echo': _echo(canvas, size);
      default: break;
    }
    canvas.restore();
  }

  // ---- helpers ----

  Paint get _line => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.8
    ..strokeJoin = StrokeJoin.round;
  Paint _fill([double a = 0.22]) => Paint()..color = color.withValues(alpha: a);

  /// x of [hz] on a log axis 20 Hz..20 kHz.
  double _fx(double hz, double w) => w * (math.log(hz.clamp(20, 20000) / 20) / math.log(1000));

  /// The engine's decay shape (DrumEnv): attack, hold, then 60 dB in [d] blended by [c].
  double _envAt(double t, double a, double h, double d, double c) {
    if (t < a) return a <= 0 ? 1 : t / a;
    t -= a + h;
    if (t < 0) return 1;
    if (d <= 0) return 0;
    final e = math.exp(-6.9 * t / d);
    if (c >= 0) return e + c * (math.exp(-6.9 * 6 * t / d) - e);
    return e - c * (math.max(0, 1 - t / d) - e);
  }

  void _label(Canvas canvas, String text, Offset at, {Color? c, double size = 9, bool right = false}) {
    final tp = TextPainter(text: TextSpan(text: text, style: Neon.code(size: size - 1, color: c ?? Neon.dim)),
      textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, right ? at - Offset(tp.width, 0) : at);
  }

  String _hz(double f) => f >= 1000 ? '${(f / 1000).toStringAsFixed(f >= 10000 ? 0 : 1)} kHz' : '${f.round()} Hz';

  /// An envelope filled under its curve over [span] seconds (default: its own length).
  void _env(Canvas canvas, Size s, double a, double h, double d, double c, {double? span, bool wave = false}) {
    final total = span ?? (a + h + d * 1.1).clamp(0.02, 4.0);
    final path = Path()..moveTo(0, s.height);
    final top = Path();
    for (var i = 0; i <= 64; i++) {
      final t = total * i / 64;
      final y = s.height - 4 - (s.height - 10) * _envAt(t, a, h, d, c);
      final x = s.width * i / 64;
      path.lineTo(x, y);
      i == 0 ? top.moveTo(x, y) : top.lineTo(x, y);
    }
    path.lineTo(s.width, s.height);
    canvas.drawPath(path, _fill(0.18));
    canvas.drawPath(top, _line);
    if (wave) {  // the waveform under it, as heard
      final w = Path();
      for (var i = 0; i <= 160; i++) {
        final t = total * i / 160, x = s.width * i / 160;
        final y = s.height / 2 + (s.height / 2 - 6) * _envAt(t, a, h, d, c) * math.sin(i / 160 * math.pi * 18);
        i == 0 ? w.moveTo(x, y) : w.lineTo(x, y);
      }
      canvas.drawPath(w, Paint()..color = color.withValues(alpha: 0.45)..style = PaintingStyle.stroke..strokeWidth = 1);
    }
    _label(canvas, total < 1 ? '${(total * 1000).round()} ms' : '${total.toStringAsFixed(1)} s', Offset(s.width - 4, 2),
      right: true);
  }

  // ---- layers ----

  void _body(Canvas canvas, Size s) {
    final a = g('body_attack'), h = g('body_hold'), d = g('body_decay', 0.4), c = g('body_dcurve');
    final span = (a + h + d * 1.1).clamp(0.05, 3.0);
    _env(canvas, s, a, h, d, c, span: span);
    // The pitch: Hz on a log axis (20 Hz..4 kHz), as the body plays it.
    final fEnd = g('body_freq', 55) * math.pow(2, g('tune') / 12);
    double st(double t) {
      if (g('penv_mode').round() == 1) {
        var from = g('body_pitch'), at = 0.0;
        for (var k = 1; k <= 4; k++) {
          final len = g('penv_t$k', 0.01), to = g('penv_p$k');
          if (t < at + len) return from + (to - from) * ((t - at) / len);
          at += len;
          from = to;
        }
        return from;
      }
      final pt = g('body_ptime', 0.05), pc = g('body_pcurve');
      final e = math.exp(-6.9 * t / pt);
      final shaped = pc >= 0 ? e + pc * (math.exp(-6.9 * 6 * t / pt) - e) : e - pc * (math.max(0, 1 - t / pt) - e);
      final fStart = fEnd * math.pow(2, g('body_pitch') / 12);
      return 12 * math.log((fEnd + (fStart - fEnd) * shaped) / fEnd) / math.ln2;
    }
    final lo = math.log(20), hi = math.log(4000);
    double y(double f) => s.height - 4 - (s.height - 10) * ((math.log(f.clamp(20, 4000)) - lo) / (hi - lo));
    final pitch = Path();
    for (var i = 0; i <= 80; i++) {
      final t = span * i / 80;
      final f = fEnd * math.pow(2, st(t) / 12);
      i == 0 ? pitch.moveTo(0, y(f)) : pitch.lineTo(s.width * i / 80, y(f));
    }
    canvas.drawPath(pitch, Paint()..color = Neon.yellow..style = PaintingStyle.stroke..strokeWidth = 2);
    _label(canvas, '${_hz(fEnd * math.pow(2, st(0) / 12))} → ${_hz(fEnd)}', const Offset(4, 2), c: Neon.yellow);
  }

  void _click(Canvas canvas, Size s) {
    final len = g('click_length', 0.008), type = g('click_type').round(), lvl = g('click_level', 0.5).clamp(0.05, 1.0);
    final span = 0.03;
    final p = Path();
    final rnd = math.Random(3);
    for (var i = 0; i <= 120; i++) {
      final t = span * i / 120, e = t < len ? math.exp(-4 * t / len) : 0.0;
      final ph = t * g('click_tone', 2000) * 2 * math.pi;
      final w = switch (type) {
        1 => i == 1 ? 1.0 : 0.0,
        2 => math.sin(ph),
        3 => math.sin(ph) >= 0 ? 1.0 : -1.0,
        4 => math.sin(ph * (1 + 3 * e)),
        _ => rnd.nextDouble() * 2 - 1,
      };
      final yy = s.height / 2 - (s.height / 2 - 4) * w * e * lvl;
      i == 0 ? p.moveTo(0, yy) : p.lineTo(s.width * i / 120, yy);
    }
    canvas.drawPath(p, _line);
    _label(canvas, '${(len * 1000).toStringAsFixed(1)} ms · ${_hz(g('click_tone', 2000))}', Offset(s.width - 4, 2), right: true);
  }

  /// The noise colour as a bar (white flat, pink and brown darker toward the highs, crushed in steps), the filter's
  /// band over it, the envelope (or the clap's bursts) under it.
  void _noise(Canvas canvas, Size s) {
    final bar = Rect.fromLTWH(0, 0, s.width, 12);
    final col = g('noise_color').round();
    final colors = switch (col) {
      1 => [const Color(0xFFFFE0F0), const Color(0xFFFF7AA8), const Color(0xFF7A2A55)],
      2 => [const Color(0xFFFFB07A), const Color(0xFF8A3A1A), const Color(0xFF2A1008)],
      3 => [Neon.dim, Neon.text, Neon.dim],
      _ => [Colors.white, Colors.white, Colors.white70],
    };
    canvas.drawRect(bar, Paint()..shader = LinearGradient(colors: colors).createShader(bar));
    if (col == 3) {
      for (var x = 0.0; x < s.width; x += 8) {
        canvas.drawRect(Rect.fromLTWH(x, 0, 4, 12), Paint()..color = Neon.bg.withValues(alpha: 0.35));
      }
    }
    final flt = g('noise_filter').round();
    if (flt != 0) {
      final fx = _fx(g('noise_freq', 2000), s.width);
      final band = switch (flt) { 1 => Rect.fromLTRB(0, 0, fx, 12), 3 => Rect.fromLTRB(fx, 0, s.width, 12),
        _ => Rect.fromLTRB(fx - 10 - 20 * (1 - g('noise_res')), 0, fx + 10 + 20 * (1 - g('noise_res')), 12) };
      canvas.drawRect(Rect.fromLTRB(0, 0, s.width, 12), Paint()..color = Neon.bg.withValues(alpha: 0.55));
      canvas.drawRect(band.intersect(bar), Paint()..shader = LinearGradient(colors: colors).createShader(bar));
      canvas.drawLine(Offset(fx, 0), Offset(fx, 14), Paint()..color = color..strokeWidth = 2);
    }
    canvas.save();
    canvas.translate(0, 14);
    final sub = Size(s.width, s.height - 14);
    if (g('noise_mode').round() == 2) {
      final n = g('noise_bursts', 3).round(), sp = g('noise_spacing', 0.01), d = g('noise_decay', 0.2);
      final span = n * sp + d * 1.1;
      final p = Path()..moveTo(0, sub.height);
      for (var i = 0; i <= 120; i++) {
        final t = span * i / 120;
        double e;
        if (t < n * sp) {
          e = math.exp(-6.9 * (t % sp) / (3 * sp));
        } else {
          e = _envAt(t - n * sp, g('noise_attack'), 0, d, g('noise_dcurve'));
        }
        p.lineTo(sub.width * i / 120, sub.height - 2 - (sub.height - 4) * e);
      }
      p.lineTo(sub.width, sub.height);
      canvas.drawPath(p, _fill(0.3));
    } else {
      _env(canvas, sub, g('noise_attack'), 0, g('noise_decay', 0.2), g('noise_dcurve'));
    }
    canvas.restore();
  }

  /// Partials as lines on a log axis: the metal's six, the resonator's modes, the FM's sidebands.
  void _lines(Canvas canvas, Size s, List<(double, double)> parts, {double? cut}) {
    for (final (f, a) in parts) {
      if (f < 20 || f > 20000) continue;
      final x = _fx(f, s.width);
      canvas.drawLine(Offset(x, s.height - 2), Offset(x, s.height - 2 - (s.height - 14) * a.clamp(0.0, 1.0)),
        Paint()..color = color..strokeWidth = 2.4..strokeCap = StrokeCap.round);
    }
    if (cut != null) {
      final x = _fx(cut, s.width);
      canvas.drawRect(Rect.fromLTRB(0, 0, x, s.height), Paint()..color = Neon.bg.withValues(alpha: 0.45));
      canvas.drawLine(Offset(x, 0), Offset(x, s.height), Paint()..color = Neon.dim..strokeWidth = 1);
    }
  }

  void _metal(Canvas canvas, Size s) {
    final set = g('metal_set').round().clamp(0, _metalRatios.length - 1);
    final stretch = 1 + 0.5 * g('metal_spread');
    final f = g('metal_freq', 410);
    _lines(canvas, s, [for (final r in _metalRatios[set]) (f * math.pow(r, stretch), 0.9)], cut: g('metal_tone', 7000));
    _label(canvas, '${_hz(f)} · decay ${(g('metal_decay', 0.05) * (1 + 15 * g('metal_open') * g('metal_open')) * 1000).round()} ms',
      const Offset(4, 2));
  }

  void _res(Canvas canvas, Size s) {
    final m = g('res_model').round().clamp(0, _modeRatios.length - 1);
    final f = g('res_freq', 150), br = g('res_bright', 0.5), damp = g('res_damp', 0.4), inh = g('res_inharm');
    final ratios = _modeRatios[m];
    _lines(canvas, s, [
      for (var k = 0; k < ratios.length; k++)
        (f * math.pow(ratios[k], 1 + 0.15 * inh), math.pow(0.35 + 0.6 * br, k) * (1 - damp * k / ratios.length) * 1.0),
    ]);
    _label(canvas, '${_hz(f)} · ${g('res_decay', 0.6).toStringAsFixed(2)} s', const Offset(4, 2));
  }

  void _fm(Canvas canvas, Size s) {
    final fc = g('fm_freq', 200), fm = fc * g('fm_ratio', 1.41), idx = g('fm_index', 3);
    final parts = <(double, double)>[(fc, 1)];
    for (var k = 1; k <= 6; k++) {
      final a = math.exp(-k / (idx * 0.6 + 0.2));
      parts..add((fc + k * fm, a))..add(((fc - k * fm).abs(), a * 0.8));
    }
    _lines(canvas, Size(s.width, s.height * 0.62), parts);
    // The depth's fall (index envelope) under the spectrum.
    canvas.save();
    canvas.translate(0, s.height * 0.62);
    _env(canvas, Size(s.width, s.height * 0.38), 0, 0, g('fm_idecay', 0.08), 0, span: g('fm_decay', 0.3) * 1.1);
    canvas.restore();
    _label(canvas, '${g('fm_ratio', 1.41).toStringAsFixed(2)} : 1', const Offset(4, 2));
  }

  void _phys(Canvas canvas, Size s) {
    // A string (a pipe: a tube) fixed at both ends, its first mode drawn, the pick marked.
    final pick = g('phys_pick', 0.2), m = g('phys_model').round();
    final p = Path();
    for (var i = 0; i <= 64; i++) {
      final x = i / 64;
      final tri = x < math.max(pick, 0.02) ? x / math.max(pick, 0.02) : (1 - x) / (1 - math.min(pick, 0.98));
      final y = s.height * 0.45 - (s.height * 0.32) * (m == 1 ? math.sin(math.pi * x) : tri);
      i == 0 ? p.moveTo(4, y) : p.lineTo(4 + (s.width - 8) * x, y);
    }
    if (m == 1) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(2, s.height * 0.1, s.width - 4, s.height * 0.38),
        const Radius.circular(10)), Paint()..color = Neon.dim..style = PaintingStyle.stroke);
    }
    canvas.drawPath(p, _line);
    final px = 4 + (s.width - 8) * pick;
    canvas.drawCircle(Offset(px, s.height * 0.13), 4, Paint()..color = Neon.yellow);
    canvas.save();
    canvas.translate(0, s.height * 0.55);
    _env(canvas, Size(s.width, s.height * 0.45), 0.001, 0, g('phys_decay', 1), 0);
    canvas.restore();
    _label(canvas, _hz(g('phys_freq', 110)), const Offset(4, 2));
  }

  void _tex(Canvas canvas, Size s) {
    final mode = g('tex_mode').round(), f = g('tex_freq', 3000), q = 0.2 + 0.8 * g('tex_res', 0.3);
    final top = Size(s.width, s.height * 0.6);
    if (mode == 0) {
      final f2 = f * math.pow(2, g('tex_spread', 1.5)), tilt = g('tex_tilt');
      final p = Path()..moveTo(0, top.height);
      for (var i = 0; i <= 100; i++) {
        final x = top.width * i / 100;
        double bump(double c, double a) => a * math.exp(-math.pow((x - _fx(c, top.width)) / (8 + 30 * (1 - q)), 2));
        final y = bump(f, 1 - 0.5 * (1 + tilt)) + bump(f2.toDouble(), 0.5 * (1 + tilt));
        p.lineTo(x, top.height - 2 - (top.height - 12) * y.clamp(0.0, 1.0));
      }
      p.lineTo(top.width, top.height);
      canvas.drawPath(p, _fill(0.4));
    } else {
      // Grains: one dot per grain over 0.3 s at the density (at most 120 drawn).
      final n = (g('tex_density', 1500) * 0.3).clamp(1, 120).round();
      final rnd = math.Random(7);
      for (var i = 0; i < n; i++) {
        final x = rnd.nextDouble() * top.width, a = mode == 2 ? rnd.nextDouble() * rnd.nextDouble() : 1.0;
        canvas.drawCircle(Offset(x, top.height - 4 - (top.height - 14) * a * rnd.nextDouble()), mode == 2 ? 2.2 : 1.4,
          Paint()..color = color.withValues(alpha: 0.85));
      }
      final fx = _fx(f, top.width);
      canvas.drawLine(Offset(fx, 0), Offset(fx, top.height), Paint()..color = Neon.yellow..strokeWidth = 1);
    }
    canvas.save();
    canvas.translate(0, s.height * 0.6);
    _env(canvas, Size(s.width, s.height * 0.4), g('tex_attack'), 0, g('tex_decay', 0.25), g('tex_dcurve'));
    canvas.restore();
    _label(canvas, _hz(f), const Offset(4, 2));
  }

  void _smp(Canvas canvas, Size s) {
    final a = g('smp_start'), b = g('smp_end', 1);
    final lo = math.min(a, b), hi = math.max(a, b);
    final rnd = math.Random(11);
    for (var i = 0; i < 60; i++) {
      final x = s.width * i / 60, inside = i / 60 >= lo && i / 60 <= hi;
      final hgt = (s.height * 0.4) * (0.3 + 0.7 * rnd.nextDouble()) * math.exp(-2.5 * i / 60);
      canvas.drawLine(Offset(x, s.height / 2 - hgt), Offset(x, s.height / 2 + hgt),
        Paint()..color = (inside ? color : Neon.dim).withValues(alpha: inside ? 0.9 : 0.3)..strokeWidth = 2);
    }
    for (final x in [lo, hi]) {
      canvas.drawLine(Offset(s.width * x, 0), Offset(s.width * x, s.height), Paint()..color = Neon.yellow..strokeWidth = 2);
    }
    if (g('smp_reverse') >= 0.5) _label(canvas, '◀ reverse', Offset(s.width - 4, 2), c: Neon.yellow, right: true);
  }

  /// A transfer curve: the drive's (or the kit drive's) waveshaper, the compressor's static curve, the clipper's.
  void _transfer(Canvas canvas, Size s) {
    final side = math.min(s.width, s.height * 1.6);
    final r = Rect.fromLTWH((s.width - side) / 2, 6, side, s.height - 12);
    canvas.drawLine(r.bottomLeft, r.topRight, Paint()..color = Neon.dim.withValues(alpha: 0.5));
    double f(double x) {
      switch (kind) {
        case 'drive' || 'kit_drive':
          final type = kind == 'drive' ? g('drive_type').round() : const [0, 1, 5, 2, 4][g('kit:kit_drive_type').round().clamp(0, 4)];
          final d = kind == 'drive' ? g('drive', 2) : g('kit:kit_drive', 2), mix = kind == 'drive' ? g('drive_mix', 1) : g('kit:kit_drive_mix', 1);
          final u = x * d;
          final y = switch (type) {
            0 => x,
            2 => u.clamp(-1.0, 1.0),
            3 => math.sin(u * math.pi / 2),
            4 => (u * 8).roundToDouble() / 8,
            5 => _tanh(u + 0.2) - _tanh(0.2),
            6 => u.abs() * 2 - 1,
            8 => x > 0 ? _tanh(2 * u) : _tanh(u),
            _ => _tanh(u),
          };
          return x + (y.clamp(-1.0, 1.0) - x) * mix;
        case 'kit_glue':
          final thr = g('kit:glue_threshold', -12), ratio = g('kit:glue_ratio', 4), amt = g('kit:glue');
          return _comp(x, thr, ratio, amt);
        case 'kit_clip':
          if (g('kit:kit_clip').round() == 0) return x;
          final u = x * math.pow(10, g('kit:kit_clip_gain') / 20);
          return g('kit:kit_clip').round() == 1 ? _tanh(u) : u.clamp(-1.0, 1.0);
        default:  // dyn: the compressor, then the clipper
          final c = g('comp');
          var y = c > 0 ? _comp(x, -6 - 24 * c, 1 + 9 * c, 1) : x;
          if (g('clip').round() != 0) {
            final u = y * math.pow(10, g('clip_gain') / 20);
            y = g('clip').round() == 1 ? _tanh(u) : u.clamp(-1.0, 1.0);
          }
          return y;
      }
    }
    final p = Path();
    for (var i = 0; i <= 80; i++) {
      final x = -1 + 2 * i / 80;
      final y = f(x).clamp(-1.0, 1.0);
      final pt = Offset(r.left + r.width * i / 80, r.center.dy - r.height / 2 * y);
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    canvas.drawPath(p, _line);
    if (kind == 'dyn') {
      _label(canvas, 'attack ${_signed(g('tr_attack'))} · sustain ${_signed(g('tr_sustain'))}', const Offset(4, 2));
    }
  }

  static String _signed(double x) => '${x >= 0 ? '+' : ''}${(x * 100).round()}%';
  static double _tanh(double x) {
    final e = math.exp(2 * x.clamp(-20.0, 20.0));
    return (e - 1) / (e + 1);
  }

  static double _comp(double x, double thrDb, double ratio, double amount) {
    final a = x.abs();
    if (a < 1e-6) return x;
    final db = 20 * math.log(a) / math.ln10;
    final out = db > thrDb ? thrDb + (db - thrDb) / ratio : db;
    final y = math.pow(10, (db + (out - db) * amount) / 20).toDouble();
    return x.sign * y;
  }

  /// A filter's response: a 2-pole low-pass, high-pass or band-pass (a 1-pole for LP 6 dB) at the cutoff.
  void _filter(Canvas canvas, Size s) {
    final type = g('flt').round(), fc = g('cutoff', 12000), q = 0.707 + 9 * math.pow(g('flt_res'), 2);
    final p = Path();
    for (var i = 0; i <= 100; i++) {
      final f = 20 * math.pow(1000, i / 100);
      final w = f / fc;
      double mag;
      switch (type) {
        case 0: mag = 1;
        case 1: mag = 1 / math.sqrt(1 + w * w);
        case 3: mag = w * w / math.sqrt(math.pow(1 - w * w, 2) + math.pow(w / q, 2));
        case 4: mag = (w / q) / math.sqrt(math.pow(1 - w * w, 2) + math.pow(w / q, 2));
        default: mag = 1 / math.sqrt(math.pow(1 - w * w, 2) + math.pow(w / q, 2));
      }
      final db = (20 * math.log(math.max(mag, 1e-4)) / math.ln10).clamp(-36.0, 18.0);
      final y = s.height * (0.35 - db / 54 * 0.65);
      i == 0 ? p.moveTo(0, y) : p.lineTo(s.width * i / 100, y);
    }
    canvas.drawPath(p, _line);
    final env = g('flt_env');
    if (env != 0 && type != 0) {  // the envelope's sweep: from cutoff × 2^env
      final x0 = _fx(fc * math.pow(2, env), s.width), x1 = _fx(fc, s.width);
      canvas.drawLine(Offset(x0, s.height - 6), Offset(x1, s.height - 6), Paint()..color = Neon.yellow..strokeWidth = 2);
      canvas.drawCircle(Offset(x0, s.height - 6), 3, Paint()..color = Neon.yellow);
    }
    if (type != 0) _label(canvas, _hz(fc), Offset(s.width - 4, 2), right: true);
  }

  void _eq(Canvas canvas, Size s) {
    final bands = kind == 'kit_eq'
        ? [(0, 100.0, g('kit:kit_low'), 0.707), (2, 8000.0, g('kit:kit_high'), 0.707)]
        : [(0, g('eq_low_freq', 120), g('eq_low'), 0.707), (1, g('eq_freq', 1000), g('eq_mid'), g('eq_q', 1)),
           (2, g('eq_high_freq', 6000), g('eq_high'), 0.707)];
    canvas.drawLine(Offset(0, s.height / 2), Offset(s.width, s.height / 2), Paint()..color = Neon.dim.withValues(alpha: 0.4));
    final p = Path();
    for (var i = 0; i <= 100; i++) {
      final f = 20 * math.pow(1000, i / 100);
      var db = 0.0;
      for (final (k, fc, gain, q) in bands) {
        final o = math.log(f / fc) / math.ln2;
        db += switch (k) {
          0 => gain / (1 + math.exp(4 * o)),
          2 => gain / (1 + math.exp(-4 * o)),
          _ => gain * math.exp(-math.pow(o * q * 1.2, 2)),
        };
      }
      final y = s.height / 2 - (s.height / 2 - 4) * (db / 18).clamp(-1.0, 1.0);
      i == 0 ? p.moveTo(0, y) : p.lineTo(s.width * i / 100, y);
    }
    canvas.drawPath(p, _line);
  }

  void _space(Canvas canvas, Size s) {
    // The stereo image: the voice's pan as a dot, its width as the span around it (the low end below width_hz stays
    // in the middle), the room send as a haze.
    final cx = s.width / 2 + (s.width / 2 - 12) * g('pan');
    final w = (s.width / 2 - 12) * g('width');
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(cx - w - 6, s.height * 0.3, cx + w + 6, s.height * 0.7),
      const Radius.circular(10)), _fill(0.25));
    canvas.drawCircle(Offset(s.width / 2, s.height / 2), 4, Paint()..color = Neon.yellow);
    canvas.drawCircle(Offset(cx, s.height / 2), 6, Paint()..color = color);
    canvas.drawRect(Rect.fromLTWH(0, s.height - 5, s.width * g('room_send'), 5), Paint()..color = Neon.violet.withValues(alpha: 0.8));
    _label(canvas, 'L', Offset(4, s.height / 2 - 6));
    _label(canvas, 'R', Offset(s.width - 4, s.height / 2 - 6), right: true);
    if (g('width') > 0) _label(canvas, 'mono below ${_hz(g('width_hz', 200))}', const Offset(4, 2));
  }

  void _bars(Canvas canvas, Size s, List<(String, double)> bars) {
    final w = s.width / bars.length;
    for (var i = 0; i < bars.length; i++) {
      final (name, a) = bars[i];
      final h = (s.height - 16) * a.clamp(0.0, 1.0);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(i * w + 6, s.height - 14 - h, w - 12, h), const Radius.circular(3)),
        Paint()..color = color.withValues(alpha: a > 0 ? 0.85 : 0.2));
      _label(canvas, name, Offset(i * w + w / 2 - name.length * 2.4, s.height - 12));
    }
  }

  /// A bar of 16ths: where each hit lands (swing and the groove move it late), how loud (its bar), the flam's grace
  /// hit before it, accented steps brighter.
  void _groove(Canvas canvas, Size s) {
    final step = s.width / 16;
    final groove = g('groove').round().clamp(0, drumGrooveSteps.length - 1), amt = g('groove_amt', 1);
    for (var k = 0; k < 16; k++) {
      canvas.drawLine(Offset(k * step, 0), Offset(k * step, s.height),
        Paint()..color = Neon.ink.withValues(alpha: k % 4 == 0 ? 0.18 : 0.07));
    }
    for (var k = 0; k < 16; k++) {
      var late = 0.0, vel = 0.8;
      if (g('swing_grid').round() == 0 && k.isOdd) late += g('swing') * 0.5;
      if (g('swing_grid').round() == 1 && k % 4 == 2) late += g('swing');
      if (groove > 0) {
        final (l, sc) = drumGrooveSteps[groove][k];
        late += amt * l;
        vel *= 1 + amt * (sc - 1);
      }
      final on = g('accent') > 0 && switch (g('accent_on').round()) { 0 => k % 4 == 0, 1 => k == 0, 2 => k % 4 == 2, _ => false };
      if (on) vel = math.min(1, vel * (1 + 0.5 * g('accent')));
      final x = (k + late) * step + step / 2, h = (s.height - 8) * vel;
      final c = on ? Neon.yellow : color;
      if (g('flam') > 0) {
        final gx = x - g('flam_time', 0.02) / 0.125 * step;  // at 120 BPM a 16th is 125 ms
        canvas.drawLine(Offset(gx, s.height - 2), Offset(gx, s.height - 2 - h * (0.25 + 0.5 * g('flam'))),
          Paint()..color = c.withValues(alpha: 0.5)..strokeWidth = 2);
      }
      canvas.drawLine(Offset(x, s.height - 2), Offset(x, s.height - 2 - h), Paint()..color = c..strokeWidth = 3..strokeCap = StrokeCap.round);
      if (g('humanize') > 0) {
        canvas.drawLine(Offset(x, s.height - 3), Offset(x + step * 0.4 * g('humanize'), s.height - 3),
          Paint()..color = Neon.dim..strokeWidth = 2);
      }
    }
  }

  void _var(Canvas canvas, Size s) {
    // Level against velocity (a soft hit's), and the random spread as a halo of dots.
    final p = Path();
    for (var i = 0; i <= 40; i++) {
      final vel = i / 40, lvl = (1 + g('vel_level', 1) * (vel - 1)).clamp(0.0, 1.0);
      final pt = Offset(4 + (s.width * 0.5 - 8) * vel, s.height - 4 - (s.height - 10) * lvl);
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    canvas.drawPath(p, _line);
    _label(canvas, 'velocity', Offset(4, s.height - 12));
    final rnd = math.Random(5);
    final c = Offset(s.width * 0.78, s.height / 2);
    final spreadX = (g('rnd_pan') + g('rnd_pitch') / 100) * s.width * 0.18, spreadY = (g('rnd_level') + g('rnd_decay') + g('rnd_tone')) * s.height * 0.15;
    for (var i = 0; i < 18; i++) {
      canvas.drawCircle(c + Offset((rnd.nextDouble() * 2 - 1) * spreadX, (rnd.nextDouble() * 2 - 1) * spreadY), 2.4,
        Paint()..color = color.withValues(alpha: 0.7));
    }
    _label(canvas, 'per hit', Offset(s.width - 4, s.height - 12), right: true);
  }

  void _pad(Canvas canvas, Size s) {
    final lvl = ((g('level') + 60) / 72).clamp(0.0, 1.0);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, s.height - 8, s.width * lvl, 6), const Radius.circular(3)), _fill(0.9));
    final cx = s.width / 2 + (s.width / 2 - 8) * g('pan');
    canvas.drawCircle(Offset(cx, s.height * 0.4), 6, Paint()..color = color);
    canvas.drawLine(Offset(s.width / 2, s.height * 0.2), Offset(s.width / 2, s.height * 0.6), Paint()..color = Neon.dim);
    final gate = g('trig').round() == 1;
    _label(canvas, '${gate ? 'Gate' : 'One-shot'} · ${g('poly', 2).round()} voices${g('choke').round() > 0 ? ' · choke ${g('choke').round()}' : ''}',
      const Offset(4, 2));
  }

  void _room(Canvas canvas, Size s) {
    final pre = g('kit:room_predelay') / 1000, d = g('kit:room_decay', 0.8);
    final span = (pre + d * 1.2).clamp(0.2, 6.0);
    final rnd = math.Random(9);
    for (var i = 0; i < 90; i++) {
      final t = pre + rnd.nextDouble() * (span - pre);
      final a = math.exp(-6.9 * (t - pre) / d) * g('kit:room') * (0.5 + 0.5 * g('kit:room_size', 0.35));
      final x = s.width * t / span;
      canvas.drawLine(Offset(x, s.height - 2), Offset(x, s.height - 2 - (s.height - 12) * a * rnd.nextDouble()),
        Paint()..color = Neon.violet.withValues(alpha: 0.7)..strokeWidth = 1.5);
    }
    _label(canvas, '${d.toStringAsFixed(1)} s', Offset(s.width - 4, 2), right: true);
  }

  void _echo(Canvas canvas, Size s) {
    const beats = [0.0, 0.25, 0.5, 0.75, 1.0, 1 / 3];
    final sync = g('kit:echo_sync').round().clamp(0, 5);
    final time = sync == 0 ? g('kit:echo_time', 0.375) : beats[sync] * 0.5;  // at 120 BPM
    final fb = g('kit:echo_feedback', 0.35), spread = g('kit:echo_spread', 0.6);
    final span = math.max(time * 6, 0.4);
    for (var k = 0; k < 12; k++) {
      final t = time * (k + 1);
      if (t > span) break;
      final a = math.pow(fb, k) * g('kit:echo');
      final x = s.width * t / span, h = (s.height / 2 - 4) * a;
      final up = spread > 0.3 ? k.isEven : true;
      canvas.drawLine(Offset(x, s.height / 2), Offset(x, s.height / 2 + (up ? -h : h)),
        Paint()..color = color..strokeWidth = 3..strokeCap = StrokeCap.round);
    }
    canvas.drawLine(Offset(0, s.height / 2), Offset(s.width, s.height / 2), Paint()..color = Neon.dim.withValues(alpha: 0.4));
    _label(canvas, '${(time * 1000).round()} ms', Offset(s.width - 4, 2), right: true);
  }

  @override
  bool shouldRepaint(covariant DrumVisualPainter o) {
    if (o.kind != kind || o.color != color || o.v.length != v.length) return true;
    for (final e in v.entries) {
      if (o.v[e.key] != e.value) return true;
    }
    return false;
  }
}
