// The Drive's 1.1.0 modes (org.caw.drive 4-6): Amp's amp face, Pedal's stompbox with its footswitch, Bands' crossover spectrum and band strips; each keeps Drive's transfer curve.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/device_style.dart' show spectrumColors;
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';
import '../modes_kit.dart';
import '../space/space_devices.dart' show mergedPage;
import 'common.dart';
import 'drive_device.dart';

/// Amp's card icon: an amp head (a box, a grille line and a row of knobs).
void driveAmpIcon(Canvas canvas, Rect r, Color c) {
  final box = Rect.fromCenter(center: r.center, width: r.width * 0.86, height: r.height * 0.8);
  canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(3)), Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.4);
  for (var k = 0; k < 5; k++) {
    canvas.drawCircle(Offset(box.left + box.width * (k + 1) / 6, box.top + box.height * 0.32), 1.8, Paint()..color = c);
  }
  canvas.drawLine(Offset(box.left + 3, box.top + box.height * 0.66), Offset(box.right - 3, box.top + box.height * 0.66),
      Paint()..color = c.withValues(alpha: 0.5));
}

/// Pedal's card icon: a stompbox with two knobs and a footswitch.
void drivePedalIcon(Canvas canvas, Rect r, Color c) {
  final box = Rect.fromCenter(center: r.center, width: math.min(r.width * 0.5, r.height * 0.75), height: r.height * 0.95);
  canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(4)), Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.4);
  for (final dx in [-0.25, 0.25]) {
    canvas.drawCircle(Offset(box.center.dx + dx * box.width, box.top + box.height * 0.25), 2, Paint()..color = c);
  }
  canvas.drawCircle(Offset(box.center.dx, box.top + box.height * 0.72), box.width * 0.16, Paint()..color = c);
}

/// Bands' card icon: three bands' bars split by two crossover lines.
void driveBandsIcon(Canvas canvas, Rect r, Color c) {
  const h = [0.55, 0.85, 0.4];
  final w = r.width / 3;
  for (var k = 0; k < 3; k++) {
    final top = r.bottom - r.height * h[k];
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(r.left + k * w + 2, top, r.left + (k + 1) * w - 2, r.bottom),
        const Radius.circular(2)), Paint()..color = c.withValues(alpha: 0.35 + 0.2 * k));
  }
  for (var k = 1; k < 3; k++) {
    canvas.drawLine(Offset(r.left + k * w, r.top), Offset(r.left + k * w, r.bottom), Paint()
      ..color = c
      ..strokeWidth = 1.4);
  }
}

/// Bands' band colours: blue, green, orange, red, low to high.
Color bandColor(int k) => spectrumColors()[const [5, 3, 1, 7][k.clamp(0, 3)]];

