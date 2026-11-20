// Bit distortion's Bitwise mode (org.caw.bits 1, 1.1.0; glitch ops 1.1.1): the word's staircase as its ops bend it, op chips with their few knobs, the 16 bit lanes drawn flipping (a tap sets the chosen mask's bit) and the 8 steps the ops act on.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../../../model/device_target.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../../kit/param_watch.dart';
import '../effect_page.dart';
import '../modes_kit.dart';

/// What Bitwise does to one sample [x] (the engine's arithmetic, builtin_fx_bits_bitwise.cpp, written out): rounded
/// to a signed word of [bits], shifted (left wraps past full scale, right coarsens), rotated by [rotate] lanes round
/// the word and its lowest [reverse] lanes reversed (1.1.1), placed in the top [bits] of 16 lanes, XORed, ORed and
/// ANDed with the masks there, and read back; a word of 0 stays 0. (Freeze, flips and the combine move with time
/// and the key: the picture leaves them out.)
double bitwiseSample(double x, {required int bits, required int shift, required int xor, required int and,
    int or = 0, int rotate = 0, int reverse = 0}) {
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
  final r = ((rotate % b) + b) % b;
  if (r != 0) w = ((w << r) | (w >> (b - r))) & full;
  final n = reverse.clamp(0, b);
  if (n > 0) {
    var rev = w & ~((1 << n) - 1) & full;
    for (var k = 0; k < n; k++) {
      rev |= ((w >> k) & 1) << (n - 1 - k);
    }
    w = rev;
  }
  final top = full << (16 - b);
  var lanes = (w << (16 - b)) & 0xffff;
  lanes ^= xor & top;
  lanes |= or & top;
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

/// Bitwise's ops as chips, in this order (keys `bitwise-op-<k>`): each chip shows its few knobs, and with a mask op
/// chosen a tap on a lane flips that mask's bit. Their parameters: the mask a chip edits (or none) and its knobs.
const bitwiseOps = ['Shift', 'XOR', 'AND', 'OR', 'Rotate', 'Reverse', 'Freeze', 'Flip', 'Key', 'Echo'];
const _opMask = <int, String>{1: 'xor', 2: 'and', 3: 'or', 6: 'freeze', 8: 'combine_mask', 9: 'combine_mask'};
const _opKnobs = <int, List<String>>{
  1: ['xor'], 2: ['and'], 3: ['or'], 4: ['rotate'], 5: ['reverse'], 6: ['grain', 'hold'], 7: ['flips', 'seed'],
  9: ['echo'],
};
const _opLabels = {'xor': 'XOR mask', 'and': 'AND mask', 'or': 'OR mask', 'echo': 'Echo'};

/// Bitwise: the staircase of two cycles of a sine (≈) as the word's operations leave it, over the clean wave (drag
/// up and down for the bits, sideways for the shift); the ops as chips (Shift, XOR, AND, OR, Rotate, Reverse, Freeze,
/// Flip, Key, Echo) with the chosen one's knobs; then the 16 lanes, most significant first, each lit by its latest bit
/// and glowing as often as it flips (the engine's), the lanes outside the word dimmed; with a mask op chosen, a tap
/// on a lane flips that mask's bit. Under them the 8 steps the ops act on (a tap turns one on or off, the step now
/// lit), the step length, Tone and Gate; Level and the key's filter under MORE.
class BitwiseDevice extends StatefulWidget {
  const BitwiseDevice({super.key, required this.cards});
  final Widget cards;

  @override
  State<BitwiseDevice> createState() => _BitwiseDeviceState();
}

class _BitwiseDeviceState extends State<BitwiseDevice> {
  int _op = 1; // an index into [bitwiseOps]

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
    final mask = _opMask[_op];
    final chips = Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (var k = 0; k < bitwiseOps.length; k++)
        if (t.param(_opMask[k] ?? (_opKnobs[k] ?? const ['shift']).first) != null)
          LitPill(label: bitwiseOps[k], on: _op == k, keyName: 'bitwise-op-$k', onTap: () => setState(() => _op = k)),
      if (mask != null) ...[
        const SizedBox(width: 6),
        LitPill(label: 'Clear', on: false, keyName: 'bitwise-clear', onTap: () => t.set(mask, mask == 'and' ? 65535.0 : 0.0)),
        LitPill(label: 'Invert', on: false, keyName: 'bitwise-invert',
            onTap: () => t.set(mask, ((~t.value(mask).round()) & 0xffff).toDouble())),
      ],
    ]);
    final lanes = _Lanes(op: _op);
    if (inline) return effectPage('bits', [widget.cards, hero, lanes, const KnobRow(['bits', 'shift'], size: 42)]);
    return effectPage('bits', [
      widget.cards,
      hero,
      Padding(padding: const EdgeInsets.only(bottom: 8), child: chips),
      if (_op >= 8) _CombineRow(source: _op - 7),
      lanes,
      KnobRow(['bits', 'shift', ...?_opKnobs[_op]], size: 50, labels: _opLabels),
      const _Steps(),
      const KnobRow(['tone', 'gate'], size: 46),
      const DeviceFold(child: ParamGrid(only: ['level', 'sc_hpf', 'sc_lpf', 'sc_listen'])),
    ]);
  }
}

