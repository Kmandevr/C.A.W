// 1.1.0's clean-up devices' pages: Preen (Denoise: the noise floor and Learn; De-hum: the hum's harmonics dipping; De-reverb: a tail before and after) and Hush (De-click, De-plosive, Breath: waveforms before and after).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/hero.dart';
import '../../kit/repaint.dart';
import '../dyn_drive/common.dart' show ChoiceChips, chipWrap;
import '../eqfilter/variant_cards.dart' show VariantCards, variantOf;
import '../modes_kit.dart' show LitPill, hzLabel, logUnit, paintLogGrid;
import '../space/space_devices.dart' show mergedPage;
import 'voice_devices.dart' show DragHero, knobWrap, rawAt;

// ---------------------------------------------------------------------------------------------------------------
// Preen

void _preenIcon(Canvas c, Rect r, int i, Color col) {
  switch (i) {
    case 0:
      iconCurve(c, r, col.withValues(alpha: 0.5), (x) => 0.75 + 0.08 * math.sin(x * 37) * math.cos(x * 13));
      iconCurve(c, r, col, (x) => 0.35 + 0.25 * math.sin(x * 6) * math.exp(-x));
    case 1:
      for (var k = 1; k <= 4; k++) {
        final x = r.left + r.width * k / 5;
        c.drawLine(Offset(x, r.bottom), Offset(x, r.bottom - r.height * (k.isOdd ? 0.9 : 0.4)), Paint()
          ..color = k.isOdd ? col : col.withValues(alpha: 0.45)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round);
      }
    default:
      iconCurve(c, r, col.withValues(alpha: 0.45), (x) => 1 - math.exp(-x * 2.2));
      iconCurve(c, r, col, (x) => 1 - math.exp(-x * 7));
  }
}

/// Preen: Denoise, De-hum and De-reverb as cards over each one's picture.
class PreenPage extends StatelessWidget {
  const PreenPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cards = VariantCards(height: 48, icon: (c, r, i, col) => _preenIcon(c, r.deflate(2), i, col));
    return switch (variantOf(context)) {
      1 => _DeHum(cards: cards),
      2 => _DeReverb(cards: cards),
      _ => _Denoise(cards: cards),
    };
  }
}

/// Denoise: the noise floor (learned, or tracked with Adaptive) filled under the picture and the gains over it
/// (what each band loses), dragged up and down for Reduction; Learn as a big button.
class _Denoise extends StatelessWidget {
  const _Denoise({required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final hero = HeroCanvas(
      color: scope.accent,
      height: 220,
      caption: 'NOISE FLOOR',
      grid: false,
      readout: DeviceDisplay(builder: (context, f) {
        final raw = f?.raw;
        if ((raw?.length ?? 0) < 74) return Text('≈ −${t.value('reduction').toStringAsFixed(0)} dB');
        return Text('${rawAt(raw, 7).toStringAsFixed(1)} dB mean · ${rawAt(raw, 5).toStringAsFixed(0)} ms');
      }),
      child: DragHero(heroKey: 'denoise-hero', y: 'reduction', painter: (context, raw, active) {
        final s = DeviceScope.of(context);
        final live = (raw?.length ?? 0) >= 74;
        return DenoisePainter(
          noise: live ? [for (var k = 0; k < 32; k++) raw![10 + k]] : null,
          gains: live ? [for (var k = 0; k < 32; k++) raw![42 + k]] : null,
          reduction: s.target.value('reduction'),
          low: s.target.value('low'),
          high: s.target.value('high'),
          color: s.accent,
          second: Neon.yellow,
          active: active);
      }),
    );
    final learn = DeviceDisplay(builder: (context, f) {
      final raw = f?.raw;
      final learning = t.value('learn') >= 0.5;
      final secs = rawAt(raw, 3);
      final has = rawAt(raw, 4) > 0.5;
      final label = learning
          ? 'Learning${secs > 0 ? ' ${secs.toStringAsFixed(1)} s' : '…'} · tap to keep'
          : (has ? 'Learn again' : 'Learn the noise');
      return Row(children: [
        Expanded(child: LitPill(label: label, icon: Icons.hearing, on: learning, height: 48, keyName: 'preen-learn', onTap: () {
          // On: average the noise played (the learned profile is used with Adaptive off); off: keep it.
          if (learning) {
            t.set('learn', 0);
          } else {
            t.setAll({'learn': 1, 'adaptive': 0});
          }
        })),
      ]);
    });
    return mergedPage(context, 'clean',
      cards: cards,
      hero: hero,
      rows: [learn, chipWrap([FittedBox(fit: BoxFit.scaleDown, child: ChoiceChips('adaptive', title: 'ADAPTIVE')), const DeviceToggle('listen', label: 'Listen')])],
      knobs: knobWrap([
        DeviceKnob('reduction', size: 64, label: 'Reduction', color: scope.accent),
        const DeviceKnob('smoothing', size: 50, label: 'Smoothing'),
        const DeviceKnob('sensitivity', size: 46, label: 'Sensitivity'),
      ]),
      more: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const KnobRow(['transient', 'low', 'high'], size: 42),
        chipWrap([FittedBox(fit: BoxFit.scaleDown, child: ChoiceChips('quality', title: 'QUALITY')), const DeviceToggle('monitor', label: 'Monitor')]),
      ]),
    );
  }
}

