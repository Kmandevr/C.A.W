// The Benchmark's drill-down for one engine part: its numbers in each profiled scenario, where it mattered most, plain tips, and for "devices" each device's cost.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/stress_result.dart';
import '../motion.dart';
import '../theme.dart';
import 'benchmark_summary.dart';

class PartDetailPage extends StatelessWidget {
  const PartDetailPage({super.key, required this.result, required this.partId});
  final StressResult result;
  final String partId;

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    final across = result.partAcross(partId);
    final headline = result.parts.where((p) => p.id == partId).firstOrNull ?? across.firstOrNull?.part;
    final part = headline ?? EnginePart(id: partId, pct: 0);
    final most = across.take(3).toList();
    final topMost = most.isEmpty ? 1.0 : math.max(1.0, most.first.part.pct);
    return Scaffold(
      appBar: AppBar(title: Text(part.name), backgroundColor: Neon.panel),
      body: SafeArea(
        top: false,
        child: ListView(key: const ValueKey('part-detail'), padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
          Text(part.about, style: const TextStyle(color: Neon.dim, fontSize: 13)),
          const SizedBox(height: 8),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: part.pct),
            duration: Motion.move(Motion.panel, level),
            builder: (_, v, _) => Text('${v.round()}% of the time in ${result.scenarioName(result.partsScenario ?? '')}',
                key: const ValueKey('part-headline'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 16),
          const _Heading('Tips'),
          for (final t in partTips(partId, part.pct))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(padding: EdgeInsets.only(top: 2, right: 6), child: Icon(Icons.lightbulb_outline, size: 16, color: Neon.yellow)),
                Expanded(child: Text(t, key: ValueKey('part-tip-${t.hashCode}'))),
              ]),
            ),
          if (most.isNotEmpty) ...[
            const SizedBox(height: 16),
            const _Heading('Where it mattered most'),
            for (final m in most)
              BenchBar(key: ValueKey('part-most-${m.scenario}'), label: result.scenarioName(m.scenario), pct: m.part.pct, top: topMost,
                  color: Neon.blue),
          ],
          if (across.isNotEmpty) ...[
            const SizedBox(height: 16),
            const _Heading('In each profiled scenario'),
            Table(
              key: const ValueKey('part-table'),
              columnWidths: const {0: FlexColumnWidth(), 1: IntrinsicColumnWidth(), 2: IntrinsicColumnWidth(), 3: IntrinsicColumnWidth()},
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(children: [
                  for (final h in const ['Scenario', 'Mean', 'p99', 'Share'])
                    Padding(
                      padding: const EdgeInsets.only(left: 8, bottom: 4),
                      child: Text(h, style: const TextStyle(color: Neon.dim, fontSize: 11), textAlign: h == 'Scenario' ? TextAlign.left : TextAlign.right),
                    ),
                ]),
                for (final a in [...across]..sort((x, y) => result.scenarioName(x.scenario).compareTo(result.scenarioName(y.scenario))))
                  TableRow(children: [
                    Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(result.scenarioName(a.scenario))),
                    _num('${a.part.meanUs.toStringAsFixed(1)} µs'),
                    _num('${a.part.p99Us.toStringAsFixed(1)} µs'),
                    _num('${a.part.pct.toStringAsFixed(1)}%'),
                  ]),
              ],
            ),
          ],
          if (partId == 'devices') ..._devices(),
        ]),
      ),
    );
  }

  Widget _num(String t) => Padding(
      padding: const EdgeInsets.only(left: 8), child: Text(t, textAlign: TextAlign.right, style: Neon.code(size: 12)));

  List<Widget> _devices() {
    if (result.costsByScenario.isEmpty) return const [];
    return [
      const SizedBox(height: 16),
      const _Heading('Each instrument and effect'),
      for (final e in result.costsByScenario.entries) ...[
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(result.scenarioName(e.key), style: const TextStyle(color: Neon.dim, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        for (final c in ([...e.value]..sort((a, b) => b.pct.compareTo(a.pct))).where((c) => c.id != 'host'))
          BenchBar(
            key: ValueKey('part-device-${e.key}-${c.id}'),
            label: c.name,
            sub: c.instances > 1 ? '${c.instances} of it' : null,
            pct: c.pct,
            top: math.max(1.0, e.value.fold(0.0, (a, x) => x.id == 'host' ? a : math.max(a, x.pct))),
          ),
      ],
    ];
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)));
}
