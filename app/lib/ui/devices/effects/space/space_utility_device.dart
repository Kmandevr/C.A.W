// The Utility/Stereo merged device's page: a goniometer and correlation meter over the variant cards, then width, balance, Haas, mono-below and channel swap as the variant has them.
import '../../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../model/device_target.dart';
import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';
import 'space_devices.dart';
import 'space_fx.dart' show SpaceBar, liveHero;
import 'space_fx_stereo.dart' show ImagerHero;

/// The pad each variant's goniometer drags (across, up; null: none): Utility pan and width, Width its width, Balance
/// its pan, Haas the delay and the delayed side's level; the Mixer's cells are knobs.
const _pads = <int, (String?, String?)>{0: ('pan', 'width'), 1: (null, 'width'), 2: ('pan', null), 4: ('delay', 'level')};

/// Utility/Stereo: its six variants as cards; the goniometer (side across, mid up: a vertical line is mono, a wide
/// cloud is wide; the Imager's from the engine's scope with its bands' widths dragged over it, the others ≈ from the
/// knobs and the engine's correlation) and the correlation meter; then each variant's controls.
class UtilityDevicePage extends StatelessWidget {
  const UtilityDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final variant = variantOf(context);
    final hero = variant == 3
        ? liveHero(context: context, caption: 'GONIOMETER · BANDS', height: 210, readout: const Text('drag a band'),
            builder: (context, secs, v) => ImagerHero(values: v))
        : liveHero(context: context, caption: 'GONIOMETER ≈', height: 210,
            readout: Builder(builder: (context) => Text(_readout(t, variant))),
            builder: (context, secs, v) => _GonioHero(variant: variant, secs: secs, live: v));
    return mergedPage(context, 'utility',
      cards: VariantCards(icon: _variantIcon, height: 50),
      hero: HeroWithMeters(height: 210, gr: false, hero: hero),
      rows: [
        DeviceDisplay(builder: (context, f) => Column(mainAxisSize: MainAxisSize.min, children: [
          SpaceBar(label: 'CORRELATION', value: f?.values['correlation'],
              text: f?.values['correlation'] == null ? (variant == 1 || variant == 2 ? 'no meter' : '—') : null),
          if (variant == 4) SpaceBar(label: 'MONO LOSS', value: f?.values['mono_loss_db'], lo: -12, hi: 0, centred: false,
              text: f == null ? '—' : '${(f.values['mono_loss_db'] ?? 0).toStringAsFixed(1)} dB'),
        ])),
        if (variant == 0) ...[
          controlsRow([smallLabel('CHANNELS'), const DeviceChoice('channels', maxSegments: 5)]),
          Wrap(spacing: 6, runSpacing: 6, children: const [
            DeviceToggle('bass_mono', label: 'Mono below', icon: Icons.speaker_outlined),
            DeviceToggle('invert_l', label: 'Ø Left', icon: Icons.swap_vert),
            DeviceToggle('invert_r', label: 'Ø Right', icon: Icons.swap_vert),
          ]),
        ],
        if (variant == 4) controlsRow([
          smallLabel('DELAYED'), const DeviceChoice('side', maxSegments: 2),
          const DeviceToggle('mono_check', label: 'Mono check', icon: Icons.speaker_phone_outlined),
        ]),
      ],
      knobs: KnobRow(switch (variant) {
        0 => ['width', 'pan', 'gain', if (t.value('bass_mono') >= 0.5) 'bass_freq'],
        1 => const ['width'],
        2 => const ['pan'],
        3 => const ['low_width', 'mid_width', 'high_width', 'low_freq', 'high_freq'],
        4 => const ['delay', 'level', 'guard'],
        _ => const ['left_to_left', 'right_to_left', 'left_to_right', 'right_to_right'],
      }, size: variant == 1 || variant == 2 ? 60 : 48, labels: const {'pan': 'Balance', 'bass_freq': 'Mono below', 'guard': 'Mono below'}),
      more: switch (variant) {
        0 => const ParamGrid(only: ['dc_block']),
        3 => const ParamGrid(only: ['mid_gain', 'side_gain']),
        _ => null,
      },
    );
  }

  static String _readout(DeviceTarget t, int variant) => switch (variant) {
    0 || 1 => 'width ${(t.value('width') * 100).round()}%',
    2 => 'balance ${formatParamValue(t.param('pan'), t.value('pan'), pan: true)}',
    4 => '${formatParamValue(t.param('delay'), t.value('delay'))} ms',
    _ => 'out ← in',
  };
}

