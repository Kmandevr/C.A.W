// The EQ's plugin UI (Pro-Q and Vital-like): the live spectrum behind a summed curve, a big node per band to drag, pinch for Q, a band strip, type tiles.
import '../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../engine/component_info.dart';
import '../../feedback.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/controls.dart';
import '../kit/device_style.dart';
import '../kit/feel.dart';
import '../kit/grab_gesture.dart';
import '../kit/hero.dart';
import '../kit/param_watch.dart';
import '../visuals/filter_curve.dart' show freqToX, xToFreq;
import 'effect_page.dart';
import '../../pointer_input.dart';
import '../../panel_motion.dart';

/// The band shapes the engine's EQ offers, in its choice order (`org.caw.eq`'s `bN_type`).
enum EqShape { bell, lowShelf, highShelf, lowCut12, lowCut24, lowCut48, highCut12, highCut24, highCut48, notch, bandPass, tilt,
  lowCut96, highCut96 }  // the 96s appended (fx-filters), as the engine appends them

/// A band's shape from its type choice's label, so an EQ with other names still draws.
EqShape eqShapeOf(String label) {
  final l = label.toLowerCase();
  final slope = l.contains('48') ? 2 : (l.contains('24') ? 1 : 0);
  if (l.contains('low') && l.contains('shelf')) return EqShape.lowShelf;
  if (l.contains('high') && l.contains('shelf')) return EqShape.highShelf;
  if (l.contains('low cut') || l.contains('high-pass') || l.contains('high pass') || l == 'hp') {
    if (l.contains('96')) return EqShape.lowCut96;
    return EqShape.values[EqShape.lowCut12.index + slope];
  }
  if (l.contains('high cut') || l.contains('low-pass') || l.contains('low pass') || l == 'lp') {
    if (l.contains('96')) return EqShape.highCut96;
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
const _butter16 = [0.5024, 0.5225, 0.5669, 0.6468, 0.7882, 1.0607, 1.7224, 5.1011];

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
        2 => [..._butter8.sublist(0, 3), _butter8[3] * qq / 0.7071],
        _ => [..._butter16.sublist(0, 7), _butter16[7] * qq / 0.7071],
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
    case EqShape.lowCut12 || EqShape.lowCut24 || EqShape.lowCut48 || EqShape.lowCut96:
      var sum = 0.0;
      for (final sq in stages(s == EqShape.lowCut96 ? 3 : s.index - EqShape.lowCut12.index)) {
        sum += db(w * w / _mag2(1, 1 / sq, 1, w));
      }
      return sum;
    case EqShape.highCut12 || EqShape.highCut24 || EqShape.highCut48 || EqShape.highCut96:
      var sum = 0.0;
      for (final sq in stages(s == EqShape.highCut96 ? 3 : s.index - EqShape.highCut12.index)) {
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
  bool _adding = false; // "+": the next tap on the curve places a band there

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
    // The bands' values, read where they are drawn: the hero, the band strip and the readout each have their own
    // watch (param_watch.dart), so a knob step rebuilds them and the knob, not the page.
    List<_Band> bandsNow() => [
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
    final selColor = colors[(sel - 1) % colors.length];
    final selOn = isOn(sel);
    final free = numbers.where((n) => !isOn(n)).firstOrNull;
    final freeColor = free == null ? null : colors[(free - 1) % colors.length];
    final typeP = t.param(id(sel, 'type'));
    return effectPage('eq', [
      LayoutBuilder(builder: (context, box) => HeroCanvas(
        color: scope.accent,
        height: box.maxWidth > 600 ? 300 : 230,
        caption: 'EQ',
        readout: const LevelReadout(),
        grid: false,
        child: watchDevice(context, (context) {
          final bands = bandsNow();
          final adding = _adding && free != null ? bands.firstWhere((b) => b.n == free) : null;
          return DeviceDisplay(builder: (context, f) => _EqView(
            bands: bands, prefix: prefix, selected: sel, rangeDb: range, spectrum: f?.spectrum,
            adding: adding,
            onAdded: () => setState(() => _adding = false),
            onSelect: (n) => setState(() => _selected = n)));
        }),
      )),
      if (_adding && free != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(
        '${PointerInput.tapCap} the curve where band $free goes', key: const ValueKey('eq-add-hint'), textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: freeColor))),
      const SizedBox(height: 6),
      // The band strip: a tap selects a band (its controls below); "+" adds one where you next tap the curve.
      SizedBox(height: 52, child: watchDevice(context, (context) => Row(children: [
        for (final b in bandsNow()) Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: _BandChip(
          band: b, selected: b.n == sel,
          onTap: () => setState(() => _selected = b.n)))),
        Padding(padding: const EdgeInsets.only(left: 2), child: _AddChip(
          active: _adding, enabled: free != null, color: freeColor ?? Neon.dim,
          onTap: () => setState(() => _adding = !_adding))),
      ]))),
      const SizedBox(height: 8),
      watchDevice(context, (context) => _BandReadout(band: bandsNow().firstWhere((b) => b.n == sel),
          type: typeP == null ? '' : formatParamValue(typeP, t.value(typeP.id)))),
      watchDevice(context, (context) {
        final shape = shapeOf(id(sel, 'type'));
        return ControlGroup(
        title: 'BAND $sel',
        color: selColor,
        trailing: _BandPower(on: selOn, color: selColor, n: sel, onTap: () => t.set(id(sel, 'on'), selOn ? 0 : 1)),
        child: LayoutBuilder(builder: (context, box) {
          final types = _TypeGrid(paramId: id(sel, 'type'), color: selColor);
          final knobs = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            KnobRow([id(sel, 'freq'), if (eqHasGain(shape)) id(sel, 'gain'), id(sel, 'q')], size: 54, color: selColor,
              labels: {id(sel, 'freq'): 'Frequency', id(sel, 'gain'): 'Gain', id(sel, 'q'): 'Width (Q)'}),
            Row(children: [
              const SizedBox(width: 64, child: Text('CHANNEL', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim))),
              Expanded(child: Align(alignment: Alignment.centerLeft, child: DeviceChoice(id(sel, 'channel'), color: selColor))),
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
      );
      }),
      ControlGroup(title: 'OUTPUT', color: scope.accent, child: ParamGrid(skip: {
        for (final p in params) if (_bandId.hasMatch(p.id)) p.id,
      })),
    ]);
  }
}

class _BandChip extends StatelessWidget {
  const _BandChip({required this.band, required this.selected, required this.onTap});
  final _Band band;
  final bool selected;
  final VoidCallback onTap;

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
        child: Pressable(glow: c, child: AnimatedContainer(
          duration: Motion.fade(Motion.small, Motion.of(context)),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: selected ? c.withValues(alpha: 0.22) : Neon.ink.withValues(alpha: 0.03),
            border: Border.all(color: selected ? c : c.withValues(alpha: 0.35), width: selected ? 1.6 : 1),
            boxShadow: selected ? [BoxShadow(color: c.withValues(alpha: 0.3), blurRadius: 8)] : null),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('${band.n}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: band.on ? Neon.text : Neon.dim)),
            SizedBox(width: 22, height: 10, child: CustomPaint(painter: _ShapeIconPainter(band.shape, c))),
            Text(band.on ? _short(band.freq) : 'off', maxLines: 1, style: Neon.code(size: 8.5, color: c)),
          ]),
        )),
      ),
    );
  }

  static String _short(double hz) => hz >= 1000 ? '${(hz / 1000).toStringAsFixed(hz >= 10000 ? 0 : 1)}k' : '${hz.round()}';
}

