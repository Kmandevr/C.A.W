// The racks' plugin UIs (fx-racks): the multiband rack's spectrum and band strips, the FX rack's modulators, and their chains of inline devices.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../model/device_target.dart';
import '../../../../model/flagship_shapes.dart' show lfoValue;
import '../../../../model/mod_matrix.dart';
import '../../../../model/racks.dart';
import '../../../files/asset_picker.dart';
import '../../../frame/sections.dart';
import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_inline.dart';
import '../../device_registry.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/device_style.dart';
import '../../kit/feel.dart';
import '../../kit/hero.dart';
import '../../visuals/envelope_view.dart';
import '../../visuals/filter_curve.dart' show freqToX, xToFreq;
import '../../visuals/mod_routing.dart';
import '../../visuals/mod_sheet.dart' show ModAssignBanner;
import '../effect_page.dart';

/// The two racks' editor entries (effect_editors.dart lists them).
final Map<String, DeviceEditorEntry> rackEditors = {
  fxRackId: DeviceEditorEntry((_) => [
        DeviceSection('rack', 'RACK', Icons.view_agenda_outlined, (_) => const FxRackPage(), showsSources: true),
        DeviceSection('routes', 'ROUTES', Icons.hub_outlined, (_) => const _RoutesPage()),
      ], family: DeviceFamily.modulation),
  multibandRackId: singlePage('mbrack', 'BANDS', Icons.view_week_outlined, DeviceFamily.eq, () => const MultibandRackPage()),
};

/// Each band's colour, low to high.
Color bandColor(int band) => [Neon.layers[7], Neon.layers[5], Neon.yellow, Neon.green, Neon.blue][band.clamp(0, 4)];

/// Asks for a built-in a rack can hold and puts it in [slot] of [rack].
Future<void> addToRack(BuildContext context, DeviceTarget rack, RackSlot slot) async {
  final pick = await showAssetPicker(context, rack.state, kinds: {AssetKind.nativeEffect}, title: 'Add to rack',
      rackChild: true);
  if (pick == null) return;
  setRackValues(rack, rackValuesWithSlot(rack, slot, pick.id));
}

// ---------- The chain of children ----------

/// A rack's chain: each child as an inline device (its own plugin UI, its knobs reachable by the rack's routes), with
/// move, switch and remove; then "+ Add effect" while a slot is free.
class RackChain extends StatelessWidget {
  const RackChain({super.key, this.band});

