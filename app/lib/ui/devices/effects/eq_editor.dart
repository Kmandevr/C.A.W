// The EQ's plugin UI (Pro-Q-like): the live spectrum behind a summed curve, one coloured node per band to drag, pinch for Q, type tiles.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../engine/component_info.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/controls.dart';
import '../kit/device_style.dart';
import '../kit/feel.dart';
import '../kit/grab_gesture.dart';
import '../kit/hero.dart';
import '../visuals/filter_curve.dart' show freqToX, xToFreq;
import 'effect_page.dart';

/// The band shapes the engine's EQ offers, in its choice order (`org.caw.eq`'s `bN_type`).
enum EqShape { bell, lowShelf, highShelf, lowCut12, lowCut24, lowCut48, highCut12, highCut24, highCut48, notch, bandPass, tilt }

/// A band's shape from its type choice's label, so an EQ with other names still draws.
EqShape eqShapeOf(String label) {
  final l = label.toLowerCase();
  final slope = l.contains('48') ? 2 : (l.contains('24') ? 1 : 0);
  if (l.contains('low') && l.contains('shelf')) return EqShape.lowShelf;
  if (l.contains('high') && l.contains('shelf')) return EqShape.highShelf;
  if (l.contains('low cut') || l.contains('high-pass') || l.contains('high pass') || l == 'hp') {
    return EqShape.values[EqShape.lowCut12.index + slope];
  }
  if (l.contains('high cut') || l.contains('low-pass') || l.contains('low pass') || l == 'lp') {
    return EqShape.values[EqShape.highCut12.index + slope];
  }
  if (l.contains('notch')) return EqShape.notch;
  if (l.contains('band')) return EqShape.bandPass;
  if (l.contains('tilt')) return EqShape.tilt;
  return EqShape.bell;
}

bool eqHasGain(EqShape s) => s == EqShape.bell || s == EqShape.lowShelf || s == EqShape.highShelf || s == EqShape.tilt;

// |a2 s² + a1 s + a0| at s = jw.
double _mag2(double a2, double a1, double a0, double w) {
  final re = a0 - a2 * w * w, im = a1 * w;
  return math.sqrt(re * re + im * im);
}

const _butter4 = [0.5412, 1.3066], _butter8 = [0.5098, 0.6013, 0.9000, 2.5629];

/// A band's gain in dB at [hz]: the analog prototypes the engine's trapezoidal SVF stages are made from (RBJ's
/// cookbook shapes; cuts as Butterworth stages whose last Q follows [q]), so the drawing follows the sound closely.
double eqShapeDb(EqShape s, double hz, double fc, double gain, double q) {
  final w = hz / fc.clamp(10.0, 30000.0);
  final qq = q.clamp(0.05, 40.0);
  final a = math.pow(10, gain / 40).toDouble();
  double db(double m) => 20 * math.log(math.max(m, 1e-9)) / math.ln10;
  List<double> stages(int n) => switch (n) {
        0 => [qq],
        1 => [_butter4[0], _butter4[1] * qq / 0.7071],
        _ => [..._butter8.sublist(0, 3), _butter8[3] * qq / 0.7071],
      };
  switch (s) {
    case EqShape.bell:
      return db(_mag2(1, a / qq, 1, w) / _mag2(1, 1 / (a * qq), 1, w));
    case EqShape.lowShelf:
      final r = math.sqrt(a) / qq;
      return db(a * _mag2(1, r, a, w) / _mag2(a, r, 1, w));
    case EqShape.highShelf:
      final r = math.sqrt(a) / qq;
      return db(a * _mag2(a, r, 1, w) / _mag2(1, r, a, w));
    case EqShape.lowCut12 || EqShape.lowCut24 || EqShape.lowCut48:
      var sum = 0.0;
      for (final sq in stages(s.index - EqShape.lowCut12.index)) {
        sum += db(w * w / _mag2(1, 1 / sq, 1, w));
      }
      return sum;
    case EqShape.highCut12 || EqShape.highCut24 || EqShape.highCut48:
      var sum = 0.0;
      for (final sq in stages(s.index - EqShape.highCut12.index)) {
        sum += db(1 / _mag2(1, 1 / sq, 1, w));
      }
      return sum;
    case EqShape.notch:
      return db(_mag2(1, 0, 1, w) / _mag2(1, 1 / qq, 1, w));
    case EqShape.bandPass:
      return db((w / qq) / _mag2(1, 1 / qq, 1, w));
    case EqShape.tilt:
      final o = math.log(w) / math.ln2;
      return gain / 2 * (2 / (1 + math.exp(-o * 1.4)) - 1);
  }
}