/// "+": the next tap on the curve turns on the first off band there.
class _AddChip extends StatelessWidget {
  const _AddChip({required this.active, required this.enabled, required this.color, required this.onTap});
  final bool active, enabled;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(message: enabled ? 'Add a band: then ${PointerInput.tap} the curve' : 'Every band is on',
    child: GestureDetector(
      key: const ValueKey('eq-add'),
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? () {
        DeviceFeel.tap();
        onTap();
      } : null,
      child: Pressable(glow: color, enabled: enabled, child: AnimatedContainer(
        duration: Motion.fade(Motion.small, Motion.of(context)),
        width: 44,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
          color: active ? color.withValues(alpha: 0.3) : Neon.ink.withValues(alpha: 0.03),
          border: Border.all(color: enabled ? color : Neon.line, width: active ? 2 : 1)),
        child: Icon(active ? Icons.close : Icons.add, size: 22, color: enabled ? color : Neon.dim),
      )),
    ));
}

/// The selected band's values in large type: type, frequency, gain and width.
class _BandReadout extends StatelessWidget {
  const _BandReadout({required this.band, required this.type});
  final _Band band;
  final String type;

  @override
  Widget build(BuildContext context) {
    // Widths by what each holds ("High cut 48", "10.0 kHz", "+12.0 dB", "Q 0.71"), with a gap so values never touch.
    Widget cell(String label, String value, int flex) => Expanded(flex: flex, child: Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, maxLines: 1, overflow: TextOverflow.clip, softWrap: false,
          style: const TextStyle(fontSize: 9, letterSpacing: 1.1, fontWeight: FontWeight.w800, color: Neon.dim)),
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: Neon.code(size: 14, color: band.on ? Neon.text : Neon.dim).copyWith(fontWeight: FontWeight.w700)),
      ]),
    ));
    return Container(
      key: const ValueKey('eq-readout'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: band.color.withValues(alpha: 0.08),
        border: Border.all(color: band.color.withValues(alpha: 0.4))),
      child: Row(children: [
        cell('BAND ${band.n}', band.on ? type : 'Off', 7),
        cell('FREQUENCY', _EqPainter._hz(band.freq), 5),
        if (eqHasGain(band.shape)) cell('GAIN', '${band.gain >= 0 ? '+' : ''}${band.gain.toStringAsFixed(1)} dB', 5),
        cell('WIDTH', 'Q ${band.q.toStringAsFixed(2)}', 4),
      ]),
    );
  }
}

