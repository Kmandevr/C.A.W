// Timber's instrument picture: each model's strings, bars, drawbars or bore drawn live from the display data, with a woodpecker perched at the strike point (its one motif), and the model cards' icons.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/device_display.dart';
import '../../theme.dart';
import '../kit/hero.dart';

/// The models in `variant` order (engine/src/builtin_timber.cpp), as the cards name them.
const timberModels = ['Piano', 'E. piano', 'Organ', 'Pluck', 'Bowed', 'Mallet', 'Winds'];

/// Model indices.
abstract final class TimberModel {
  static const piano = 0, epiano = 1, organ = 2, plucked = 3, bowed = 4, mallets = 5, winds = 6;
}

/// The organ's drawbars in order, with their footages in feet (ASCII: the mono font has no ⅓).
const organDrawbars = ['db16', 'db513', 'db8', 'db4', 'db223', 'db2', 'db135', 'db113', 'db1'];
const organFootages = ['16', '5 1/3', '8', '4', '2 2/3', '2', '1 3/5', '1 1/3', '1'];

/// What Timber's display frame says (docs/engine.md, Display data, `org.caw.timber`): the shared floats 0–8, the
/// model's own from 9.
class TimberFrame {
  const TimberFrame(this.f);
  final DeviceDisplayFrame? f;
  double _at(int i, [double d = 0]) => f?.at(i, d) ?? d;
  bool get live => f != null && _at(0) >= 1;
  int get model => _at(1).round();
  int get sounding => _at(2).round();
  int get cap => _at(3).round();
  double get peakDb => _at(4, -120);
  double get pedal => _at(5);
  int get lastKey => _at(6, -1).round();
  double get lastVelocity => _at(7);
  int get notes => _at(8).round();
  double own(int i) => _at(9 + i);
}

/// The values the picture draws: the device's knobs it shows ([value]) and the newest frame.
class TimberPicture {
  const TimberPicture({required this.model, required this.value, required this.frame, required this.seconds,
    required this.accent, required this.secondary});
  final int model;
  final double Function(String id) value;
  final TimberFrame frame;
  final double seconds;
  final Color accent, secondary;

  /// How much the instrument is sounding, 0..1 (the output peak over 54 dB).
  double get energy => frame.live && frame.sounding > 0 ? dbUnit(frame.peakDb, floor: 54) : 0;
}

/// Where a drag on the picture goes for [model]: the parameter and whether it moves sideways (else up and down);
/// the organ's drawbars are their own drag ([organDrawbars]). Null: no drag.
({String id, bool horizontal})? timberGrab(int model) => switch (model) {
      TimberModel.piano => (id: 'hammer', horizontal: false),
      TimberModel.epiano => (id: 'pickup', horizontal: false),
      TimberModel.plucked || TimberModel.bowed || TimberModel.mallets => (id: 'position', horizontal: true),
      TimberModel.winds => (id: 'breath', horizontal: false),
      _ => null,
    };

/// The organ's drawbar under [x] in a picture [width] wide.
int organBarAt(double x, double width) {
  final r = _organArea(Size(width, 1));
  return ((x - r.left) / (r.width / 9)).floor().clamp(0, 8);
}

Rect _organArea(Size s) => Rect.fromLTWH(s.width * 0.06, 0, s.width * 0.62, s.height);

