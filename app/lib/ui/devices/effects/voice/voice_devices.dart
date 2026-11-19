// 1.1.0's voice devices' pages: the Exciter (Glint: harmonics bars), the Vocoder (Mimic: band bars, the carrier choice and the formant shift) and Lark's registration (lark_device.dart), and the drag hero they and the clean-up pages share.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_registry.dart';
import '../../device_scope.dart';
import '../../sidechain_bar.dart' show KeyFilterControls;
import '../../kit/controls.dart';
import '../../kit/device_style.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../../kit/repaint.dart';
import '../dyn_drive/common.dart' show ChoiceChips, chipWrap;
import '../eqfilter/variant_cards.dart' show VariantCards, variantOf;
import '../modes_kit.dart' show travelBy, hzLabel, logUnit;
import '../space/space_devices.dart' show mergedPage, pitchAccent;
import 'clean_devices.dart';
import 'lark_device.dart';

/// The voice and clean-up devices' pages by id (effect_editors.dart merges them in). A page with variants keys its
/// section by the variant, so a new variant builds afresh, and shows them as cards ([DeviceEditorEntry.ownsVariant]).
final Map<String, DeviceEditorEntry> voiceEditors = {
  'org.caw.exciter': _cards('exciter', 'EXCITE', Icons.auto_awesome, DeviceFamily.drive, () => const GlintPage()),
  'org.caw.vocoder': DeviceEditorEntry((_) => [DeviceSection('vocoder', 'VOCODER', Icons.record_voice_over_outlined,
      (_) => const MimicPage())], family: DeviceFamily.creative),
  'org.caw.clean': _cards('clean', 'CLEAN', Icons.cleaning_services_outlined, DeviceFamily.utility, () => const PreenPage()),
  'org.caw.vocalclean': _cards('vocalclean', 'VOCAL', Icons.mic_none, DeviceFamily.utility, () => const HushPage()),
  // Lark (pitch correction): the Pitch family's pink.
  'org.caw.pitchfix': DeviceEditorEntry((_) => [DeviceSection('pitchfix', 'PITCH', Icons.multiline_chart,
      (_) => const LarkPage())], family: DeviceFamily.creative, accent: pitchAccent),
};

DeviceEditorEntry _cards(String id, String label, IconData icon, DeviceFamily family, Widget Function() page) =>
    DeviceEditorEntry((t) => [DeviceSection('$id-${t.info?.variantIndex ?? 0}', label, icon, (_) => page())],
        family: family, ownsVariant: true);

/// A hero that drags [x] sideways and [y] up and down (each over its whole travel across the hero; a second finger
/// or Shift for fine), double-tap: both to their defaults. [painter] draws it from the newest display frame.
class DragHero extends StatefulWidget {
  const DragHero({super.key, required this.heroKey, this.x, this.y, required this.painter, this.xTravel = 1, this.yTravel = 1});
  final String heroKey;
  final String? x, y;
  final double xTravel, yTravel;
  final CustomPainter Function(BuildContext context, List<double>? raw, bool active) painter;

  @override
  State<DragHero> createState() => _DragHeroState();
}

class _DragHeroState extends State<DragHero> {
  bool _active = false;
  double _x = 0, _y = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      return GrabGesture(
        key: ValueKey(widget.heroKey),
        onStart: (_, _) {
          if (widget.x case final x?) _x = t.value(x);
          if (widget.y case final y?) _y = t.value(y);
          DeviceFeel.grab();
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          final values = <String, double>{};
          if (widget.x case final x?) {
            _x = travelBy(scope, x, _x, u.delta.dx / size.width * widget.xTravel * fine);
            values[x] = _x;
          }
          if (widget.y case final y?) {
            _y = travelBy(scope, y, _y, -u.delta.dy / size.height * widget.yTravel * fine);
            values[y] = _y;
          }
          for (final e in values.entries) {
            t.setLive(e.key, e.value);
          }
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({
          for (final id in [?widget.x, ?widget.y]) id: t.param(id)?.defaultValue ?? t.value(id),
        }),
        child: DeviceDisplay(builder: (context, f) =>
            CustomPaint(size: size, painter: widget.painter(context, f?.raw, _active))),
      );
    });
  }
}

/// A line of knobs of different sizes, spread evenly; on a narrow panel (inline in the FX stack) it wraps.
Widget knobWrap(List<Widget> knobs) => Wrap(alignment: WrapAlignment.spaceEvenly, runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.end, children: knobs);

/// Float [i] of a display frame's [raw] floats, or [fallback].
double rawAt(List<double>? raw, int i, [double fallback = 0]) => raw != null && i < raw.length ? raw[i] : fallback;