/// One band as the view sees it.
class _Band {
  _Band(this.n, this.on, this.shape, this.freq, this.gain, this.q, this.color);
  final int n;
  final bool on;
  final EqShape shape;
  final double freq, gain, q;
  final Color color;
}

/// The EQ page: the hero (spectrum, curve, nodes), the band chips, the selected band's type, knobs and channel.
class EqEditorPage extends StatefulWidget {
  const EqEditorPage({super.key});

  @override
  State<EqEditorPage> createState() => _EqEditorPageState();
}

final _bandId = RegExp(r'^(band|b)(\d+)_(freq|gain|q|type|on|channel)$');

class _EqEditorPageState extends State<EqEditorPage> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final params = t.info?.parameters ?? const <ComponentParameterInfo>[];
    final prefix = t.param('band1_freq') != null ? 'band' : 'b';
    final numbers = <int>{for (final p in params) if (_bandId.firstMatch(p.id) case final m?) int.parse(m.group(2)!)}.toList()..sort();
    if (numbers.isEmpty) return const SizedBox.shrink();
    String id(int n, String k) => '$prefix${n}_$k';
    bool isOn(int n) => t.param(id(n, 'on')) == null || t.value(id(n, 'on')) >= 0.5;
    final sel = numbers.contains(_selected) ? _selected! : (numbers.where(isOn).firstOrNull ?? numbers.first);
    EqShape shapeOf(String typeId) {
      final p = t.param(typeId);
      return p != null && p.isChoice ? eqShapeOf(formatParamValue(p, t.value(p.id))) : EqShape.bell;
    }

    final colors = spectrumColors();
    final bands = [
      for (final n in numbers)
        _Band(
          n,
          isOn(n),
          shapeOf(id(n, 'type')),
          t.value(id(n, 'freq')),
          t.value(id(n, 'gain')),
          t.param(id(n, 'q')) == null ? 0.71 : t.value(id(n, 'q')),
          colors[(n - 1) % colors.length]),
    ];
    final range = math.min(24.0, t.param(id(numbers.first, 'gain'))?.max ?? 18);
    final selBand = bands.firstWhere((b) => b.n == sel);
    return effectPage('eq', [
      LayoutBuilder(builder: (context, box) => HeroCanvas(
        color: scope.accent,
        height: box.maxWidth > 600 ? 300 : 230,
        caption: 'EQ',
        readout: const LevelReadout(),
        grid: false,
        child: DeviceDisplay(builder: (context, f) => _EqView(
          bands: bands, prefix: prefix, selected: sel, rangeDb: range, spectrum: f?.spectrum,
          onSelect: (n) => setState(() => _selected = n))),
      )),
      SizedBox(height: 40, child: Row(children: [
        for (final b in bands) Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: _BandChip(
          band: b, selected: b.n == sel,
          onTap: () => setState(() => _selected = b.n),
          onToggle: () => t.set(id(b.n, 'on'), b.on ? 0 : 1)))),
      ])),
      const SizedBox(height: 8),
      ControlGroup(
        title: 'BAND $sel',
        color: selBand.color,
        trailing: DevicePower(id(sel, 'on'), color: selBand.color),
        child: LayoutBuilder(builder: (context, box) {
          final types = _TypeGrid(paramId: id(sel, 'type'), color: selBand.color);
          final knobs = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            KnobRow([id(sel, 'freq'), if (eqHasGain(selBand.shape)) id(sel, 'gain'), id(sel, 'q')], size: 54, color: selBand.color),
            Row(children: [
              const SizedBox(width: 64, child: Text('CHANNEL', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim))),
              Expanded(child: Align(alignment: Alignment.centerLeft, child: DeviceChoice(id(sel, 'channel'), color: selBand.color))),
            ]),
          ]);
          if (box.maxWidth < 700) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [types, knobs]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 5, child: types),
            const SizedBox(width: 16),
            Expanded(flex: 4, child: knobs),
          ]);
        }),
      ),
      ControlGroup(title: 'OUTPUT', color: scope.accent, child: ParamGrid(skip: {
        for (final p in params) if (_bandId.hasMatch(p.id)) p.id,
      })),
    ]);
  }
}

class _BandChip extends StatelessWidget {
  const _BandChip({required this.band, required this.selected, required this.onTap, required this.onToggle});
  final _Band band;
  final bool selected;
  final VoidCallback onTap, onToggle;