/// The combine's row for [source] (1 Key, 2 Echo): whether the word combines with it, and how (XOR, AND or OR).
class _CombineRow extends StatelessWidget {
  const _CombineRow({required this.source});
  final int source;

  @override
  Widget build(BuildContext context) => watchDevice(context, (context) {
    final t = DeviceScope.of(context).target;
    if (t.param('combine') == null) return const SizedBox.shrink();
    final on = t.value('combine').round() == source;
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: Wrap(spacing: 6, runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center, children: [
      LitPill(label: source == 1 ? 'With the key' : 'With its echo', on: on, keyName: 'bitwise-combine',
          onTap: () => t.set('combine', on ? 0.0 : source.toDouble())),
      const ChoicePill('combine_op'),
      Text(source == 1 ? 'Route a key to it in the routing view' : 'The word ${t.value('echo').toStringAsFixed(1)} ms ago',
          style: const TextStyle(fontSize: 10, color: Neon.dim)),
    ]));
  });
}

/// The 8 steps the ops act on (pattern bit k: step k; keys `bitwise-step-<k>`), the step now lit from the engine,
/// and the step length.
class _Steps extends StatelessWidget {
  const _Steps();

  @override
  Widget build(BuildContext context) => watchDevice(context, (context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    if (t.param('pattern') == null) return const SizedBox.shrink();
    final pattern = t.value('pattern').round();
    return DeviceDisplay(builder: (context, f) {
      final now = f != null && f.at(38, -1) >= 0 ? f.at(38).round() : -1;
      return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [
        const Text('STEPS', style: TextStyle(fontSize: 8, letterSpacing: 0.8, color: Neon.dim, fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        for (var k = 0; k < 8; k++)
          Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: Semantics(button: true,
              label: 'Step ${k + 1}', toggled: (pattern >> k) & 1 == 1, child: GestureDetector(
            key: ValueKey('bitwise-step-$k'),
            behavior: HitTestBehavior.opaque,
            onTap: () {
              DeviceFeel.tap();
              t.set('pattern', (pattern ^ (1 << k)).toDouble());
            },
            child: Container(
              height: 26,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                color: (pattern >> k) & 1 == 1 ? scope.accent.withValues(alpha: now == k ? 0.8 : 0.4) : Neon.ink.withValues(alpha: 0.03),
                border: Border.all(color: now == k ? Neon.text : Neon.line, width: now == k ? 1.6 : 1),
              ),
            ),
          )))),
        const SizedBox(width: 8),
        const ChoicePill('rate'),
      ]));
    });
  });
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
          and: t.value('and').round(), or: _int(t, 'or'), rotate: _int(t, 'rotate'), reverse: _int(t, 'reverse'),
          color: scope.accent, active: _active)),
      );
    });
  }
}