/// The noise floor on 32 log points (20 Hz..20 kHz; the engine's [noise] dB, else a hiss ≈) filled in grey under
/// a −100..0 dB scale, the gains (the engine's [gains] dB, else −[reduction] where the floor sits) as a [color]
/// line hanging from the top; the protected ends ([low], [high]) shaded.
class DenoisePainter extends CustomPainter {
  DenoisePainter({required this.noise, required this.gains, required this.reduction, required this.low, required this.high,
    required this.color, required this.second, required this.active});
  final List<double>? noise, gains;
  final double reduction, low, high;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(10, 26, size.width - 10, size.height - 10);
    paintLogGrid(canvas, r);
    final n = noise ?? [for (var k = 0; k < 32; k++) -78 + 10 * math.exp(-k / 4) - k * 0.25 + 1.5 * math.sin(k * 1.7)];
    final g = gains ?? [for (var k = 0; k < 32; k++) -reduction * (0.75 + 0.25 * math.sin(k * 0.9).abs())];
    double x(int k) => r.left + r.width * k / 31;
    double y(double db) => r.top + r.height * (-db / 100).clamp(0.0, 1.0);
    for (final (a, b) in [(20.0, low), (high, 20000.0)]) {
      if (b <= a * 1.01) continue;
      canvas.drawRect(Rect.fromLTRB(r.left + r.width * logUnit(a), r.top, r.left + r.width * logUnit(b), r.bottom),
          Paint()..color = second.withValues(alpha: 0.07));
    }
    final floor = Path()..moveTo(x(0), y(n[0]));
    for (var k = 1; k < 32; k++) {
      floor.lineTo(x(k), y(n[k]));
    }
    fillFade(canvas, Path.from(floor), r.bottom, size, Neon.dim, alpha: 0.45);
    strokeGlow(canvas, floor, Neon.dim, width: 1.4, glow: false);
    // The gains: 0 dB at the top, each dB of cut one percent of the height down.
    final cut = Path()..moveTo(x(0), r.top + r.height * (-g[0] / 100).clamp(0.0, 1.0));
    for (var k = 1; k < 32; k++) {
      cut.lineTo(x(k), r.top + r.height * (-g[k] / 100).clamp(0.0, 1.0));
    }
    strokeGlow(canvas, cut, color, width: active ? 2.6 : 2);
    canvas.drawLine(Offset(r.left, r.top), Offset(r.right, r.top), Paint()..color = color.withValues(alpha: 0.3));
    paintLabel(canvas, 'CUT', Offset(r.left + 2, r.top + 8), color, size: 7.5, weight: FontWeight.w800);
    paintLabel(canvas, noise == null ? 'NOISE ≈' : 'NOISE', Offset(r.left + 2, r.bottom - 8), Neon.dim, size: 7.5,
        weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant DenoisePainter o) => paintInputsChanged(
      [...?o.noise, ...?o.gains, o.reduction, o.low, o.high, o.color, o.active],
      [...?noise, ...?gains, reduction, low, high, color, active]);
}