  @override
  Widget build(BuildContext context) {
    final c = band.on ? band.color : Neon.dim;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Band ${band.n}${band.on ? '' : ', off'}',
      child: GestureDetector(
        key: ValueKey('eq-band-${band.n}'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          DeviceFeel.tap();
          onTap();
        },
        onLongPress: () {
          DeviceFeel.tap();
          onToggle();
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: selected ? c.withValues(alpha: 0.22) : Colors.white.withValues(alpha: 0.03),
            border: Border.all(color: selected ? c : c.withValues(alpha: 0.35))),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('${band.n}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: band.on ? Neon.text : Neon.dim)),
            SizedBox(width: 22, height: 10, child: CustomPaint(painter: _ShapeIconPainter(band.shape, c))),
          ]),
        ),
      ),
    );
  }
}

class _ShapeIconPainter extends CustomPainter {
  _ShapeIconPainter(this.shape, this.color);
  final EqShape shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => eqShapeIcon(canvas, Offset.zero & size, shape.index, color);

  @override
  bool shouldRepaint(covariant _ShapeIconPainter o) => o.shape != shape || o.color != color;
}

/// A band shape's little curve (for the type tiles and band chips).
void eqShapeIcon(Canvas canvas, Rect r, int index, Color color) {
  final s = EqShape.values[index.clamp(0, EqShape.values.length - 1)];
  final g = eqHasGain(s) ? 12.0 : 0.0;
  iconCurve(canvas, r, color, (x) {
    final hz = 1000 * math.pow(2, x * 4).toDouble();
    return (eqShapeDb(s, hz, 1000, g, s == EqShape.notch ? 2 : 1.2) / 18).clamp(-1.0, 1.0);
  }, width: r.height < 20 ? 1.4 : 1.8);
}

/// The type choice as a grid of drawn shapes (two rows of six for the engine's twelve).
class _TypeGrid extends StatelessWidget {
  const _TypeGrid({required this.paramId, required this.color});
  final String paramId;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final p = t.param(paramId);
    if (p == null || !p.isChoice) return const SizedBox.shrink();
    final sel = (t.value(p.id) - p.min).round();
    final n = p.choices.length;
    const perRow = 6;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (var row = 0; row * perRow < n; row++)
        Padding(padding: const EdgeInsets.only(bottom: 4), child: SizedBox(height: 46, child: Row(children: [
          for (var k = row * perRow; k < math.min(n, row * perRow + perRow); k++)
            Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: Semantics(
              button: true,
              selected: k == sel,
              label: p.choices[k],
              child: GestureDetector(
                key: ValueKey('eq-type-$k'),
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  DeviceFeel.tap();
                  t.set(p.id, p.min + k);
                },
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: k == sel ? color.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.03),
                    border: Border.all(color: k == sel ? color : Neon.line)),
                  child: Column(children: [
                    Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(6, 5, 6, 1), child: CustomPaint(size: Size.infinite,
                      painter: _ShapeIconPainter(eqShapeOf(p.choices[k]), k == sel ? color : Neon.dim)))),
                    Text(_shortType(p.choices[k]), maxLines: 1, style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w700,
                      color: k == sel ? Neon.text : Neon.dim)),
                    const SizedBox(height: 3),
                  ]),
                ),
              ),
            ))),
        ]))),
    ]);
  }

  static String _shortType(String s) => s
      .replaceAll('Low shelf', 'Lo shelf')
      .replaceAll('High shelf', 'Hi shelf')
      .replaceAll('Low cut ', 'LC ')
      .replaceAll('High cut ', 'HC ');
}

/// The EQ's main visual: the live spectrum (violet) behind each band's own shape in its colour and the summed curve,
/// a node per band. Drag a node: sideways its frequency, up and down its gain (a cut's or notch's Q); a second finger
/// pinches its Q (spread wider: a wider band); the wheel sets Q on a desktop. Tap selects, double-tap switches a band
/// on or off, double-tap on empty space turns the first off band on there, long-press picks its type.
class _EqView extends StatefulWidget {
  const _EqView({required this.bands, required this.prefix, required this.selected, required this.onSelect,
    this.rangeDb = 18, this.spectrum});
  final List<_Band> bands;
  final String prefix;
  final int selected;
  final ValueChanged<int> onSelect;
  final double rangeDb;
  final List<double>? spectrum;

  @override
  State<_EqView> createState() => _EqViewState();
}

class _EqViewState extends State<_EqView> {
  int? _active, _held;
  double _x = 0, _gain = 0, _q = 1, _q0 = 1;

