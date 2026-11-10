// The flagship synth's MOD page (envelopes, LFOs and random as visual, draggable sources, and the route list) and FX page.
import 'package:flutter/material.dart';

import '../../../model/mod_matrix.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../visuals/envelope_view.dart';
import '../visuals/fx_visuals.dart';
import '../visuals/lfo_view.dart';
import '../visuals/mod_routing.dart';
import 'flagship_editor.dart';

/// What each note-driven source means, for its card.
const Map<ModSource, String> _noteSourceNotes = {
  ModSource.velocity: 'How hard each note is played.',
  ModSource.note: 'The note\'s pitch: higher notes, more.',
  ModSource.bend: 'The note\'s own pitch bend, over the bend range.',
  ModSource.pressure: 'Pressure (aftertouch) on each note.',
  ModSource.timbre: 'Each note\'s timbre (MPE slide).',
  ModSource.modWheel: 'The mod wheel (controller 1) of a connected keyboard.',
};

/// The sources: on a phone the one a chip picked (the strip above), side by side when wide; then the routes.
class FlagshipModPage extends StatelessWidget {
  const FlagshipModPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return ValueListenableBuilder<ModSource>(
      valueListenable: scope.focusSource,
      builder: (context, focus, _) => LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= flagshipWide;
        return ListView(key: const ValueKey('flagship-mod'), padding: const EdgeInsets.fromLTRB(8, 8, 8, 24), children: [
          if (wide) ...[
            DeviceColumns(minWidth: 280, children: [for (final s in [ModSource.env1, ModSource.env2, ModSource.env3]) SourceCard(s)]),
            DeviceColumns(minWidth: 220, children: [
              for (final s in [ModSource.lfo1, ModSource.lfo2, ModSource.lfo3, ModSource.random]) SourceCard(s),
            ]),
          ] else
            AnimatedSwitcher(duration: Motion.fade(Motion.standard, Motion.of(context)),
              child: SourceCard(focus, key: ValueKey('source-${focus.name}'))),
          DeviceCard(title: 'MATRIX', color: Neon.violet, child: ModRouteList(newSource: focus)),
        ]);
      }),
    );
  }
}

/// One mod source: its chip (drag it onto a knob), its shape, its knobs.
class SourceCard extends StatelessWidget {
  const SourceCard(this.source, {super.key});
  final ModSource source;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final c = modSourceColor(source);
    final bpm = scope.target.state.project.bpm;
    final count = scope.matrix?.routes.where((r) => r.source == source).length ?? 0;
    final chip = ModSourceChip(source, selected: true, count: count);
    final Widget body;
    switch (source) {
      case ModSource.env1 || ModSource.env2 || ModSource.env3:
        final p = 'env${source.index - ModSource.env1.index + 1}_';
        body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EnvelopeView(prefix: p, color: c),
          knobRow([
            DeviceKnob('${p}attack', color: c), DeviceKnob('${p}decay', color: c), DeviceKnob('${p}sustain', color: c),
            DeviceKnob('${p}release', color: c),
          ]),
          if (source == ModSource.env1) const Padding(padding: EdgeInsets.only(top: 2), child: Text(
            'Env 1 shapes each note\'s level.', style: TextStyle(fontSize: 9, color: Neon.dim))),
        ]);
      case ModSource.lfo1 || ModSource.lfo2 || ModSource.lfo3:
        final p = 'lfo${source.index - ModSource.lfo1.index + 1}_';
        final synced = scope.target.value('${p}sync') >= 1;
        body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LfoView(rateParam: '${p}rate', shapeParam: '${p}shape', syncParam: '${p}sync', bpm: bpm, color: c),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DeviceChoice('${p}shape', maxSegments: 0, color: c),
            DeviceChoice('${p}sync', maxSegments: 0, color: c),
            DeviceChoice('${p}mode', color: c),
          ]),
          knobRow([if (!synced) DeviceKnob('${p}rate', color: c)]),
        ]);
      case ModSource.random:
        body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LfoView(rateParam: 'rnd_rate', randomModeParam: 'rnd_mode', bpm: bpm, color: c),
          const SizedBox(height: 4),
          Row(children: [DeviceChoice('rnd_mode', color: c)]),
          knobRow([DeviceKnob('rnd_rate', color: c)]),
        ]);
      default:
        body = Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(
          _noteSourceNotes[source] ?? '', style: const TextStyle(fontSize: 11, color: Neon.dim)));
    }
    return DeviceCard(title: source.label.toUpperCase(), color: c, actions: [chip], child: body);
  }
}

/// The effects rack, in the engine's order: distortion, EQ, chorus, delay, reverb.
class FlagshipFxPage extends StatelessWidget {
  const FlagshipFxPage({super.key});