  /// The multiband rack's band (null: the FX rack's one chain).
  final int? band;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final rack = scope.target;
    final slots = rackChildren(rack, band: band);
    final filled = [for (final (s, id) in slots) if (id != null) (s, id)];
    final free = slots.where((e) => e.$2 == null).map((e) => e.$1).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < filled.length; i++)
        _child(context, rack, filled[i].$1, filled[i].$2, up: i > 0 ? filled[i - 1].$1 : null,
            down: i + 1 < filled.length ? filled[i + 1].$1 : null),
      if (free != null)
        Padding(padding: const EdgeInsets.only(top: 4), child: OutlinedButton.icon(
          key: ValueKey('rack-add-${band ?? 0}'),
          onPressed: () => addToRack(context, rack, free),
          icon: const Icon(Icons.add, size: 16),
          label: Text(filled.isEmpty ? 'Add an effect' : 'Add effect', style: const TextStyle(fontSize: 12)),
        )),
    ]);
  }

  Widget _child(BuildContext context, DeviceTarget rack, RackSlot slot, String id, {RackSlot? up, RackSlot? down}) {
    final child = RackChildTarget(rack, slot, id);
    final scope = DeviceScope.of(context);
    final matrix = scope.matrix == null ? null : ModMatrix(rack, prefix: '${slot.name}.');
    Widget action(String key, IconData icon, String tip, VoidCallback? onTap, {Color? color}) => IconButton(
      key: ValueKey('rack-$key-${slot.name}'), tooltip: tip, iconSize: 18,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      onPressed: onTap == null ? null : () {
        DeviceFeel.tap();
        onTap();
      },
      icon: Icon(icon, color: color));
    final actions = [
      action('up', Icons.arrow_upward, 'Earlier in the chain', up == null ? null : () => setRackValues(rack, rackValuesMoved(rack, slot, up))),
      action('on', Icons.power_settings_new, child.bypass ? 'Switch on' : 'Switch off', () => child.setBypass(!child.bypass),
          color: child.bypass ? Neon.dim : scope.accent),
      action('remove', Icons.close, 'Remove from the rack', () => setRackValues(rack, rackValuesWithSlot(rack, slot, null))),
    ];
    if (!hasInlineDevice(child)) {
      return DeviceScope(target: child, matrix: matrix, dragging: scope.dragging, accent: scope.accent,
        focusSource: scope.focusSource, assigning: scope.assigning, selectedSlot: scope.selectedSlot, inline: true,
        child: Container(
          key: ValueKey('rack-child-${slot.name}'),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: Neon.line)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [const SizedBox(width: 10), Expanded(child: Text(child.label,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800))), ...actions]),
            const ParamGrid(),
          ])));
    }
    return KeyedSubtree(key: ValueKey('rack-child-${slot.name}'), child: DeviceInline(
      target: child, nested: true, matrix: matrix, actions: actions,
      leading: Padding(padding: const EdgeInsets.only(left: 8, right: 4), child: Text(slot.label,
        style: Neon.code(size: 9, color: Neon.dim))),
    ));
  }
}

// ---------- The multiband rack ----------

/// The multiband rack: the band count, the spectrum with the bands tinted and their crossovers to drag, a strip per
/// band (mute, solo, bypass, gain, pan; tap to show its chain), the selected band's chain, then mix and output.
class MultibandRackPage extends StatefulWidget {
  const MultibandRackPage({super.key});

  @override
  State<MultibandRackPage> createState() => _MultibandRackPageState();
}

class _MultibandRackPageState extends State<MultibandRackPage> {
  int _band = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final bands = t.value('bands').round().clamp(1, multibandBands);
    final band = _band.clamp(0, bands - 1);
    return effectPage('mbrack', [
      // A Wrap, so the chips go onto a second line in a narrow inline column instead of overflowing.
      Padding(padding: const EdgeInsets.only(bottom: 8), child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 4, children: [
        const Text('BANDS', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)),
        const SizedBox(width: 8),
        for (var n = 1; n <= multibandBands; n++)
          Padding(padding: const EdgeInsets.only(right: 4), child: ChoiceChip(
            key: ValueKey('mb-bands-$n'),
            visualDensity: VisualDensity.compact,
            label: Text('$n', style: const TextStyle(fontSize: 11)),
            selected: n == bands,
            showCheckmark: false,
            onSelected: (_) {
              DeviceFeel.tap();
              t.set('bands', n.toDouble());
            })),
      ])),
      HeroCanvas(color: scope.accent, height: 190, caption: 'BANDS', grid: false,
        readout: const LevelReadout(),
        child: _BandsHero(bands: bands, selected: band, onSelect: (b) => setState(() => _band = b))),
      SizedBox(height: 132, child: Row(children: [
        for (var b = 0; b < bands; b++) Expanded(child: _BandStrip(band: b, selected: b == band,
            onTap: () => setState(() => _band = b))),
      ])),
      ControlGroup(title: 'BAND ${band + 1} CHAIN', color: bandColor(band), child: RackChain(key: ValueKey('mb-chain-$band'), band: band)),
      const KnobRow(['mix', 'output'], size: 46),
    ]);
  }
}

/// The spectrum (live while playing), each band tinted, a handle on each crossover: drag it sideways.
class _BandsHero extends StatefulWidget {
  const _BandsHero({required this.bands, required this.selected, required this.onSelect});
  final int bands, selected;
  final ValueChanged<int> onSelect;