double _db(double gain) => gain <= 1e-6 ? -120 : 20 * math.log(gain) / math.ln10;

// ---------------------------------------------------------------------------------------------------------------
// Glint (the Exciter)

/// Glint: Exciter and Bass as cards over the harmonics bars (harmonics 2 to 9, relative to the band: the engine's
/// while it plays, else worked out from the knobs ≈); drag up for Amount, sideways for Character (even ↔ odd).
class GlintPage extends StatelessWidget {
  const GlintPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final bass = variantOf(context) == 1;
    final cards = VariantCards(height: 48, icon: (c, r, i, col) {
      for (var k = 0; k < 5; k++) {
        final h = i == 0 ? [0.3, 0.9, 0.7, 0.45, 0.3][k] : [0.95, 0.6, 0.45, 0.3, 0.2][k];
        final x = r.left + r.width * (0.12 + k * 0.19);
        c.drawLine(Offset(x, r.bottom), Offset(x, r.bottom - r.height * h), Paint()
          ..color = k == 0 ? col.withValues(alpha: 0.45) : col
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
      }
    });
    return mergedPage(context, 'exciter',
      cards: cards,
      hero: HeroCanvas(
        color: scope.accent,
        height: 210,
        caption: 'HARMONICS',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final live = (f?.raw?.length ?? 0) >= 17;
          return Text(live
              ? '${hzLabel(f!.at(3))} Hz · harmonics ${(f.at(5) - f.at(4)).clamp(-60.0, 24.0).toStringAsFixed(1)} dB${f.at(16) > 1.5 ? ' · 2x' : ''}'
              : '≈ ${hzLabel(scope.target.value('freq'))} Hz');
        }),
        child: DragHero(heroKey: 'glint-hero', x: 'character', y: 'amount', painter: (context, raw, active) {
          final t = DeviceScope.of(context).target;
          return HarmonicsPainter(
            bars: (raw?.length ?? 0) >= 17 ? [for (var k = 0; k < 8; k++) raw![8 + k]] : glintBars(
                amount: t.value('amount'), character: t.value('character'), density: bass ? t.value('density') : 0),
            live: (raw?.length ?? 0) >= 17,
            character: t.value('character'),
            color: DeviceScope.of(context).accent,
            second: Neon.yellow,
            active: active);
        }),
      ),
      rows: [chipWrap([const DeviceToggle('listen', label: 'Listen')])],
      knobs: KnobRow(['freq', 'amount', 'character', if (bass) ...['density', 'cut'] else 'tone'], size: 50),
      more: const KnobRow(['output'], size: 42),
    );
  }
}

/// Harmonics 2 to 9 in dB relative to the band, as the engine adds them for a sine (≈: its weights, the even part
/// by 1 − Character, the odd by Character; Density adds the 4th and 5th).
List<double> glintBars({required double amount, required double character, double density = 0}) {
  final a = 2 * amount;
  final w = [a * (1 - character), a * character, a * density * (1 - character) * 0.7, a * density * character * 0.7];
  return [for (var k = 0; k < 8; k++) k < w.length ? _db(w[k]) : -120];
}

