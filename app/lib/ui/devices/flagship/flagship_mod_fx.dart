// The flagship synth's modulators (envelopes, LFOs and random as visual sources you drag or tap onto knobs), its MATRIX page and its EFFECTS page.
import 'package:flutter/material.dart';

import '../../../model/mod_matrix.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/controls.dart';
import '../kit/device_style.dart';
import '../visuals/envelope_view.dart';
import '../visuals/fx_visuals.dart';
import '../kit/param_watch.dart';
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

/// The envelopes as one section: a picker (Env 1 shapes each note's level, so it says AMP), the chosen envelope's
/// shape with draggable handles, its knobs, and the knobs it moves. Opening the source from the strip picks it.
class EnvelopesCard extends StatelessWidget {
  const EnvelopesCard({super.key});

  @override
  Widget build(BuildContext context) => watchDevice(context, (_) => const _SourcesCard(
    storageId: 'flagship-envelopes', title: 'ENVELOPES',
    sources: [ModSource.env1, ModSource.env2, ModSource.env3],
    labels: ['ENV 1 · AMP', 'ENV 2', 'ENV 3']));
}

/// The LFOs and random as one section, as [EnvelopesCard].
class LfosCard extends StatelessWidget {
  const LfosCard({super.key});

  @override
  Widget build(BuildContext context) => watchDevice(context, (_) => const _SourcesCard(
    storageId: 'flagship-lfos', title: 'LFOs & RANDOM',
    sources: [ModSource.lfo1, ModSource.lfo2, ModSource.lfo3, ModSource.random],
    labels: ['LFO 1', 'LFO 2', 'LFO 3', 'RANDOM']));
}

class _SourcesCard extends StatefulWidget {
  const _SourcesCard({required this.storageId, required this.title, required this.sources, required this.labels});
  final String storageId, title;
  final List<ModSource> sources;
  final List<String> labels;

  @override
  State<_SourcesCard> createState() => _SourcesCardState();
}

class _SourcesCardState extends State<_SourcesCard> {
  int _i = 0;
  final _open = ValueNotifier<bool>(false);
  ValueNotifier<ModSource>? _focus;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final f = DeviceScope.of(context).focusSource;
    if (f != _focus) {
      _focus?.removeListener(_focused);
      _focus = f..addListener(_focused);
      final k = widget.sources.indexOf(f.value);
      if (k >= 0) _i = k;
    }
  }

  @override
  void dispose() {
    _focus?.removeListener(_focused);
    _open.dispose();
    super.dispose();
  }

  // A source opened from the strip (assign mode's Edit): pick it and open the section.
  void _focused() {
    final k = widget.sources.indexOf(_focus!.value);
    if (k < 0) return;
    setState(() => _i = k);
    _open.value = false;
    _open.value = true;
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final src = widget.sources[_i];
    final routes = scope.matrix?.routes ?? const <ModRoute>[];
    final moves = routes.where((r) => r.source == src).length;
    return DeviceExpandCard(
      key: ValueKey(widget.storageId),
      storageId: widget.storageId,
      title: widget.title,
      summary: '${widget.labels[_i]} moves $moves knob${moves == 1 ? '' : 's'}',
      color: modSourceColor(src),
      open: _open,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        DevicePicker(labels: widget.labels, selected: _i, keyPrefix: '${widget.storageId}-pick',
          colors: [for (final s in widget.sources) modSourceColor(s)],
          onPick: (k) => setState(() => _i = k)),
        const SizedBox(height: 6),
        AnimatedSwitcher(duration: Motion.fade(Motion.standard, Motion.of(context)),
          child: SourceBody(src, key: ValueKey('source-${src.name}'))),
        DeviceFold(title: 'WHAT ${src.short} MOVES ($moves)', child: ModRouteList(only: src)),
      ]),
    );
  }
}

/// The MATRIX page: every route as a card with a big amount slider, and what the note's own sources mean.
class FlagshipMatrixPage extends StatelessWidget {
  const FlagshipMatrixPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return ValueListenableBuilder<ModSource>(
      valueListenable: scope.focusSource,
      builder: (context, focus, _) => ListView(key: const ValueKey('flagship-matrix'),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 32), children: [
          DeviceCard(title: 'MODULATION', color: Neon.violet, child: ModRouteList(newSource: focus)),
          DeviceCard(title: 'NOTE SOURCES', color: Neon.yellow, child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              for (final e in _noteSourceNotes.entries) Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 82, child: Text(e.key.label, style: const TextStyle(fontSize: 11,
                    fontWeight: FontWeight.w800, color: Neon.yellow))),
                  Expanded(child: Text(e.value, style: const TextStyle(fontSize: 11, color: Neon.dim))),
                ])),
            ])),
        ]),
    );
  }
}

