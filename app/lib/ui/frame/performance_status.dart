// The quiet performance status (1.1.2): the CPU readout opens a Performance sheet (a plain heat reading, tracks muted for headroom, smart freeze's one-time suggestion, tips), and a small dot beside it marks something new there; nothing pops up over the work.
import 'package:flutter/material.dart';

import '../../engine/execution.dart';
import '../../model/app_state.dart';
import '../../model/freeze.dart';
import '../../model/freeze_hint.dart';
import '../../model/routing_edit.dart';
import '../arrange/freeze_ui.dart';
import '../glass.dart';
import '../motion.dart';
import '../theme.dart';
import '../widgets.dart' show Heading;

/// What the Performance sheet has to say now, most urgent first, each as (its key, its colour).
List<(String, Color)> performanceIssues(AppState s) => [
      if (s.meters.overloaded > 0) ('muted', Neon.pink),
      if (s.freezeHint.suggestion.value case final f?) ('freeze:${f.layerId}', Neon.blue),
    ];

// The issues the sheet has shown, per app state: the dot stays off for them until they clear and come back.
final _seen = Expando<Set<String>>('performance-seen');
Set<String> _seenOf(AppState s) => _seen[s] ??= <String>{};

/// [child] (the CPU readout) made the way into the Performance sheet: a tap opens it, and a small dot just
/// after it shows, in the colour of the most urgent, that the sheet has something not seen yet.
class PerformanceStatus extends StatefulWidget {
  const PerformanceStatus({super.key, required this.state, required this.child});
  final AppState state;
  final Widget child;

  @override
  State<PerformanceStatus> createState() => _PerformanceStatusState();
}

class _PerformanceStatusState extends State<PerformanceStatus> {
  Future<void> _open() async {
    final s = widget.state;
    _seenOf(s).addAll(performanceIssues(s).map((i) => i.$1));
    setState(() {});
    await showPerformanceSheet(context, s);
    if (!mounted) return;
    _seenOf(s).addAll(performanceIssues(s).map((i) => i.$1));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final motion = Motion.of(context);
    return Tooltip(
      message: 'Performance',
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        key: const ValueKey('performance-status'),
        borderRadius: BorderRadius.circular(6),
        onTap: _open,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          // The dot after the readout, which is right-aligned in its box: it sits beside the text.
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            widget.child,
            const SizedBox(width: 4),
            ListenableBuilder(
              listenable: Listenable.merge([s.tick, s.pressure, s.freezeHint.suggestion]),
              builder: (context, _) {
                final issues = performanceIssues(s);
                final seen = _seenOf(s)..retainAll(issues.map((i) => i.$1));
                final fresh = issues.where((i) => !seen.contains(i.$1)).firstOrNull;
                return AnimatedContainer(
                  key: ValueKey(fresh == null ? 'performance-dot-off' : 'performance-dot'),
                  duration: Motion.fade(Motion.standard, motion),
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(shape: BoxShape.circle,
                      color: fresh == null ? Neon.dim.withValues(alpha: 0) : fresh.$2),
                );
              },
            ),
          ]),
        ),
      ),
    );
  }
}

/// The Performance sheet: the CPU, the heat level, tracks muted for headroom (with Unmute), smart freeze's
/// suggestion (with Freeze) and tips. It follows the state while open and changes no setting by itself.
Future<void> showPerformanceSheet(BuildContext context, AppState s) => showGlassSheet<void>(
      context: context,
      backgroundColor: Neon.panel,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(sheet).size.height * 0.75),
          child: ListenableBuilder(
            listenable: Listenable.merge([s.tick, s.pressure, s.freezeHint.suggestion]),
            builder: (sheet, _) => _PerformanceList(state: s, host: context, sheet: sheet),
          ),
        ),
      ),
    );

class _PerformanceList extends StatelessWidget {
  const _PerformanceList({required this.state, required this.host, required this.sheet});
  final AppState state;

  /// Where the sheet was opened from (the freeze's progress dialog opens there once the sheet has closed).
  final BuildContext host;
  final BuildContext sheet;

