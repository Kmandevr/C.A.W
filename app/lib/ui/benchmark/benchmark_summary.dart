// The Benchmark's summary (owner's look 2026-11-13, "Summary, then drill down"): the verdict card, where the time goes by engine part, and the scenarios grouped by feature.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/stress_result.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';

Color benchTierColor(StressTier? t) => switch (t) {
      StressTier.comfortable => Neon.green,
      StressTier.tight => Neon.yellow,
      StressTier.over => Neon.pink,
      null => Neon.dim,
    };

/// The verdict: the device, the overall tier, the limits and the biggest cost, in plain words.
class BenchVerdictCard extends StatelessWidget {
  const BenchVerdictCard({super.key, required this.result});
  final StressResult result;

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    final t = result.overall;
    final color = benchTierColor(t);
    final name = '${result.device['name'] ?? ''}'.trim();
    final limits = result.limitsShort;
    final cost = result.biggestCost;
    return AnimatedContainer(
      key: const ValueKey('bench-verdict'),
      duration: Motion.fade(Motion.panel, level),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name.isEmpty ? 'This device' : name,
            key: const ValueKey('bench-device'), style: const TextStyle(color: Neon.dim, fontSize: 12), overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        AnimatedSwitcher(
          duration: Motion.fade(Motion.standard, level),
          child: Text(t?.label ?? 'No verdict yet',
              key: ValueKey('bench-overall-${t?.wire ?? 'none'}'),
              style: TextStyle(color: color, fontSize: 24, fontWeight: FontWeight.w700)),
        ),
        Text(result.verdictText, style: const TextStyle(fontSize: 13)),
        if (limits.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(limits, key: const ValueKey('bench-limits-short'), style: Neon.code(size: 14)),
        ],
        if (cost != null) ...[
          const SizedBox(height: 6),
          Text(cost, key: const ValueKey('bench-biggest'), style: const TextStyle(color: Neon.dim, fontSize: 13)),
        ],
      ]),
    );
  }
}

/// A labelled bar with its share: the name, a bar against the largest, the percentage.
class BenchBar extends StatelessWidget {
  const BenchBar({super.key, required this.label, required this.pct, required this.top, this.color = Neon.violet, this.onTap, this.sub});
  final String label;
  final String? sub;
  final double pct, top;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))),
          Text('${pct.toStringAsFixed(pct < 10 ? 1 : 0)}%', style: Neon.code(size: 12)),
          if (onTap != null) const Icon(Icons.chevron_right, size: 18, color: Neon.dim),
        ]),
        if (sub != null) Text(sub!, style: const TextStyle(color: Neon.dim, fontSize: 11), overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: top <= 0 ? 0 : pct / top),
          duration: Motion.move(Motion.panel, level),
          builder: (_, v, _) => LinearProgressIndicator(
              value: v.clamp(0.0, 1.0), minHeight: 6, color: color, backgroundColor: Neon.line,
              borderRadius: BorderRadius.circular(3)),
        ),
      ]),
    );
    if (onTap == null) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        Haptics.tap();
        onTap!();
      },
      child: row,
    );
  }
}

/// "Where the time goes": a bar per engine part, costliest first; tap one to drill down. From an engine without
/// parts (API 29), the components' costs instead, without the drill-down.
class BenchPartBars extends StatelessWidget {
  const BenchPartBars({super.key, required this.result, required this.onOpen});
  final StressResult result;
  final void Function(String partId) onOpen;