/// Eight bars (harmonics 2..9) from −48 to +6 dB, even ones in [color], odd ones in [second]; a band at the left as
/// the fundamental's level (0 dB) and the even/odd balance as a slider under them.
class HarmonicsPainter extends CustomPainter {
  HarmonicsPainter({required this.bars, required this.live, required this.character, required this.color, required this.second,
    required this.active});
  final List<double> bars;
  final bool live;
  final double character;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(16, 28, size.width - 16, size.height - 30);
    double y(double db) => r.bottom - r.height * ((db + 48) / 54).clamp(0.0, 1.0);
    for (final db in [0.0, -12.0, -24.0, -36.0]) {
      canvas.drawLine(Offset(r.left, y(db)), Offset(r.right, y(db)), Paint()..color = Neon.ink.withValues(alpha: db == 0 ? 0.14 : 0.05));
      paintLabel(canvas, '${db.round()}', Offset(r.right, y(db) - 6), Neon.dim, size: 7.5, align: 1);
    }
    final slot = r.width / 9;
    // The fundamental (the band) for scale.
    final f0 = Rect.fromLTRB(r.left + slot * 0.25, y(0), r.left + slot * 0.75, r.bottom);
    canvas.drawRRect(RRect.fromRectAndRadius(f0, const Radius.circular(4)), Paint()..color = Neon.dim.withValues(alpha: 0.35));
    paintLabel(canvas, '1', Offset(f0.center.dx, r.bottom + 9), Neon.dim, size: 8, align: 0);
    for (var k = 0; k < 8; k++) {
      final c = k.isEven ? color : second;
      final x = r.left + slot * (k + 1);
      final b = Rect.fromLTRB(x + slot * 0.2, y(bars[k]), x + slot * 0.8, r.bottom);
      if (bars[k] > -48) {
        canvas.drawRRect(RRect.fromRectAndRadius(b, const Radius.circular(4)), Paint()
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: Neon.ramp([c.withValues(alpha: active ? 0.95 : 0.8), c.withValues(alpha: 0.15)])).createShader(b));
        strokeGlow(canvas, Path()..moveTo(b.left, b.top)..lineTo(b.right, b.top), c, width: 2, glow: k < 2);
      }
      paintLabel(canvas, '${k + 2}', Offset(b.center.dx, r.bottom + 9), k.isEven ? color : second, size: 8, align: 0,
          weight: FontWeight.w700);
    }
    // Even ↔ odd.
    final sy = size.height - 9;
    canvas.drawLine(Offset(r.left + 40, sy), Offset(r.right - 40, sy), Paint()
      ..shader = LinearGradient(colors: [color, second]).createShader(Rect.fromLTRB(r.left + 40, sy - 1, r.right - 40, sy + 1))
      ..strokeWidth = 2);
    paintLabel(canvas, 'EVEN', Offset(r.left, sy), color, size: 7, weight: FontWeight.w800);
    paintLabel(canvas, 'ODD', Offset(r.right, sy), second, size: 7, align: 1, weight: FontWeight.w800);
    paintHandle(canvas, Offset(r.left + 40 + (r.width - 80) * character, sy), Color.lerp(color, second, character)!,
        active: active, r: 4.5);
    if (!live) paintLabel(canvas, '≈', Offset(r.left, r.top - 8), Neon.dim, size: 9);
  }

  @override
  bool shouldRepaint(covariant HarmonicsPainter o) => paintInputsChanged(
      [...o.bars, o.live, o.character, o.color, o.second, o.active], [...bars, live, character, color, second, active]);
}

// ---------------------------------------------------------------------------------------------------------------
// Mimic (the Vocoder)

/// Mimic: the band bars (the modulator's level in each band, the carrier's as a tick; the engine's while it plays,
/// else a sung vowel ≈ moved by Formant), dragged sideways for the formant shift; the carrier choice (Built-in with
/// its wave, or the key's audio) and Freeze over the knobs; the carrier's voice and the bank under MORE.
class MimicPage extends StatelessWidget {
  const MimicPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final builtIn = t.value('carrier') < 0.5;
    return mergedPage(context, 'vocoder',
      hero: HeroCanvas(
        color: scope.accent,
        height: 210,
        caption: 'BANDS',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final live = (f?.raw?.length ?? 0) >= 8;
          final formant = t.value('formant');
          final shift = '${formant >= 0 ? '+' : ''}${formant.toStringAsFixed(1)} st';
          if (!live) return Text('≈ formant $shift');
          final carrier = f!.at(3) > 0.5 ? 'key ${f.at(7).toStringAsFixed(0)} dB' : '${f.at(4).round()} notes';
          return Text('${f.at(2).round()} bands · $carrier · $shift');
        }),
        child: DragHero(heroKey: 'mimic-hero', x: 'formant', xTravel: 0.8, painter: (context, raw, active) {
          final s = DeviceScope.of(context);
          final n = (rawAt(raw, 2)).round();
          final live = n > 0 && (raw?.length ?? 0) >= 8 + 3 * n;
          return BandsPainter(
            centres: live ? [for (var k = 0; k < n; k++) raw![8 + 3 * k]] : null,
            modulator: live ? [for (var k = 0; k < n; k++) raw![9 + 3 * k]] : null,
            carrier: live ? [for (var k = 0; k < n; k++) raw![10 + 3 * k]] : null,
            bands: const [20, 12, 20, 32][s.target.value('bands').round().clamp(0, 3)],
            low: s.target.value('low'),
            high: s.target.value('high'),
            formant: s.target.value('formant'),
            frozen: s.target.value('freeze') > 0.5,
            color: s.accent,
            second: Neon.yellow,
            active: active);
        }),
      ),
      rows: [chipWrap([
        FittedBox(fit: BoxFit.scaleDown, child: ChoiceChips('carrier', title: 'CARRIER')),
        if (builtIn) FittedBox(fit: BoxFit.scaleDown, child: ChoiceChips('wave', title: 'WAVE')),
        const DeviceToggle('freeze', label: 'Freeze'),
      ]), if (!builtIn && !DeviceScope.isInline(context)) const KeyFilterControls()],
      knobs: knobWrap([
        DeviceKnob('formant', size: 64, label: 'Formant', color: scope.accent),
        const DeviceKnob('sibilance', size: 46, label: 'Sibilance'),
        const DeviceKnob('width', size: 46, label: 'Width'),
        const DeviceKnob('mix', size: 46, label: 'Mix'),
      ]),
      more: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (builtIn) const KnobRow(['note', 'octave', 'unison', 'detune', 'glide'], size: 40),
        chipWrap([FittedBox(fit: BoxFit.scaleDown, child: ChoiceChips('bands', title: 'BANDS'))]),
        const KnobRow(['low', 'high', 'sharpness', 'attack', 'release', 'output'], size: 40),
      ]),
    );
  }
}