void _variantIcon(Canvas canvas, Rect r, int index, Color color) {
  final c = r.center;
  final rad = math.min(r.width, r.height) * 0.45;
  final s = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.6
    ..strokeCap = StrokeCap.round;
  final f = Paint()..color = color;
  switch (index) {
    case 0: // gain and the field: a fader cap over a fan
      canvas.drawArc(Rect.fromCircle(center: c + Offset(0, rad * 0.6), radius: rad), math.pi * 1.2, math.pi * 0.6, false, s);
      canvas.drawLine(c + Offset(0, rad * 0.6), c + Offset(0, -rad * 0.4), s);
    case 1: // width: arrows apart
      canvas.drawLine(c - Offset(rad, 0), c + Offset(rad, 0), s);
      for (final d in [-1.0, 1.0]) {
        canvas.drawLine(c + Offset(d * rad, 0), c + Offset(d * (rad - 5), -4), s);
        canvas.drawLine(c + Offset(d * rad, 0), c + Offset(d * (rad - 5), 4), s);
      }
    case 2: // balance: a puck off centre on a line
      canvas.drawLine(c - Offset(rad, 0), c + Offset(rad, 0), s..color = color.withValues(alpha: 0.5));
      canvas.drawCircle(c + Offset(rad * 0.4, 0), 4, f);
    case 3: // imager: three bars
      for (var k = 0; k < 3; k++) {
        final hh = rad * (0.6 + 0.4 * ((k + 1) % 3) / 2);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: c + Offset((k - 1) * rad * 0.7, rad - hh / 2), width: 5, height: hh), const Radius.circular(2)), f);
      }
    case 4: // haas: two spikes, one late
      canvas.drawLine(c + Offset(-rad * 0.6, rad * 0.6), c + Offset(-rad * 0.6, -rad * 0.6), s);
      canvas.drawLine(c + Offset(rad * 0.2, rad * 0.6), c + Offset(rad * 0.2, -rad * 0.3), s..color = color.withValues(alpha: 0.6));
    default: // mixer: a 2 x 2 grid
      for (var k = 0; k < 4; k++) {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: c + Offset((k % 2 - 0.5) * rad, (k ~/ 2 - 0.5) * rad),
            width: rad * 0.8, height: rad * 0.8), const Radius.circular(2)), k == 0 || k == 3 ? f : (s..color = color));
      }
  }
}

/// The goniometer of the variants without a scope ≈: a cloud of points of a stereo signal as the knobs make it
/// (width scales the side, pan and balance tip it, Mono, Left, Right and Swap fold or turn it, Haas widens it by
/// its delay), its width matched to the engine's correlation while it plays; drags on the variant's pad.
class _GonioHero extends StatefulWidget {
  const _GonioHero({required this.variant, required this.secs, required this.live});
  final int variant;
  final double secs;
  final Map<String, double>? live;

  @override
  State<_GonioHero> createState() => _GonioHeroState();
}

class _GonioHeroState extends State<_GonioHero> {
  bool _active = false;
  double _x = 0, _y = 0, _width0 = 1;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final (xId, yId) = _pads[widget.variant] ?? (null, null);
    final px = xId == null ? null : t.param(xId), py = yId == null ? null : t.param(yId);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final painter = GoniometerPainter(points: gonioPoints(t, widget.variant, widget.secs, widget.live?['correlation']),
          color: scope.accent, second: scope.secondary, active: _active,
          swap: widget.variant == 0 && t.value('channels').round() == 4);
      if (px == null && py == null) return CustomPaint(size: Size(w, h), painter: painter);
      return GrabGesture(
        key: const ValueKey('utility-hero'),
        onStart: (_, _) {
          _x = px == null ? 0 : taperOf(px).position(t.value(px.id));
          _y = py == null ? 0 : taperOf(py).position(t.value(py.id));
          _width0 = t.value('width');
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          if (u.pointers >= 2 && py?.id == 'width') {
            // A pinch: the width by the fingers' spread.
            t.setLive('width', (_width0 * u.scale).clamp(py!.min, py.max));
            return;
          }
          if (px != null) {
            final before = _x;
            _x = (_x + u.delta.dx / w * fine).clamp(0.0, 1.0);
            final mid = taperOf(px).position(px.defaultValue);
            if ((before - mid) * (_x - mid) < 0) DeviceFeel.detent();
            t.setLive(px.id, (_x - mid).abs() < 0.01 ? px.defaultValue : taperOf(px).value(_x));
          }
          if (py != null) {
            _y = (_y - u.delta.dy / h * fine).clamp(0.0, 1.0);
            t.setLive(py.id, taperOf(py).value(_y));
          }
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({if (px != null) px.id: px.defaultValue, if (py != null) py.id: py.defaultValue}),
        child: CustomPaint(size: Size(w, h), painter: painter),
      );
    });
  }
}