  @override
  State<_BandsHero> createState() => _BandsHeroState();
}

class _BandsHeroState extends State<_BandsHero> {
  int? _drag;

  List<double> _xovers(DeviceTarget t) => [for (var c = 1; c <= 4; c++) t.value('xover$c')];

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final xs = _xovers(t);
      int? nearest(double x) {
        int? best;
        var dist = 28.0;
        for (var c = 0; c < widget.bands - 1; c++) {
          final d = (freqToX(xs[c], w) - x).abs();
          if (d < dist) {
            dist = d;
            best = c;
          }
        }
        return best;
      }
      void move(int c, double x) {
        final lo = c == 0 ? 20.0 : xs[c - 1] * 1.04, hi = c + 2 < widget.bands ? xs[c + 1] / 1.04 : 20000.0;
        t.setLive('xover${c + 1}', xToFreq(x.clamp(0, w), w).clamp(lo, hi).toDouble());
      }
      return GestureDetector(
        key: const ValueKey('mb-hero'),
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          var b = 0;
          for (var c = 0; c < widget.bands - 1; c++) {
            if (d.localPosition.dx > freqToX(xs[c], w)) b = c + 1;
          }
          DeviceFeel.tap();
          widget.onSelect(b);
        },
        onHorizontalDragStart: (d) {
          _drag = nearest(d.localPosition.dx);
          if (_drag != null) DeviceFeel.grab();
        },
        onHorizontalDragUpdate: (d) {
          if (_drag != null) move(_drag!, d.localPosition.dx);
        },
        onHorizontalDragEnd: (_) {
          if (_drag != null) t.commit();
          setState(() => _drag = null);
        },
        child: DeviceDisplay(builder: (context, f) => CustomPaint(
          size: Size(w, box.maxHeight),
          painter: _BandsPainter(bands: widget.bands, xovers: xs, selected: widget.selected, spectrum: f?.spectrum,
              out: f == null ? null : [for (var j = 0; f.values.containsKey('out$j'); j++) ((f.values['out$j']! + 90) / 90).clamp(0.0, 1.0)],
              levels: [for (var b = 0; b < 5; b++) f?.values['band${b + 1}_db']], active: _drag),
        )),
      );
    });
  }
}

class _BandsPainter extends CustomPainter {
  _BandsPainter({required this.bands, required this.xovers, required this.selected, this.spectrum, this.out,
    required this.levels, this.active});
  final int bands, selected;
  final List<double> xovers;
  final List<double>? spectrum, out;
  final List<double?> levels;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final edges = [0.0, for (var c = 0; c < bands - 1; c++) freqToX(xovers[c], w), w];
    for (var b = 0; b < bands; b++) {
      final c = bandColor(b);
      final r = Rect.fromLTRB(edges[b], 0, edges[b + 1], h);
      canvas.drawRect(r, Paint()..color = c.withValues(alpha: b == selected ? 0.16 : 0.06));
      final db = levels[b];
      if (db != null) {
        final u = dbUnit(db);
        canvas.drawRect(Rect.fromLTRB(r.left + 2, h - 6, r.left + 2 + (r.width - 4) * u, h - 2), Paint()..color = c.withValues(alpha: 0.8));
      }
      paintLabel(canvas, '${b + 1}', Offset((r.left + r.right) / 2, 20), c, align: 0);
    }
    void curve(List<double> s, Color color, {double width = 1.6}) {
      if (s.length < 2) return;
      final p = Path();
      for (var j = 0; j < s.length; j++) {
        final x = w * j / (s.length - 1), y = h - 10 - (h - 30) * s[j];
        j == 0 ? p.moveTo(x, y) : p.lineTo(x, y);
      }
      strokeGlow(canvas, p, color, width: width, glow: false);
    }
    if (spectrum != null) curve(spectrum!, Neon.dim, width: 1.2);
    if (out != null) curve(out!, Neon.text, width: 1.4);
    for (var c = 0; c < bands - 1; c++) {
      final x = edges[c + 1];
      canvas.drawLine(Offset(x, 0), Offset(x, h), Paint()..color = Neon.text.withValues(alpha: 0.5)..strokeWidth = 1);
      paintHandle(canvas, Offset(x, h / 2), bandColor(c + 1), active: active == c, label: _hz(xovers[c]));
    }
  }

  static String _hz(double v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(v >= 10000 ? 0 : 1)}k' : v.toStringAsFixed(0);

  @override
  bool shouldRepaint(_BandsPainter o) => true;
}