/// De-hum: the hum's harmonics as spikes (their level before in grey), each dipping by what Depth removes (the
/// engine's level now as a tick); drag up and down for Depth, sideways for how many harmonics.
class _DeHum extends StatelessWidget {
  const _DeHum({required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final custom = t.value('frequency').round() == 3;
    return mergedPage(context, 'clean',
      cards: cards,
      hero: HeroCanvas(
        color: scope.accent,
        height: 210,
        caption: 'HUM',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final hz = rawAt(f?.raw, 2);
          return Text(hz > 0 ? 'found ${hz.toStringAsFixed(1)} Hz${rawAt(f?.raw, 4) > 0.5 ? ' · held' : ''}' : 'listening for hum');
        }),
        child: DragHero(heroKey: 'dehum-hero', x: 'harmonics', y: 'depth', painter: (context, raw, active) {
          final s = DeviceScope.of(context);
          final found = rawAt(raw, 2);
          final family = s.target.value('frequency').round();
          final f0 = found > 0 ? found : switch (family) { 2 => 60.0, 3 => s.target.value('custom'), _ => 50.0 };
          return HumPainter(
            f0: f0,
            harmonics: s.target.value('harmonics').round(),
            depth: s.target.value('depth'),
            balance: s.target.value('balance'),
            levels: (raw?.length ?? 0) >= 14 && found > 0 ? [for (var k = 0; k < 8; k++) raw![6 + k]] : null,
            color: s.accent,
            active: active);
        }),
      ),
      rows: [chipWrap([FittedBox(fit: BoxFit.scaleDown, child: ChoiceChips('frequency', title: 'HUM')), const DeviceToggle('follow', label: 'Follow'),
        const DeviceToggle('listen', label: 'Listen')])],
      knobs: KnobRow(['depth', 'harmonics', 'width', 'balance', if (custom) 'custom'], size: 48),
    );
  }
}

/// The hum at [f0] and its first [harmonics] multiples (a log axis 20 Hz..2 kHz): each a grey spike at its level
/// before, and a [color] spike lowered by [depth] (odd or even ones more by [balance]); the engine's [levels] (dB,
/// harmonics 1..8) as white ticks.
class HumPainter extends CustomPainter {
  HumPainter({required this.f0, required this.harmonics, required this.depth, required this.balance, required this.levels,
    required this.color, required this.active});
  final double f0, depth, balance;
  final int harmonics;
  final List<double>? levels;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(12, 26, size.width - 12, size.height - 20);
    double x(double hz) => r.left + r.width * logUnit(hz, lo: 20, hi: 2000);
    double y(double db) => r.bottom - r.height * ((db + 90) / 90).clamp(0.0, 1.0);
    for (final hz in [50.0, 100.0, 200.0, 500.0, 1000.0]) {
      canvas.drawLine(Offset(x(hz), r.top), Offset(x(hz), r.bottom), Paint()..color = Neon.ink.withValues(alpha: 0.05));
      paintLabel(canvas, hzLabel(hz), Offset(x(hz), r.bottom + 9), Neon.dim, size: 8, align: 0);
    }
    canvas.drawLine(Offset(r.left, r.bottom), Offset(r.right, r.bottom), Paint()..color = Neon.ink.withAlpha(0x26));
    for (var k = 1; k <= 16; k++) {
      final hz = f0 * k;
      if (hz > 2000) break;
      final before = -12 - 4.0 * (k - 1);
      final on = k <= harmonics;
      final weight = (1 + (k.isOdd ? -balance : balance) * 0.5).clamp(0.5, 1.5);
      final after = on ? before - 60 * depth * weight : before;
      canvas.drawLine(Offset(x(hz), r.bottom), Offset(x(hz), y(before)), Paint()
        ..color = Neon.dim.withValues(alpha: 0.4)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round);
      strokeGlow(canvas, Path()..moveTo(x(hz), r.bottom)..lineTo(x(hz), y(after)), on ? color : Neon.dim,
          width: active ? 3 : 2.4, glow: on && k < 4);
      if (on && after < before - 1) {
        // The dip: a small notch drawn at the spike's old top.
        canvas.drawLine(Offset(x(hz) - 4, y(before)), Offset(x(hz) + 4, y(before)), Paint()
          ..color = color.withValues(alpha: 0.5)
          ..strokeWidth = 1.2);
      }
      if (levels case final l? when k <= 8) {
        canvas.drawLine(Offset(x(hz) - 5, y(l[k - 1])), Offset(x(hz) + 5, y(l[k - 1])), Paint()
          ..color = Neon.text
          ..strokeWidth = 1.4);
      }
    }
    paintLabel(canvas, '${hzLabel(f0)} Hz × $harmonics', Offset(r.left, r.top + 4), color, size: 8, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant HumPainter o) => paintInputsChanged(
      [o.f0, o.harmonics, o.depth, o.balance, ...?o.levels, o.color, o.active],
      [f0, harmonics, depth, balance, ...?levels, color, active]);
}