/// The Drive's Amp, Pedal and Bands modes under the Drive's [cards].
class DriveModesPage extends StatelessWidget {
  const DriveModesPage({super.key, required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) => switch (DeviceScope.of(context).target.info?.variantIndex ?? 4) {
        5 => _PedalPage(cards: cards),
        6 => _BandsPage(cards: cards),
        _ => _AmpPage(cards: cards),
      };
}

Widget _curveHero(BuildContext context, {int band = 0, double height = 180, String? readoutParam}) {
  final scope = DeviceScope.of(context);
  final id = readoutParam ?? driveParamOf(scope.target.info?.variantIndex ?? 0, band: band);
  return HeroCanvas(
    color: scope.accent,
    height: height,
    grid: false,
    readout: Builder(builder: (context) => Text('${shortParamLabel(scope.target.param(id), 'Drive')} ${valueText(scope, id)}')),
    child: DriveHero(key: ValueKey('drive-hero-band-$band'), band: band),
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Amp

class _AmpPage extends StatelessWidget {
  const _AmpPage({required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final inline = DeviceScope.isInline(context);
    const face = _AmpFace();
    if (inline) return effectPage('drive', [cards, _curveHero(context), face]);
    return mergedPage(context, 'drive', cards: cards, hero: _curveHero(context), knobs: face,
        more: const ChoiceChips('oversample', title: 'OVERSAMPLE'));
  }
}

/// The amp's control panel: the voicing as a channel selector and its pilot light, then the tone stack's knobs in a
/// row as on an amp (Gain, Bass, Mid, Treble, Presence, Output), on a tolex-framed plate.
class _AmpFace extends StatelessWidget {
  const _AmpFace();

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final c = scope.accent;
    final inline = DeviceScope.isInline(context);
    return Container(
      key: const ValueKey('amp-face'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Color.lerp(Neon.bg, Colors.black, 0.35),
        border: Border.all(color: Neon.line),
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
            Color.lerp(Neon.panelHi, c, 0.16)!, Color.lerp(Neon.panel, c, 0.06)!,
          ]),
          border: Border.all(color: c.withValues(alpha: 0.45)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            LedLight(on: true, color: redColor(), size: 10),
            const SizedBox(width: 8),
            Text('VOICING', style: TextStyle(fontSize: 9, letterSpacing: 1.6, fontWeight: FontWeight.w800, color: c)),
            const SizedBox(width: 8),
            const Expanded(child: Align(alignment: Alignment.centerLeft,
                child: FittedBox(fit: BoxFit.scaleDown, child: DeviceChoice('voicing', maxSegments: 4)))),
          ]),
          const SizedBox(height: 4),
          Container(height: 1, color: c.withValues(alpha: 0.3)),
          KnobRow(const ['gain', 'bass', 'mid', 'treble', 'presence', 'output'], size: inline ? 38 : 44, color: c),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Pedal

/// Each pedal type's enclosure colour: Overdrive green, Distortion red, Fuzz pink.
Color _pedalColor(int type) => spectrumColors()[const [3, 7, 0][type.clamp(0, 2)]];

class _PedalPage extends StatelessWidget {
  const _PedalPage({required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final inline = DeviceScope.isInline(context);
    if (inline) return effectPage('drive', [cards, _curveHero(context, height: 150), const _PedalFace()]);
    return mergedPage(context, 'drive', cards: cards, hero: _curveHero(context), knobs: const _PedalFace(),
        more: const ChoiceChips('oversample', title: 'OVERSAMPLE'));
  }
}

/// The stompbox: its type's colour, Drive, Tone and Level knobs on top, the type as a switch, the LED and a big
/// footswitch that bypasses the device (the header's power, as on a pedal).
class _PedalFace extends StatelessWidget {
  const _PedalFace();

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final type = t.value('type').round();
    final c = _pedalColor(type);
    final inline = DeviceScope.isInline(context);
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 340), child: Container(
      key: const ValueKey('pedal-face'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [
          Color.lerp(Neon.panelHi, c, 0.34)!, Color.lerp(Neon.panel, c, 0.18)!,
        ]),
        border: Border.all(color: c, width: 1.5),
        boxShadow: [BoxShadow(color: c.withValues(alpha: 0.22), blurRadius: 16)],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        KnobRow(const ['drive', 'tone', 'level'], size: inline ? 40 : 48, color: c),
        FittedBox(fit: BoxFit.scaleDown, child: DeviceChoice('type', maxSegments: 3, color: c)),
        const SizedBox(height: 10),
        ListenableBuilder(listenable: t.state, builder: (context, _) {
          final on = !t.bypass;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            LedLight(on: on, color: redColor(), size: 14),
            const SizedBox(height: 10),
            Semantics(button: true, toggled: on, label: on ? 'Footswitch: on' : 'Footswitch: bypassed', child: GestureDetector(
              key: const ValueKey('pedal-footswitch'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                DeviceFeel.grab();
                t.setBypass(on);
              },
              child: Container(
                width: inline ? 54 : 66,
                height: inline ? 54 : 66,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [Neon.ink.withValues(alpha: 0.5), Neon.ink.withValues(alpha: 0.2)]),
                  border: Border.all(color: Neon.ink.withValues(alpha: 0.5), width: 3),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 6, offset: const Offset(0, 3))],
                ),
                child: Center(child: Container(width: inline ? 30 : 38, height: inline ? 30 : 38, decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color.lerp(Neon.panelHi, Neon.ink, 0.25),
                  border: Border.all(color: Neon.ink.withValues(alpha: 0.4)),
                ))),
              ),
            )),
            const SizedBox(height: 4),
            Text(on ? 'ON' : 'BYPASSED', style: TextStyle(fontSize: 9, letterSpacing: 1.4, fontWeight: FontWeight.w800,
                color: on ? Neon.text : Neon.dim)),
          ]);
        }),
      ]),
    )));
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Bands

class _BandsPage extends StatefulWidget {
  const _BandsPage({required this.cards});
  final Widget cards;

  @override
  State<_BandsPage> createState() => _BandsPageState();
}