/// One band's strip: its name and range, M / S / B, gain and pan.
class _BandStrip extends StatelessWidget {
  const _BandStrip({required this.band, required this.selected, required this.onTap});
  final int band;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final c = bandColor(band);
    final n = band + 1;
    Widget toggle(String id, String label, Color on) {
      final v = t.value('band${n}_$id') >= 0.5;
      return Expanded(child: GestureDetector(
        key: ValueKey('mb-$id-$n'),
        onTap: () {
          DeviceFeel.tap();
          t.set('band${n}_$id', v ? 0 : 1);
        },
        child: Container(
          height: 22, margin: const EdgeInsets.symmetric(horizontal: 1), alignment: Alignment.center,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), color: v ? on.withValues(alpha: 0.85) : Neon.ink.withValues(alpha: 0.04),
            border: Border.all(color: v ? on : Neon.line)),
          child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: v ? Neon.bg : Neon.dim)))));
    }
    final count = rackChildren(t, band: band).where((e) => e.$2 != null).length;
    return GestureDetector(
      key: ValueKey('mb-band-$n'),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
          color: c.withValues(alpha: selected ? 0.14 : 0.04), border: Border.all(color: selected ? c : c.withValues(alpha: 0.3))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('BAND $n', maxLines: 1, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: c)),
          Text(count == 0 ? 'empty' : '$count FX', style: const TextStyle(fontSize: 9, color: Neon.dim)),
          const SizedBox(height: 2),
          Row(children: [toggle('mute', 'M', Neon.layers[7]), toggle('solo', 'S', Neon.yellow), toggle('bypass', 'B', Neon.dim)]),
          Expanded(child: FittedBox(child: Row(mainAxisSize: MainAxisSize.min, children: [
            DeviceKnob('band${n}_gain', size: 30, label: 'GAIN', color: c),
            DeviceKnob('band${n}_pan', size: 30, label: 'PAN', color: c),
          ]))),
        ]),
      ),
    );
  }
}

// ---------- The FX rack ----------

/// The FX rack: its modulator strip on top (chips to drag onto any knob below, or tap for assign mode), the focused
/// modulator's controls (an LFO's shape, which you can pick or draw), the macros, then the chain, then mix and output.
class FxRackPage extends StatelessWidget {
  const FxRackPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final m = scope.matrix;
    return effectPage('fxrack', [
      // Inline in the FX stack the strip is the rack's own (the full-screen editor shows one above every page).
      if (m != null && DeviceScope.isInline(context)) ...[const ModSourceStrip(), const ModAssignBanner()],
      const _ModulatorPicker(),
      ValueListenableBuilder<ModSource>(valueListenable: scope.focusSource, builder: (context, focus, _) =>
          _ModulatorPanel(source: focus)),
      ControlGroup(title: 'MACROS', color: Neon.violet, child: KnobRow([for (var i = 1; i <= 8; i++) 'macro$i'], size: 40,
          color: Neon.violet, labels: {for (var i = 1; i <= 8; i++) 'macro$i': 'M$i'})),
      ControlGroup(title: 'CHAIN', color: scope.accent, child: const RackChain()),
      const KnobRow(['mix', 'output'], size: 46),
    ]);
  }
}