  String _id(int n, String k) => '${widget.prefix}${n}_$k';

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      const pad = 18.0;
      double y(double db) => h / 2 - db / widget.rangeDb * (h / 2 - pad);
      double dbAt(double py) => (h / 2 - py) / (h / 2 - pad) * widget.rangeDb;
      Offset node(_Band b) {
        final g = eqHasGain(b.shape) ? b.gain : 0.0;
        return Offset(freqToX(b.freq, w), y(b.shape == EqShape.tilt ? g / 2 : g));
      }

      _Band? nearest(Offset p) {
        _Band? best;
        var d = 30.0;
        for (final b in widget.bands) {
          final dist = (node(b) - p).distance - (b.n == widget.selected ? 4 : 0);
          if (dist < d) {
            d = dist;
            best = b;
          }
        }
        return best;
      }

      _Band? band(int? n) => n == null ? null : widget.bands.where((b) => b.n == n).firstOrNull;

      void setQ(int n, double q) {
        final p = t.param(_id(n, 'q'));
        if (p != null) t.setLive(p.id, q.clamp(p.min, p.max));
      }

      return GrabGesture(
        key: const ValueKey('eq-view'),
        grabs: (p) => nearest(p) != null,
        onStart: (p, pointers) {
          // A second finger restarts the gesture as a pinch on the band the first one holds.
          final b = pointers >= 2 ? band(_active ?? _held) : nearest(p);
          if (b == null) return;
          if (_active != b.n) widget.onSelect(b.n);
          _x = node(b).dx;
          _gain = b.gain;
          _q = _q0 = b.q;
          if (!b.on) t.setLive(_id(b.n, 'on'), 1);
          _held = b.n;
          setState(() => _active = b.n);
        },
        onUpdate: (u) {
          final b = band(_active);
          if (b == null) return;
          if (u.pointers >= 2) {
            setQ(b.n, _q0 / math.max(0.05, u.scale));
            return;
          }
          final f = DeviceFingers.fine;
          _x = (_x + u.delta.dx * f).clamp(0.0, w);
          t.setLive(_id(b.n, 'freq'), xToFreq(_x, w));
          if (eqHasGain(b.shape)) {
            _gain -= u.delta.dy * f / (h / 2 - pad) * widget.rangeDb * (b.shape == EqShape.tilt ? 2 : 1);
            t.setLive(_id(b.n, 'gain'), _gain);
          } else {
            _q = (_q * math.pow(2, -u.delta.dy * f / 40)).toDouble();
            setQ(b.n, _q);
          }
        },
        onEnd: () {
          if (_active != null) t.commit();
          setState(() => _active = null);
        },
        onTap: (p) {
          if (nearest(p) case final b?) {
            DeviceFeel.tap();
            widget.onSelect(b.n);
          }
        },
        onDoubleTap: (p) {
          if (nearest(p) case final b?) {
            t.set(_id(b.n, 'on'), b.on ? 0 : 1);
            return;
          }
          final off = widget.bands.where((b) => !b.on).firstOrNull;
          if (off == null) return;
          t.setAll({
            _id(off.n, 'on'): 1,
            _id(off.n, 'freq'): xToFreq(p.dx, w),
            if (eqHasGain(off.shape)) _id(off.n, 'gain'): dbAt(p.dy).clamp(-widget.rangeDb, widget.rangeDb),
          });
          widget.onSelect(off.n);
        },
        onLongPress: (p) async {
          final b = nearest(p);
          final tp = t.param(_id(b?.n ?? 0, 'type'));
          if (b == null || tp == null) return;
          widget.onSelect(b.n);
          final box = context.findRenderObject() as RenderBox;
          final at = box.localToGlobal(p);
          final k = await showMenu<int>(context: context, position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy), items: [
            for (var i = 0; i < tp.choices.length; i++)
              PopupMenuItem(value: i, height: 36, child: Row(children: [
                SizedBox(width: 26, height: 14, child: CustomPaint(painter: _ShapeIconPainter(eqShapeOf(tp.choices[i]), b.color))),
                const SizedBox(width: 10),
                Text(tp.choices[i], style: const TextStyle(fontSize: 12)),
              ])),
          ]);
          if (k != null) t.set(tp.id, tp.min + k);
        },
        onScroll: (p, dy) {
          final b = nearest(p) ?? band(widget.selected);
          if (b == null) return;
          setQ(b.n, b.q * math.pow(2, -dy / 400).toDouble());
          t.commit();
        },
        child: CustomPaint(size: Size(w, h), painter: _EqPainter(
          bands: widget.bands, y: y, node: node, selected: widget.selected, active: _active, spectrum: widget.spectrum,
          rangeDb: widget.rangeDb, color: DeviceScope.of(context).accent)),
      );
    });
  }
}