class _BandsPageState extends State<_BandsPage> {
  int _band = 0;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final bp = t.param('bands');
    final count = bp == null ? 3 : (t.value('bands') - bp.min).round() + 1;
    final band = _band.clamp(0, count - 1);
    void pick(int k) => setState(() => _band = k);
    final spectrum = _BandSpectrum(count: count, selected: band, onSelect: pick);
    final inline = DeviceScope.isInline(context);
    if (inline) {
      return effectPage('drive', [widget.cards, spectrum, _BandStrip(band: band, selected: true, onSelect: pick)]);
    }
    return mergedPage(context, 'drive', cards: widget.cards,
      hero: Column(mainAxisSize: MainAxisSize.min, children: [spectrum, _curveHero(context, band: band, height: 170)]),
      rows: [
        chipWrap([smallBandsLabel(), const DeviceChoice('bands', maxSegments: 4)]),
        for (var k = 0; k < count; k++) _BandStrip(band: k, selected: k == band, onSelect: pick),
      ],
      knobs: const SizedBox.shrink());  // Output and Mix: the footer's
  }

  static Widget smallBandsLabel() => const Text('BANDS',
      style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim));
}

/// The bands on a log frequency axis, each its colour with its live level (in faint, out solid); 1-3 crossover
/// handles dragged sideways; a tap on a band selects it.
class _BandSpectrum extends StatefulWidget {
  const _BandSpectrum({required this.count, required this.selected, required this.onSelect});
  final int count, selected;
  final ValueChanged<int> onSelect;

  @override
  State<_BandSpectrum> createState() => _BandSpectrumState();
}

class _BandSpectrumState extends State<_BandSpectrum> {
  int? _grip;
  double _u = 0;

  List<double> _xs(DeviceScope scope) => [for (var k = 1; k < widget.count; k++) scope.target.value('x$k')];

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return HeroCanvas(color: scope.accent, height: 170, caption: 'BANDS', grid: false, child: LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final plot = Rect.fromLTRB(8, 22, w - 8, h - 6);
      int bandAt(double x) {
        final hz = logHz((x - plot.left) / plot.width);
        var k = 0;
        for (final xc in _xs(scope)) {
          if (hz > xc) k++;
        }
        return k;
      }
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('bands-spectrum'),
        grabs: (p) {
          final xs = _xs(scope);
          for (var k = 0; k < xs.length; k++) {
            if ((plot.left + logUnit(xs[k]) * plot.width - p.dx).abs() < 22) return true;
          }
          return false;
        },
        onTap: (p) {
          DeviceFeel.tap();
          widget.onSelect(bandAt(p.dx));
        },
        onStart: (p, _) {
          final xs = _xs(scope);
          var best = 0;
          for (var k = 1; k < xs.length; k++) {
            if ((plot.left + logUnit(xs[k]) * plot.width - p.dx).abs() < (plot.left + logUnit(xs[best]) * plot.width - p.dx).abs()) best = k;
          }
          _grip = best;
          _u = logUnit(xs[best]);
          DeviceFeel.grab();
          setState(() {});
        },
        onUpdate: (u) {
          final g = _grip;
          if (g == null) return;
          _u = (_u + u.delta.dx / plot.width * DeviceFingers.fine).clamp(0.0, 1.0);
          t.setLive('x${g + 1}', clampParam(scope, 'x${g + 1}', logHz(_u)));
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _grip = null);
        },
        onDoubleTap: (_) => t.setAll({for (var k = 1; k <= 3; k++) if (t.param('x$k') case final p?) 'x$k': p.defaultValue}),
        child: CustomPaint(size: Size(w, h), painter: _BandsPainter(
          plot: plot,
          xs: _xs(scope),
          selected: widget.selected,
          grip: _grip,
          levels: [
            for (var k = 0; k < widget.count; k++)
              (f?.raw == null ? null : f!.at(6 + k * 5, -120), f?.raw == null ? null : f!.at(7 + k * 5, -120),
                  f?.raw == null ? true : f!.at(10 + k * 5, 1) >= 0.5 && t.value('b${k + 1}_mute') < 0.5),
          ],
          muted: [for (var k = 0; k < widget.count; k++) t.value('b${k + 1}_mute') >= 0.5],
          types: [for (var k = 0; k < widget.count; k++) valueText(scope, 'b${k + 1}_type')],
        )),
      ));
    }));
  }
}

class _BandsPainter extends CustomPainter {
  _BandsPainter({required this.plot, required this.xs, required this.selected, required this.grip, required this.levels,
    required this.muted, required this.types});
  final Rect plot;
  final List<double> xs;
  final int selected;
  final int? grip;
  final List<(double?, double?, bool)> levels;
  final List<bool> muted;
  final List<String> types;