  static const _delayWholes = [0.0, 0.0625, 0.125, 0.1875, 0.25, 0.375, 0.5, 1.0];

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    double v(String id) => t.value(id);
    bool on(String id) => v(id) >= 0.5;
    final bpm = t.state.project.bpm;
    final sync = v('fx_delay_sync').round().clamp(0, _delayWholes.length - 1);
    final delaySeconds = sync == 0 ? v('fx_delay_time') : _delayWholes[sync] * 4 * 60 / bpm;
    return ListView(key: const ValueKey('flagship-fx'), padding: const EdgeInsets.fromLTRB(8, 8, 8, 24), children: [
      DeviceColumns(minWidth: 330, children: [
        DeviceCard(title: 'DISTORTION', color: Neon.pink, dimmed: !on('fx_dist_on'),
          leading: const DevicePower('fx_dist_on', color: Neon.pink),
          actions: const [DeviceChoice('fx_dist_type', color: Neon.pink)],
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SaturationCurve(type: v('fx_dist_type').round(), drive: v('fx_dist_drive'), mix: v('fx_dist_mix')),
            knobRow(const [DeviceKnob('fx_dist_drive', label: 'Drive', color: Neon.pink),
              DeviceKnob('fx_dist_mix', label: 'Mix', color: Neon.pink)]),
          ])),
        DeviceCard(title: 'EQ', color: Neon.yellow, dimmed: !on('fx_eq_on'),
          leading: const DevicePower('fx_eq_on', color: Neon.yellow),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const EqCurve(color: Neon.yellow, height: 96, bands: [
              EqBand(kind: EqKind.lowShelf, fixedFreq: 250, gainParam: 'fx_eq_low', label: 'LOW'),
              EqBand(kind: EqKind.peak, freqParam: 'fx_eq_mid_freq', gainParam: 'fx_eq_mid', label: 'MID'),
              EqBand(kind: EqKind.highShelf, fixedFreq: 4000, gainParam: 'fx_eq_high', label: 'HIGH'),
            ]),
            knobRow(const [
              DeviceKnob('fx_eq_low', label: 'Low', color: Neon.yellow), DeviceKnob('fx_eq_mid', label: 'Mid', color: Neon.yellow),
              DeviceKnob('fx_eq_mid_freq', label: 'Freq', color: Neon.yellow),
              DeviceKnob('fx_eq_high', label: 'High', color: Neon.yellow), DeviceKnob('fx_eq_mix', label: 'Mix', color: Neon.yellow),
            ]),
          ])),
        DeviceCard(title: 'CHORUS', color: Neon.blue, dimmed: !on('fx_chorus_on'),
          leading: const DevicePower('fx_chorus_on', color: Neon.blue),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            LfoView(rateParam: 'fx_chorus_rate', height: 48, bpm: bpm, color: Neon.blue),
            knobRow(const [DeviceKnob('fx_chorus_rate', label: 'Rate', color: Neon.blue),
              DeviceKnob('fx_chorus_depth', label: 'Depth', color: Neon.blue),
              DeviceKnob('fx_chorus_mix', label: 'Mix', color: Neon.blue)]),
          ])),
        DeviceCard(title: 'DELAY', color: Neon.green, dimmed: !on('fx_delay_on'),
          leading: const DevicePower('fx_delay_on', color: Neon.green),
          actions: const [DeviceChoice('fx_delay_sync', maxSegments: 0, color: Neon.green)],
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DelayEchoes(seconds: delaySeconds, feedback: v('fx_delay_feedback'), mix: v('fx_delay_mix'), color: Neon.green),
            knobRow([
              if (sync == 0) const DeviceKnob('fx_delay_time', label: 'Time', color: Neon.green),
              const DeviceKnob('fx_delay_feedback', label: 'Feedback', color: Neon.green),
              const DeviceKnob('fx_delay_mix', label: 'Mix', color: Neon.green),
            ]),
          ])),
        DeviceCard(title: 'REVERB', color: Neon.violet, dimmed: !on('fx_reverb_on'),
          leading: const DevicePower('fx_reverb_on', color: Neon.violet),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ReverbTail(decaySeconds: v('fx_reverb_decay'), size: v('fx_reverb_size'), damping: v('fx_reverb_damping'),
              mix: v('fx_reverb_mix')),
            knobRow(const [DeviceKnob('fx_reverb_size', label: 'Size', color: Neon.violet),
              DeviceKnob('fx_reverb_decay', label: 'Decay', color: Neon.violet),
              DeviceKnob('fx_reverb_damping', label: 'Damping', color: Neon.violet),
              DeviceKnob('fx_reverb_mix', label: 'Mix', color: Neon.violet)]),
            if (!on('fx_reverb_on')) const Text('Off by default: a reverb on every track costs about two voices.',
              style: TextStyle(fontSize: 9, color: Neon.dim)),
          ])),
      ]),
    ]);
  }
}
