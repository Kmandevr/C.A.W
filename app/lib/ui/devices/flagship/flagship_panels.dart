// The flagship's panels: an oscillator (its wavetable in depth and its knobs), a filter (its curve), the switch between the two filters, the voice, and the panel frame and knobs they share.
import 'package:flutter/material.dart';

import '../../../model/flagship_shapes.dart' show Warp, sourceWarps, warpNames;
import '../../../model/mod_matrix.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/feel.dart';
import '../kit/param_watch.dart';
import '../visuals/filter_curve.dart';
import '../visuals/unison_view.dart';
import '../visuals/wavetable_view.dart';
import 'flagship_editor.dart' show flagshipLabels;
import 'flagship_tools.dart';
import 'flagship_wavetable.dart';

/// A flagship knob: [DeviceKnob], plus the "What's modulating?" highlight: with it on, a modulated knob glows in
/// its sources' colour and names them above it, and an unmodulated one fades.
class FKnob extends StatelessWidget {
  const FKnob(this.id, {super.key, this.label, this.size = 40, this.color});
  final String id;
  final String? label;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final knob = DeviceKnob(id, label: label, size: size, color: color);
    final ui = FlagshipUi.maybeOf(context);
    final on = ui != null && ui.whoMods && (ui.only == null || ui.only == id);
    final routes = on ? DeviceScope.of(context).matrix?.routesTo(id) ?? const <ModRoute>[] : const <ModRoute>[];
    final c = routes.isEmpty ? null : modSourceColor(routes.first.source);
    final d = Motion.fade(Motion.small, Motion.of(context));
    return Stack(clipBehavior: Clip.none, children: [
      AnimatedOpacity(duration: d, opacity: on && routes.isEmpty && ui.only == null ? 0.3 : 1, child: AnimatedContainer(
        duration: d,
        // The outline is drawn over the knob, so it takes no room (a row of knobs fits as before).
        foregroundDecoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c?.withValues(alpha: 0.9) ?? Colors.transparent, width: 1.4)),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
          boxShadow: c == null ? null : [BoxShadow(color: c.withValues(alpha: 0.35), blurRadius: 10)]),
        child: knob)),
      if (routes.isNotEmpty) Positioned(left: 0, right: 0, top: -7, child: Center(child: Container(
        key: ValueKey('whomods-$id'),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(color: Neon.bg, borderRadius: BorderRadius.circular(6), border: Border.all(color: c!)),
        child: Text(routes.map((r) => r.source.short).join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: c, decoration: TextDecoration.none))))),
    ]);
  }
}

/// [FKnob]s spread across the width in balanced rows (as the kit's KnobRow), leaving out parameters the device lacks.
class FKnobRow extends StatelessWidget {
  const FKnobRow(this.ids, {super.key, this.size = 40, this.labels = const {}, this.color});
  final List<String> ids;
  final double size;
  final Map<String, String> labels;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final list = [for (final k in ids) if (t.param(k) != null) k];
    if (list.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, box) {
      final item = DeviceKnob.widthFor(size);
      final fit = (box.maxWidth / item).floor().clamp(1, 99);
      final rows = (list.length / fit).ceil();
      final per = (list.length / rows).ceil();
      return Padding(padding: const EdgeInsets.only(top: 6), child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var r = 0; r < rows; r++)
          Padding(padding: EdgeInsets.only(top: r == 0 ? 0 : 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [for (final id in list.skip(r * per).take(per)) FKnob(id, size: size, color: color,
              label: labels[id] ?? _plain(id))])),
      ]));
    });
  }

  static String? _plain(String id) {
    final i = id.indexOf('_');
    return i < 0 ? null : flagshipLabels[id.substring(i + 1)];
  }
}