  @override
  void paint(Canvas canvas, Size size) {
    paintLogGrid(canvas, plot, labels: false);
    final edges = [0.0, for (final x in xs) logUnit(x), 1.0];
    for (var k = 0; k + 1 < edges.length; k++) {
      final c = bandColor(k);
      final r = Rect.fromLTRB(plot.left + edges[k] * plot.width, plot.top, plot.left + edges[k + 1] * plot.width, plot.bottom);
      final (inDb, outDb, active) = k < levels.length ? levels[k] : (null, null, true);
      final on = active && !(k < muted.length && muted[k]);
      canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(1.5), const Radius.circular(6)),
          Paint()..color = c.withValues(alpha: on ? (k == selected ? 0.2 : 0.1) : 0.03));
      if (k == selected) {
        canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(1.5), const Radius.circular(6)), Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
      }
      final bw = math.min(26.0, r.width * 0.3);
      void bar(double? db, double dx, double alpha) {
        if (db == null) return;
        final hgt = dbUnit(db, floor: 60) * (r.height - 34);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(r.center.dx + dx - bw / 2, r.bottom - 6 - hgt, bw, hgt),
            const Radius.circular(3)), Paint()..color = c.withValues(alpha: alpha));
      }
      bar(inDb, -bw * 0.55, on ? 0.3 : 0.1);
      bar(outDb, bw * 0.55, on ? 0.9 : 0.15);
      if (r.width > 34) {
        paintLabel(canvas, 'B${k + 1}', Offset(r.center.dx, r.top + 10), on ? c : Neon.dim, size: 9, align: 0, weight: FontWeight.w800);
        if (k < types.length && r.width > 50) {
          paintLabel(canvas, types[k].toUpperCase(), Offset(r.center.dx, r.top + 22), Neon.dim, size: 7.5, align: 0);
        }
      }
    }
    for (var k = 0; k < xs.length; k++) {
      final x = plot.left + logUnit(xs[k]) * plot.width;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), Paint()
        ..color = Neon.text.withValues(alpha: grip == k ? 0.9 : 0.5)
        ..strokeWidth = grip == k ? 2 : 1.2);
      paintHandle(canvas, Offset(x, plot.center.dy + 8), Neon.text, active: grip == k, r: 6);
      paintLabel(canvas, hzLabel(xs[k]), Offset(x + 4, plot.bottom - 8), Neon.text, size: 8, weight: FontWeight.w700);
    }
  }

  @override
  bool shouldRepaint(covariant _BandsPainter o) => true;
}

/// One band's strip in its colour: its name, drive type (a chip), drive and mix, then Solo, Mute and Clean; a tap
/// touch selects it.
class _BandStrip extends StatelessWidget {
  const _BandStrip({required this.band, required this.selected, required this.onSelect});
  final int band;
  final bool selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final c = bandColor(band);
    final b = 'b${band + 1}_';
    bool on(String id) => t.value(id) >= 0.5;
    void flip(String id) => t.set(id, on(id) ? 0 : 1);
    // Any touch on the strip (its knobs and pills too) selects the band.
    return Listener(
      key: ValueKey('band-strip-$band'),
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => onSelect(band),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: c.withValues(alpha: selected ? 0.12 : 0.05),
          border: Border.all(color: selected ? c : c.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          Container(width: 5, height: 52, margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(color: c, borderRadius: const BorderRadius.horizontal(right: Radius.circular(3)))),
          Expanded(child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('B${band + 1}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: c)),
            ChoicePill('${b}type', color: c),
            DeviceKnob('${b}drive', size: 30, label: 'Drive', color: c),
            DeviceKnob('${b}mix', size: 30, label: 'Mix', color: c),
            Row(mainAxisSize: MainAxisSize.min, children: [
              LitPill(label: 'S', on: on('${b}solo'), color: Neon.yellow, onTap: () => flip('${b}solo'), keyName: 'band-$band-solo'),
              const SizedBox(width: 4),
              LitPill(label: 'M', on: on('${b}mute'), color: redColor(), onTap: () => flip('${b}mute'), keyName: 'band-$band-mute'),
              const SizedBox(width: 4),
              LitPill(label: 'Clean', on: t.value('${b}type').round() == 0, color: c,
                  onTap: () => t.set('${b}type', 0), keyName: 'band-$band-clean'),
            ]),
          ])),
        ]),
      ),
    );
  }
}
