// Editors for built-in effects (by id, or found by their parameters): EQ, dynamics, saturation, delay, reverb and the kit,
// drawn from their parameters with the engine's live display data (spectrum, gain reduction, levels) from DeviceDisplaySource.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../engine/component_info.dart';
import '../../../model/device_display.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_registry.dart';
import '../device_scope.dart';
import '../visuals/fx_visuals.dart';

// An EQ band's knobs: `bandN_` or the built-in EQ's `bN_` (org.caw.eq).
final _band = RegExp(r'^(band|b)(\d+)_(freq|gain|q|type|on|channel)$');

bool _has(NativeComponentInfo i, String id) => i.parameters.any((p) => p.id == id);

/// The editor for a built-in effect whose parameters look like an EQ (`bandN_freq` and `bandN_gain`), a compressor
/// (`threshold`, `ratio`), a delay (`feedback` with `time` or `sync`), a reverb (`decay` with `size`) or a
/// saturation (`drive` with `type` or `shape`); null for anything else (the fallback page).
DeviceEditorEntry? effectEditorFor(NativeComponentInfo info) {
  if (info.isInstrument) return null;
  if (_byId[info.id] case final e?) return e;
  if (info.parameters.any((p) => _band.hasMatch(p.id)) &&
      ((_has(info, 'band1_freq') && _has(info, 'band1_gain')) || (_has(info, 'b1_freq') && _has(info, 'b1_gain')))) {
    return DeviceEditorEntry((_) => [DeviceSection('eq', 'EQ', Icons.graphic_eq, (_) => const EqEditorPage())],
        accent: Neon.yellow);
  }
  if (_has(info, 'threshold') && _has(info, 'ratio')) {
    return DeviceEditorEntry((_) => [DeviceSection('comp', 'COMP', Icons.compress, (_) => const CompressorEditorPage())],
        accent: Neon.yellow);
  }
  if (_has(info, 'feedback') && (_has(info, 'time') || _has(info, 'sync'))) {
    return DeviceEditorEntry((_) => [DeviceSection('delay', 'DELAY', Icons.blur_linear, (_) => const DelayEditorPage())],
        accent: Neon.green);
  }
  if (_has(info, 'decay') && _has(info, 'size')) {
    return DeviceEditorEntry((_) => [DeviceSection('reverb', 'REVERB', Icons.blur_on, (_) => const ReverbEditorPage())],
        accent: Neon.violet);
  }
  if (_has(info, 'drive') && (_has(info, 'type') || _has(info, 'shape') || _has(info, 'mode'))) {
    return DeviceEditorEntry((_) => [DeviceSection('sat', 'DRIVE', Icons.whatshot_outlined, (_) => const SaturationEditorPage())],
        accent: Neon.pink);
  }
  return null;
}

DeviceEditorEntry _levels(String id, String label, IconData icon, Color accent) =>
    DeviceEditorEntry((_) => [DeviceSection(id, label, icon, (_) => const LevelsEditorPage())], accent: accent);

/// The built-in effects without a shape the matchers know (#173): a live view of their levels and display values.
final Map<String, DeviceEditorEntry> _byId = {
  'org.caw.limiter': DeviceEditorEntry((_) => [DeviceSection('limit', 'LIMIT', Icons.vertical_align_top, (_) => const LimiterEditorPage())],
      accent: Neon.yellow),
  'org.caw.gate': _levels('gate', 'GATE', Icons.door_sliding_outlined, Neon.yellow),
  'org.caw.transient': _levels('transient', 'SHAPE', Icons.show_chart, Neon.yellow),
  'org.caw.filter': _levels('filter', 'FILTER', Icons.filter_alt_outlined, Neon.green),
  'org.caw.phaser': _levels('phaser', 'PHASER', Icons.waves, Neon.violet),
  'org.caw.flanger': _levels('flanger', 'FLANGER', Icons.waves, Neon.violet),
  'org.caw.utility': _levels('utility', 'UTILITY', Icons.tune, Neon.green),
};

/// Every parameter not in [skip] as knobs and choices: what an effect page shows under its visual.
class ParamGrid extends StatelessWidget {
  const ParamGrid({super.key, this.skip = const {}, this.only});
  final Set<String> skip;
  final List<String>? only;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final params = [
      for (final p in t.info?.parameters ?? const <ComponentParameterInfo>[])
        if (!skip.contains(p.id) && (only == null || only!.contains(p.id))) p,
    ];
    return Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final p in params)
        if (p.isChoice)
          p.choices.length == 2 && p.choices.first == 'Off'
              ? Row(mainAxisSize: MainAxisSize.min, children: [DevicePower(p.id), Text(p.label, style: const TextStyle(fontSize: 10))])
              : DeviceChoice(p.id, label: p.label, maxSegments: 4)
        else
          DeviceKnob(p.id),
    ]);
  }
}

/// Listens to the device's display frames (none until the engine offers them).
class _Display extends StatelessWidget {
  const _Display({required this.builder});
  final Widget Function(BuildContext context, DeviceDisplayFrame? frame) builder;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    return ValueListenableBuilder<DeviceDisplayFrame?>(
      valueListenable: DeviceDisplaySource.current.frames(t),
      builder: (context, f, _) => builder(context, f));
  }
}