int _int(DeviceTarget t, String id) => t.param(id) == null ? 0 : t.value(id).round();

class _WordPainter extends CustomPainter {
  _WordPainter({required this.bits, required this.shift, required this.xor, required this.and, required this.or,
    required this.rotate, required this.reverse, required this.color, required this.active});
  final int bits, shift, xor, and, or, rotate, reverse;
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
      final o = bitwiseSample(s, bits: bits, shift: shift, xor: xor, and: and, or: or, rotate: rotate, reverse: reverse);
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
      o.bits != bits || o.shift != shift || o.xor != xor || o.and != and || o.or != or || o.rotate != rotate ||
      o.reverse != reverse || o.color != color || o.active != active;
}

/// The 16 lanes, most significant on the left: each lit by its latest bit, glowing by how often it flips, the chosen
/// op's mask bit marked (XOR X, AND a gap, OR 1, Freeze F, the combine's lanes K or E) and a tap flipping it; a lane
/// frozen or flipped now outlined. Keys `bit-lane-<lane>`.
class _Lanes extends StatelessWidget {
  const _Lanes({required this.op});
  final int op;

  // Its own watch: the bits and masks it draws rebuild it alone.
  @override
  Widget build(BuildContext context) => watchDevice(context, _body);

  Widget _body(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final bits = t.value('bits').round().clamp(2, 16);
    final id = _opMask[op];
    final mask = id == null || t.param(id) == null ? 0 : t.value(id).round();
    return DeviceDisplay(builder: (context, f) {
      final live = f?.raw != null && f!.raw!.length >= 38;
      final hot = f?.raw != null && f!.raw!.length >= 45 ? f.at(40).round() | f.at(41).round() : 0;
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
                  marked: id != null && (id == 'and' ? (mask >> i) & 1 == 0 : (mask >> i) & 1 == 1),
                  hot: (hot >> i) & 1 == 1,
                  mark: switch (op) { 1 => 'X', 2 => '-', 3 => '1', 6 => 'F', 8 => 'K', _ => 'E' },
                  color: scope.accent,
                  onTap: id == null || t.param(id) == null || i < 16 - bits ? null : () {
                    DeviceFeel.tap();
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
                2 => 'TAP A LANE: CLEAR IT (AND)',
                3 => 'TAP A LANE: SET IT (OR)',
                4 => 'ROTATE ${t.value('rotate').round()}: lanes wrap round the word',
                5 => 'REVERSE THE LOWEST ${t.value('reverse').round()} LANES',
                6 => 'TAP A LANE: FREEZE IT ON THE STEPS',
                7 => 'FLIPS ${(t.value('flips') * 100).round()} %: lanes flip at random each step',
                _ => 'TAP A LANE: COMBINE IT',
              }, style: const TextStyle(fontSize: 8, letterSpacing: 0.8, color: Neon.dim, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis))),
              const Text('LSB', style: TextStyle(fontSize: 8, color: Neon.dim, fontWeight: FontWeight.w700)),
            ]),
          ]),
        );
      });
    });
  }
}

class _Lane extends StatelessWidget {
  const _Lane({required this.lane, required this.inWord, required this.bit, required this.flips, required this.marked,
    required this.hot, required this.mark, required this.color, required this.onTap});
  final int lane;
  final bool inWord, marked, hot;
  final bool? bit;
  final double flips;
  final String mark;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final on = bit ?? false;
    final masked = inWord && marked;
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
            border: Border.all(color: masked || (inWord && hot) ? Neon.text : (inWord ? c.withValues(alpha: 0.5) : Neon.line),
                width: masked || (inWord && hot) ? 1.6 : 1),
            boxShadow: inWord && flips > 0.05 ? [BoxShadow(color: c.withValues(alpha: 0.5 * flips), blurRadius: 8)] : null,
          ),
          alignment: Alignment.center,
          child: Text(masked ? mark : (on ? '1' : '0'),
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