class TimberPainter extends CustomPainter {
  TimberPainter(this.p);
  final TimberPicture p;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    switch (p.model) {
      case TimberModel.piano:
        _piano(canvas, size);
      case TimberModel.epiano:
        _epiano(canvas, size);
      case TimberModel.organ:
        _organ(canvas, size);
      case TimberModel.plucked:
        _plucked(canvas, size);
      case TimberModel.bowed:
        _bowed(canvas, size);
      case TimberModel.mallets:
        _mallets(canvas, size);
      default:
        _winds(canvas, size);
    }
  }

  Paint _line(Color c, double w) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round;

  /// A string from [a] to [b], shaking as its first mode with [amp] px at time [t] and rate [hz].
  void _string(Canvas canvas, Offset a, Offset b, Color c, double w, double amp, double hz, {double glow = 0}) {
    if (amp < 0.2) {
      canvas.drawLine(a, b, _line(c, w));
      return;
    }
    final path = Path()..moveTo(a.dx, a.dy);
    final d = b - a;
    final n = Offset(-d.dy, d.dx) / d.distance;
    final s = math.sin(p.seconds * hz * 2 * math.pi);
    for (var i = 1; i <= 24; i++) {
      final u = i / 24;
      final pt = a + d * u + n * (amp * s * math.sin(math.pi * u));
      path.lineTo(pt.dx, pt.dy);
    }
    glow > 0 ? strokeGlow(canvas, path, c, width: w) : canvas.drawPath(path, _line(c, w));
  }

  /// The struck string's index among [count] for the last key (spread over the keyboard's 88).
  int _struck(int count) {
    final k = p.frame.lastKey;
    if (k < 0) return -1;
    return ((k - 21).clamp(0, 87) / 88 * count).floor().clamp(0, count - 1);
  }

  double get _amp => p.energy * (0.4 + 0.6 * p.frame.lastVelocity.clamp(0, 1));

  // ---------- Piano: a grand's soundboard with its strings, the hammer line and the dampers ----------
  void _piano(Canvas canvas, Size s) {
    final top = s.height * 0.2, bottom = s.height * 0.92;
    final left = s.width * 0.05, rightLong = s.width * 0.94, rightShort = s.width * 0.42;
    // The case: a grand's bentside, long in the bass (bottom), short in the treble (top).
    final body = Path()
      ..moveTo(left, top)
      ..lineTo(rightShort, top)
      ..cubicTo(rightShort + s.width * 0.18, top, rightLong - s.width * 0.12, bottom - s.height * 0.35, rightLong, bottom - s.height * 0.12)
      ..lineTo(rightLong, bottom)
      ..lineTo(left, bottom)
      ..close();
    canvas.drawPath(body, Paint()..color = p.accent.withValues(alpha: 0.07 + 0.1 * p.value('body')));
    canvas.drawPath(body, _line(p.accent.withValues(alpha: 0.5), 1.4));
    const count = 18;
    final strings = p.frame.live ? p.frame.own(3).round().clamp(1, 3) : 2;
    final hit = _struck(count);
    final felt = p.value('character').round() == 2;
    final soft = p.value('soft');
    final hammerX = left + (s.width * 0.1) + soft * 4;
    final pedal = math.max(p.value('sustain'), p.frame.pedal);
    for (var i = 0; i < count; i++) {
      // Treble (i = count - 1) at the top; its string ends where the bentside is at that height.
      final u = i / (count - 1);
      final y = bottom - 6 - u * (bottom - top - 12);
      final end = _bentsideX(s, y, left, top, bottom, rightShort, rightLong) - 6;
      final struck = i == hit;
      final c = struck ? p.accent : Neon.ink.withValues(alpha: 0.35);
      for (var k = 0; k < (struck ? strings : 1); k++) {
        _string(canvas, Offset(left + 8, y + k * 1.6), Offset(end, y + k * 1.6), c, struck ? 1.4 : 0.9,
            struck ? _amp * 4 : 0, 7 + u * 6, glow: struck ? 1 : 0);
      }
      // A damper over each string below F#6 (the top fifth has none); lifted with the pedal.
      if (u < 0.82) {
        final lift = pedal * 4;
        canvas.drawRect(Rect.fromLTWH(end - 14, y - 3 - lift, 7, 3), Paint()..color = Neon.dim.withValues(alpha: 0.55));
      }
    }
    // Felt: a strip of felt between hammers and strings.
    if (felt) {
      canvas.drawRect(Rect.fromLTRB(hammerX - 5, top + 2, hammerX + 3, bottom - 2), Paint()..color = p.secondary.withValues(alpha: 0.18));
    }
    // The hammer line; its height shows how hard the hammer is.
    final hard = p.value('hammer');
    canvas.drawLine(Offset(hammerX, top + 4), Offset(hammerX, bottom - 4), _line(p.secondary.withValues(alpha: 0.35 + 0.5 * hard), 1.2));
    final hy = hit < 0 ? (top + bottom) / 2 : bottom - 6 - hit / (count - 1) * (bottom - top - 12);
    paintWoodpecker(canvas, Offset(hammerX, hy - 2), s.height * 0.16, p.accent, beak: 0.3 + 0.7 * hard);
  }

  double _bentsideX(Size s, double y, double left, double top, double bottom, double rs, double rl) {
    // Along the cubic from (rs, top) to (rl, bottom - 0.12h): solve by sampling.
    final a = Offset(rs, top), b = Offset(rs + s.width * 0.18, top), c = Offset(rl - s.width * 0.12, bottom - s.height * 0.35),
        d = Offset(rl, bottom - s.height * 0.12);
    if (y >= d.dy) return rl;
    var best = rs;
    for (var i = 0; i <= 40; i++) {
      final t = i / 40, m = 1 - t;
      final pt = a * (m * m * m) + b * (3 * m * m * t) + c * (3 * m * t * t) + d * (t * t * t);
      if (pt.dy <= y) best = pt.dx;
    }
    return best;
  }

  // ---------- Electric piano: tines and tonebars over their pickups ----------
  void _epiano(Canvas canvas, Size s) {
    const count = 9;
    final hit = _struck(count);
    final reed = p.value('kind').round() == 1;
    final dist = p.value('pickup');
    final top = s.height * 0.2, step = (s.height * 0.74) / count;
    final anchor = s.width * 0.1, tip = s.width * 0.72;
    canvas.drawRect(Rect.fromLTRB(anchor - 8, top - 4, anchor, top + step * count), Paint()..color = Neon.ink.withValues(alpha: 0.18));
    for (var i = 0; i < count; i++) {
      final y = top + step * (i + 0.5);
      final struck = count - 1 - i == hit;
      final c = struck ? p.accent : Neon.ink.withValues(alpha: 0.4);
      final len = (tip - anchor) * (1 - i / count * 0.45);
      // The tonebar (Tine) above, or the reed alone.
      if (!reed) canvas.drawLine(Offset(anchor, y - 4), Offset(anchor + len * 0.8, y - 4), _line(Neon.dim.withValues(alpha: 0.45), 2.4));
      final sway = struck ? _amp * 5 * math.sin(p.seconds * 2 * math.pi * 6) : 0.0;
      final path = Path()
        ..moveTo(anchor, y)
        ..quadraticBezierTo(anchor + len * 0.6, y, anchor + len, y + sway);
      struck ? strokeGlow(canvas, path, c, width: 1.6) : canvas.drawPath(path, _line(c, 1.1));
      // The pickup: nearer the tip as `pickup` falls (a close pickup barks).
      final px = anchor + len + 5 + dist * 14;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(px, y), width: 6, height: step * 0.7),
          const Radius.circular(2)), Paint()..color = (struck ? p.secondary : Neon.dim).withValues(alpha: 0.7));
    }
    // The tremolo: an auto-pan (Tine) or a level (Reed) swinging at its phase.
    final depth = p.frame.live ? p.frame.own(2) : p.value('tremolo');
    if (depth > 0.01) {
      final ph = p.frame.live ? p.frame.own(1) : 0.25;
      final x = s.width * 0.86, y = s.height * 0.55, w = s.width * 0.08;
      canvas.drawLine(Offset(x - w, y), Offset(x + w, y), _line(Neon.dim.withValues(alpha: 0.5), 1));
      canvas.drawCircle(Offset(x + w * depth * math.sin(ph * 2 * math.pi), y), 4, Paint()..color = p.secondary);
      paintLabel(canvas, reed ? 'TREM' : 'PAN', Offset(x, y + 12), Neon.dim, size: 8, align: 0);
    }
    final y = top + step * ((hit < 0 ? count ~/ 2 : count - 1 - hit) + 0.5);
    final len = (tip - anchor) * (1 - (hit < 0 ? count ~/ 2 : count - 1 - hit) / count * 0.45);
    paintWoodpecker(canvas, Offset(anchor + len + 5 + dist * 14, y - step * 0.35), s.height * 0.15, p.accent);
  }

  // ---------- Organ: nine drawbars (drag one to pull it) and the rotary's horn ----------
  void _organ(Canvas canvas, Size s) {
    final r = _organArea(s);
    final w = r.width / 9;
    final top = s.height * 0.16, bottom = s.height * 0.86;
    canvas.drawLine(Offset(r.left, top), Offset(r.right, top), _line(Neon.ink.withValues(alpha: 0.3), 1.2));
    final brown = Color.lerp(_orangeOf(), Neon.bg, 0.25)!;
    for (var k = 0; k < 9; k++) {
      final v = p.value(organDrawbars[k]).clamp(0.0, 8.0);
      final x = r.left + w * (k + 0.5);
      // Brown for the sub-harmonics, black for the off-octave ones, white for the octaves (as on the organ).
      final c = k < 2 ? brown : const {4, 6, 7}.contains(k) ? Neon.dim : Neon.ink.withValues(alpha: 0.85);
      final len = (bottom - top - 16) * v / 8;
      final bar = Rect.fromLTWH(x - w * 0.18, top, w * 0.36, len + 8);
      canvas.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(2)), Paint()..color = c.withValues(alpha: 0.3 + 0.07 * v));
      // The handle at the bar's end, lit while keys are held.
      final held = p.frame.live && p.frame.own(1) > 0 && v > 0;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, top + len + 8), width: w * 0.62, height: 8),
          const Radius.circular(3)), Paint()..color = held ? p.accent : c);
      for (var step = 1; step < 9; step++) {
        final ty = top + (bottom - top - 16) * step / 8;
        if (ty < top + len) canvas.drawLine(Offset(x - w * 0.12, ty), Offset(x + w * 0.12, ty), _line(Neon.bg.withValues(alpha: 0.5), 0.8));
      }
      paintLabel(canvas, organFootages[k], Offset(x, bottom + 6), Neon.dim, size: 7.5, align: 0);
      paintLabel(canvas, '${v.round()}', Offset(x, top - 7), held ? p.accent : Neon.dim, size: 8, align: 0, weight: FontWeight.w800);
    }
    // The rotary: the horn turning at its angle (the engine's), a drum below it.
    final rot = p.value('rotary').round();
    final cx = s.width * 0.84, cy = s.height * 0.42, rr = math.min(s.width * 0.1, s.height * 0.26);
    canvas.drawCircle(Offset(cx, cy), rr, _line(Neon.ink.withValues(alpha: rot == 0 ? 0.15 : 0.4), 1.2));
    if (rot > 0) {
      final horn = p.frame.live ? p.frame.own(4) * 2 * math.pi : p.seconds * (rot == 2 ? 6.5 : 0.8) * 2 * math.pi;
      final drum = p.frame.live ? p.frame.own(5) * 2 * math.pi : p.seconds * (rot == 2 ? 5.7 : 0.7) * 2 * math.pi;
      final a = Offset(math.cos(horn), math.sin(horn) * 0.45) * rr;
      strokeGlow(canvas, Path()..moveTo(cx - a.dx, cy - a.dy)..lineTo(cx + a.dx, cy + a.dy), p.accent, width: 3);
      canvas.drawCircle(Offset(cx + a.dx, cy + a.dy), 4, Paint()..color = p.accent);
      final dy = cy + rr * 1.25;
      canvas.drawOval(Rect.fromCenter(center: Offset(cx, dy), width: rr * 1.8, height: rr * 0.5), _line(Neon.dim, 1));
      canvas.drawCircle(Offset(cx + math.cos(drum) * rr * 0.9, dy + math.sin(drum) * rr * 0.25), 3, Paint()..color = p.secondary);
    }
    paintLabel(canvas, const ['OFF', 'SLOW', 'FAST', 'BRAKE'][rot.clamp(0, 3)], Offset(cx, s.height * 0.9), Neon.dim, size: 8, align: 0);
    // The woodpecker on the cabinet's top rail, by the rotary.
    paintWoodpecker(canvas, Offset(cx - rr * 1.35, cy - rr * 0.7), s.height * 0.15, p.accent);
  }

  Color _orangeOf() => Neon.layers.length > 5 ? Neon.layers[5] : Neon.yellow;

  // ---------- Plucked: strings over a guitar body, a harp's frame or a koto's board ----------
  void _plucked(Canvas canvas, Size s) {
    final kind = p.value('instrument').round();
    final harp = kind == 2, koto = kind == 3;
    final count = harp ? 12 : koto ? 13 : 6;
    final left = s.width * 0.06, right = s.width * 0.94;
    final top = s.height * 0.22, bottom = s.height * 0.86;
    if (harp) {
      // The harp's frame: the neck's curve on top, the pillar on the left, the soundboard slanting.
      final frame = Path()
        ..moveTo(left, bottom)
        ..lineTo(left, top)
        ..quadraticBezierTo(s.width * 0.5, top - s.height * 0.15, right, top + s.height * 0.1)
        ..lineTo(right - s.width * 0.1, bottom)
        ..close();
      canvas.drawPath(frame, Paint()..color = p.accent.withValues(alpha: 0.05 + 0.08 * p.value('body')));
      canvas.drawPath(frame, _line(p.accent.withValues(alpha: 0.5), 1.4));
    } else {
      // A guitar body (two bouts and a sound hole) or a koto's long board, on the right where the strings are plucked.
      final body = Path();
      if (koto) {
        body.addRRect(RRect.fromRectAndRadius(Rect.fromLTRB(left, top - 6, right, bottom + 6), const Radius.circular(18)));
      } else {
        final cx = s.width * 0.68, cy = (top + bottom) / 2, h = (bottom - top) * 0.62;
        body
          ..addOval(Rect.fromCenter(center: Offset(cx + h * 0.55, cy), width: h * 1.5, height: h * 1.6))
          ..addOval(Rect.fromCenter(center: Offset(cx - h * 0.45, cy), width: h * 1.2, height: h * 1.3));
      }
      canvas.drawPath(body, Paint()..color = p.accent.withValues(alpha: 0.06 + 0.08 * p.value('body')));
      canvas.drawPath(body, _line(p.accent.withValues(alpha: 0.45), 1.2));
      if (!koto) canvas.drawCircle(Offset(s.width * 0.66, (top + bottom) / 2), (bottom - top) * 0.16, _line(Neon.dim, 1.2));
    }
    final hit = _struck(count);
    final mute = p.value('damping');
    final pos = p.value('position');
    for (var i = 0; i < count; i++) {
      final u = i / (count - 1);
      final y = bottom - u * (bottom - top);
      final a = Offset(harp ? left + 4 : left, harp ? y : y), b = Offset(harp ? right - s.width * 0.1 * (1 - u) - 6 : right, y);
      final struck = i == hit;
      final c = struck ? p.accent : Neon.ink.withValues(alpha: 0.4);
      _string(canvas, a, b, c, struck ? 1.5 : 0.9 + (koto ? 0 : (1 - u) * 0.8), struck ? _amp * 5 * (1 - 0.7 * mute) : 0,
          5 + u * 5, glow: struck ? 1 : 0);
    }
    // The bridge at the right end, a palm mute over it as damping rises.
    final bridge = right - 4;
    canvas.drawLine(Offset(bridge, top - 4), Offset(bridge, bottom + 4), _line(Neon.ink.withValues(alpha: 0.5), 2));
    if (mute > 0.02) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(bridge - 6 - 18 * mute, top - 6, bridge + 2, bottom + 6),
          const Radius.circular(8)), Paint()..color = p.secondary.withValues(alpha: 0.12 + 0.2 * mute));
    }
    // The pluck point: `position` of the string from the bridge, where the woodpecker sits.
    final x = bridge - (right - left) * pos;
    canvas.drawLine(Offset(x, top - 6), Offset(x, bottom + 6), _line(p.secondary.withValues(alpha: 0.5), 1));
    paintWoodpecker(canvas, Offset(x, top - 6), s.height * 0.16, p.accent);
  }

  // ---------- Bowed: four strings, the body's f-holes and the bow across them ----------
  void _bowed(Canvas canvas, Size s) {
    final section = p.value('section').round();
    final left = s.width * 0.05, right = s.width * 0.95;
    final top = s.height * 0.3, bottom = s.height * 0.8;
    // The body behind: wider for the cello and bass.
    final bw = s.width * (0.5 + section * 0.06), cx = s.width * 0.62, cy = (top + bottom) / 2;
    final body = Path()
      ..addOval(Rect.fromCenter(center: Offset(cx - bw * 0.22, cy), width: bw * 0.5, height: s.height * 0.78))
      ..addOval(Rect.fromCenter(center: Offset(cx + bw * 0.24, cy), width: bw * 0.56, height: s.height * 0.86));
    canvas.drawPath(body, Paint()..color = p.accent.withValues(alpha: 0.05 + 0.08 * p.value('body')));
    canvas.drawPath(body, _line(p.accent.withValues(alpha: 0.4), 1.2));
    for (final dy in [-1.0, 1.0]) {
      final f = Path()
        ..moveTo(cx - bw * 0.08, cy + dy * s.height * 0.32)
        ..cubicTo(cx, cy + dy * s.height * 0.2, cx - bw * 0.04, cy + dy * s.height * 0.12, cx + bw * 0.06, cy + dy * s.height * 0.06);
      canvas.drawPath(f, _line(Neon.dim, 1.2));
    }
    const count = 4;
    final hit = _struck(count);
    final sounding = p.energy;
    for (var i = 0; i < count; i++) {
      final y = top + (bottom - top) * i / (count - 1);
      final struck = count - 1 - i == hit;
      _string(canvas, Offset(left, y), Offset(right, y), struck ? p.accent : Neon.ink.withValues(alpha: 0.45),
          struck ? 1.5 : 1.0 + i * 0.25, struck ? sounding * 3 : 0, 11, glow: struck ? 1 : 0);
    }
    // The bow: across the strings at `position` from the bridge (right), thicker with pressure, moving with speed.
    final bridge = right - s.width * 0.08;
    canvas.drawLine(Offset(bridge, top - 8), Offset(bridge, bottom + 8), _line(Neon.ink.withValues(alpha: 0.5), 2));
    final x = bridge - (right - left) * p.value('position') / 0.3 * 0.45;
    final travel = sounding > 0 ? math.sin(p.seconds * 2 * math.pi * (0.3 + p.value('speed'))) * s.height * 0.12 : 0.0;
    final press = p.value('pressure');
    final bow = Path()
      ..moveTo(x - 10, top - s.height * 0.22 + travel)
      ..lineTo(x + 10, bottom + s.height * 0.16 + travel);
    strokeGlow(canvas, bow, p.secondary, width: 2 + press * 3, glow: sounding > 0);
    paintWoodpecker(canvas, Offset(x - 14, top - s.height * 0.12 + travel), s.height * 0.15, p.accent);
  }

  // ---------- Mallets: bars over resonator tubes, hanging chimes or a bell ----------
  void _mallets(Canvas canvas, Size s) {
    final kind = p.value('instrument').round();
    final left = s.width * 0.05, right = s.width * 0.95;
    final top = s.height * 0.18, bottom = s.height * 0.9;
    final pos = p.value('position');
    if (kind == 5) {
      // A bell: its profile ringing.
      final cx = s.width * 0.5, w = s.height * 0.62;
      final ring = 1 + p.energy * 0.03 * math.sin(p.seconds * 2 * math.pi * 9);
      final bell = Path()
        ..moveTo(cx - w * 0.18 * ring, top + 10)
        ..cubicTo(cx - w * 0.3 * ring, top + w * 0.5, cx - w * 0.45 * ring, bottom - 18, cx - w * 0.62 * ring, bottom - 6)
        ..lineTo(cx + w * 0.62 * ring, bottom - 6)
        ..cubicTo(cx + w * 0.45 * ring, bottom - 18, cx + w * 0.3 * ring, top + w * 0.5, cx + w * 0.18 * ring, top + 10)
        ..close();
      canvas.drawPath(bell, Paint()..color = p.accent.withValues(alpha: 0.08 + 0.25 * p.energy));
      strokeGlow(canvas, bell, p.accent, width: 1.6, glow: p.energy > 0);
      final sx = cx + (pos - 0.5) * w * 1.1;
      paintWoodpecker(canvas, Offset(sx, top + 8 + (pos - 0.5).abs() * 20), s.height * 0.15, p.accent);
      return;
    }
    final chimes = kind == 4;
    final count = chimes ? 9 : 12;
    final hit = _struck(count);
    final w = (right - left) / count;
    final motor = p.value('motor');
    for (var i = 0; i < count; i++) {
      final u = i / (count - 1);
      final x = left + w * (i + 0.5);
      final struck = i == hit;
      final c = struck ? p.accent : Neon.ink.withValues(alpha: 0.45);
      if (chimes) {
        // Tubes hanging from a rail, longer in the bass.
        final len = (bottom - top - 10) * (1 - u * 0.5);
        final swing = struck ? p.energy * 3 * math.sin(p.seconds * 2 * math.pi * 1.3) : 0.0;
        canvas.drawLine(Offset(x, top), Offset(x + swing, top + len), _line(c.withValues(alpha: struck ? 1 : 0.5), w * 0.4));
      } else {
        // A bar, shorter in the treble, over its resonator tube (marimba and vibraphone).
        final len = (bottom - top) * (0.55 - u * 0.25);
        final y0 = top + (bottom - top - len) * 0.25;
        final bar = Rect.fromLTWH(x - w * 0.38, y0, w * 0.76, len * 0.6);
        canvas.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(3)),
            Paint()..color = c.withValues(alpha: struck ? 0.35 + 0.5 * p.energy : 0.22));
        if (kind <= 1) {
          final tube = Rect.fromLTRB(x - w * 0.2, bar.bottom + 4, x + w * 0.2, bottom);
          canvas.drawRect(tube, Paint()..color = Neon.dim.withValues(alpha: 0.12));
          // The vibraphone's motor: a disc in each tube's top turning.
          if (kind == 1 && motor > 0) {
            final ph = p.frame.live ? p.frame.own(1) * 2 * math.pi : p.seconds * motor * 2 * math.pi;
            canvas.drawLine(Offset(x - w * 0.18 * math.cos(ph), bar.bottom + 8), Offset(x + w * 0.18 * math.cos(ph), bar.bottom + 8),
                _line(p.secondary, 1.6));
          }
        }
        if (struck && p.energy > 0) {
          canvas.drawRRect(RRect.fromRectAndRadius(bar.inflate(2), const Radius.circular(4)), _line(p.accent, 1.2));
        }
      }
    }
    // The strike point along the bar (from its middle, 0, to its end, 1): the woodpecker there over the struck bar.
    final at = hit < 0 ? count ~/ 2 : hit;
    final x = left + w * (at + 0.5);
    final u = at / (count - 1);
    final barTop = chimes ? top + (bottom - top - 10) * (1 - u * 0.5) * (0.15 + 0.5 * pos)
        : top + (bottom - top - (bottom - top) * (0.55 - u * 0.25)) * 0.25 - 2;
    paintWoodpecker(canvas, Offset(x + (chimes ? -w * 0.3 : w * 0.38 * (pos * 2 - 1)), barTop), s.height * 0.15, p.accent);
  }

  // ---------- Winds: the bore with its tone holes, the breath going in and the standing wave ----------
  void _winds(Canvas canvas, Size s) {
    final kind = p.value('instrument').round();
    final flute = kind == 1, sax = kind == 2, brass = kind == 3;
    final left = s.width * 0.12, right = s.width * (brass || sax ? 0.8 : 0.9);
    final cy = s.height * 0.55, r0 = s.height * 0.07, r1 = s.height * (sax ? 0.13 : 0.08);
    final bore = Path()
      ..moveTo(left, cy - r0)
      ..lineTo(right, cy - r1)
      ..lineTo(right, cy + r1)
      ..lineTo(left, cy + r0)
      ..close();
    canvas.drawPath(bore, Paint()..color = p.accent.withValues(alpha: 0.08 + 0.05 * p.value('body')));
    canvas.drawPath(bore, _line(p.accent.withValues(alpha: 0.6), 1.4));
    // The bell: brass and sax flare (the sax upturned); the clarinet's is small, the flute has none.
    if (!flute) {
      final flare = brass ? s.height * 0.32 : sax ? s.height * 0.26 : s.height * 0.14;
      final end = brass ? s.width * 0.96 : sax ? s.width * 0.9 : s.width * 0.96;
      final up = sax ? -s.height * 0.16 : 0.0;
      final bell = Path()
        ..moveTo(right, cy - r1)
        ..quadraticBezierTo(end - (end - right) * 0.3, cy - r1 + up, end, cy - flare + up)
        ..lineTo(end, cy + flare + up)
        ..quadraticBezierTo(end - (end - right) * 0.3, cy + r1 + up, right, cy + r1)
        ..close();
      canvas.drawPath(bell, Paint()..color = p.accent.withValues(alpha: 0.12));
      canvas.drawPath(bell, _line(p.accent.withValues(alpha: 0.6), 1.4));
    }
    // Tone holes (not on brass); the standing wave inside while it sounds.
    if (!brass) {
      for (var i = 0; i < 7; i++) {
        final x = left + (right - left) * (0.3 + i * 0.09);
        canvas.drawCircle(Offset(x, cy - r0 * 0.6), r0 * 0.32, Paint()..color = Neon.bg);
        canvas.drawCircle(Offset(x, cy - r0 * 0.6), r0 * 0.32, _line(Neon.dim, 1));
      }
    }
    final e = p.energy;
    if (e > 0) {
      final path = Path();
      final ph = math.sin(p.seconds * 2 * math.pi * 3);
      for (var i = 0; i <= 40; i++) {
        final u = i / 40;
        final x = left + (right - left) * u;
        final y = cy + r0 * 0.5 * e * ph * math.cos(math.pi * u * (flute ? 2 : 1.5) * 2);
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      strokeGlow(canvas, path, p.secondary, width: 1.4);
    }
    // The breath: dots flowing into the mouthpiece, more with `breath`, noisier with `noise`.
    final breath = p.frame.live && e > 0 ? p.frame.own(1).clamp(0.0, 1.0) : p.value('breath');
    final noise = p.value('noise');
    final rnd = math.Random(7);
    for (var i = 0; i < 9; i++) {
      final u = ((p.seconds * (0.6 + breath) + i / 9) % 1.0);
      final x = s.width * 0.02 + (left - s.width * 0.02) * u;
      final y = cy + (rnd.nextDouble() - 0.5) * r0 * 2 * (0.4 + noise);
      canvas.drawCircle(Offset(x, y), 1.2 + breath * 1.4, Paint()..color = p.accent.withValues(alpha: 0.2 + 0.6 * breath * (1 - u * 0.5)));
    }
    // The mouthpiece: a reed (clarinet, sax), an embouchure hole (flute) or a cup (brass); `reed` its stiffness.
    final reed = p.value('reed');
    if (flute) {
      canvas.drawOval(Rect.fromCenter(center: Offset(left + r0 * 2, cy - r0 * 0.6), width: r0 * 1.2, height: r0 * 0.7), Paint()..color = p.secondary);
    } else if (brass) {
      canvas.drawArc(Rect.fromCenter(center: Offset(left, cy), width: r0 * 2.4, height: r0 * 3), math.pi / 2, math.pi, false, _line(p.secondary, 2));
    } else {
      canvas.drawLine(Offset(left - r0 * 1.8, cy + r0 * (1 - reed)), Offset(left, cy + r0 * 0.2), _line(p.secondary, 2));
    }
    paintWoodpecker(canvas, Offset(left + (right - left) * 0.18, cy - r0 - 1), s.height * 0.16, p.accent);
  }

  @override
  bool shouldRepaint(covariant TimberPainter o) => true;
}

