// The Benchmark (beta plan C, owner's look 2026-11-12): Quick or Full run, a live load graph, tiers, limits, what's holding it back, per-scenario rows, Share/Save JSON.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../engine/execution.dart';
import '../../model/stress_result.dart';
import '../../model/stress_runner.dart';
import '../../model/telemetry/telemetry.dart';
import '../../platform/resource_signals.dart';
import '../../platform/save_copy.dart';
import '../haptics.dart';
import '../motion.dart';
import '../panel_motion.dart';
import '../theme.dart';

/// Opens the Benchmark full screen. [host] is the app's state (its transport and device are set aside while it runs).
Future<void> showBenchmark(BuildContext context, {StressHost? host}) =>
    Navigator.of(context).push(panelRoute<void>(context, (_) => BenchmarkScreen(runner: defaultStressRunner(host))));

/// The runner the app uses: the engine, the platform's heat and battery signals, the work budget, telemetry.
StressRunner defaultStressRunner(StressHost? host) {
  int? budget;
  Map<String, Object?> device = {'platform': Platform.operatingSystem};
  try {
    final hw = EngineExecutionPolicy.hardwareProfile;
    budget = hw.memoryBudgetMiB;
    device = {...device, 'logical_cores': hw.logicalCores, 'memory_budget_mib': hw.memoryBudgetMiB};
  } catch (_) {
    // No engine: the runs fail with their own reason.
  }
  return StressRunner(
    host: host,
    memoryBudgetMiB: budget,
    pressure: ResourceSignals.changes.handleError((Object _) {}),
    readPressure: ResourceSignals.read,
    readThermal: ResourceSignals.readThermal,
    sendTelemetry: (stress) async => Telemetry.current?.sendStressReport(stress),
    workDir: () async {
      try {
        return await (await getTemporaryDirectory()).createTemp('caw-benchmark');
      } catch (_) {
        return null;
      }
    },
    device: device,
  );
}

Color tierColor(StressTier? t) => switch (t) {
      StressTier.comfortable => Neon.green,
      StressTier.tight => Neon.yellow,
      StressTier.over => Neon.pink,
      null => Neon.dim,
    };

class BenchmarkScreen extends StatefulWidget {
  const BenchmarkScreen({super.key, required this.runner, this.saveJson, this.share});
  final StressRunner runner;

  /// Saves the JSON (tests pass their own); the system's save picker by default.
  final Future<bool> Function(String json)? saveJson;