/// 160 (side, mid) points ≈ of what [variant] makes of a stereo signal at [secs] (−1..1), with the engine's
/// correlation [corr] when it plays.
List<Offset> gonioPoints(DeviceTarget t, int variant, double secs, double? corr) {
  double v(String id, double or) => t.param(id) == null ? or : t.value(id);
  var seed = 1 + (secs * 30).floor();
  double rand() {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return seed / 0x7FFFFFFF * 2 - 1;
  }
  // The side's share: from the engine's correlation (ρ: S/M = √((1 − ρ)/(1 + ρ))), else a typical mix's 0.45.
  final rho = corr?.clamp(-0.99, 0.99);
  final base = rho == null ? 0.45 : math.sqrt((1 - rho) / (1 + rho));
  final width = switch (variant) { 0 || 1 => v('width', 1), 4 => 1 + v('delay', 12) / 20, _ => 1.0 };
  final sideShare = rho == null ? base * width : base;
  final pan = variant == 0 || variant == 2 ? v('pan', 0) : 0.0;
  final channels = variant == 0 ? v('channels', 0).round() : 0;
  final out = <Offset>[];
  for (var i = 0; i < 160; i++) {
    // Sums of three: a rounded cloud, denser at the centre, as music's is.
    final a = (rand() + rand() + rand()) * 0.33, b = (rand() + rand() + rand()) * 0.33 * sideShare;
    var l = a + b, r = a - b;
    if (variant == 5) {
      final ll = l * v('left_to_left', 1) + r * v('right_to_left', 0);
      final rr = l * v('left_to_right', 0) + r * v('right_to_right', 1);
      l = ll;
      r = rr;
    }
    switch (channels) {
      case 1:
        l = r = (l + r) / 2;
      case 2:
        r = l;
      case 3:
        l = r;
      case 4:
        final x = l;
        l = r;
        r = x;
    }
    if (variant == 0) {
      if (v('invert_l', 0) >= 0.5) l = -l;
      if (v('invert_r', 0) >= 0.5) r = -r;
    }
    l *= math.min(1, 1 - pan);
    r *= math.min(1, 1 + pan);
    out.add(Offset((l - r) / 2, (l + r) / 2));
  }
  return out;
}

/// A goniometer: side across (left to the left), mid up, the ±45° lines where a hard-left or hard-right signal
/// falls, the points glowing.
class GoniometerPainter extends CustomPainter {
  GoniometerPainter({required this.points, required this.color, required this.second, required this.active, this.swap = false});
  final List<Offset> points;
  final Color color, second;
  final bool active, swap;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2 + 8);
    final r = math.min(size.width, size.height) / 2 - 20;
    final faint = Paint()
      ..color = Neon.ink.withAlpha(0x1F)
      ..style = PaintingStyle.stroke;
    final diamond = Path()
      ..moveTo(c.dx, c.dy - r)
      ..lineTo(c.dx + r, c.dy)
      ..lineTo(c.dx, c.dy + r)
      ..lineTo(c.dx - r, c.dy)
      ..close();
    canvas.drawPath(diamond, faint);
    canvas.drawLine(c - Offset(0, r), c + Offset(0, r), faint);
    canvas.drawLine(c - Offset(r / 2, r / 2), c + Offset(r / 2, r / 2), faint);
    canvas.drawLine(c - Offset(-r / 2, r / 2), c + Offset(-r / 2, r / 2), faint);
    paintLabel(canvas, 'M', c - Offset(0, r + 8), Neon.dim, size: 8, align: 0, weight: FontWeight.w800);
    paintLabel(canvas, 'L', c + Offset(-r / 2 - 8, -r / 2 - 6), color, size: 9, align: 0, weight: FontWeight.w800);
    paintLabel(canvas, 'R', c + Offset(r / 2 + 8, -r / 2 - 6), second, size: 9, align: 0, weight: FontWeight.w800);
    final dot = Paint();
    for (final p in points) {
      // Side across: left (L > R, positive side) to the left.
      final at = c + Offset(-p.dx * r, -p.dy * r);
      dot.color = Color.lerp(color, second, (0.5 - p.dx).clamp(0.0, 1.0))!.withValues(alpha: active ? 0.9 : 0.7);
      canvas.drawCircle(at, 1.7, dot);
    }
    if (swap) paintLabel(canvas, 'L ⇄ R', c + Offset(0, r + 4), Neon.text, size: 9, align: 0, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant GoniometerPainter o) =>
      paintInputsChanged([o.points, o.color, o.second, o.active, o.swap], [points, color, second, active, swap]);
}