/// Timber's one motif: a small woodpecker perched with its feet at [feet], [size] tall, facing left (its beak at the
/// strike point). [beak] 0..1 tilts it from upright to pecking (the piano's hammer hardness).
void paintWoodpecker(Canvas canvas, Offset feet, double size, Color color, {double beak = 0.4}) {
  final h = size.clamp(10.0, 30.0);
  canvas.save();
  canvas.translate(feet.dx, feet.dy);
  final body = Paint()..color = Color.lerp(Neon.ink, Neon.bg, 0.15)!;
  final edge = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  // Tail prop and body, leaning against the post.
  final tail = Path()
    ..moveTo(h * 0.18, -h * 0.05)
    ..lineTo(h * 0.42, h * 0.12)
    ..lineTo(h * 0.26, -h * 0.2)
    ..close();
  canvas.drawPath(tail, body);
  canvas.rotate(-0.15 - beak * 0.25);
  final torso = Rect.fromCenter(center: Offset(h * 0.12, -h * 0.42), width: h * 0.42, height: h * 0.7);
  canvas.drawOval(torso, body);
  canvas.drawOval(torso, edge);
  // The head, its red crest and the beak (pointing left, down as it pecks).
  final head = Offset(h * 0.02, -h * 0.82);
  canvas.drawCircle(head, h * 0.17, body);
  canvas.drawCircle(head, h * 0.17, edge);
  canvas.drawPath(Path()..addArc(Rect.fromCircle(center: head, radius: h * 0.17), -math.pi * 0.95, math.pi * 0.7),
      Paint()..color = Neon.pink..style = PaintingStyle.stroke..strokeWidth = h * 0.09);
  final beakPath = Path()
    ..moveTo(head.dx - h * 0.12, head.dy - h * 0.05)
    ..lineTo(head.dx - h * 0.46, head.dy + h * 0.02 + beak * h * 0.06)
    ..lineTo(head.dx - h * 0.12, head.dy + h * 0.06)
    ..close();
  canvas.drawPath(beakPath, Paint()..color = color);
  canvas.drawCircle(head + Offset(-h * 0.05, -h * 0.03), h * 0.035, Paint()..color = color);
  canvas.restore();
}