/// A panel of the flagship's one screen: a thin top stripe in [color], a title row ([leading] power, the title,
/// [trailing] choices and menus) and [child]. Not a fold: everything in it shows.
class FPanel extends StatelessWidget {
  const FPanel({super.key, required this.title, required this.child, this.color, this.leading, this.trailing = const [],
    this.dimmed = false, this.padding = const EdgeInsets.fromLTRB(8, 0, 8, 8)});
  final String title;
  final Widget child;
  final Color? color;
  final Widget? leading;
  final List<Widget> trailing;
  final bool dimmed;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = color ?? DeviceScope.of(context).accent;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: Neon.ramp([
          Color.lerp(Neon.panel, c, 0.12)!.withValues(alpha: 0.72),
          Color.lerp(Neon.panel, c, 0.03)!.withValues(alpha: 0.6),
        ])),
        border: Border.all(color: c.withValues(alpha: 0.32)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Container(height: 2, decoration: BoxDecoration(gradient: LinearGradient(colors: Neon.ramp([
          c.withValues(alpha: 0.9), c.withValues(alpha: 0.0)])))),
        SizedBox(height: 30, child: Row(children: [
          if (leading != null) leading! else const SizedBox(width: 10),
          Text(title, maxLines: 1, style: TextStyle(fontSize: 11, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: c,
            shadows: [Shadow(color: c.withValues(alpha: 0.5), blurRadius: 8)])),
          const SizedBox(width: 6),
          // Scaled down rather than cut off when a phone is too narrow for them (the sampler's header, 1.1.3-alpha.2).
          Expanded(child: Align(alignment: Alignment.centerRight, child: FittedBox(fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight, child: Row(mainAxisSize: MainAxisSize.min, children: trailing)))),
          const SizedBox(width: 2),
        ])),
        AnimatedOpacity(duration: Motion.fade(Motion.small, Motion.of(context)), opacity: dimmed ? 0.5 : 1,
          child: Padding(padding: padding, child: child)),
      ]),
    );
  }
}

/// A small label before a control in a panel's row.
Widget fLabel(String text) => Padding(padding: const EdgeInsets.only(right: 4), child: Text(text,
  style: const TextStyle(fontSize: 9, letterSpacing: 0.8, fontWeight: FontWeight.w800, color: Neon.dim)));

/// One oscillator: power, wavetable and its menu (copy, paste, import) on top; the wavetable drawn in depth (drag
/// sideways for the frame, up for the warp; drop a source on it to modulate the frame); warp and where it goes;
/// then its knobs, MAIN (level, pan, voices, detune, semitones) or MORE (position, warp, octave, fine, the unison
/// fan and stack, width, blend, detune curve, phase).
class OscPanel extends StatefulWidget {
  const OscPanel(this.n, {super.key, this.waveHeight = 92, this.knobSize = 40});
  final int n;
  final double waveHeight, knobSize;

  @override
  State<OscPanel> createState() => _OscPanelState();
}

class _OscPanelState extends State<OscPanel> {
  bool _more = false;

  @override
  Widget build(BuildContext context) => watchDevice(context, _body);

