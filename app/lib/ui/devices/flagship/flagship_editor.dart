// The flagship synth's editor (`org.caw.synth.flagship`, #171): three tabs like Vital's (SYNTH, EFFECTS, MATRIX), the SYNTH page's sections expanding in place.
import 'package:flutter/material.dart';

import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_registry.dart';
import '../device_scope.dart';
import '../kit/param_watch.dart';
import '../kit/controls.dart';
import '../visuals/filter_curve.dart';
import '../visuals/unison_view.dart';
import '../visuals/wavetable_view.dart';
import '../../../model/device_target.dart';
import '../../../model/flagship_shapes.dart' show filterTypeNames, warpNames;
import 'flagship_mod_fx.dart';
import '../../pointer_input.dart';
import 'flagship_wavetable.dart';

const flagshipComponentId = 'org.caw.synth.flagship';

/// Width from which a page lays its cards side by side.
const double flagshipWide = 700;

/// Three tabs, as Vital has Voice, Effects and Matrix: everything that makes the sound on one page of sections
/// that open in place (owner, 2026-11-10: "Everything doesn't need to be a separate screen"), the effects rack,
/// and the list of every modulation.
List<DeviceSection> flagshipSections(DeviceTarget target) => [
  DeviceSection('synth', 'SYNTH', Icons.graphic_eq, (_) => const FlagshipSynthPage(), showsSources: true),
  DeviceSection('fx', 'EFFECTS', Icons.auto_awesome_outlined, (_) => const FlagshipFxPage()),
  DeviceSection('matrix', 'MATRIX', Icons.hub_outlined, (_) => const FlagshipMatrixPage()),
];

/// Knobs in rows that wrap.
Widget knobRow(List<Widget> knobs) => Padding(
  padding: const EdgeInsets.only(top: 4),
  child: Wrap(spacing: 0, runSpacing: 2, children: knobs),
);

/// Plain names for the flagship's knobs (owner, 2026-11-10: no cryptic abbreviations), by parameter id suffix.
const Map<String, String> flagshipLabels = {
  'frame': 'Position', 'warp_amt': 'Warp', 'level': 'Level', 'pan': 'Pan', 'octave': 'Octave', 'semi': 'Semitones',
  'fine': 'Fine tune', 'phase': 'Start phase', 'phase_rand': 'Random phase', 'unison': 'Voices', 'detune': 'Detune',
  'detune_power': 'Detune curve', 'spread': 'Stereo width', 'blend': 'Blend', 'cutoff': 'Cutoff',
  'resonance': 'Resonance', 'drive': 'Drive', 'keytrack': 'Key tracking', 'mix': 'Mix', 'attack': 'Attack',
  'decay': 'Decay', 'sustain': 'Sustain', 'release': 'Release',
};

/// [prefix] + each of [names] as big knobs with their plain labels.
Widget plainKnobs(String prefix, List<String> names, {double size = 46, Map<String, String> labels = const {},
    Color? color}) =>
    KnobRow([for (final n in names) '$prefix$n'], size: size, color: color,
      labels: {for (final n in names) '$prefix$n': labels[n] ?? flagshipLabels[n] ?? n});

/// The SYNTH page: oscillators, filters, envelopes, LFOs and the voice, each a section that opens in place (one
/// oscillator open to start). Wide, the oscillators, filters and modulators sit side by side.
class FlagshipSynthPage extends StatelessWidget {
  const FlagshipSynthPage({super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final wide = box.maxWidth >= flagshipWide;
    // Built whole (not lazily), so a source opened from the strip finds its section and scrolls to it.
    return SingleChildScrollView(key: const ValueKey('flagship-synth'), padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _Group('OSCILLATORS', 'Each draws a wavetable; turn one on with its power button.'),
      DeviceColumns(minWidth: 300, children: [for (var o = 1; o <= 3; o++) OscCard(o, initiallyOpen: wide || o == 1)]),
      const _Group('FILTERS', 'Shape the oscillators\' tone. Drag a curve: sideways for cutoff, up for resonance.'),
      DeviceColumns(minWidth: 340, children: [for (var f = 1; f <= 2; f++) FilterCard(f, initiallyOpen: wide || f == 1)]),
      const FilterRoutingCard(),
      _Group('MODULATORS', '${PointerInput.tapCap} a source chip above, then ${PointerInput.tap} knobs. Or drag the chip onto a knob.'),
      DeviceColumns(minWidth: 320, children: const [EnvelopesCard(), LfosCard()]),
      const VoiceCard(),
    ]));
  });
}

/// A small heading between a page's groups of sections, with a one-line hint.
class _Group extends StatelessWidget {
  const _Group(this.title, this.hint);
  final String title, hint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 10, letterSpacing: 1.8, fontWeight: FontWeight.w900, color: Neon.text)),
      Text(hint, style: const TextStyle(fontSize: 10, color: Neon.dim)),
    ]),
  );
}

