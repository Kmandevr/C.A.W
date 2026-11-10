// Editors for built-in effects (by id, or found by their parameters): EQ, dynamics, saturation, delay, reverb and the kit,
// drawn from their parameters with the engine's live display data (spectrum, gain reduction, levels) from DeviceDisplaySource.
import 'package:flutter/material.dart';

import '../../../engine/component_info.dart';
import '../../../model/device_display.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_registry.dart';
import '../device_scope.dart';
import '../kit/device_style.dart';
import 'dynamics_editors.dart';
import 'drive_editors.dart';
import 'effect_page.dart';
import 'filter_editor.dart';
import 'space_editors.dart';
import 'eq_editor.dart';

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
    return singlePage('eq', 'EQ', Icons.graphic_eq, DeviceFamily.eq, () => const EqEditorPage());
  }
  if (_has(info, 'threshold') && _has(info, 'ratio')) {
    return singlePage('comp', 'COMP', Icons.compress, DeviceFamily.dynamics, () => const CompressorPage());
  }
  if (_has(info, 'feedback') && (_has(info, 'time') || _has(info, 'sync'))) {
    return singlePage('delay', 'DELAY', Icons.blur_linear, DeviceFamily.space, () => const DelayPage());
  }
  if (_has(info, 'decay') && _has(info, 'size')) {
    return singlePage('reverb', 'REVERB', Icons.blur_on, DeviceFamily.space, () => const ReverbPage());
  }
  if (_has(info, 'drive') && (_has(info, 'type') || _has(info, 'shape') || _has(info, 'mode'))) {
    return singlePage('drive', 'DRIVE', Icons.whatshot_outlined, DeviceFamily.drive, () => const DrivePage());
  }
  return null;
}

DeviceEditorEntry _levels(String id, String label, IconData icon, Color accent) =>
    DeviceEditorEntry((_) => [DeviceSection(id, label, icon, (_) => const LevelsEditorPage())], accent: accent);

/// The built-in effects without a shape the matchers know (#173): a live view of their levels and display values.
final Map<String, DeviceEditorEntry> _byId = {
  'org.caw.eq': singlePage('eq', 'EQ', Icons.graphic_eq, DeviceFamily.eq, () => const EqEditorPage()),
  'org.caw.compressor': singlePage('comp', 'COMP', Icons.compress, DeviceFamily.dynamics, () => const CompressorPage()),
  'org.caw.reverb.pro': singlePage('reverb', 'REVERB', Icons.blur_on, DeviceFamily.space, () => const ReverbPage()),
  'org.caw.delay.pro': singlePage('delay', 'DELAY', Icons.blur_linear, DeviceFamily.space, () => const DelayPage()),
  'org.caw.delay.pingpong': singlePage('delay', 'DELAY', Icons.blur_linear, DeviceFamily.space, () => const DelayPage()),
  'org.caw.saturator': singlePage('drive', 'DRIVE', Icons.whatshot_outlined, DeviceFamily.drive, () => const DrivePage()),
  'org.caw.distortion': singlePage('drive', 'DRIVE', Icons.whatshot_outlined, DeviceFamily.drive, () => const DrivePage()),
  'org.caw.limiter': singlePage('limit', 'LIMIT', Icons.vertical_align_top, DeviceFamily.dynamics, () => const LimiterPage()),
  'org.caw.gate': singlePage('gate', 'GATE', Icons.door_sliding_outlined, DeviceFamily.dynamics, () => const GatePage()),
  'org.caw.transient': singlePage('transient', 'SHAPE', Icons.show_chart, DeviceFamily.dynamics, () => const TransientPage()),
  'org.caw.filter': singlePage('filter', 'FILTER', Icons.filter_alt_outlined, DeviceFamily.filter, () => const FilterPage()),
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