  static String _heatLevel(EnginePressure p) => switch (p) {
        EnginePressure.normal || EnginePressure.batterySaver => 'Normal',
        EnginePressure.thermalWarm => 'Warm',
        EnginePressure.thermalHot => 'Hot',
        EnginePressure.thermalCritical => 'Very hot',
        EnginePressure.unknown => 'Not reported',
      };

  @override
  Widget build(BuildContext context) {
    final s = state;
    final m = s.meters;
    final p = s.pressure.value;
    final f = s.freezeHint.suggestion.value;
    final cpu = (m.cpu * 100).clamp(0, 999).toStringAsFixed(0);
    final muted = m.overloaded;
    return ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
      const Heading('Performance'),
      ListTile(
        key: const ValueKey('performance-cpu'),
        leading: Icon(Icons.speed, color: m.cpu > 0.85 ? Neon.pink : Neon.dim),
        title: const Text('CPU'),
        subtitle: const Text('Of the time each audio block has', style: TextStyle(color: Neon.dim)),
        trailing: Text('$cpu%', style: Neon.code(size: 13, color: m.cpu > 0.85 ? Neon.pink : Neon.text)),
      ),
      ListTile(
        key: const ValueKey('heat-banner'),
        // A plain reading (owner, 2026-11-24: heat is the system's job, and a hot phone need not stutter).
        leading: const Icon(Icons.device_thermostat, color: Neon.dim),
        title: Text('Heat: ${_heatLevel(p)}'),
      ),
      ListTile(
        key: const ValueKey('performance-overload'),
        leading: Icon(Icons.volume_off, color: muted > 0 ? Neon.pink : Neon.dim),
        title: Text(muted > 0 ? 'Out of headroom' : 'No tracks muted for headroom'),
        subtitle: muted > 0
            ? Text('The newest track${muted > 1 ? 's were' : ' was'} muted to keep audio clean.'
                '${s.lightTurnedOnBySelf ? ' The Lightweight profile is now on (Settings › App).' : ''}',
                style: const TextStyle(color: Neon.pink))
            : null,
        trailing: muted > 0
            ? TextButton(key: const ValueKey('performance-unmute'), onPressed: s.clearOverload, child: const Text('Unmute'))
            : null,
      ),
      if (f != null) _freeze(f),
      const Heading('Tips'),
      for (final tip in const [
        'Freeze heavy tracks to play them from audio.',
        'A larger buffer (Settings › Sound › Quality and buffer) gives each block more time.',
        'The Lightweight profile (Settings › App) asks less of the phone.',
      ])
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
          child: Text(tip, style: const TextStyle(fontSize: 12, color: Neon.dim)),
        ),
    ]);
  }

  Widget _freeze(FreezeSuggestion f) {
    final s = state;
    final share = f.share;
    final cost = share == null ? '' : ' (${(share * 100).toStringAsFixed(share < 0.1 ? 1 : 0)}% of a core)';
    return ListTile(
      key: const ValueKey('freeze-suggestion'),
      leading: const Icon(Icons.ac_unit, color: Neon.blue),
      title: Text('Near the phone\'s limit. ${f.name} is the heaviest track$cost: freeze it to free the CPU?'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        TextButton(key: const ValueKey('freeze-suggestion-freeze'), onPressed: () async {
          s.freezeHint.dismiss();
          Navigator.of(sheet).pop();
          final layer = s.layerById(f.layerId);
          if (layer == null || layer.frozen || !s.canRenderTrack(layer) || !host.mounted) return;
          await runTrackRender(host, 'Freeze ${layer.name}', () => s.freezeTrack(layer));
        }, child: const Text('Freeze')),
        IconButton(key: const ValueKey('freeze-suggestion-close'), tooltip: 'Not now', iconSize: 18,
            visualDensity: VisualDensity.compact, color: Neon.dim, onPressed: s.freezeHint.dismiss,
            icon: const Icon(Icons.close)),
      ]),
    );
  }
}