  Widget _body(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final n = widget.n;
    final p = 'osc${n}_';
    final on = t.value('${p}on') >= 0.5;
    final fold = t.value('${p}warp').round() == warpNames.indexOf('Fold') && t.param('${p}fold_mode') != null;
    final warpNow = t.value('${p}warp').round();
    // Osc FM, RM, AM and sync hear another oscillator or noise (1.1.0): their source shows beside the warp.
    final heard = warpNow >= 0 && warpNow < Warp.values.length && sourceWarps.contains(Warp.values[warpNow]) &&
        t.param('${p}mod_src') != null;
    final k = widget.knobSize;
    final main = FKnobRow(key: ValueKey('osc$n-main'), ['${p}level', '${p}pan', '${p}unison', '${p}detune', '${p}semi'],
      size: k, labels: {'${p}semi': 'Semitones'});
    final more = Column(key: ValueKey('osc$n-more'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [fLabel('STACK'), DeviceChoice('${p}stack', maxSegments: 0)]),
          if (fold) Row(mainAxisSize: MainAxisSize.min, children: [fLabel('FOLD'), DeviceChoice('${p}fold_mode', maxSegments: 2)]),
        ]),
        watchDevice(context, (_) => UnisonView(prefix: p, height: 46)),
        FKnobRow(['${p}frame', '${p}warp_amt', '${p}octave', '${p}fine', '${p}spread', '${p}blend', '${p}detune_power',
          '${p}phase', '${p}phase_rand'], size: k - 4),
      ]);
    return FPanel(
      key: ValueKey('osc-$n'),
      title: 'OSC $n',
      dimmed: !on,
      leading: DevicePower('${p}on'),
      trailing: [
        DeviceChoice('${p}table', maxSegments: 0),
        ImportWavetableButton(prefix: p, compact: true),
        _OscMenu(n),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        DragTarget<ModSource>(
          onWillAcceptWithDetails: (d) => scope.matrix?.canModulate('${p}frame') ?? false,
          onAcceptWithDetails: (d) {
            final slot = scope.matrix?.add(d.data, '${p}frame');
            DeviceFeel.detent();
            if (slot != null) scope.selectedSlot?.value = slot;
          },
          builder: (context, hover, _) => AnimatedContainer(
            duration: Motion.fade(Motion.small, Motion.of(context)),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(
              color: hover.isEmpty ? Neon.line.withValues(alpha: 0.5) : modSourceColor(hover.first!), width: hover.isEmpty ? 1 : 2)),
            child: ClipRRect(borderRadius: BorderRadius.circular(9),
              child: watchDevice(context, (_) => WavetableView(prefix: p, height: widget.waveHeight))),
          ),
        ),
        const SizedBox(height: 4),
        // Warp, where it goes and MAIN / MORE; on a narrow panel the toggle wraps under them.
        Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 2,
          children: [
            // The warp, its source (the warps that hear another oscillator) and where it goes: a wrap, as 1.1.0's
            // longer warp names and the source can outgrow a narrow panel.
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 2, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                fLabel('WARP'), DeviceChoice('${p}warp', maxSegments: 0, labels: warpNames)]),
              if (heard) Row(mainAxisSize: MainAxisSize.min, children: [
                fLabel('FROM'), DeviceChoice('${p}mod_src', maxSegments: 0)]),
              Row(mainAxisSize: MainAxisSize.min, children: [
                fLabel('TO'),
                DeviceChoice('${p}dest', maxSegments: 0, labels: const ['Filter 1', 'Filter 2', 'Both', 'No filter'])]),
            ]),
            _PageToggle(key: ValueKey('osc$n-toggle'), more: _more, onTap: () => setState(() => _more = !_more)),
          ]),
        AnimatedSwitcher(duration: Motion.fade(Motion.standard, Motion.of(context)),
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
          child: _more ? more : main),
      ]),
    );
  }
}

/// MAIN / MORE: which of an oscillator's knob sets shows (a small switch: more knobs, or back to the main ones).
class _PageToggle extends StatelessWidget {
  const _PageToggle({super.key, required this.more, required this.onTap});
  final bool more;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = DeviceScope.of(context).accent;
    return Tooltip(message: more ? 'Back to the main knobs' : 'More knobs: position, warp, tuning, unison, phase',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          Motion.tick();
          onTap();
        },
        child: AnimatedContainer(
          duration: Motion.fade(Motion.small, Motion.of(context)),
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: more ? c : Neon.line),
            color: more ? c.withValues(alpha: 0.18) : Colors.transparent),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.tune, size: 14, color: more ? c : Neon.dim),
            const SizedBox(width: 3),
            Text('MORE', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800,
              letterSpacing: 0.5, color: more ? Neon.text : Neon.dim)),
          ]),
        ),
      ));
  }
}

/// An oscillator's menu: copy its settings, paste copied ones.
class _OscMenu extends StatelessWidget {
  const _OscMenu(this.n);
  final int n;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    return PopupMenuButton<String>(
      key: ValueKey('osc$n-menu'),
      tooltip: 'Copy or paste this oscillator',
      iconSize: 18,
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert, color: Neon.dim),
      onSelected: (v) {
        DeviceFeel.tap();
        if (v == 'copy') {
          copyOscillator(t, n);
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(duration: const Duration(seconds: 2),
            content: Text('Oscillator $n copied')));
        } else {
          pasteOscillator(t, n);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(key: ValueKey('osc$n-copy'), value: 'copy', child: const Text('Copy oscillator')),
        PopupMenuItem(key: ValueKey('osc$n-paste'), value: 'paste', enabled: flagshipOscClipboard != null,
          child: const Text('Paste oscillator')),
      ],
    );
  }
}

/// One filter: power and type on top, its response curve (drag: cutoff sideways, resonance up), its knobs.
class FilterPanel extends StatelessWidget {
  const FilterPanel(this.n, {super.key, this.curveHeight = 76, this.knobSize = 38});
  final int n;
  final double curveHeight, knobSize;

  @override
  Widget build(BuildContext context) => watchDevice(context, _body);

