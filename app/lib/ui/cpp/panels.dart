// The C++ Builder's sheets and side panels: Problems, Snippets and the ♪ Test strip.
import 'package:flutter/material.dart';

import '../../engine/component_info.dart';
import '../../model/cpp_diagnostics.dart';
import '../../model/cpp_snippets.dart';
import '../../model/cpp_workbench.dart';
import '../arrange/knob.dart' show Taper;
import '../theme.dart';
import '../widgets.dart' show ResetOnDoubleTap;

TextStyle _small({Color color = Neon.text, FontWeight? weight}) => TextStyle(fontSize: 12, color: color, fontWeight: weight);

Widget _heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Text(text.toUpperCase(),
          style: const TextStyle(fontSize: 10.5, letterSpacing: 1.3, fontWeight: FontWeight.w700, color: Neon.dim)),
    );

/// Errors and warnings grouped by file (warnings dimmed); tapping one jumps to it.
class ProblemsList extends StatelessWidget {
  const ProblemsList({super.key, required this.workbench, required this.onJump});

  final CppWorkbench workbench;
  final ValueChanged<CppDiagnostic> onJump;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: workbench,
        builder: (context, _) {
          final w = workbench;
          final groups = groupDiagnostics(w.diagnostics, order: w.fileOrder);
          final note = w.checkNote;
          return ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              if (note != null)
                Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text(note, style: _small(color: Neon.dim))),
              if (groups.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Icon(w.checking ? Icons.sync : Icons.check_circle_outline, size: 16, color: Neon.green),
                    const SizedBox(width: 8),
                    Text(w.checking ? 'Checking…' : 'No problems', style: _small(color: Neon.dim)),
                  ]),
                ),
              for (final entry in groups.entries) ...[
                _heading(entry.key),
                for (final d in entry.value)
                  InkWell(
                    key: ValueKey('problem ${d.file}:${d.line}:${d.column}'),
                    onTap: () => onJump(d),
                    child: Opacity(
                      opacity: d.isError ? 1 : 0.6,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Icon(d.isError ? Icons.error_outline : Icons.warning_amber, size: 16, color: d.isError ? Neon.pink : Neon.yellow),
                          const SizedBox(width: 8),
                          SizedBox(width: 44, child: Text('${d.line}:${d.column}', style: Neon.code(size: 11, color: Neon.dim))),
                          Expanded(child: Text(d.message, style: _small(), maxLines: 2, overflow: TextOverflow.ellipsis)),
                        ]),
                      ),
                    ),
                  ),
              ],
            ],
          );
        },
      );
}

/// The snippets, each with a preview and an Insert button.
class SnippetList extends StatelessWidget {
  const SnippetList({super.key, required this.onInsert});
  final ValueChanged<String> onInsert;

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.only(bottom: 12), children: [
        for (final s in cppSnippets)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.title, style: _small(weight: FontWeight.w600)),
                  Text(s.summary, style: _small(color: Neon.dim)),
                  const SizedBox(height: 4),
                  Text(s.code.trim().split('\n').take(4).join('\n'),
                      style: Neon.code(size: 11, color: Neon.dim), maxLines: 4, overflow: TextOverflow.ellipsis),
                ]),
              ),
              IconButton(
                key: ValueKey('snippet ${s.title}'),
                tooltip: 'Insert',
                iconSize: 18,
                icon: const Icon(Icons.input),
                onPressed: () => onInsert(s.code),
              ),
            ]),
          ),
      ]);
}

/// ♪ Test: plays a track that uses this effect (soloed while testing, as it was after), with an A/B bypass and the
/// effect's knobs. With no track using it, it says so and plays nothing (owner: no default test sound).
class TestStrip extends StatefulWidget {
  const TestStrip({super.key, required this.workbench});
  final CppWorkbench workbench;

  @override
  State<TestStrip> createState() => _TestStripState();
}

class _TestStripState extends State<TestStrip> {
  int _use = 0;
  bool _playing = false;
  bool _bypassed = false;
  bool _wasPlaying = false;
  CppEffectUse? _soloed, _bypassedUse;

  CppWorkbench get w => widget.workbench;

  @override
  void dispose() {
    _stop(rebuild: false);
    super.dispose();
  }

  void _play(CppEffectUse u) {
    final s = w.state;
    final engine = s.engine;
    final layer = u.layer;
    if (layer != null && engine != null) {
      engine.setLayerMix(layer.id, layer.volume, layer.pan, layer.mute, true);
      _soloed = u;
    }
    _wasPlaying = s.transportOn;
    if (!s.transportOn) s.togglePlay();
    setState(() => _playing = true);
  }