/// The model cards' icons ([ChoiceIcon]): keys, tines, drawbars, a guitar, a bow on a string, bars, a horn.
void timberModelIcon(Canvas canvas, Rect r, int k, Color c) {
  final line = Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..strokeCap = StrokeCap.round;
  final fill = Paint()..color = c;
  final s = math.min(r.width, r.height);
  final box = Rect.fromCenter(center: r.center, width: s * 1.3, height: s);
  switch (k) {
    case TimberModel.piano:
      for (var i = 0; i < 4; i++) {
        canvas.drawRect(Rect.fromLTWH(box.left + box.width * i / 4, box.top, box.width / 4, box.height), line);
      }
      for (final i in [1, 2]) {
        canvas.drawRect(Rect.fromLTWH(box.left + box.width * i / 4 - box.width * 0.07, box.top, box.width * 0.14, box.height * 0.6), fill);
      }
    case TimberModel.epiano:
      for (var i = 0; i < 3; i++) {
        final y = box.top + box.height * (0.2 + i * 0.3);
        canvas.drawLine(Offset(box.left, y), Offset(box.right - box.width * 0.25 - i * box.width * 0.1, y), line);
        canvas.drawCircle(Offset(box.right - box.width * 0.12, y), 1.8, fill);
      }
    case TimberModel.organ:
      const lens = [0.9, 0.9, 0.9, 0.3, 0.1, 0.5, 0.2, 0.6, 0.4];
      for (var i = 0; i < 9; i++) {
        final x = box.left + box.width * (i + 0.5) / 9;
        canvas.drawLine(Offset(x, box.top), Offset(x, box.top + box.height * lens[i]), line);
      }
    case TimberModel.plucked:
      final cy = box.center.dy;
      canvas.drawOval(Rect.fromCenter(center: Offset(box.right - box.width * 0.22, cy), width: box.height * 0.9, height: box.height), line);
      canvas.drawOval(Rect.fromCenter(center: Offset(box.right - box.width * 0.55, cy), width: box.height * 0.7, height: box.height * 0.8), line);
      canvas.drawLine(Offset(box.left, cy), Offset(box.right, cy), line);
    case TimberModel.bowed:
      canvas.drawLine(Offset(box.left, box.center.dy), Offset(box.right, box.center.dy), line);
      canvas.drawLine(Offset(box.left + box.width * 0.3, box.bottom), Offset(box.right - box.width * 0.25, box.top), line..strokeWidth = 2.4);
    case TimberModel.mallets:
      for (var i = 0; i < 5; i++) {
        final h = box.height * (0.9 - i * 0.12);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(box.left + box.width * i / 5 + 1, box.top + (box.height - h) / 2,
            box.width / 5 - 2, h), const Radius.circular(1.5)), line);
      }
    default:
      final cy = box.center.dy;
      canvas.drawLine(Offset(box.left, cy), Offset(box.right - box.width * 0.25, cy), line..strokeWidth = 3);
      canvas.drawPath(Path()
        ..moveTo(box.right - box.width * 0.25, cy - 1.5)
        ..lineTo(box.right, cy - box.height * 0.45)
        ..lineTo(box.right, cy + box.height * 0.45)
        ..lineTo(box.right - box.width * 0.25, cy + 1.5)
        ..close(), fill);
  }
}