Widget _page(List<Widget> children) => ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 24), children: children);

/// Input, output and gain reduction meters from the display data, and its other values as numbers.
class LevelMeters extends StatelessWidget {
  const LevelMeters({super.key, this.showValues = true});
  final bool showValues;

  @override
  Widget build(BuildContext context) {
    final accent = DeviceScope.of(context).accent;
    return _Display(builder: (context, f) {
      if (f == null) return const Text('No live data (the track is not playing this device)', style: TextStyle(fontSize: 10));
      Widget bar(String label, double? db, {bool reduction = false}) {
        final v = db == null ? 0.0 : (reduction ? (-db / 24) : ((db + 60) / 60)).clamp(0.0, 1.0).toDouble();
        return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(children: [
          SizedBox(width: 34, child: Text(label, style: const TextStyle(fontSize: 10))),
          Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(2), child: LinearProgressIndicator(
            value: v, minHeight: 6, color: reduction ? Neon.pink : accent, backgroundColor: accent.withValues(alpha: 0.12)))),
          SizedBox(width: 52, child: Text(db == null ? '' : '${db.toStringAsFixed(1)} dB', textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 10))),
        ]));
      }
      final values = showValues ? f.values.entries.where((e) => !e.key.startsWith('curve')).toList() : const [];
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        bar('IN', f.inputDb),
        bar('OUT', f.outputDb),
        if (f.gainReductionDb != null) bar('GR', f.gainReductionDb, reduction: true),
        if (values.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4), child: Wrap(spacing: 10, runSpacing: 2, children: [
            for (final e in values) Text('${e.key.replaceAll('_', ' ')} ${e.value.toStringAsFixed(e.value.abs() >= 100 ? 0 : 2)}',
              style: const TextStyle(fontSize: 10)),
          ])),
      ]);
    });
  }
}

/// A device shown by its live levels and values, and its knobs (gate, transient shaper, filter, phaser, flanger,
/// utility).
class LevelsEditorPage extends StatelessWidget {
  const LevelsEditorPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return _page([
      DeviceCard(title: 'LIVE', color: scope.accent, child: const LevelMeters()),
      const ParamGrid(),
    ]);
  }
}

/// The limiter: its curve (the input gain up to the ceiling, flat above) and its gain-reduction meter.
class LimiterEditorPage extends StatelessWidget {
  const LimiterEditorPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final gain = t.value('gain'), ceiling = t.value('ceiling');
    return _page([
      DeviceCard(title: 'CEILING', color: scope.accent, child: _Display(builder: (context, f) => CompressorGraph(
        threshold: ceiling - gain, ratio: 50, knee: 0, makeup: gain, color: scope.accent, height: 140,
        gainReductionDb: f?.gainReductionDb, inputDb: f?.inputDb))),
      DeviceCard(title: 'LIVE', color: scope.accent, child: const LevelMeters(showValues: false)),
      const ParamGrid(),
    ]);
  }
}

/// An EQ: one curve with a node per `bandN_`, its type read from `bandN_type`'s choice label (shelf, cut, peak).
class EqEditorPage extends StatelessWidget {
  const EqEditorPage({super.key});

  static EqKind kindOf(String label) {
    final l = label.toLowerCase();
    if (l.contains('low') && l.contains('shelf')) return EqKind.lowShelf;
    if (l.contains('high') && l.contains('shelf')) return EqKind.highShelf;
    if (l.contains('low cut') || l.contains('high pass') || l.contains('highpass') || l == 'hp') return EqKind.lowCut;
    if (l.contains('high cut') || l.contains('low pass') || l.contains('lowpass') || l == 'lp') return EqKind.highCut;
    return EqKind.peak;
  }

  static EqKind _kind(ComponentParameterInfo? p, double v) =>
      p != null && p.isChoice ? kindOf(formatParamValue(p, v)) : EqKind.peak;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    var prefix = 'band';
    final numbers = <int>{
      for (final p in t.info?.parameters ?? const <ComponentParameterInfo>[])
        if (_band.firstMatch(p.id) case final m?) int.parse(m.group(2)!),
    }.toList()
      ..sort();
    if (t.param('band1_freq') == null && t.param('b1_freq') != null) prefix = 'b';
    String? id(int n, String k) => t.param('$prefix${n}_$k') == null ? null : '$prefix${n}_$k';
    final bands = [
      for (final n in numbers)
        EqBand(
          kind: _kind(t.param('$prefix${n}_type'), t.value('$prefix${n}_type')),
          freqParam: id(n, 'freq'),
          gainParam: id(n, 'gain'),
          qParam: id(n, 'q'),
          onParam: id(n, 'on'),
          label: '$n'),
    ];
    final range = t.param('${prefix}1_gain')?.max ?? 18;
    return _page([
      DeviceCard(title: 'BANDS', color: scope.accent, child: _Display(builder: (context, f) => EqCurve(
        bands: bands, height: 160, rangeDb: range, spectrum: f?.spectrum))),
      DeviceCard(title: 'LIVE', color: scope.accent, child: const LevelMeters(showValues: false)),
      for (final n in numbers)
        DeviceCard(title: 'BAND $n', color: scope.accent, child: ParamGrid(only: [
          for (final k in ['on', 'type', 'freq', 'gain', 'q', 'channel']) '$prefix${n}_$k',
        ])),
      ParamGrid(skip: {for (final p in t.info?.parameters ?? const <ComponentParameterInfo>[]) if (_band.hasMatch(p.id)) p.id}),
    ]);
  }
}