  void _stop({bool rebuild = true}) {
    final s = w.state;
    // Playback that was going before Test goes on; Test's own playback stops.
    if (_playing && !_wasPlaying) s.stopPlayback();
    final layer = _soloed?.layer;
    if (layer != null) s.engine?.setLayerMix(layer.id, layer.volume, layer.pan, layer.mute, layer.solo);
    final bypassed = _bypassedUse;
    if (_bypassed && bypassed != null) _setBypass(bypassed, false);
    _soloed = null;
    _playing = false;
    if (rebuild && mounted) setState(() {});
  }

  void _setBypass(CppEffectUse u, bool on) {
    final index = w.engineIndex(u);
    if (index != null) w.state.engine?.setComponentBypass(u.layer?.id, index, on || u.use.bypass);
    _bypassed = on;
    _bypassedUse = on ? u : null;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: w,
        builder: (context, _) {
          final uses = w.uses;
          if (uses.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Text('No track uses this effect yet. Add it to a track (FX, + effect) to test it here.',
                  style: _small(color: Neon.dim)),
            );
          }
          final u = uses[_use.clamp(0, uses.length - 1)];
          final info = w.info;
          return ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), children: [
            Row(children: [
              Expanded(
                child: DropdownButton<int>(
                  key: const ValueKey('test track'),
                  isExpanded: true,
                  value: uses.indexOf(u),
                  style: _small(),
                  underline: const SizedBox(),
                  items: [
                    for (var i = 0; i < uses.length; i++)
                      DropdownMenuItem(value: i, child: Text(uses[i].layer?.name ?? 'Master', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (i) {
                    if (i == null || i == _use) return;
                    _stop();
                    setState(() => _use = i);
                  },
                ),
              ),
              IconButton(
                key: const ValueKey('test play'),
                tooltip: _playing ? 'Stop' : 'Play',
                iconSize: 22,
                color: _playing ? Neon.pink : Neon.green,
                icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
                onPressed: () => _playing ? _stop() : _play(u),
              ),
              TextButton(
                key: const ValueKey('test ab'),
                onPressed: () => setState(() => _setBypass(u, !_bypassed)),
                child: Text(_bypassed ? 'B · bypassed' : 'A · effect on', style: _small(color: _bypassed ? Neon.yellow : Neon.green)),
              ),
            ]),
            if (info == null)
              Text('Build the effect to show its knobs.', style: _small(color: Neon.dim))
            else if (info.parameters.isEmpty)
              Text('This effect has no knobs.', style: _small(color: Neon.dim))
            else
              for (final p in info.parameters) _Knob(workbench: w, use: u, parameter: p),
          ]);
        },
      );
}

class _Knob extends StatelessWidget {
  const _Knob({required this.workbench, required this.use, required this.parameter});
  final CppWorkbench workbench;
  final CppEffectUse use;
  final ComponentParameterInfo parameter;

  @override
  Widget build(BuildContext context) {
    final p = parameter;
    final value = (use.use.params[p.id] ?? p.defaultValue).clamp(p.min, p.max).toDouble();
    // An exponential parameter's slider moves along its taper (fine at the start, coarse at the end).
    final taper = Taper(p.min, p.max, exponential: p.exponential);
    return SizedBox(
      height: 36,
      child: Row(children: [
        SizedBox(width: 80, child: Text(p.label, style: _small(), overflow: TextOverflow.ellipsis)),
        Expanded(
          // Double-tap: back to the descriptor's default; a single tap still moves the slider at once.
          child: ResetOnDoubleTap(
            onReset: () => workbench.setKnob(use, p.id, p.defaultValue, commit: true),
            child: p.exponential && p.max > p.min
                ? Slider(
                    value: taper.position(value),
                    onChanged: (t) => workbench.setKnob(use, p.id, _snap(taper.value(t), p)),
                    onChangeEnd: (t) => workbench.setKnob(use, p.id, _snap(taper.value(t), p), commit: true),
                  )
                : Slider(
                    value: value,
                    min: p.min,
                    max: p.max > p.min ? p.max : p.min + 1,
                    divisions: p.step > 0 && p.max > p.min ? ((p.max - p.min) / p.step).round().clamp(1, 1000) : null,
                    onChanged: (v) => workbench.setKnob(use, p.id, v),
                    onChangeEnd: (v) => workbench.setKnob(use, p.id, v, commit: true),
                  ),
          ),
        ),
        SizedBox(
          width: 64,
          child: Text('${formatKnob(value)}${p.unit.isEmpty ? '' : ' ${p.unit}'}',
              textAlign: TextAlign.right, style: Neon.code(size: 11, color: Neon.dim)),
        ),
      ]),
    );
  }
}

/// [v] on [p]'s step, when it has one.
double _snap(double v, ComponentParameterInfo p) =>
    p.step > 0 ? (p.min + ((v - p.min) / p.step).round() * p.step).clamp(p.min, p.max).toDouble() : v;

String formatKnob(double v) => v.abs() >= 100 ? v.toStringAsFixed(0) : v.abs() >= 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(2);