  Widget _body(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final p = 'flt${n}_';
    final type = t.value('${p}type').round();
    final on = t.value('${p}on') >= 0.5;
    return FPanel(
      key: ValueKey('filter-$n'),
      title: 'FILTER $n',
      dimmed: !on,
      leading: DevicePower('${p}on'),
      trailing: [DeviceChoice('${p}type', maxSegments: 0)],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        watchDevice(context, (_) => FilterCurve(prefix: p, height: curveHeight)),
        FKnobRow(['${p}cutoff', '${p}resonance', '${p}drive', '${p}mix', '${p}keytrack', '${p}morph'], size: knobSize,
          labels: {'${p}morph': type == 8 ? 'Vowel' : (type == 7 ? 'Damping' : 'Morph'), '${p}keytrack': 'Key track'}),
      ]),
    );
  }
}

/// Series or parallel, drawn between the two filters: a tap switches it. [vertical] stands it between two filters
/// side by side; otherwise it lies between two stacked ones.
class FilterRouteSwitch extends StatelessWidget {
  const FilterRouteSwitch({super.key, this.vertical = true});
  final bool vertical;

  @override
  Widget build(BuildContext context) => watchDevice(context, (context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final parallel = t.value('flt_routing') >= 0.5;
    final label = parallel ? 'PARALLEL' : 'SERIES';
    final drawing = CustomPaint(size: vertical ? const Size(44, 64) : const Size(64, 30),
      painter: _RoutePainter(parallel, scope.accent, vertical));
    return Semantics(button: true, label: 'Filter routing: ${parallel ? 'parallel' : 'series'}', child: Tooltip(
      message: parallel ? 'Parallel: both filters hear the oscillators. Tap for series.'
          : 'Series: filter 1, then filter 2. Tap for parallel.',
      child: InkWell(
        key: const ValueKey('flagship-routing'),
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          DeviceFeel.tap();
          t.set('flt_routing', parallel ? 0 : 1);
        },
        child: Padding(padding: const EdgeInsets.all(4), child: vertical
            ? Column(mainAxisSize: MainAxisSize.min, children: [drawing, const SizedBox(height: 4), _routeText(label, scope.accent)])
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [drawing, const SizedBox(width: 8),
                Flexible(child: _routeText(parallel ? 'PARALLEL · both hear the oscillators' : 'SERIES · filter 1, then filter 2',
                  scope.accent))])),
      ),
    ));
  });

  static Widget _routeText(String s, Color c) => Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 9, letterSpacing: 1,
    fontWeight: FontWeight.w800, color: c));
}

class _RoutePainter extends CustomPainter {
  _RoutePainter(this.parallel, this.color, this.vertical);
  final bool parallel, vertical;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final box = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10));
    canvas.drawRRect(box, Paint()..color = color.withValues(alpha: 0.12));
    canvas.drawRRect(box, Paint()
      ..color = color.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke);
    // Drawn left to right (filter 1 on the left), turned for the vertical switch's own box.
    final w = vertical ? size.height : size.width, h = vertical ? size.width : size.height;
    canvas.save();
    if (vertical) {
      canvas.translate(size.width, 0);
      canvas.rotate(1.5707963);
    }
    final mid = h / 2;
    if (!parallel) {
      canvas.drawLine(Offset(w * 0.18, mid), Offset(w * 0.82, mid), line);
      final a = Path()
        ..moveTo(w * 0.7, mid - 5)
        ..lineTo(w * 0.82, mid)
        ..lineTo(w * 0.7, mid + 5);
      canvas.drawPath(a, line);
    } else {
      for (final y in [h * 0.3, h * 0.7]) {
        canvas.drawLine(Offset(w * 0.18, y), Offset(w * 0.82, y), line);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RoutePainter o) => o.parallel != parallel || o.color != color || o.vertical != vertical;
}

/// The voice: poly, mono or legato, volume, velocity, bend range and glide.
class VoicePanel extends StatelessWidget {
  const VoicePanel({super.key, this.knobSize = 38});
  final double knobSize;

  @override
  Widget build(BuildContext context) => watchDevice(context, (context) => FPanel(
    key: const ValueKey('flagship-voice'),
    title: 'VOICE',
    trailing: const [DeviceChoice('voice_mode', maxSegments: 3)],
    child: FKnobRow(const ['volume', 'velocity', 'bend_range', 'glide'], size: knobSize,
      labels: const {'volume': 'Volume', 'velocity': 'Velocity', 'bend_range': 'Bend range', 'glide': 'Glide'}),
  ));
}
