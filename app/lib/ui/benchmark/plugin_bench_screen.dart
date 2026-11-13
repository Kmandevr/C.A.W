// The plug-in benchmark (owner's look 2026-11-13, "Checks + sections"): the component's cost of a block, its checks, its own CAW_PROFILE_SCOPE sections and small curves. Never sent anywhere.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/component_bench.dart';
import '../../model/component_bench_result.dart';
import '../../model/stress_runner.dart';
import '../haptics.dart';
import '../motion.dart';
import '../panel_motion.dart';
import '../theme.dart';
import 'benchmark_summary.dart';

/// Opens the plug-in benchmark for [target] and starts it.
Future<void> showPluginBench(BuildContext context, ComponentBenchTarget target, {StressHost? host, ComponentBenchBackend? backend}) =>
    Navigator.of(context).push(panelRoute<void>(
        context, (_) => PluginBenchScreen(target: target, runner: ComponentBenchRunner(backend: backend, host: host))));

class PluginBenchScreen extends StatefulWidget {
  const PluginBenchScreen({super.key, required this.target, required this.runner});
  final ComponentBenchTarget target;
  final ComponentBenchRunner runner;

  @override
  State<PluginBenchScreen> createState() => _PluginBenchScreenState();
}

class _PluginBenchScreenState extends State<PluginBenchScreen> {
  ComponentBenchRunner get r => widget.runner;
  bool _curves = false;

  @override
  void initState() {
    super.initState();
    // After the first frame: the run sets the app's transport aside, which rebuilds what listens to it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
  }

  void _start() {
    if (r.running) return;
    r.run(widget.target.request);
  }

