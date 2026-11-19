// Bit distortion's Bitwise mode (org.caw.bits 1, 1.1.0): the word's staircase as shift, XOR and AND bend it, mode chips, and the 16 bit lanes drawn flipping, each a tap to set its mask bit.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';
import '../modes_kit.dart';

/// What Bitwise does to one sample [x] (the engine's arithmetic, builtin_fx_bits_bitwise.cpp, written out): rounded
/// to a signed word of [bits], shifted (left wraps past full scale, right coarsens), placed in the top [bits] of 16
/// lanes, XORed and ANDed with the masks there, and read back; a word of 0 stays 0.
double bitwiseSample(double x, {required int bits, required int shift, required int xor, required int and}) {
  final b = bits.clamp(2, 16);
  final q = 1 << (b - 1);
  var w = (x.clamp(-1.0, 1.0) * (q - 1)).round();
  if (w == 0) return 0;
  final full = (1 << b) - 1;
  if (shift > 0) {
    w = (w << shift) & full;
  } else if (shift < 0) {
    w = (w >> -shift) & full;
  } else {
    w &= full;
  }
  final top = full << (16 - b);
  var lanes = (w << (16 - b)) & 0xffff;
  lanes ^= xor & top;
  lanes &= and | ~top & 0xffff;
  var out = (lanes >> (16 - b)) & full;
  if (out >= q) out -= 1 << b;
  return out / (q - 1);
}

/// The 16-bit word of [x] as Bitwise holds it ([bitwiseSample]'s lanes), lane 0 the least significant.
int bitwiseWord(double x, {required int bits, required int shift, required int xor, required int and}) {
  final b = bits.clamp(2, 16);
  final y = bitwiseSample(x, bits: b, shift: shift, xor: xor, and: and);
  final q = 1 << (b - 1);
  return (((y * (q - 1)).round()) & ((1 << b) - 1)) << (16 - b) & 0xffff;
}

/// Bitwise: the staircase of two cycles of a sine (≈) as the word's operations leave it, over the clean wave (drag
/// up and down for the bits, sideways for the shift); the ops as chips (Shift, XOR, AND); then the 16 lanes, most
/// significant first, each lit by its latest bit and glowing as often as it flips (the engine's), the lanes outside
/// the word dimmed; with XOR or AND chosen, a tap on a lane flips that mask's bit.
class BitwiseDevice extends StatefulWidget {
  const BitwiseDevice({super.key, required this.cards});
  final Widget cards;

  @override
  State<BitwiseDevice> createState() => _BitwiseDeviceState();
}

class _BitwiseDeviceState extends State<BitwiseDevice> {
  int _op = 1; // 0 shift, 1 XOR, 2 AND

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final inline = DeviceScope.isInline(context);
    final hero = HeroCanvas(
      color: scope.accent,
      height: 180,
      caption: 'WORD ≈',
      grid: false,
      readout: Builder(builder: (context) => Text('${t.value('bits').round()} bit · shift ${t.value('shift').round()}')),
      child: const _WordHero(),
    );
    const ops = ['Shift', 'XOR', 'AND'];
    final chips = Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (var k = 0; k < 3; k++)
        LitPill(label: ops[k], on: _op == k, keyName: 'bitwise-op-$k', onTap: () => setState(() => _op = k)),
      if (_op > 0) ...[
        const SizedBox(width: 6),
        LitPill(label: 'Clear', on: false, keyName: 'bitwise-clear', onTap: () => t.set(_op == 1 ? 'xor' : 'and', _op == 1 ? 0.0 : 65535.0)),
        LitPill(label: 'Invert', on: false, keyName: 'bitwise-invert',
            onTap: () => t.set(_op == 1 ? 'xor' : 'and', ((~t.value(_op == 1 ? 'xor' : 'and').round()) & 0xffff).toDouble())),
      ],
    ]);
    final lanes = _Lanes(op: _op);
    if (inline) return effectPage('bits', [widget.cards, hero, lanes, const KnobRow(['bits', 'shift'], size: 42)]);
    return effectPage('bits', [
      widget.cards,
      hero,
      Padding(padding: const EdgeInsets.only(bottom: 8), child: chips),
      lanes,
      const KnobRow(['bits', 'shift', 'xor', 'and'], size: 50, labels: {'xor': 'XOR mask', 'and': 'AND mask'}),
    ]);
  }
}

class _WordHero extends StatefulWidget {
  const _WordHero();

  @override
  State<_WordHero> createState() => _WordHeroState();
}

class _WordHeroState extends State<_WordHero> {
  bool _active = false;
  double _bits = 12, _shift = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return GrabGesture(
        key: const ValueKey('bitwise-hero'),
        onStart: (_, _) {
          _bits = t.value('bits');
          _shift = t.value('shift');
          DeviceFeel.grab();
          setState(() => _active = true);
        },
        onUpdate: (u) {
          _bits = (_bits - u.delta.dy / h * 14 * DeviceFingers.fine).clamp(2.0, 16.0);
          _shift = (_shift + u.delta.dx / w * 16 * DeviceFingers.fine).clamp(-8.0, 8.0);
          t.setLive('bits', _bits.roundToDouble());
          t.setLive('shift', _shift.roundToDouble());
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({for (final id in ['bits', 'shift']) if (t.param(id) case final p?) id: p.defaultValue}),
        child: CustomPaint(size: Size(w, h), painter: _WordPainter(
          bits: t.value('bits').round(), shift: t.value('shift').round(), xor: t.value('xor').round(),
          and: t.value('and').round(), color: scope.accent, active: _active)),
      );
    });
  }
}