/// De-reverb: a sung phrase's tail before (grey: its reverb decaying over T60) and after (the late part taken down
/// by Amount, no lower than the Floor); drag up and down for Amount.
class _DeReverb extends StatelessWidget {
  const _DeReverb({required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return mergedPage(context, 'clean',
      cards: cards,
      hero: HeroCanvas(
        color: scope.accent,
        height: 210,
        caption: 'BEFORE · AFTER',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final raw = f?.raw;
          if ((raw?.length ?? 0) < 41) return Text('≈ T60 ${t.value('decay').toStringAsFixed(1)} s');
          return Text('T60 ${rawAt(raw, 2).toStringAsFixed(2)} s${t.value('decay_mode') < 0.5 ? ' (auto)' : ''}');
        }),
        child: DragHero(heroKey: 'dereverb-hero', y: 'amount', painter: (context, raw, active) {
          final s = DeviceScope.of(context);
          final measured = rawAt(raw, 2);
          return TailPainter(
            t60: (raw?.length ?? 0) >= 41 && measured > 0 ? measured : s.target.value('decay'),
            amount: s.target.value('amount'),
            floor: s.target.value('floor'),
            early: s.target.value('early'),
            color: s.accent,
            active: active);
        }),
      ),
      rows: [chipWrap([FittedBox(fit: BoxFit.scaleDown, child: ChoiceChips('decay_mode', title: 'DECAY')), const DeviceToggle('listen', label: 'Listen')])],
      knobs: knobWrap([
        DeviceKnob('amount', size: 64, label: 'Amount', color: scope.accent),
        const DeviceKnob('decay', size: 46, label: 'Decay'),
        const DeviceKnob('floor', size: 46, label: 'Floor'),
        const DeviceKnob('early', size: 46, label: 'Early'),
      ]),
      more: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const KnobRow(['smoothing', 'low', 'high'], size: 42),
        chipWrap([FittedBox(fit: BoxFit.scaleDown, child: ChoiceChips('quality', title: 'QUALITY')), const DeviceToggle('monitor', label: 'Monitor')]),
      ]),
    );
  }
}

