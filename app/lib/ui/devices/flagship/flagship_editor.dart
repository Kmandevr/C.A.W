// The flagship synth's editor (`org.caw.synth.flagship`, #171): its tabs, and the OSC and FILTER pages.
import 'package:flutter/material.dart';

import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_registry.dart';
import '../device_scope.dart';
import '../visuals/filter_curve.dart';
import '../visuals/unison_view.dart';
import '../visuals/wavetable_view.dart';
import '../../../model/device_target.dart';
import 'flagship_mod_fx.dart';

const flagshipComponentId = 'org.caw.synth.flagship';

/// Width from which a page lays its cards side by side.
const double flagshipWide = 700;

List<DeviceSection> flagshipSections(DeviceTarget target) => [
  DeviceSection('osc', 'OSC', Icons.waves, (_) => const FlagshipOscPage()),
  DeviceSection('filter', 'FILTER', Icons.filter_alt_outlined, (_) => const FlagshipFilterPage()),
  DeviceSection('mod', 'MOD', Icons.hub_outlined, (_) => const FlagshipModPage()),
  DeviceSection('fx', 'FX', Icons.auto_awesome_outlined, (_) => const FlagshipFxPage()),
];

/// Knobs in rows that wrap.
Widget knobRow(List<Widget> knobs) => Padding(
  padding: const EdgeInsets.only(top: 4),
  child: Wrap(spacing: 0, runSpacing: 2, children: knobs),
);

/// The three oscillators: one at a time on a phone (a selector picks it), side by side when wide; the voice settings.
class FlagshipOscPage extends StatefulWidget {
  const FlagshipOscPage({super.key});

  @override
  State<FlagshipOscPage> createState() => _FlagshipOscPageState();
}

class _FlagshipOscPageState extends State<FlagshipOscPage> {
  int _osc = 1;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= flagshipWide;
      return ListView(key: const ValueKey('flagship-osc'), padding: const EdgeInsets.fromLTRB(8, 8, 8, 24), children: [
        if (!wide) Padding(padding: const EdgeInsets.only(bottom: 8), child: DevicePicker(
          labels: const ['OSC 1', 'OSC 2', 'OSC 3'],
          on: [for (var o = 1; o <= 3; o++) t.value('osc${o}_on') >= 0.5],
          selected: _osc - 1,
          keyPrefix: 'osc-pick',
          onPick: (i) => setState(() => _osc = i + 1))),
        if (wide)
          DeviceColumns(minWidth: 300, children: [for (var o = 1; o <= 3; o++) OscCard(o)])
        else
          AnimatedSwitcher(duration: Motion.fade(Motion.standard, Motion.of(context)),
            child: OscCard(_osc, key: ValueKey('osc-card-$_osc'))),
        DeviceCard(title: 'VOICE', child: knobRow(const [
          DeviceKnob('volume'), DeviceKnob('velocity', label: 'Velocity'), DeviceKnob('bend_range', label: 'Bend'),
        ])),
      ]);
    });
  }
}

/// A row of segments with an on-dot each: picks the oscillator, filter or source shown on a phone.
class DevicePicker extends StatelessWidget {
  const DevicePicker({super.key, required this.labels, required this.selected, required this.onPick, this.on, this.keyPrefix = 'pick'});
  final List<String> labels;
  final List<bool>? on;
  final int selected;
  final ValueChanged<int> onPick;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final c = DeviceScope.of(context).accent;
    return SizedBox(height: 30, child: Row(children: [
      for (var i = 0; i < labels.length; i++)
        Expanded(child: Padding(padding: EdgeInsets.only(right: i < labels.length - 1 ? 4 : 0), child: InkWell(
          key: ValueKey('$keyPrefix-${i + 1}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            Motion.tick();
            onPick(i);
          },
          child: AnimatedContainer(
            duration: Motion.fade(Motion.small, Motion.of(context)),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: i == selected ? c.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.03),
              border: Border.all(color: i == selected ? c : Neon.line)),
            alignment: Alignment.center,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (on != null) Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 5), decoration: BoxDecoration(
                shape: BoxShape.circle, color: on![i] ? Neon.green : Neon.line)),
              Text(labels[i], style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.8,
                color: i == selected ? Neon.text : Neon.dim)),
            ]),
          ),
        ))),
    ]));
  }
}