/// The selected band's power, explicit (a double-tap on a node resets it instead).
class _BandPower extends StatelessWidget {
  const _BandPower({required this.on, required this.color, required this.n, required this.onTap});
  final bool on;
  final Color color;
  final int n;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(toggled: on, label: 'Band $n', child: GestureDetector(
    key: const ValueKey('eq-band-power'),
    behavior: HitTestBehavior.opaque,
    onTap: () {
      DeviceFeel.tap();
      onTap();
    },
    child: Pressable(glow: color, radius: 16, child: AnimatedContainer(
      duration: Motion.fade(Motion.small, Motion.of(context)),
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16),
        color: on ? color.withValues(alpha: 0.22) : Neon.ink.withValues(alpha: 0.03),
        border: Border.all(color: on ? color : Neon.line)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.power_settings_new, size: 15, color: on ? color : Neon.dim),
        const SizedBox(width: 4),
        Text(on ? 'ON' : 'OFF', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1,
          color: on ? Neon.text : Neon.dim)),
      ]),
    )),
  ));
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

/// The type choice as a grid of drawn shapes (two rows of seven for the engine's fourteen).
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
    const perRow = 7;
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
                    color: k == sel ? color.withValues(alpha: 0.2) : Neon.ink.withValues(alpha: 0.03),
                    border: Border.all(color: k == sel ? color : Neon.line)),
                  child: Column(children: [
                    Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(6, 5, 6, 1), child: CustomPaint(size: Size.infinite,
                      painter: _ShapeIconPainter(eqShapeOf(p.choices[k]), k == sel ? color : Neon.dim)))),
                    // The whole name ("Low cut 24"), a little smaller where the tile is narrow.
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: FittedBox(fit: BoxFit.scaleDown,
                      child: Text(_shortType(p.choices[k]), maxLines: 1, style: TextStyle(fontSize: 8.5,
                        fontWeight: FontWeight.w700, color: k == sel ? Neon.text : Neon.dim)))),
                    const SizedBox(height: 3),
                  ]),
                ),
              ),
            ))),
        ]))),
    ]);
  }

  static String _shortType(String s) => s.replaceAll('Band-pass', 'Band pass');
}