/// Two syllables over 1.6 s: their envelope with the reverb's tail (−60 dB over [t60]) in grey, and after (the
/// part later than [early] down by up to 30 dB × [amount], held over [floor] dB under the tail) in [color]; a
/// −60..0 dB scale.
class TailPainter extends CustomPainter {
  TailPainter({required this.t60, required this.amount, required this.floor, required this.early, required this.color,
    required this.active});
  final double t60, amount, floor, early;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(12, 26, size.width - 12, size.height - 20);
    const span = 1.6;
    double y(double db) => r.bottom - r.height * ((db + 60) / 60).clamp(0.0, 1.0);
    final before = Path(), after = Path();
    for (var i = 0; i <= 160; i++) {
      final s = i / 160 * span;
      // Each syllable: 0.25 s at −6 dB; the room's tail falls 60 dB over T60 from its end.
      var dry = -60.0, tail = -60.0;
      for (final start in [0.05, 0.75]) {
        if (s >= start && s < start + 0.25) dry = -6;
        if (s >= start + 0.25) tail = math.max(tail, -8 - 60 * (s - start - 0.25) / t60);
      }
      final b = math.max(dry, tail);
      // The late part: the tail older than the early window (ms), cut by Amount, at most down to the floor.
      final late = tail > -60 && dry <= -60 && i > 0;
      final cut = late ? math.min(-floor, 30 * amount) : 0.0;
      final a = late ? math.max(tail - cut, -60.0) : b;
      final x = r.left + r.width * s / span;
      i == 0 ? before.moveTo(x, y(b)) : before.lineTo(x, y(b));
      i == 0 ? after.moveTo(x, y(a)) : after.lineTo(x, y(a));
    }
    fillFade(canvas, Path.from(before), r.bottom, size, Neon.dim, alpha: 0.35);
    strokeGlow(canvas, before, Neon.dim, width: 1.4, glow: false);
    fillFade(canvas, Path.from(after), r.bottom, size, color, alpha: 0.3);
    strokeGlow(canvas, after, color, width: active ? 2.6 : 2);
    canvas.drawLine(Offset(r.left, r.bottom), Offset(r.right, r.bottom), Paint()..color = Neon.ink.withAlpha(0x26));
    paintLabel(canvas, 'BEFORE', Offset(r.right, r.top + 4), Neon.dim, size: 7.5, align: 1, weight: FontWeight.w800);
    paintLabel(canvas, 'AFTER', Offset(r.right, r.top + 16), color, size: 7.5, align: 1, weight: FontWeight.w800);
    paintLabel(canvas, '${early.round()} ms kept', Offset(r.left, r.bottom + 9), Neon.dim, size: 8);
  }

  @override
  bool shouldRepaint(covariant TailPainter o) => paintInputsChanged(
      [o.t60, o.amount, o.floor, o.early, o.color, o.active], [t60, amount, floor, early, color, active]);
}

// ---------------------------------------------------------------------------------------------------------------
// Hush

void _hushIcon(Canvas c, Rect r, int i, Color col) {
  iconCurve(c, r, col, (x) {
    final v = 0.5 + 0.25 * math.sin(x * 40) * math.sin(x * math.pi);
    return switch (i) {
      0 => (x - 0.55).abs() < 0.03 ? 0.05 : v,
      1 => x < 0.25 ? 0.5 - 0.45 * math.sin(x / 0.25 * math.pi) : v,
      _ => x > 0.4 && x < 0.6 ? 0.5 + 0.06 * math.sin(x * 160) : v,
    };
  }, steps: 80, width: 1.4);
}

/// Hush: De-click, De-plosive and Breath as cards over a waveform before (grey) and after (in colour), with what
/// the variant fixes in it (≈); drag up and down for Sensitivity.
class HushPage extends StatelessWidget {
  const HushPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final v = variantOf(context);
    final cards = VariantCards(height: 48, icon: (c, r, i, col) => _hushIcon(c, r.deflate(2), i, col));
    final hero = HeroCanvas(
      color: scope.accent,
      height: 220,
      caption: 'BEFORE · AFTER ≈',
      grid: false,
      readout: DeviceDisplay(builder: (context, f) {
        final raw = f?.raw;
        if (raw == null || raw.length < 7) return const Text('');
        return Text(switch (v) {
          1 => '${rawAt(raw, 3).round()} plosives · ${rawAt(raw, 2).toStringAsFixed(1)} dB',
          2 => '${rawAt(raw, 3).round()} breaths · ${rawAt(raw, 2).toStringAsFixed(1)} dB',
          _ => '${rawAt(raw, 2).round()} clicks repaired',
        });
      }),
      child: DragHero(heroKey: 'hush-hero', y: 'sensitivity', painter: (context, raw, active) {
        final s = DeviceScope.of(context);
        return BeforeAfterPainter(
          variant: v,
          sensitivity: s.target.value('sensitivity'),
          amount: switch (v) { 1 => s.target.value('amount') / 24, 2 => s.target.value('range') / 40, _ => 1 },
          color: s.accent,
          active: active);
      }),
    );
    return mergedPage(context, 'vocalclean',
      cards: cards,
      hero: hero,
      rows: [chipWrap([
        if (v == 0) FittedBox(fit: BoxFit.scaleDown, child: ChoiceChips('mode', title: 'MODE')),
        if (v == 2) const DeviceToggle('keep', label: 'Keep between phrases'),
        const DeviceToggle('listen', label: 'Listen'),
      ])],
      knobs: knobWrap([
        DeviceKnob('sensitivity', size: 62, label: 'Sensitivity', color: scope.accent),
        for (final id in switch (v) { 1 => ['frequency', 'amount', 'length'], 2 => ['range', 'fade'], _ => ['length'] })
          DeviceKnob(id, size: 46),
      ]),
      more: t.param('output') == null ? null : const KnobRow(['output'], size: 42),
    );
  }
}