/// The vocoder's bands on a log axis ([low]..[high]): each band a bar of the modulator's level in [color] and the
/// carrier's as a [second] tick (the engine's [centres], [modulator] and [carrier] dB), else [bands] bars of a sung
/// "ah" (formants at 700, 1,200 and 2,600 Hz) moved by [formant] semitones (≈); Freeze dims the bars' tops.
class BandsPainter extends CustomPainter {
  BandsPainter({required this.centres, required this.modulator, required this.carrier, required this.bands, required this.low,
    required this.high, required this.formant, required this.frozen, required this.color, required this.second,
    required this.active});
  final List<double>? centres, modulator, carrier;
  final int bands;
  final double low, high, formant;
  final bool frozen, active;
  final Color color, second;

  /// A sung vowel's level (dB) at [hz], its formants moved by [shift] semitones.
  static double vowel(double hz, double shift) {
    final r = math.pow(2, shift / 12).toDouble();
    var g = 0.0;
    for (final (f, a) in [(700.0, 1.0), (1200.0, 0.7), (2600.0, 0.35)]) {
      final d = math.log(hz / (f * r)) / math.ln2;
      g += a * math.exp(-d * d / 0.08);
    }
    return _db(g + 0.02) - 6 * math.log(hz / 200) / math.ln2 * 0.5;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(12, 28, size.width - 12, size.height - 24);
    final n = centres?.length ?? bands;
    final hzs = centres ?? [for (var k = 0; k < n; k++) low * math.pow(high / low, (k + 0.5) / n).toDouble()];
    final mod = modulator ?? [for (final hz in hzs) vowel(hz, formant)];
    double y(double db) => r.bottom - r.height * ((db + 60) / 60).clamp(0.0, 1.0);
    final slot = r.width / n;
    for (var k = 0; k < n; k++) {
      final x = r.left + slot * k;
      final b = Rect.fromLTRB(x + slot * 0.14, y(mod[k]), x + slot * 0.86, r.bottom);
      canvas.drawRRect(RRect.fromRectAndRadius(b, Radius.circular(math.min(3, slot / 4))), Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: Neon.ramp([color.withValues(alpha: frozen ? 0.45 : (active ? 0.95 : 0.8)), color.withValues(alpha: 0.12)]))
            .createShader(b));
      if (carrier case final c?) {
        canvas.drawLine(Offset(b.left, y(c[k])), Offset(b.right, y(c[k])), Paint()
          ..color = second
          ..strokeWidth = 2);
      }
    }
    canvas.drawLine(Offset(r.left, r.bottom), Offset(r.right, r.bottom), Paint()..color = Neon.ink.withAlpha(0x26));
    for (final hz in [100.0, 1000.0, 10000.0]) {
      if (hz < hzs.first || hz > hzs.last) continue;
      final u = (logUnit(hz, lo: hzs.first, hi: hzs.last) * (n - 1) + 0.5) / n;
      paintLabel(canvas, hzLabel(hz), Offset(r.left + r.width * u, r.bottom + 9), Neon.dim, size: 8, align: 0);
    }
    // The formant shift: an arrow from 0 to its semitones over the bars.
    final mid = r.center.dx, to = mid + formant / 12 * r.width * 0.4;
    strokeGlow(canvas, Path()..moveTo(mid, r.top - 4)..lineTo(to, r.top - 4), color, width: 3);
    paintHandle(canvas, Offset(to, r.top - 4), color, active: active, r: 5);
    paintLabel(canvas, frozen ? 'FROZEN' : (centres == null ? '≈ “AH”' : 'VOICE'), Offset(r.left, r.top + 6),
        frozen ? second : color, size: 7.5, weight: FontWeight.w800);
    if (carrier != null) paintLabel(canvas, 'CARRIER', Offset(r.right, r.top + 6), second, size: 7.5, align: 1, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant BandsPainter o) => paintInputsChanged(
      [...?o.modulator, ...?o.carrier, ...?o.centres, o.bands, o.low, o.high, o.formant, o.frozen, o.color, o.second, o.active],
      [...?modulator, ...?carrier, ...?centres, bands, low, high, formant, frozen, color, second, active]);
}