/// Which modulator the panel below shows: the shaped ones (the macros' knobs are always in MACROS).
class _ModulatorPicker extends StatelessWidget {
  const _ModulatorPicker();

  static const sources = [ModSource.lfo1, ModSource.lfo2, ModSource.lfo3, ModSource.lfo4, ModSource.follow1,
    ModSource.follow2, ModSource.env1, ModSource.env2, ModSource.random];

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return ValueListenableBuilder<ModSource>(valueListenable: scope.focusSource, builder: (context, focus, _) =>
        SizedBox(height: 36, child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final s in sources)
            Padding(padding: const EdgeInsets.only(right: 4), child: ChoiceChip(
              key: ValueKey('rack-focus-${s.name}'),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              label: Text(s.short, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800,
                  color: s == focus ? Neon.bg : modSourceColor(s))),
              selected: s == focus,
              selectedColor: modSourceColor(s),
              showCheckmark: false,
              onSelected: (_) {
                DeviceFeel.tap();
                scope.focusSource.value = s;
              })),
        ])));
  }
}

/// The controls of the focused modulator: an LFO (shape tiles or a drawn shape, rate or sync, phase, mode), a
/// follower, an envelope, the random source; a macro or a note source shows its knob.
class _ModulatorPanel extends StatelessWidget {
  const _ModulatorPanel({required this.source});
  final ModSource source;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final c = modSourceColor(source);
    final lfo = switch (source) {
      ModSource.lfo1 => 1, ModSource.lfo2 => 2, ModSource.lfo3 => 3, ModSource.lfo4 => 4, _ => 0 };
    if (lfo > 0) {
      final p = 'lfo${lfo}_';
      final custom = t.value('${p}shape').round() == 7;
      return ControlGroup(title: 'LFO $lfo', color: c, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ModeTiles('${p}shape', height: 40, color: c,
          names: const ['Sine', 'Tri', 'Up', 'Down', 'Sqr', 'S&H', 'Smth', 'Draw'],
          icon: (canvas, r, i, col) => iconCurve(canvas, r.deflate(2), col, (x) {
            if (i == 7) return math.sin(x * math.pi * 2) * 0.4 + (x > 0 ? 0.3 : -0.3);
            final ph = i >= 5 ? (x + 1) * 2 : (x + 1) / 2;
            return lfoValue(i, ph, cycle: ph.floor() + 3) * 0.9;
          }, steps: 60)),
        const SizedBox(height: 6),
        HeroCanvas(color: c, height: 110, caption: custom ? 'DRAW THE SHAPE' : 'SHAPE ≈', child: LfoShapeEditor(prefix: p, color: c)),
        Row(children: [
          const Text('SYNC', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)),
          const SizedBox(width: 8),
          Expanded(child: DeviceChoice('${p}sync', maxSegments: 0, color: c)),
          DeviceChoice('${p}mode', color: c),
        ]),
        KnobRow([if (t.value('${p}sync') < 0.5) '${p}rate', '${p}phase'], size: 44, color: c,
            labels: {'${p}rate': 'Rate', '${p}phase': 'Phase'}),
      ]));
    }
    if (source == ModSource.follow1 || source == ModSource.follow2) {
      final n = source == ModSource.follow1 ? 1 : 2;
      final p = 'fol${n}_';
      return ControlGroup(title: 'FOLLOWER $n', color: c, child: Column(mainAxisSize: MainAxisSize.min, children: [
        DeviceChoice('${p}src', color: c),
        KnobRow(['${p}attack', '${p}release', '${p}gain'], size: 44, color: c,
            labels: {'${p}attack': 'Attack', '${p}release': 'Release', '${p}gain': 'Gain'}),
      ]));
    }
    if (source == ModSource.env1 || source == ModSource.env2) {
      final n = source == ModSource.env1 ? 1 : 2;
      final p = 'env${n}_';
      return ControlGroup(title: 'ENVELOPE $n · NOTES', color: c, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        EnvelopeView(prefix: p, height: 90, color: c),
        KnobRow(['${p}attack', '${p}decay', '${p}sustain', '${p}release'], size: 40, color: c,
            labels: {'${p}attack': 'A', '${p}decay': 'D', '${p}sustain': 'S', '${p}release': 'R'}),
      ]));
    }
    if (source == ModSource.random) {
      return ControlGroup(title: 'RANDOM', color: c, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Text('SYNC', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)),
          const SizedBox(width: 8),
          Expanded(child: DeviceChoice('rnd_sync', maxSegments: 0, color: c)),
        ]),
        KnobRow([if (t.value('rnd_sync') < 0.5) 'rnd_rate', 'rnd_smooth'], size: 44, color: c,
            labels: const {'rnd_rate': 'Rate', 'rnd_smooth': 'Smooth'}),
      ]));
    }
    return const SizedBox.shrink();  // a macro: its knob is in MACROS
  }
}