class _WordPainter extends CustomPainter {
  _WordPainter({required this.bits, required this.shift, required this.xor, required this.and, required this.color,
    required this.active});
  final int bits, shift, xor, and;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(10, 24, size.width - 10, size.height - 8);
    double y(double v) => r.center.dy - v.clamp(-1.1, 1.1) * r.height * 0.45;
    canvas.drawLine(Offset(r.left, r.center.dy), Offset(r.right, r.center.dy), Paint()..color = Neon.ink.withValues(alpha: 0.08));
    final clean = Path(), bent = Path();
    const n = 512;
    for (var i = 0; i <= n; i++) {
      final x = r.left + r.width * i / n;
      final s = 0.9 * math.sin(4 * math.pi * i / n);
      i == 0 ? clean.moveTo(x, y(s)) : clean.lineTo(x, y(s));
      final o = bitwiseSample(s, bits: bits, shift: shift, xor: xor, and: and);
      i == 0 ? bent.moveTo(x, y(o)) : bent.lineTo(x, y(o));
    }
    canvas.drawPath(clean, Paint()
      ..color = Neon.ink.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    strokeGlow(canvas, bent, color, width: active ? 2.4 : 1.8);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WordPainter o) =>
      o.bits != bits || o.shift != shift || o.xor != xor || o.and != and || o.color != color || o.active != active;
}

/// The 16 lanes, most significant on the left: each lit by its latest bit, glowing by how often it flips, its mask
/// bit marked (XOR: a ring that flips it; AND: a gap that clears it). Keys `bit-lane-<lane>`.
class _Lanes extends StatelessWidget {
  const _Lanes({required this.op});
  final int op;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final bits = t.value('bits').round().clamp(2, 16);
    final xor = t.value('xor').round(), and = t.value('and').round();
    return DeviceDisplay(builder: (context, f) {
      final live = f?.raw != null && f!.raw!.length >= 38;
      return LayoutBuilder(builder: (context, box) {
        final gap = box.maxWidth < 420 ? 2.0 : 4.0;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: Neon.line),
              color: Neon.ink.withValues(alpha: 0.03)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              for (var i = 15; i >= 0; i--)
                Expanded(child: Padding(padding: EdgeInsets.symmetric(horizontal: gap / 2), child: _Lane(
                  lane: i,
                  inWord: i >= 16 - bits,
                  bit: live ? f.at(22 + i) >= 0.5 : null,
                  flips: live ? f.at(6 + i).clamp(0.0, 1.0) : 0,
                  xor: (xor >> i) & 1 == 1,
                  and: (and >> i) & 1 == 1,
                  op: op,
                  color: scope.accent,
                  onTap: op == 0 || i < 16 - bits ? null : () {
                    DeviceFeel.tap();
                    final id = op == 1 ? 'xor' : 'and';
                    t.set(id, (t.value(id).round() ^ (1 << i)).toDouble());
                  },
                ))),
            ]),
            const SizedBox(height: 3),
            Row(children: [
              const Text('MSB', style: TextStyle(fontSize: 8, color: Neon.dim, fontWeight: FontWeight.w700)),
              Expanded(child: Center(child: Text(switch (op) {
                0 => 'SHIFT ${t.value('shift').round()}: drag the word sideways',
                1 => 'TAP A LANE: FLIP IT (XOR)',
                _ => 'TAP A LANE: CLEAR IT (AND)',
              }, style: const TextStyle(fontSize: 8, letterSpacing: 0.8, color: Neon.dim, fontWeight: FontWeight.w700)))),
              const Text('LSB', style: TextStyle(fontSize: 8, color: Neon.dim, fontWeight: FontWeight.w700)),
            ]),
          ]),
        );
      });
    });
  }
}

class _Lane extends StatelessWidget {
  const _Lane({required this.lane, required this.inWord, required this.bit, required this.flips, required this.xor,
    required this.and, required this.op, required this.color, required this.onTap});
  final int lane, op;
  final bool inWord, xor, and;
  final bool? bit;
  final double flips;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final on = bit ?? false;
    final masked = inWord && ((op == 1 && xor) || (op == 2 && !and));
    final c = inWord ? color : Neon.dim;
    return Semantics(button: onTap != null, label: 'Bit $lane', child: GestureDetector(
      key: ValueKey('bit-lane-$lane'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            color: inWord ? c.withValues(alpha: on ? 0.75 : 0.08 + 0.4 * flips) : Neon.ink.withValues(alpha: 0.03),
            border: Border.all(color: masked ? Neon.text : (inWord ? c.withValues(alpha: 0.5) : Neon.line),
                width: masked ? 1.6 : 1),
            boxShadow: inWord && flips > 0.05 ? [BoxShadow(color: c.withValues(alpha: 0.5 * flips), blurRadius: 8)] : null,
          ),
          alignment: Alignment.center,
          child: Text(masked ? (op == 1 ? 'X' : '-') : (on ? '1' : '0'),
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: on && !masked ? Neon.bg : Neon.dim)),
        ),
        const SizedBox(height: 2),
        Text('$lane', style: const TextStyle(fontSize: 7, color: Neon.dim)),
      ]),
    ));
  }
}

/// Bitwise's card icon: a row of bits, some lit.
void bitwiseIcon(Canvas canvas, Rect r, Color c) {
  const lit = [1, 0, 1, 1, 0, 1, 0, 0];
  final w = r.width / lit.length;
  for (var k = 0; k < lit.length; k++) {
    final cell = Rect.fromLTWH(r.left + k * w + 1, r.center.dy - r.height * 0.3, w - 2, r.height * 0.6);
    canvas.drawRRect(RRect.fromRectAndRadius(cell, const Radius.circular(1.5)), Paint()
      ..color = c.withValues(alpha: lit[k] == 1 ? 0.9 : 0.25));
  }
}