/// The EQ's main visual: the live spectrum (violet) behind each band's own shape in its colour and the summed curve,
/// a node per band. Drag a node: sideways its frequency, up and down its gain (a cut's or notch's Q); a second finger
/// pinches its Q (spread wider: a wider band); the wheel sets Q on a desktop. Tap selects, double-tap resets a
/// band (gain to 0 dB and its width to the default; the band power is a button of its own), long-press picks its
/// type. With [adding] (the strip's "+") a tap on the curve turns that band on there.
class _EqView extends StatefulWidget {
  const _EqView({required this.bands, required this.prefix, required this.selected, required this.onSelect,
    this.rangeDb = 18, this.spectrum, this.adding, this.onAdded});
  final _Band? adding;
  final VoidCallback? onAdded;
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
        var d = 40.0; // a finger's reach around the 11–13 dp nodes
        if (widget.adding != null) return null; // placing a band: every tap places it
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
          if (widget.adding case final off?) {
            DeviceFeel.detent();
            t.setAll({
              _id(off.n, 'on'): 1,
              _id(off.n, 'freq'): xToFreq(p.dx, w),
              if (eqHasGain(off.shape)) _id(off.n, 'gain'): dbAt(p.dy).clamp(-widget.rangeDb, widget.rangeDb),
            });
            widget.onSelect(off.n);
            widget.onAdded?.call();
            return;
          }
          if (nearest(p) case final b?) {
            DeviceFeel.tap();
            widget.onSelect(b.n);
          }
        },
        onDoubleTap: (p) {
          if (nearest(p) case final b?) {
            final q = t.param(_id(b.n, 'q'));
            t.setAll({
              if (eqHasGain(b.shape)) _id(b.n, 'gain'): 0,
              if (q != null) q.id: q.defaultValue,
            });
            widget.onSelect(b.n);
          }
        },
        onLongPress: (p) async {
          final b = nearest(p);
          final tp = t.param(_id(b?.n ?? 0, 'type'));
          if (b == null || tp == null) return;
          widget.onSelect(b.n);
          final box = context.findRenderObject() as RenderBox;
          final at = box.localToGlobal(p);
          final k = await showMenu<int>(context: context, popUpAnimationStyle: menuAnimation(context), position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy), items: [
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
          rangeDb: widget.rangeDb, color: DeviceScope.of(context).accent, adding: widget.adding != null)),
      );
    });
  }
}

class _EqPainter extends CustomPainter {
  _EqPainter({required this.bands, required this.y, required this.node, required this.selected, required this.active,
    required this.spectrum, required this.rangeDb, required this.color, this.adding = false});
  final bool adding;
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
    final grid = Paint()..color = Neon.ink.withValues(alpha: 0.05);
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
    canvas.drawLine(Offset(0, y(0)), Offset(w, y(0)), Paint()..color = Neon.ink.withValues(alpha: 0.12));
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
            colors: Neon.ramp([Neon.violet.withValues(alpha: 0.35), Neon.violet.withValues(alpha: 0.05)])).createShader(Offset.zero & size));
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
    strokeGlow(canvas, curve, Neon.ink.withValues(alpha: 0.92), width: 2);
    if (adding) {
      canvas.drawRect(Offset.zero & size, Paint()
        ..color = Neon.ink.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }
    for (final b in bands) {
      final at = node(b);
      final c = b.on ? b.color : Neon.dim;
      if (!b.on && b.n != selected) {
        paintHandle(canvas, at, c, r: 8, label: '${b.n}');
        continue;
      }
      paintHandle(canvas, at, c, active: b.n == active, r: b.n == selected ? 13 : 11, label: '${b.n}');
      if (b.n == active || (b.n == selected && active == null)) {
        paintLabel(canvas, '${_hz(b.freq)}  ${eqHasGain(b.shape) ? '${b.gain >= 0 ? '+' : ''}${b.gain.toStringAsFixed(1)} dB  ' : ''}'
            'Q ${b.q.toStringAsFixed(2)}', at + Offset(0, at.dy > size.height / 2 ? -28 : 28),
            b.n == active ? Neon.text : Neon.dim, size: b.n == active ? 11 : 9.5, align: 0,
            weight: FontWeight.w700);
      }
    }
  }

  static String _hz(double v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(v >= 10000 ? 1 : 2)} kHz' : '${v.round()} Hz';

  @override
  bool shouldRepaint(covariant _EqPainter o) =>
      paintInputsChanged([o.adding, o.bands, o.y, o.node, o.selected, o.active, o.spectrum, o.rangeDb, o.color], [adding, bands, y, node, selected, active, spectrum, rangeDb, color]);
}