/// An LFO's shape over one cycle: the picked shape drawn, or (Draw) its 16 points, set by dragging across them.
class LfoShapeEditor extends StatelessWidget {
  const LfoShapeEditor({super.key, required this.prefix, required this.color});
  final String prefix;
  final Color color;

  static const points = 16;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final shape = t.value('${prefix}shape').round();
    final values = [for (var i = 1; i <= points; i++) t.value('${prefix}p$i')];
    return LayoutBuilder(builder: (context, box) {
      void set(Offset at) {
        if (shape != 7) return;
        final i = (at.dx / box.maxWidth * points).floor().clamp(0, points - 1);
        final v = (1 - (at.dy - 18) / (box.maxHeight - 26)).clamp(0.0, 1.0);
        t.setLive('${prefix}p${i + 1}', v);
      }
      return GestureDetector(
        key: ValueKey('lfo-draw-$prefix'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) => set(d.localPosition),
        onPanUpdate: (d) => set(d.localPosition),
        onPanEnd: (_) => t.commit(),
        onTapUp: (d) {
          set(d.localPosition);
          t.commit();
        },
        child: CustomPaint(size: Size(box.maxWidth, box.maxHeight),
            painter: _ShapePainter(shape: shape, points: values, color: color, phase: t.value('${prefix}phase'))),
      );
    });
  }
}

class _ShapePainter extends CustomPainter {
  _ShapePainter({required this.shape, required this.points, required this.color, required this.phase});
  final int shape;
  final List<double> points;
  final Color color;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final top = 18.0, h = size.height - 26;
    double u(double x) {
      final p = (x + phase) % 1.0;
      if (shape == 7) {
        final at = p * points.length;
        final i = at.floor() % points.length;
        final a = points[i], b = points[(i + 1) % points.length];
        return a + (b - a) * (at - at.floor());
      }
      return (lfoValue(shape, shape >= 5 ? p * 4 : p, cycle: shape >= 5 ? (p * 4).floor() + 3 : 0) + 1) / 2;
    }
    final path = Path();
    for (var k = 0; k <= 120; k++) {
      final x = k / 120;
      final y = top + h * (1 - u(x));
      k == 0 ? path.moveTo(x * size.width, y) : path.lineTo(x * size.width, y);
    }
    fillFade(canvas, path, top + h, size, color);
    strokeGlow(canvas, path, color);
    if (shape == 7) {
      for (var i = 0; i < points.length; i++) {
        final x = (i + 0.5) / points.length * size.width;
        canvas.drawCircle(Offset(x, top + h * (1 - points[i])), 3, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(_ShapePainter o) => true;
}

/// Every route of the rack, as the Flagship's mod page lists them.
class _RoutesPage extends StatelessWidget {
  const _RoutesPage();

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.fromLTRB(10, 10, 10, 28), children: const [ModRouteList()]);
}