/// One mod source as a card: its chip (tap for assign mode, or drag it onto a knob), its shape, its knobs.
class SourceCard extends StatelessWidget {
  const SourceCard(this.source, {super.key});
  final ModSource source;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final count = scope.matrix?.routes.where((r) => r.source == source).length ?? 0;
    final chip = ModSourceChip(source, selected: true, count: count);
    return DeviceCard(title: source.label.toUpperCase(), color: modSourceColor(source), actions: [chip],
      child: SourceBody(source));
  }
}

/// A mod source's own controls: an envelope's shape (drag its handles) and times, an LFO's shape (drag sideways
/// for the rate), shape, sync and mode, random's rate; a note source says what it follows. Its chip sits on top.
class SourceBody extends StatelessWidget {
  const SourceBody(this.source, {super.key, this.compact = false});
  final ModSource source;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final c = modSourceColor(source);
    final bpm = scope.target.state.project.bpm;
    final count = scope.matrix?.routes.where((r) => r.source == source).length ?? 0;
    final chipRow = Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
      ModSourceChip(source, selected: true, count: count),
      const SizedBox(width: 8),
      const Expanded(child: Text('Tap, then tap knobs · or drag onto a knob', maxLines: 2,
        style: TextStyle(fontSize: 10, color: Neon.dim))),
    ]));
    final Widget body;
    switch (source) {
      case ModSource.env1 || ModSource.env2 || ModSource.env3:
        final p = 'env${source.index - ModSource.env1.index + 1}_';
        body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EnvelopeView(prefix: p, color: c, height: compact ? 84 : 110),
          plainKnobs(p, const ['attack', 'decay', 'sustain', 'release'], color: c),
          if (source == ModSource.env1) const Padding(padding: EdgeInsets.only(top: 2), child: Text(
            'Env 1 shapes each note\'s level.', style: TextStyle(fontSize: 9, color: Neon.dim))),
        ]);
      case ModSource.lfo1 || ModSource.lfo2 || ModSource.lfo3:
        final p = 'lfo${source.index - ModSource.lfo1.index + 1}_';
        final synced = scope.target.value('${p}sync') >= 1;
        body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LfoView(rateParam: '${p}rate', shapeParam: '${p}shape', syncParam: '${p}sync', bpm: bpm, color: c,
            height: compact ? 64 : 84),
          LabeledRow('SHAPE', DeviceChoice('${p}shape', maxSegments: 0, color: c)),
          LabeledRow('TEMPO SYNC', DeviceChoice('${p}sync', maxSegments: 0, color: c)),
          LabeledRow('RESTARTS', DeviceChoice('${p}mode', color: c)),
          if (!synced) KnobRow(['${p}rate'], size: 46, color: c, labels: {'${p}rate': 'Rate'}),
        ]);
      case ModSource.random:
        body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LfoView(rateParam: 'rnd_rate', randomModeParam: 'rnd_mode', bpm: bpm, color: c, height: compact ? 64 : 84),
          LabeledRow('STEPS', DeviceChoice('rnd_mode', color: c)),
          KnobRow(const ['rnd_rate'], size: 46, color: c, labels: const {'rnd_rate': 'Rate'}),
        ]);
      default:
        body = Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(
          _noteSourceNotes[source] ?? '', style: const TextStyle(fontSize: 11, color: Neon.dim)));
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [chipRow, body]);
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
    // Each effect in its family's colour, as the stand-alone devices.
    final drive = deviceStyle(DeviceFamily.drive).primary, eq = deviceStyle(DeviceFamily.eq).primary;
    final mod = deviceStyle(DeviceFamily.modulation).primary, space = deviceStyle(DeviceFamily.space);
    return ListView(key: ValueKey('flagship-fx'), padding: EdgeInsets.fromLTRB(8, 8, 8, 24), children: [
      DeviceColumns(minWidth: 330, children: [
        DeviceExpandCard(storageId: 'flagship-fx_dist_on', initiallyOpen: on('fx_dist_on'), summary: on('fx_dist_on') ? 'On' : 'Off', title: 'DISTORTION', color: drive, dimmed: !on('fx_dist_on'),
          leading: DevicePower('fx_dist_on', color: drive),
          actions: [DeviceChoice('fx_dist_type', color: drive)],
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SaturationCurve(type: v('fx_dist_type').round(), drive: v('fx_dist_drive'), mix: v('fx_dist_mix')),
            knobRow([DeviceKnob('fx_dist_drive', label: 'Drive', color: drive),
              DeviceKnob('fx_dist_mix', label: 'Mix', color: drive)]),
          ])),
        DeviceExpandCard(storageId: 'flagship-fx_eq_on', initiallyOpen: on('fx_eq_on'), summary: on('fx_eq_on') ? 'On' : 'Off', title: 'EQ', color: eq, dimmed: !on('fx_eq_on'),
          leading: DevicePower('fx_eq_on', color: eq),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            EqCurve(color: eq, height: 96, bands: [
              EqBand(kind: EqKind.lowShelf, fixedFreq: 250, gainParam: 'fx_eq_low', label: 'LOW'),
              EqBand(kind: EqKind.peak, freqParam: 'fx_eq_mid_freq', gainParam: 'fx_eq_mid', label: 'MID'),
              EqBand(kind: EqKind.highShelf, fixedFreq: 4000, gainParam: 'fx_eq_high', label: 'HIGH'),
            ]),
            knobRow([
              DeviceKnob('fx_eq_low', label: 'Low', color: eq), DeviceKnob('fx_eq_mid', label: 'Mid', color: eq),
              DeviceKnob('fx_eq_mid_freq', label: 'Freq', color: eq),
              DeviceKnob('fx_eq_high', label: 'High', color: eq), DeviceKnob('fx_eq_mix', label: 'Mix', color: eq),
            ]),
          ])),
        DeviceExpandCard(storageId: 'flagship-fx_chorus_on', initiallyOpen: on('fx_chorus_on'), summary: on('fx_chorus_on') ? 'On' : 'Off', title: 'CHORUS', color: mod, dimmed: !on('fx_chorus_on'),
          leading: DevicePower('fx_chorus_on', color: mod),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            LfoView(rateParam: 'fx_chorus_rate', height: 56, bpm: bpm, color: mod),
            knobRow([DeviceKnob('fx_chorus_rate', label: 'Rate', color: mod),
              DeviceKnob('fx_chorus_depth', label: 'Depth', color: mod),
              DeviceKnob('fx_chorus_mix', label: 'Mix', color: mod)]),
          ])),
        DeviceExpandCard(storageId: 'flagship-fx_delay_on', initiallyOpen: on('fx_delay_on'), summary: on('fx_delay_on') ? 'On' : 'Off', title: 'DELAY', color: space.secondary, dimmed: !on('fx_delay_on'),
          leading: DevicePower('fx_delay_on', color: space.secondary),
          actions: [DeviceChoice('fx_delay_sync', maxSegments: 0, color: space.secondary)],
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DelayEchoes(seconds: delaySeconds, feedback: v('fx_delay_feedback'), mix: v('fx_delay_mix'), color: space.secondary),
            knobRow([
              if (sync == 0) DeviceKnob('fx_delay_time', label: 'Time', color: space.secondary),
              DeviceKnob('fx_delay_feedback', label: 'Feedback', color: space.secondary),
              DeviceKnob('fx_delay_mix', label: 'Mix', color: space.secondary),
            ]),
          ])),
        DeviceExpandCard(storageId: 'flagship-fx_reverb_on', initiallyOpen: on('fx_reverb_on'), summary: on('fx_reverb_on') ? 'On' : 'Off', title: 'REVERB', color: space.primary, dimmed: !on('fx_reverb_on'),
          leading: DevicePower('fx_reverb_on', color: space.primary),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ReverbTail(decaySeconds: v('fx_reverb_decay'), size: v('fx_reverb_size'), damping: v('fx_reverb_damping'),
              mix: v('fx_reverb_mix')),
            knobRow([DeviceKnob('fx_reverb_size', label: 'Size', color: space.primary),
              DeviceKnob('fx_reverb_decay', label: 'Decay', color: space.primary),
              DeviceKnob('fx_reverb_damping', label: 'Damping', color: space.primary),
              DeviceKnob('fx_reverb_mix', label: 'Mix', color: space.primary)]),
            if (!on('fx_reverb_on')) Text('Off by default: a reverb on every track costs about two voices.',
              style: TextStyle(fontSize: 9, color: Neon.dim)),
          ])),
      ]),
    ]);
  }
}