/// A compressor: its transfer graph from `threshold`, `ratio`, `knee` and `makeup`, with the gain-reduction meter
/// from the display data.
class CompressorEditorPage extends StatelessWidget {
  const CompressorEditorPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return _page([
      DeviceCard(title: 'TRANSFER', color: scope.accent, child: _Display(builder: (context, f) => CompressorGraph(
        threshold: t.value('threshold'), ratio: t.value('ratio'), knee: t.param('knee') == null ? 0 : t.value('knee'),
        makeup: t.param('makeup') == null ? 0 : t.value('makeup'), color: scope.accent, height: 160,
        gainReductionDb: f?.gainReductionDb, inputDb: f?.inputDb))),
      DeviceCard(title: 'LIVE', color: scope.accent, child: const LevelMeters(showValues: false)),
      const ParamGrid(),
    ]);
  }
}

/// A delay: its echoes from `time` (s or ms) or `sync`, `feedback` and `mix`.
class DelayEditorPage extends StatelessWidget {
  const DelayEditorPage({super.key});

  static const _syncWholes = {'1/32': 1 / 32, '1/16': 1 / 16, '1/8': 1 / 8, '1/8 dotted': 3 / 16, '1/4': 1 / 4,
    '1/4 dotted': 3 / 8, '1/2': 1 / 2, '1 bar': 1.0, '2 bars': 2.0,
    // org.caw.delay.pro's triplets (T, x 2/3) and dotted (D, x 1.5)
    '1/16 T': 1 / 24, '1/16 D': 3 / 32, '1/8 T': 1 / 12, '1/8 D': 3 / 16, '1/4 T': 1 / 6, '1/4 D': 3 / 8, '1/2 T': 1 / 3,
    '1/2 D': 3 / 4};

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final time = t.param('time');
    var seconds = time == null ? 0.3 : t.value('time') / (time.unit == 'ms' ? 1000 : 1);
    if (t.param('sync') case final p? when p.isChoice) {
      final wholes = _syncWholes[formatParamValue(p, t.value(p.id))];
      if (wholes != null) seconds = wholes * 4 * 60 / t.state.project.bpm;
    }
    return _page([
      DeviceCard(title: 'ECHOES', color: scope.accent, child: _Display(builder: (context, f) => DelayEchoes(
        seconds: f?.values['time_l_s'] ?? seconds, feedback: t.value('feedback'),
        mix: t.param('mix') == null ? 0.5 : t.value('mix'), color: scope.accent, height: 90))),
      DeviceCard(title: 'LIVE', color: scope.accent, child: const LevelMeters()),
      const ParamGrid(),
    ]);
  }
}

/// A reverb: its tail from `decay`, `size`, `damping` and `mix`.
class ReverbEditorPage extends StatelessWidget {
  const ReverbEditorPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return _page([
      DeviceCard(title: 'TAIL', color: scope.accent, child: ReverbTail(decaySeconds: t.value('decay'),
        size: t.value('size'), damping: t.param('damping') == null ? 0.4 : t.value('damping'),
        mix: t.param('mix') == null ? 0.3 : t.value('mix'), color: scope.accent, height: 90)),
      DeviceCard(title: 'LIVE', color: scope.accent, child: const LevelMeters()),
      const ParamGrid(),
    ]);
  }
}

/// A saturation: its transfer curve from `type`/`shape` (Drive, Hard clip, Fold, Crush), `drive` and `mix`.
class SaturationEditorPage extends StatelessWidget {
  const SaturationEditorPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final typeId = t.param('type') != null ? 'type' : (t.param('shape') != null ? 'shape' : 'mode');
    final label = formatParamValue(t.param(typeId), t.value(typeId)).toLowerCase();
    final type = label.contains('clip') ? 1 : (label.contains('fold') ? 2 : (label.contains('crush') ? 3 : 0));
    // org.caw.saturator's drive is in dB (0..36); the curve wants a gain.
    final drive = t.param('drive')?.unit == 'dB' ? math.pow(10, t.value('drive') / 20).toDouble() : t.value('drive');
    return _page([
      DeviceCard(title: 'CURVE', color: scope.accent, child: SaturationCurve(type: type, drive: drive,
        mix: t.param('mix') == null ? 1 : t.value('mix'), color: scope.accent, height: 130)),
      DeviceCard(title: 'LIVE', color: scope.accent, child: const LevelMeters(showValues: false)),
      const ParamGrid(),
    ]);
  }
}
