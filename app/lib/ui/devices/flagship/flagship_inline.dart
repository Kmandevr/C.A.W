// The flagship synth inline in the FX stack: the mod strip, then chips pick one oscillator, a filter, the amp envelope or a mod source, each a compact hero and its main knobs.
import 'package:flutter/material.dart';

import '../../../model/mod_matrix.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/controls.dart';
import '../kit/hero.dart';
import '../visuals/envelope_view.dart';
import '../visuals/filter_curve.dart';
import '../visuals/wavetable_view.dart';
import '../effects/effect_page.dart' show InlineSplit;
import '../visuals/mod_routing.dart';
import '../visuals/mod_sheet.dart';
import 'flagship_mod_fx.dart' show SourceBody;
import 'flagship_editor.dart' show DevicePicker;

/// What the FX tab shows of the flagship: the mod source strip (tap a chip, then tap knobs; or drag it onto a knob;
/// long-press a knob for its Modulation sheet), then one section at a time, picked by chips (OSC 1–3, FILTER, AMP,
/// MOD), so a phone keeps one big hero and a single row of big knobs instead of every page squeezed small. MOD shows
/// one source's shape and knobs and the routes it makes. The unison fan, tuning, filter routing, the full matrix
/// and the FX rack stay in the full-screen editor (⤢).
class FlagshipInline extends StatefulWidget {
  const FlagshipInline({super.key});

  @override
  State<FlagshipInline> createState() => _FlagshipInlineState();
}

class _FlagshipInlineState extends State<FlagshipInline> {
  static const _labels = ['OSC 1', 'OSC 2', 'OSC 3', 'FILTER', 'AMP', 'MOD'];
  static const _sources = [ModSource.env2, ModSource.env3, ModSource.lfo1, ModSource.lfo2, ModSource.lfo3, ModSource.random];
  int _section = 0;
  int _filter = 1;
  ModSource _source = ModSource.lfo1;

  void _openSource(ModSource s) => setState(() {
    _section = 5;
    _source = s;
  });

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    bool on(String id) => t.value(id) >= 0.5;
    final Widget body;
    if (_section < 3) {
      final p = 'osc${_section + 1}_';
      body = InlineSplit(key: ValueKey('flagship-inline-osc${_section + 1}'), lead:
          _row([DevicePower('${p}on'), const SizedBox(width: 6), Flexible(child: DeviceChoice('${p}table', maxSegments: 0))]), children: [
          AnimatedOpacity(duration: Motion.fade(Motion.small, Motion.of(context)), opacity: on('${p}on') ? 1 : 0.5,
            child: WavetableView(prefix: p, height: inlineHeroHeight(context, 150) - 10)),
          KnobRow(['${p}frame', '${p}warp_amt', '${p}level', '${p}unison', '${p}detune'], size: 48,
            labels: {'${p}frame': 'Position', '${p}warp_amt': 'Warp', '${p}level': 'Level', '${p}unison': 'Voices',
              '${p}detune': 'Detune'}),
        ]);
    } else if (_section == 3) {
      final p = 'flt${_filter}_';
      body = InlineSplit(key: const ValueKey('flagship-inline-filter'), lead:
          _row([
            DevicePower('${p}on'),
            const SizedBox(width: 6),
            for (final f in [1, 2]) Padding(padding: const EdgeInsets.only(right: 4), child: _MiniChip(
              key: ValueKey('flagship-inline-flt$f'), label: 'F$f', selected: _filter == f, color: scope.accent,
              onTap: () => setState(() => _filter = f))),
            const SizedBox(width: 4),
            Flexible(child: DeviceChoice('${p}type', maxSegments: 0)),
          ]), children: [
          AnimatedOpacity(duration: Motion.fade(Motion.small, Motion.of(context)), opacity: on('${p}on') ? 1 : 0.5,
            child: FilterCurve(key: ValueKey('flagship-inline-curve$_filter'), prefix: p, height: inlineHeroHeight(context, 150) - 10)),
          KnobRow(['${p}cutoff', '${p}resonance', '${p}drive', '${p}mix'], size: 50,
            labels: {'${p}cutoff': 'Cutoff', '${p}resonance': 'Resonance', '${p}drive': 'Drive', '${p}mix': 'Mix'}),
        ]);
    } else if (_section == 5) {
      body = Column(key: const ValueKey('flagship-inline-mod'), crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min, children: [
          SizedBox(height: 34, child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final s in _sources) Padding(padding: const EdgeInsets.only(right: 4), child: _MiniChip(
              key: ValueKey('flagship-inline-src-${s.name}'), label: s.short, selected: _source == s,
              color: modSourceColor(s), width: 52, onTap: () => setState(() => _source = s))),
          ])),
          const SizedBox(height: 6),
          InlineSplit(children: [
            SourceBody(_source, key: ValueKey('flagship-inline-source-${_source.name}'), compact: true),
            ModRouteList(only: _source),
          ]),
        ]);
    } else {
      body = InlineSplit(key: const ValueKey('flagship-inline-amp'), children: [
          EnvelopeView(prefix: 'env1_', height: inlineHeroHeight(context, 150) - 10, color: modSourceColor(ModSource.env1)),
          KnobRow(const ['env1_attack', 'env1_decay', 'env1_sustain', 'env1_release', 'volume'], size: 48,
            labels: const {'env1_attack': 'Attack', 'env1_decay': 'Decay', 'env1_sustain': 'Sustain',
              'env1_release': 'Release', 'volume': 'Volume'}),
        ]);
    }
    return scope.copyWith(openSource: _openSource, child: Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 4), child: Column(
      key: const ValueKey('flagship-inline'), crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min,
      children: [
        if (scope.matrix != null) ...[
          const ModSourceStrip(),
          const ModAssignBanner(),
        ],
        DevicePicker(
          labels: _labels,
          on: [on('osc1_on'), on('osc2_on'), on('osc3_on'), on('flt1_on') || on('flt2_on'), true,
            (scope.matrix?.routes.isNotEmpty ?? false)],
          selected: _section,
          keyPrefix: 'flagship-inline-pick',
          onPick: (i) => setState(() => _section = i)),
        const SizedBox(height: 6),
        AnimatedSwitcher(duration: Motion.fade(Motion.standard, Motion.of(context)), child: body),
      ])));
  }

  Widget _row(List<Widget> children) => Padding(padding: const EdgeInsets.only(bottom: 6),
    child: SizedBox(height: 28, child: Row(children: children)));
}

/// A small selector chip (filter 1 or 2).
class _MiniChip extends StatelessWidget {
  const _MiniChip({super.key, required this.label, required this.selected, required this.color, required this.onTap,
    this.width = 40});
  final double width;
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(6),
    onTap: () {
      Motion.tick();
      onTap();
    },
    child: Container(
      height: 32, width: width,
      alignment: Alignment.center,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(6),
        color: selected ? color.withValues(alpha: 0.2) : Colors.transparent,
        border: Border.all(color: selected ? color : Neon.line)),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: selected ? Neon.text : Neon.dim)),
    ),
  );
}

/// The registry's inline builder for the flagship.
Widget flagshipInline(BuildContext context) => const FlagshipInline();