/// A row of segments with an on-dot each: picks the oscillator, filter or source shown.
class DevicePicker extends StatelessWidget {
  const DevicePicker({super.key, required this.labels, required this.selected, required this.onPick, this.on,
    this.keyPrefix = 'pick', this.colors});
  final List<String> labels;
  final List<bool>? on;
  final int selected;
  final ValueChanged<int> onPick;
  final String keyPrefix;

  /// Each segment's own colour (a mod source's); the device's accent when null.
  final List<Color>? colors;

  @override
  Widget build(BuildContext context) {
    final accent = DeviceScope.of(context).accent;
    return SizedBox(height: 36, child: Row(children: [
      for (var i = 0; i < labels.length; i++)
        Expanded(child: Padding(padding: EdgeInsets.only(right: i < labels.length - 1 ? 4 : 0), child: InkWell(
          key: ValueKey('$keyPrefix-${i + 1}'),
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            Motion.tick();
            onPick(i);
          },
          child: AnimatedContainer(
            duration: Motion.fade(Motion.small, Motion.of(context)),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: i == selected ? (colors?[i] ?? accent).withValues(alpha: 0.2) : Neon.ink.withValues(alpha: 0.03),
              border: Border.all(color: i == selected ? (colors?[i] ?? accent) : Neon.line),
              boxShadow: i == selected ? [BoxShadow(color: (colors?[i] ?? accent).withValues(alpha: 0.25), blurRadius: 8)] : null),
            alignment: Alignment.center,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (on != null) Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 5), decoration: BoxDecoration(
                shape: BoxShape.circle, color: on![i] ? Neon.green : Neon.line)),
              Flexible(child: Text(labels[i], maxLines: 1, overflow: TextOverflow.clip, softWrap: false,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.6,
                  color: i == selected ? Neon.text : Neon.dim))),
            ]),
          ),
        ))),
    ]));
  }
}

/// A label over a control (a choice in a section): small, dim, spaced.
class LabeledRow extends StatelessWidget {
  const LabeledRow(this.label, this.child, {super.key});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 2),
    child: Row(children: [
      SizedBox(width: 78, child: Text(label, style: const TextStyle(fontSize: 10, letterSpacing: 0.6,
        fontWeight: FontWeight.w700, color: Neon.dim))),
      Flexible(child: Align(alignment: Alignment.centerLeft, child: child)),
    ]),
  );
}

/// One oscillator as a section: closed, its power, name and what it is set to ("Analog · 7 voices · to Filter 1");
/// open, its wavetable (drag sideways for the position, up for the warp), the warp, level and pan, its pitch, its
/// unison fan (drag for width and detune) and where it goes.
class OscCard extends StatelessWidget {
  const OscCard(this.n, {super.key, this.initiallyOpen = false});
  final int n;
  final bool initiallyOpen;

  // Its own watch (param_watch.dart): a knob step in another card doesn't rebuild it.
  @override
  Widget build(BuildContext context) => watchDevice(context, _body);

  Widget _body(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final p = 'osc${n}_';
    final on = t.value('${p}on') >= 0.5;
    String choice(String id) => formatParamValue(t.param(id), t.value(id));
    final voices = t.value('${p}unison').round();
    final summary = on ? '${choice('${p}table')} · $voices voice${voices == 1 ? '' : 's'} · to ${choice('${p}dest')}' : 'Off';
    return DeviceExpandCard(
      key: ValueKey('osc-$n'),
      storageId: 'flagship-osc-$n',
      title: 'OSCILLATOR $n',
      summary: summary,
      color: scope.accent,
      dimmed: !on,
      initiallyOpen: initiallyOpen,
      leading: DevicePower('${p}on'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        // Six long names as segments from about 440 dp; narrower, a menu.
        LabeledRow('WAVETABLE', LayoutBuilder(builder: (context, box) =>
            DeviceChoice('${p}table', maxSegments: box.maxWidth >= 440 ? 6 : 0))),
        const SizedBox(height: 4),
        // The visuals have their own watches: a knob step redraws them and the knob, not the card.
        watchDevice(context, (_) => WavetableView(prefix: p)),
        ImportWavetableButton(prefix: p),
        LabeledRow('WARP', _roomy((roomy) => DeviceChoice('${p}warp', maxSegments: roomy ? 5 : 0, labels: warpNames))),
        plainKnobs(p, const ['frame', 'warp_amt', 'level', 'pan']),
        const DeviceHeading('PITCH'),
        plainKnobs(p, const ['octave', 'semi', 'fine'], size: 42),
        DeviceHeading('UNISON', trailing: DeviceChoice('${p}stack', maxSegments: 0)),
        watchDevice(context, (_) => UnisonView(prefix: p)),
        plainKnobs(p, const ['unison', 'detune', 'spread', 'blend', 'detune_power'], size: 42),
        LabeledRow('SENDS TO', DeviceChoice('${p}dest', labels: const ['Filter 1', 'Filter 2', 'Both', 'No filter'])),
        DeviceFold(title: 'PHASE', child: plainKnobs(p, const ['phase', 'phase_rand'], size: 42)),
      ]),
    );
  }
}