class _EqPainter extends CustomPainter {
  _EqPainter({required this.bands, required this.y, required this.node, required this.selected, required this.active,
    required this.spectrum, required this.rangeDb, required this.color});
  final List<_Band> bands;
  final double Function(double db) y;
  final Offset Function(_Band b) node;
  final int selected;
  final int? active;
  final List<double>? spectrum;
  final double rangeDb;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final grid = Paint()..color = Colors.white.withValues(alpha: 0.05);
    for (final (hz, label) in [(50.0, '50'), (100.0, '100'), (200.0, '200'), (500.0, '500'), (1000.0, '1k'), (2000.0, '2k'),
        (5000.0, '5k'), (10000.0, '10k')]) {
      final x = freqToX(hz, w);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      paintLabel(canvas, label, Offset(x + 2, size.height - 7), Neon.dim.withValues(alpha: 0.7), size: 8);
    }
    for (final db in [-12.0, -6.0, 6.0, 12.0]) {
      if (db.abs() > rangeDb) continue;
      canvas.drawLine(Offset(0, y(db)), Offset(w, y(db)), grid);
      paintLabel(canvas, '${db > 0 ? '+' : ''}${db.round()}', Offset(w - 4, y(db)), Neon.dim.withValues(alpha: 0.7), size: 8, align: 1);
    }
    canvas.drawLine(Offset(0, y(0)), Offset(w, y(0)), Paint()..color = Colors.white.withValues(alpha: 0.12));
    // The live spectrum, from the bottom.
    if (spectrum case final s? when s.length > 1) {
      final p = Path()..moveTo(0, size.height);
      for (var i = 0; i < s.length; i++) {
        p.lineTo(w * i / (s.length - 1), size.height * (1 - s[i].clamp(0.0, 1.0) * 0.92));
      }
      p
        ..lineTo(w, size.height)
        ..close();
      canvas.drawPath(p, Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Neon.violet.withValues(alpha: 0.35), Neon.violet.withValues(alpha: 0.05)]).createShader(Offset.zero & size));
    }
    final n = math.max(80, w ~/ 3);
    final xs = [for (var i = 0; i <= n; i++) w * i / n];
    final freqs = [for (final x in xs) xToFreq(x, w)];
    final sum = List<double>.filled(xs.length, 0);
    // Each band's own shape, filled in its colour.
    for (final b in bands) {
      if (!b.on) continue;
      final path = Path();
      for (var i = 0; i < xs.length; i++) {
        final db = eqShapeDb(b.shape, freqs[i], b.freq, b.gain, b.q);
        sum[i] += db;
        final py = y(db.clamp(-rangeDb * 1.3, rangeDb * 1.3));
        i == 0 ? path.moveTo(xs[i], py) : path.lineTo(xs[i], py);
      }
      final emph = b.n == selected || b.n == active;
      final fill = Path.from(path)
        ..lineTo(w, y(0))
        ..lineTo(0, y(0))
        ..close();
      canvas.drawPath(fill, Paint()..color = b.color.withValues(alpha: emph ? 0.22 : 0.09));
      if (emph) {
        canvas.drawPath(path, Paint()
          ..color = b.color.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
      }
    }
    final curve = Path();
    for (var i = 0; i < xs.length; i++) {
      final py = y(sum[i].clamp(-rangeDb * 1.3, rangeDb * 1.3));
      i == 0 ? curve.moveTo(xs[i], py) : curve.lineTo(xs[i], py);
    }
    strokeGlow(canvas, curve, Colors.white.withValues(alpha: 0.92), width: 2);
    for (final b in bands) {
      final at = node(b);
      final c = b.on ? b.color : Neon.dim;
      paintHandle(canvas, at, c, active: b.n == active, r: b.n == selected ? 9 : 7.5, label: '${b.n}');
      if (b.n == active) {
        paintLabel(canvas, '${_hz(b.freq)}  ${eqHasGain(b.shape) ? '${b.gain >= 0 ? '+' : ''}${b.gain.toStringAsFixed(1)} dB  ' : ''}'
            'Q ${b.q.toStringAsFixed(2)}', at + Offset(0, at.dy > size.height / 2 ? -26 : 24), Neon.text, size: 10, align: 0,
            weight: FontWeight.w700);
      }
    }
  }

  static String _hz(double v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(v >= 10000 ? 1 : 2)} kHz' : '${v.round()} Hz';

  @override
  bool shouldRepaint(covariant _EqPainter o) => true;
}