/// A voice's waveform over about a second, before (grey, top lane) and after (in [color], bottom lane): De-click's
/// clicks, De-plosive's low thump and Breath's noisy breath, each found when [sensitivity] reaches it and taken
/// down by [amount] (0..1).
class BeforeAfterPainter extends CustomPainter {
  BeforeAfterPainter({required this.variant, required this.sensitivity, required this.amount, required this.color,
    required this.active});
  final int variant;
  final double sensitivity, amount;
  final Color color;
  final bool active;

  /// The voice at [u] 0..1 and what the variant fixes there (0 elsewhere).
  (double, double) _sample(double u) {
    final syllable = math.max(0.0, math.sin(((u - 0.08) / 0.84 * 2).clamp(0.0, 2.0) * math.pi)).toDouble();
    var voice = syllable * (0.55 * math.sin(u * 260) + 0.2 * math.sin(u * 790 + 1));
    var event = 0.0;
    switch (variant) {
      case 0:
        // Clicks of four sizes; the quieter ones need more sensitivity.
        for (final (at, size) in [(0.2, 0.9), (0.36, 0.5), (0.63, 0.7), (0.8, 0.35)]) {
          if ((u - at).abs() < 0.004) event = size * (u < at ? 1 : -1);
        }
      case 1:
        if (u > 0.05 && u < 0.2) event = 0.85 * math.sin((u - 0.05) / 0.15 * math.pi) * math.sin((u - 0.05) * 90);
      default:
        if (u > 0.44 && u < 0.56) {
          voice = 0;
          event = 0.2 * math.sin((u - 0.44) / 0.12 * math.pi) * math.sin(u * 4000) * math.cos(u * 2300);
        }
    }
    return (voice, event);
  }

  double _kept(double event) {
    if (event == 0) return 0;
    final found = variant == 0 ? event.abs() > 1 - sensitivity : sensitivity > 0.15;
    return found ? event * (1 - amount) : event;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final h = (size.height - 34) / 2;
    final top = Rect.fromLTWH(12, 24, size.width - 24, h), bottom = Rect.fromLTWH(12, 28 + h, size.width - 24, h);
    final before = Path(), after = Path();
    const n = 360;
    for (var i = 0; i <= n; i++) {
      final u = i / n;
      final (v, e) = _sample(u);
      final x = top.left + top.width * u;
      final yb = top.center.dy - (v + e).clamp(-1.0, 1.0) * h * 0.46;
      final ya = bottom.center.dy - (v + _kept(e)).clamp(-1.0, 1.0) * h * 0.46;
      i == 0 ? before.moveTo(x, yb) : before.lineTo(x, yb);
      i == 0 ? after.moveTo(x, ya) : after.lineTo(x, ya);
    }
    for (final lane in [top, bottom]) {
      canvas.drawLine(Offset(lane.left, lane.center.dy), Offset(lane.right, lane.center.dy), Paint()..color = Neon.ink.withAlpha(0x1c));
    }
    strokeGlow(canvas, before, Neon.dim, width: 1.2, glow: false);
    strokeGlow(canvas, after, color, width: active ? 1.8 : 1.4);
    paintLabel(canvas, 'BEFORE', Offset(top.left, top.top + 6), Neon.dim, size: 7.5, weight: FontWeight.w800);
    paintLabel(canvas, 'AFTER', Offset(bottom.left, bottom.top + 6), color, size: 7.5, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant BeforeAfterPainter o) => paintInputsChanged(
      [o.variant, o.sensitivity, o.amount, o.color, o.active], [variant, sensitivity, amount, color, active]);
}