/// One oscillator: its table drawn in depth (drag for the frame), warp, level and tuning, and its unison fan.
class OscCard extends StatelessWidget {
  const OscCard(this.n, {super.key});
  final int n;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final p = 'osc${n}_';
    final on = scope.target.value('${p}on') >= 0.5;
    return DeviceCard(
      key: ValueKey('osc-$n'),
      title: 'OSC $n',
      color: scope.accent,
      dimmed: !on,
      leading: DevicePower('${p}on'),
      actions: [DeviceChoice('${p}table', maxSegments: 4)],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        WavetableView(prefix: p),
        const SizedBox(height: 4),
        Row(children: [
          const Text('WARP', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)),
          const SizedBox(width: 6),
          Flexible(child: DeviceChoice('${p}warp', labels: const ['None', 'Bend', 'Sync', 'Mirror', 'Quant'])),
        ]),
        knobRow([
          DeviceKnob('${p}frame'), DeviceKnob('${p}warp_amt', label: 'Warp'), DeviceKnob('${p}level'),
          DeviceKnob('${p}pan'), DeviceKnob('${p}octave', label: 'Oct'), DeviceKnob('${p}semi', label: 'Semi'),
          DeviceKnob('${p}fine'), DeviceKnob('${p}phase'), DeviceKnob('${p}phase_rand', label: 'Rand'),
        ]),
        const SizedBox(height: 6),
        DeviceHeading('UNISON', trailing: DeviceChoice('${p}stack', maxSegments: 0)),
        UnisonView(prefix: p),
        knobRow([
          DeviceKnob('${p}unison', label: 'Voices'), DeviceKnob('${p}detune'), DeviceKnob('${p}detune_power', label: 'Power'),
          DeviceKnob('${p}spread'), DeviceKnob('${p}blend'),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          const Text('TO', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)),
          const SizedBox(width: 6),
          Flexible(child: DeviceChoice('${p}dest', labels: const ['Filter 1', 'Filter 2', 'Both', 'Dry'])),
        ]),
      ]),
    );
  }
}

/// The two filters with their curves (drag: cutoff and resonance), how they connect, and where each oscillator goes.
class FlagshipFilterPage extends StatelessWidget {
  const FlagshipFilterPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final parallel = t.value('flt_routing') >= 0.5;
    return ListView(key: const ValueKey('flagship-filter'), padding: const EdgeInsets.fromLTRB(8, 8, 8, 24), children: [
      DeviceColumns(minWidth: 340, children: [for (var f = 1; f <= 2; f++) FilterCard(f)]),
      DeviceCard(title: 'ROUTING', actions: const [DeviceChoice('flt_routing')], child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          SizedBox(height: 34, child: CustomPaint(painter: _RoutingPainter(parallel, scope.accent))),
          const SizedBox(height: 6),
          for (var o = 1; o <= 3; o++)
            Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
              SizedBox(width: 48, child: Text('OSC $o', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800,
                color: t.value('osc${o}_on') >= 0.5 ? Neon.text : Neon.dim))),
              Flexible(child: DeviceChoice('osc${o}_dest', labels: const ['Filter 1', 'Filter 2', 'Both', 'Dry'])),
            ])),
        ])),
    ]);
  }
}

class _RoutingPainter extends CustomPainter {
  _RoutingPainter(this.parallel, this.color);
  final bool parallel;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    void box(Rect r, String text) {
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(5)), Paint()..color = color.withValues(alpha: 0.15));
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(5)), line);
      final tp = TextPainter(text: TextSpan(text: text, style: Neon.code(size: 9, color: Neon.text)),
        textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
    }

    final mid = size.height / 2, w = size.width;
    if (!parallel) {
      canvas.drawLine(Offset(0, mid), Offset(w, mid), line);
      box(Rect.fromCenter(center: Offset(w * 0.33, mid), width: 64, height: 22), 'Filter 1');
      box(Rect.fromCenter(center: Offset(w * 0.66, mid), width: 64, height: 22), 'Filter 2');
    } else {
      final path = Path()
        ..moveTo(0, mid)
        ..lineTo(w * 0.2, mid)
        ..moveTo(w * 0.2, 6)
        ..lineTo(w * 0.2, size.height - 6)
        ..moveTo(w * 0.2, 6)
        ..lineTo(w * 0.8, 6)
        ..moveTo(w * 0.2, size.height - 6)
        ..lineTo(w * 0.8, size.height - 6)
        ..moveTo(w * 0.8, 6)
        ..lineTo(w * 0.8, size.height - 6)
        ..moveTo(w * 0.8, mid)
        ..lineTo(w, mid);
      canvas.drawPath(path, line);
      box(Rect.fromCenter(center: Offset(w * 0.5, 6), width: 64, height: 14), 'Filter 1');
      box(Rect.fromCenter(center: Offset(w * 0.5, size.height - 6), width: 64, height: 14), 'Filter 2');
    }
  }

  @override
  bool shouldRepaint(covariant _RoutingPainter o) => o.parallel != parallel || o.color != color;
}

/// One filter: power, type, its response curve and knobs.
class FilterCard extends StatelessWidget {
  const FilterCard(this.n, {super.key});
  final int n;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final p = 'flt${n}_';
    final type = scope.target.value('${p}type').round();
    return DeviceCard(
      key: ValueKey('filter-$n'),
      title: 'FILTER $n',
      color: scope.accent,
      dimmed: scope.target.value('${p}on') < 0.5,
      leading: DevicePower('${p}on'),
      actions: [DeviceChoice('${p}type')],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        FilterCurve(prefix: p),
        knobRow([
          DeviceKnob('${p}cutoff'), DeviceKnob('${p}resonance', label: 'Reso'), DeviceKnob('${p}drive'),
          DeviceKnob('${p}keytrack', label: 'Key'),
          DeviceKnob('${p}morph', label: type == 8 ? 'Vowel' : (type == 7 ? 'Damp' : 'Morph')),
          DeviceKnob('${p}mix'),
        ]),
      ]),
    );
  }
}