  @override
  void dispose() {
    r.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Plug-in benchmark'), backgroundColor: Neon.panel),
        body: SafeArea(
          top: false,
          child: ListenableBuilder(
            listenable: r,
            builder: (context, _) {
              final level = Motion.of(context);
              final res = r.result;
              return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
                AnimatedSwitcher(
                  duration: Motion.fade(Motion.panel, level),
                  child: r.running || res == null
                      ? _running(level)
                      : res.ok
                          ? _results(res, level)
                          : _failed(res),
                ),
              ]);
            },
          ),
        ),
      );

  Widget _running(MotionLevel level) => Column(key: const ValueKey('pbench-running'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Timing ${widget.target.name}…', style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TweenAnimationBuilder<double>(
          tween: Tween(end: r.fraction),
          duration: Motion.move(Motion.standard, level),
          builder: (_, v, _) => LinearProgressIndicator(value: v <= 0 ? null : v, minHeight: 3),
        ),
        const SizedBox(height: 8),
        const Text('It plays your plug-in silently on its own, at several voice counts, block sizes and sample rates.',
            style: TextStyle(color: Neon.dim, fontSize: 12)),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('pbench-stop'),
            onPressed: () {
              Haptics.tap();
              r.cancel();
            },
            style: TextButton.styleFrom(foregroundColor: Neon.pink),
            icon: const Icon(Icons.stop, size: 18),
            label: const Text('Stop'),
          ),
        ),
      ]);

  Widget _again() => Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('pbench-again'),
          onPressed: () {
            Haptics.tap();
            _start();
          },
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Run again'),
        ),
      );

  Widget _failed(ComponentBenchResult res) => Column(key: const ValueKey('pbench-failed'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.target.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(res.error ?? 'No result', key: const ValueKey('pbench-error'), style: const TextStyle(color: Neon.pink)),
        const SizedBox(height: 12),
        _again(),
      ]);

  Widget _results(ComponentBenchResult res, MotionLevel level) {
    final instrument = res.componentId.isEmpty && res.name.isEmpty ? widget.target.instrument : res.isInstrument;
    final color = res.costPct <= 10 ? Neon.green : res.costPct <= 30 ? Neon.yellow : Neon.pink;
    return Column(key: const ValueKey('pbench-results'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The header: the component and its share of a block.
      Text('${res.name.isEmpty ? widget.target.name : res.name} · ${instrument ? 'instrument' : 'effect'}',
          key: const ValueKey('pbench-name'), style: const TextStyle(color: Neon.dim, fontSize: 13), overflow: TextOverflow.ellipsis),
      TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: res.costPct),
        duration: Motion.move(Motion.panel, level),
        builder: (_, v, _) => Text('${v.toStringAsFixed(v < 10 ? 1 : 0)}% of a block',
            key: const ValueKey('pbench-cost'), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: color)),
      ),
      if (res.budgetUs > 0)
        Text('${res.meanUs.toStringAsFixed(1)} µs on average, ${res.p99Us.toStringAsFixed(1)} µs at p99, '
            'of ${res.budgetUs.toStringAsFixed(0)} µs a block',
            style: const TextStyle(color: Neon.dim, fontSize: 12)),
      const SizedBox(height: 16),
      if (res.checks.isNotEmpty) ...[
        const Text('Checks', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        const SizedBox(height: 4),
        for (final c in res.checks) _check(c),
        const SizedBox(height: 16),
      ],
      const Text('Your sections (slowest first)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      if (res.sections.isEmpty)
        const Padding(
          key: ValueKey('pbench-no-sections'),
          padding: EdgeInsets.only(top: 4),
          child: Text('None timed. Wrap a part of your process() in CAW_PROFILE_SCOPE("name") and it shows here; '
              'it costs nothing outside a benchmark.', style: TextStyle(color: Neon.dim, fontSize: 12)),
        )
      else
        for (final s in res.sections)
          BenchBar(
            key: ValueKey('pbench-section-${s.name}'),
            label: s.name,
            sub: s.calls > 0 ? '${(s.meanNs / 1000).toStringAsFixed(1)} µs a call · ${s.calls} calls' : null,
            pct: s.pct,
            top: math.max(1.0, res.sections.first.pct),
          ),
      if (res.curves.isNotEmpty) ...[
        const SizedBox(height: 12),
        InkWell(
          key: const ValueKey('pbench-curves-toggle'),
          onTap: () {
            Haptics.tap();
            setState(() => _curves = !_curves);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(children: [
              const Expanded(child: Text('Curves', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
              AnimatedRotation(
                turns: _curves ? 0.5 : 0,
                duration: Motion.move(Motion.standard, level),
                child: const Icon(Icons.expand_more, size: 20, color: Neon.dim),
              ),
            ]),
          ),
        ),
        BenchGrow(
          child: AnimatedSwitcher(
            duration: Motion.fade(Motion.standard, level),
            child: !_curves
                ? const SizedBox(width: double.infinity)
                : Column(key: const ValueKey('pbench-curves'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final c in res.curves) _curve(c),
                  ]),
          ),
        ),
      ],
      const SizedBox(height: 16),
      const Text('These numbers stay on this device; they are never sent.', style: TextStyle(color: Neon.dim, fontSize: 12)),
      const SizedBox(height: 8),
      _again(),
    ]);
  }

  Widget _check(BenchCheck c) {
    final color = switch (c.status) {
      BenchCheckStatus.pass => Neon.green,
      BenchCheckStatus.warn => Neon.yellow,
      BenchCheckStatus.fail => Neon.pink,
    };
    return Padding(
      key: ValueKey('pbench-check-${c.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ✓ / ⚠ / ✗ as icons (every platform's font has them), the mark as their label.
        SizedBox(
          width: 24,
          child: Icon(
              switch (c.status) {
                BenchCheckStatus.pass => Icons.check,
                BenchCheckStatus.warn => Icons.warning_amber_rounded,
                BenchCheckStatus.fail => Icons.close,
              },
              size: 18,
              color: color,
              semanticLabel: c.status.mark),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            if (c.detail.isNotEmpty) Text(c.detail, style: const TextStyle(color: Neon.dim, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }

  Widget _curve(BenchCurve c) {
    String fmt(double v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(v % 1000 == 0 ? 0 : 1)}k' : v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1);
    final ys = c.points.map((p) => p.$2);
    return Padding(
      key: ValueKey('pbench-curve-${c.id}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(c.name, style: const TextStyle(fontSize: 13))),
          Text('up to ${ys.reduce(math.max).toStringAsFixed(1)}% of a block', style: Neon.code(size: 11, color: Neon.dim)),
        ]),
        const SizedBox(height: 4),
        SizedBox(
          height: 72,
          child: RepaintBoundary(child: CustomPaint(painter: BenchCurvePainter(c.points), size: Size.infinite)),
        ),
        Row(children: [
          Text(fmt(c.points.first.$1), style: Neon.code(size: 10, color: Neon.dim)),
          const Spacer(),
          Text(fmt(c.points.last.$1), style: Neon.code(size: 10, color: Neon.dim)),
        ]),
      ]),
    );
  }
}

/// A small line chart: x evenly by rank (voices, sizes and rates are steps, not a scale), y from 0 to the largest.
class BenchCurvePainter extends CustomPainter {
  BenchCurvePainter(this.points);
  final List<(double, double)> points;

  @override
  void paint(Canvas canvas, Size size) {
    final axis = Paint()
      ..color = Neon.line
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), axis);
    if (points.length < 2) return;
    final top = math.max(0.1, points.map((p) => p.$2).reduce(math.max)) * 1.1;
    final dx = size.width / (points.length - 1);
    Offset at(int i) => Offset(i * dx, size.height * (1 - points[i].$2 / top));
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = Neon.violet
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    final dot = Paint()..color = Neon.violet;
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(at(i), 2.5, dot);
    }
  }

  @override
  bool shouldRepaint(BenchCurvePainter old) => old.points != points;
}