  @override
  Widget build(BuildContext context) {
    final parts = result.parts;
    final scenario = result.partsScenario ?? result.costsScenario;
    final children = <Widget>[];
    if (parts.isNotEmpty) {
      final top = math.max(1.0, parts.first.pct);
      for (final p in parts) {
        children.add(BenchBar(
            key: ValueKey('bench-part-${p.id}'),
            label: p.name,
            pct: p.pct,
            top: top,
            color: p.id == 'devices' ? Neon.violet : Neon.blue,
            onTap: () => onOpen(p.id)));
      }
    } else {
      final costs = result.holdingBack.take(8).toList();
      final top = costs.isEmpty ? 1.0 : math.max(1.0, costs.first.pct);
      for (final c in costs) {
        children.add(BenchBar(key: ValueKey('bench-partcost-${c.id}'), label: c.name, pct: c.pct, top: top,
            color: c.id == 'host' ? Neon.blue : Neon.violet));
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(key: const ValueKey('bench-parts'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Where the time goes', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      if (scenario != null)
        Text('In ${result.scenarioName(scenario)}${parts.isEmpty ? '' : ', by part of the engine. Tap one for more.'}',
            style: const TextStyle(color: Neon.dim, fontSize: 12)),
      const SizedBox(height: 4),
      ...children,
    ]);
  }
}

/// "Scenarios, best → worst": grouped by feature (each group by its worst), each row in its tier's colour; tap a
/// row for its full numbers.
class BenchScenarioGroups extends StatefulWidget {
  const BenchScenarioGroups({super.key, required this.result});
  final StressResult result;

  @override
  State<BenchScenarioGroups> createState() => _BenchScenarioGroupsState();
}

class _BenchScenarioGroupsState extends State<BenchScenarioGroups> {
  String? _open;

  static double _cost(ScenarioResult s) => s.ran ? s.p99Pct : double.infinity;

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    final groups = <String, List<ScenarioResult>>{};
    for (final s in widget.result.scenarios) {
      (groups[s.feature] ??= []).add(s);
    }
    final order = stressFeatures.keys.toList();
    for (final g in groups.values) {
      g.sort((a, b) => _cost(a).compareTo(_cost(b)));
    }
    double worst(List<ScenarioResult> g) => g.where((s) => s.ran).fold(0.0, (a, s) => math.max(a, s.p99Pct));
    final keys = groups.keys.toList()
      ..sort((a, b) {
        final c = worst(groups[a]!).compareTo(worst(groups[b]!));
        return c != 0 ? c : order.indexOf(a).compareTo(order.indexOf(b));
      });
    if (keys.isEmpty) return const SizedBox.shrink();
    return Column(key: const ValueKey('bench-scenarios'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Scenarios, best to worst', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      for (final f in keys) ...[
        Padding(
          key: ValueKey('bench-group-$f'),
          padding: const EdgeInsets.only(top: 10, bottom: 2),
          child: Row(children: [
            Expanded(child: Text(stressFeatures[f] ?? f, style: const TextStyle(color: Neon.dim, fontSize: 12, fontWeight: FontWeight.w600))),
            Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle,
                color: benchTierColor(groups[f]!.any((s) => s.ran) ? StressTier.of(worst(groups[f]!)) : null))),
          ]),
        ),
        for (final s in groups[f]!) _row(s, level),
      ],
    ]);
  }

  Widget _row(ScenarioResult s, MotionLevel level) {
    final open = _open == s.key;
    final t = s.ran ? StressTier.of(s.p99Pct) : null;
    final color = benchTierColor(t);
    return AnimatedContainer(
      key: ValueKey('bench-scn-${s.key}'),
      duration: Motion.fade(Motion.standard, level),
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: Neon.panel.withValues(alpha: open ? 0.7 : 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          Haptics.tap();
          setState(() => _open = open ? null : s.key);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 8, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('${s.name}${s.modeLabel}', maxLines: 2)),
              Text(s.ran ? '${s.p99Pct.round()}%' : '—', style: Neon.code(size: 13, color: color)),
              AnimatedRotation(
                turns: open ? 0.5 : 0,
                duration: Motion.move(Motion.standard, level),
                child: const Icon(Icons.expand_more, size: 18, color: Neon.dim),
              ),
            ]),
            BenchGrow(
              child: AnimatedSwitcher(
                duration: Motion.fade(Motion.standard, level),
                child: !open
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        key: ValueKey('bench-scn-open-${s.key}'),
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(scenarioNumbers(s), style: const TextStyle(color: Neon.dim, fontSize: 12)),
                      ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A scenario's full numbers in words (the rows' expanded text).
String scenarioNumbers(ScenarioResult s) {
  if (!s.ran) return s.skipped ?? s.error ?? 'Not run';
  final tier = StressTier.of(s.p99Pct).label;
  return '$tier. Average ${s.meanPct.round()}% of the time it has, 99% of callbacks within ${s.p99Pct.round()}%, '
      'the slowest ${s.worstPct.round()}%.\n'
      '${s.live ? '${s.dropouts} dropouts' : '${s.overBudget} callbacks ran out of time'} in '
      '${s.callbacks} callbacks of ${s.frames} frames '
      '(${(s.meanUs / 1000).toStringAsFixed(2)} ms mean, ${(s.p99Us / 1000).toStringAsFixed(2)} ms p99, '
      '${(s.budgetUs / 1000).toStringAsFixed(2)} ms budget).';
}

/// Grows and shrinks to its child through the motion tokens; at Reduced or Off it snaps (an AnimatedSize with no
/// duration re-dirties itself in its own layout).
class BenchGrow extends StatelessWidget {
  const BenchGrow({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final d = Motion.move(Motion.panel, Motion.of(context));
    if (d == Duration.zero) return child;
    return AnimatedSize(duration: d, alignment: Alignment.topCenter, child: child);
  }
}