/// Five long names fit as segments from about 360 dp; narrower, a menu keeps them whole (no "Harmo…").
Widget _roomy(Widget Function(bool roomy) b) => LayoutBuilder(builder: (context, box) => b(box.maxWidth >= 360));

/// How the two filters connect (series or parallel), drawn.
class FilterRoutingCard extends StatelessWidget {
  const FilterRoutingCard({super.key});

  // Its own watch (param_watch.dart): a knob step in another card doesn't rebuild it.
  @override
  Widget build(BuildContext context) => watchDevice(context, _body);

  Widget _body(BuildContext context) {
    final scope = DeviceScope.of(context);
    final parallel = scope.target.value('flt_routing') >= 0.5;
    return DeviceExpandCard(
      storageId: 'flagship-filter-routing',
      title: 'FILTER ROUTING',
      summary: parallel ? 'Parallel: side by side' : 'Series: filter 1, then filter 2',
      color: scope.accent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Align(alignment: Alignment.centerLeft, child: DeviceChoice('flt_routing')),
        const SizedBox(height: 6),
        SizedBox(height: 40, child: CustomPaint(painter: _RoutingPainter(parallel, scope.accent))),
        const SizedBox(height: 4),
        const Text('Each oscillator picks its filter in its own section (Sends to).',
          style: TextStyle(fontSize: 10, color: Neon.dim)),
      ]),
    );
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
        ..moveTo(w * 0.2, 7)
        ..lineTo(w * 0.2, size.height - 7)
        ..moveTo(w * 0.2, 7)
        ..lineTo(w * 0.8, 7)
        ..moveTo(w * 0.2, size.height - 7)
        ..lineTo(w * 0.8, size.height - 7)
        ..moveTo(w * 0.8, 7)
        ..lineTo(w * 0.8, size.height - 7)
        ..moveTo(w * 0.8, mid)
        ..lineTo(w, mid);
      canvas.drawPath(path, line);
      box(Rect.fromCenter(center: Offset(w * 0.5, 7), width: 64, height: 14), 'Filter 1');
      box(Rect.fromCenter(center: Offset(w * 0.5, size.height - 7), width: 64, height: 14), 'Filter 2');
    }
  }

  @override
  bool shouldRepaint(covariant _RoutingPainter o) => o.parallel != parallel || o.color != color;
}

/// One filter as a section: power, type, its response curve (drag: cutoff sideways, resonance up) and knobs.
class FilterCard extends StatelessWidget {
  const FilterCard(this.n, {super.key, this.initiallyOpen = false});
  final int n;
  final bool initiallyOpen;

  // Its own watch (param_watch.dart): a knob step in another card doesn't rebuild it.
  @override
  Widget build(BuildContext context) => watchDevice(context, _body);

  Widget _body(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final p = 'flt${n}_';
    final type = t.value('${p}type').round();
    final on = t.value('${p}on') >= 0.5;
    final summary = on
        ? '${filterTypeNames.elementAtOrNull(type) ?? ''} · ${formatParamValue(t.param('${p}cutoff'), t.value('${p}cutoff'))} Hz'
        : 'Off';
    return DeviceExpandCard(
      key: ValueKey('filter-$n'),
      storageId: 'flagship-filter-$n',
      title: 'FILTER $n',
      summary: summary,
      color: scope.accent,
      dimmed: !on,
      initiallyOpen: initiallyOpen,
      leading: DevicePower('${p}on'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        LabeledRow('TYPE', DeviceChoice('${p}type', maxSegments: 0)),
        const SizedBox(height: 4),
        watchDevice(context, (_) => FilterCurve(prefix: p)),
        plainKnobs(p, const ['cutoff', 'resonance', 'drive', 'mix']),
        plainKnobs(p, const ['keytrack', 'morph'], size: 42,
          labels: {'morph': type == 8 ? 'Vowel' : (type == 7 ? 'Damping' : 'Morph')}),
      ]),
    );
  }
}

/// The voice: poly or mono, volume, velocity, bend range and glide.
class VoiceCard extends StatelessWidget {
  const VoiceCard({super.key});

  // Its own watch (param_watch.dart): a knob step in another card doesn't rebuild it.
  @override
  Widget build(BuildContext context) => watchDevice(context, _body);

  Widget _body(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return DeviceExpandCard(
      storageId: 'flagship-voice',
      title: 'VOICE',
      summary: '${formatParamValue(t.param('voice_mode'), t.value('voice_mode'))} · volume ${formatParamValue(t.param('volume'), t.value('volume'))}',
      color: scope.accent,
      // Poly, Mono or Legato with its glide (one synth, 2026-11-10: the Mono bass and Acid 303 presets play legato).
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        LabeledRow('PLAYS', DeviceChoice('voice_mode', maxSegments: 3)),
        KnobRow(const ['volume', 'velocity', 'bend_range', 'glide'], size: 46,
          labels: const {'volume': 'Volume', 'velocity': 'Velocity', 'bend_range': 'Bend range', 'glide': 'Glide'}),
      ]),
    );
  }
}