  /// Shares the text; the share sheet (desktop: the clipboard) by default.
  final Future<bool> Function(String text)? share;

  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<BenchmarkScreen> {
  StressRunner get r => widget.runner;
  String? _open; // the expanded scenario row

  @override
  void dispose() {
    r.cancel();
    r.dispose();
    super.dispose();
  }

  void _say(String text) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 4)));

  Future<void> _start(StressPlanKind kind) async {
    Haptics.tap();
    await r.run(kind);
  }

  Future<bool> _defaultSave(String json) async {
    final dir = await Directory.systemTemp.createTemp('caw-benchmark-save');
    final f = File('${dir.path}${Platform.pathSeparator}caw-benchmark.json');
    await f.writeAsString(json);
    try {
      return await saveCopyOf(f, name: 'caw-benchmark.json', mimeType: 'application/json', extension: 'json');
    } finally {
      await dir.delete(recursive: true);
    }
  }

  Future<void> _save(StressResult res) async {
    final ok = await (widget.saveJson ?? _defaultSave)(res.toJsonText());
    if (mounted && ok) _say('Benchmark saved.');
  }

  Future<void> _share(StressResult res) async {
    final text = '${res.summary()}\n${res.toJsonText()}';
    final shared = await (widget.share ?? (t) => shareText(t, subject: 'C.A.W Benchmark'))(text);
    if (mounted && !shared) _say('Copied to the clipboard.');
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !r.running,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) r.cancel(); // back while running stops it first; the result stays to read
        },
        child: Scaffold(
          appBar: AppBar(title: const Text('Benchmark'), backgroundColor: Neon.panel),
          body: SafeArea(top: false, child: ListenableBuilder(
            listenable: r,
            builder: (context, _) {
              final level = Motion.of(context);
              final res = r.result;
              return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
                const Text('How much can this device play? The Benchmark plays built-in songs on its own, silently, and '
                    'times the sound engine. Your project isn\'t touched.',
                    style: TextStyle(color: Neon.dim, fontSize: 13)),
                const SizedBox(height: 12),
                AnimatedSwitcher(
                  duration: Motion.fade(Motion.panel, level),
                  child: r.running ? _runningCard(context, level) : _startButtons(),
                ),
                AnimatedSize(
                  duration: Motion.move(Motion.panel, level),
                  alignment: Alignment.topCenter,
                  child: res == null || (r.running && res.scenarios.isEmpty)
                      ? const SizedBox(width: double.infinity)
                      : _results(context, res, level),
                ),
              ]);
            },
          )),
        ),
      );

  Widget _startButtons() => Column(key: const ValueKey('bench-start'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final k in StressPlanKind.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: (k == StressPlanKind.quick ? FilledButton.icon : OutlinedButton.icon)(
              key: ValueKey('bench-${k.name}'),
              onPressed: () => _start(k),
              icon: Icon(k == StressPlanKind.quick ? Icons.bolt : Icons.timer_outlined, size: 18),
              label: Text('${k.label} run · ${k.duration}'),
            ),
          ),
        const Text('Sound stays off while it runs. Plug in or keep the screen on for the steadiest numbers.',
            style: TextStyle(color: Neon.dim, fontSize: 12)),
      ]);

  Widget _runningCard(BuildContext context, MotionLevel level) => Card(
        key: const ValueKey('bench-running'),
        color: Neon.panel.withValues(alpha: 0.5),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: AnimatedSwitcher(
                  duration: Motion.fade(Motion.standard, level),
                  child: Text(r.phase, key: ValueKey(r.phase), style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
              Text('${(100 * r.load).round()}% load', style: Neon.code(size: 12, color: Neon.dim)),
            ]),
            const SizedBox(height: 8),
            TweenAnimationBuilder<double>(
              tween: Tween(end: r.fraction),
              duration: Motion.move(Motion.standard, level),
              builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: 3),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 120,
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey('bench-graph'),
                  painter: LoadGraphPainter(points: List.of(r.loadPoints), version: r.pointsSeen),
                  size: Size.infinite,
                ),
              ),
            ),
            const SizedBox(height: 4),
            const Text('The line is the engine\'s load: under the dashed line the sound keeps up.',
                style: TextStyle(color: Neon.dim, fontSize: 11)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('bench-stop'),
                onPressed: () {
                  Haptics.tap();
                  r.cancel();
                },
                style: TextButton.styleFrom(foregroundColor: Neon.pink),
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('Stop'),
              ),
            ),
          ]),
        ),
      );

  Widget _results(BuildContext context, StressResult res, MotionLevel level) {
    final costs = res.holdingBack.take(8).toList();
    final top = costs.isEmpty ? 1.0 : math.max(1.0, costs.first.pct);
    return Column(key: const ValueKey('bench-results'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 16),
      if (res.stoppedBecause != null && !r.running)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(res.stoppedBecause!, key: const ValueKey('bench-stopped'), style: const TextStyle(color: Neon.yellow)),
        ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final t in const ['normal', 'heavy', 'extreme']) _tierBadge(t, res.tier(t), level),
      ]),
      if (res.limitsText.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(res.limitsText, key: const ValueKey('bench-limits'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const Text('The most it kept up with before a callback ran out of time.', style: TextStyle(color: Neon.dim, fontSize: 12)),
      ],
      if (costs.isNotEmpty) ...[
        const SizedBox(height: 16),
        const Text('What\'s holding it back', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        for (final c in costs)
          Padding(
            key: ValueKey('bench-cost-${c.id}'),
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(flex: 5, child: Text(c.name, overflow: TextOverflow.ellipsis)),
              Expanded(
                flex: 4,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: c.pct / top),
                  duration: Motion.move(Motion.panel, level),
                  builder: (_, v, _) => LinearProgressIndicator(
                      value: v.clamp(0.0, 1.0), minHeight: 6, color: c.id == 'host' ? Neon.blue : Neon.violet,
                      backgroundColor: Neon.line),
                ),
              ),
              SizedBox(width: 44, child: Text('${c.pct.round()}%', textAlign: TextAlign.right, style: Neon.code(size: 12))),
            ]),
          ),
      ],
      if (res.sustained != null) ...[
        const SizedBox(height: 12),
        Text(
            res.sustained!.driftPct > 10
                ? 'Over two minutes it slowed by ${res.sustained!.driftPct.round()}%: the device warms up and throttles.'
                : 'Over two minutes it held steady (${res.sustained!.driftPct.round()}% change).',
            style: const TextStyle(color: Neon.dim)),
      ],
      const SizedBox(height: 16),
      const Text('Each song', style: TextStyle(fontWeight: FontWeight.w600)),
      for (final s in res.scenarios) _scenarioRow(s, level),
      if (!r.running) ...[
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              key: const ValueKey('bench-share'),
              onPressed: () => _share(res),
              icon: const Icon(Icons.share, size: 18),
              label: const Text('Share')),
          OutlinedButton.icon(
              key: const ValueKey('bench-save'),
              onPressed: () => _save(res),
              icon: const Icon(Icons.file_download_outlined, size: 18),
              label: const Text('Save JSON')),
        ]),
        const SizedBox(height: 8),
        const Text('With telemetry on (Settings › Privacy), each run\'s numbers are sent anonymously to help make '
            'C.A.W faster.', style: TextStyle(color: Neon.dim, fontSize: 12)),
      ],
    ]);
  }

  Widget _tierBadge(String tier, StressTier? t, MotionLevel level) {
    final color = tierColor(t);
    return AnimatedContainer(
      key: ValueKey('bench-tier-$tier'),
      duration: Motion.fade(Motion.standard, level),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('${tier[0].toUpperCase()}${tier.substring(1)} projects', style: const TextStyle(fontSize: 11, color: Neon.dim)),
        Text(t?.label ?? 'Not run', style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _scenarioRow(ScenarioResult s, MotionLevel level) {
    final key = s.key;
    final open = _open == key;
    final t = s.ran ? StressTier.of(s.p99Pct) : null;
    return Card(
      key: ValueKey('bench-row-$key'),
      color: Neon.panel.withValues(alpha: 0.5),
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: () {
          Haptics.tap();
          setState(() => _open = open ? null : key);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('${s.name}${s.modeLabel}', overflow: TextOverflow.ellipsis)),
              Text(s.ran ? '${s.p99Pct.round()}%' : '—', style: Neon.code(size: 13, color: tierColor(t))),
              AnimatedRotation(
                turns: open ? 0.5 : 0,
                duration: Motion.move(Motion.standard, level),
                child: const Icon(Icons.expand_more, size: 18, color: Neon.dim),
              ),
            ]),
            AnimatedSize(
              duration: Motion.move(Motion.panel, level),
              alignment: Alignment.topCenter,
              child: !open
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        s.ran
                            ? 'Average ${s.meanPct.round()}% of the time it has, 99% of callbacks within ${s.p99Pct.round()}%, '
                                'the slowest ${s.worstPct.round()}%.\n'
                                '${s.live ? '${s.dropouts} dropouts' : '${s.overBudget} callbacks ran out of time'} in '
                                '${s.callbacks} callbacks of ${s.frames} frames '
                                '(${(s.meanUs / 1000).toStringAsFixed(2)} ms mean, '
                                '${(s.budgetUs / 1000).toStringAsFixed(2)} ms budget).'
                            : (s.skipped ?? s.error ?? 'Not run'),
                        style: const TextStyle(color: Neon.dim, fontSize: 12),
                      ),
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The live load graph: the load every 100 ms (a share of the budget) and the budget as a dashed line.
class LoadGraphPainter extends CustomPainter {
  LoadGraphPainter({required this.points, required this.version});
  final List<double> points;
  final int version;

  static const double top = 1.5; // the graph shows up to 150% of the budget

  @override
  void paint(Canvas canvas, Size size) {
    final budgetY = size.height * (1 - 1 / top);
    final dash = Paint()
      ..color = Neon.dim
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, budgetY), Offset(math.min(size.width, x + 4), budgetY), dash);
    }
    if (points.length < 2) return;
    final n = math.min(points.length, StressRunner.maxPoints);
    final shown = points.sublist(points.length - n);
    final dx = size.width / math.max(1, StressRunner.maxPoints ~/ 2 - 1);
    final start = math.max(0, shown.length - StressRunner.maxPoints ~/ 2);
    final path = Path();
    for (var i = start; i < shown.length; i++) {
      final x = (i - start) * dx;
      final y = size.height * (1 - (shown[i].clamp(0.0, top) / top));
      i == start ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = shown.last > 1 ? Neon.pink : Neon.green
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(LoadGraphPainter old) => old.version != version;
}
