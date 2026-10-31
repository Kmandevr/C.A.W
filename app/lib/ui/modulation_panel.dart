import 'package:flutter/material.dart';
import '../engine/engine.dart';
import '../model/project.dart';
import 'theme.dart';
import 'widgets.dart';

class SignalOption {
  const SignalOption(this.value, this.label);
  final String value, label;
}

class ModulationPanel extends StatelessWidget {
  const ModulationPanel({
    super.key, required this.module, required this.info, required this.sources,
    required this.onSourceChanged, required this.onAddSidechain, required this.onRemoveSidechain,
  });
  final ModuleDoc module;
  final ModuleInfo? info;
  final List<SignalOption> sources;
  final Future<void> Function(String) onSourceChanged;
  final Future<void> Function(String, double) onAddSidechain;
  final VoidCallback onRemoveSidechain;

  @override
  Widget build(BuildContext context) {
    if (info?.kind == 'synth') return _SynthModEditor(source: module.source, onChanged: onSourceChanged);
    if (info?.kind != 'effect') return const SizedBox.shrink();
    final route = RegExp(r'util\.duck\s*\(\s*in\s*,\s*([A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*)\s*,\s*amount\s*\)')
        .firstMatch(module.source);
    if (route != null) {
      return _SidechainRoute(
        current: route.group(1)!, sources: sources,
        onChanged: (value) => onSourceChanged(module.source.replaceRange(route.start(1)!, route.end(1)!, value)),
        onRemove: onRemoveSidechain,
      );
    }
    return _SidechainCreator(sources: sources, onCreate: onAddSidechain);
  }
}

class _Route {
  const _Route(this.line, this.source, this.destination, this.amount);
  final int line;
  final String source, destination;
  final double amount;
}

class _SynthModEditor extends StatefulWidget {
  const _SynthModEditor({required this.source, required this.onChanged});
  final String source;
  final Future<void> Function(String) onChanged;
  @override
  State<_SynthModEditor> createState() => _SynthModEditorState();
}

class _SynthModEditorState extends State<_SynthModEditor> {
  String? newSource, newDestination;
  double newAmount = 0.5;

  List<String> get availableSources {
    final out = <String>['vel'];
    for (final kind in ['env', 'lfo', 'macro']) {
      final max = kind == 'env' ? 3 : 4;
      for (var i = kind == 'env' ? 2 : 1; i <= max; i++) {
        if (RegExp('^\\s*$kind\\s+$i(?:\\s|$)', multiLine: true).hasMatch(widget.source)) out.add('$kind $i');
      }
    }
    return out;
  }

  List<String> get availableDestinations {
    final out = <String>['volume'];
    for (final osc in ['a', 'b', 'c']) {
      if (RegExp('^\\s*osc\\s+$osc(?:\\s|$)', multiLine: true).hasMatch(widget.source)) {
        out.addAll(['osc $osc pos', 'osc $osc level', 'osc $osc pitch']);
      }
    }
    for (var i = 1; i <= 2; i++) {
      if (RegExp('^\\s*filter\\s+$i(?:\\s|$)', multiLine: true).hasMatch(widget.source)) {
        out.addAll(['filter $i cutoff', 'filter $i res']);
      }
    }
    return out;
  }

  List<_Route> get routes {
    final lines = widget.source.split('\n');
    final pattern = RegExp(r'^\s*mod\s+(.+?)\s*->\s*(.+?)\s+(-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+))\s*(?://.*)?$');
    final out = <_Route>[];
    for (var i = 0; i < lines.length; i++) {
      final m = pattern.firstMatch(lines[i]);
      final amount = m == null ? null : double.tryParse(m.group(3)!);
      if (m != null && amount != null && amount.isFinite) out.add(_Route(i, m.group(1)!, m.group(2)!, amount));
    }
    return out;
  }

  Future<void> replace(_Route route, {String? source, String? destination, double? amount}) async {
    final lines = widget.source.split('\n');
    if (route.line >= lines.length) return;
    lines[route.line] = 'mod ' + (source ?? route.source) + ' -> ' + (destination ?? route.destination) +
        ' ' + (amount ?? route.amount).toStringAsFixed(3);
    await widget.onChanged(lines.join('\n'));
  }

  Future<void> remove(_Route route) async {
    final lines = widget.source.split('\n');
    if (route.line >= lines.length) return;
    lines.removeAt(route.line);
    await widget.onChanged(lines.join('\n'));
  }

  Future<void> add() async {
    final src = newSource ?? availableSources.firstOrNull;
    final dst = newDestination ?? availableDestinations.firstOrNull;
    if (src == null || dst == null) return;
    final prefix = widget.source.endsWith('\n') ? widget.source : widget.source + '\n';
    await widget.onChanged(prefix + 'mod ' + src + ' -> ' + dst + ' ' + newAmount.toStringAsFixed(3) + '\n');
  }

  @override
  Widget build(BuildContext context) {
    final srcs = availableSources, dsts = availableDestinations, current = routes;
    newSource ??= srcs.firstOrNull;
    newDestination ??= dsts.firstOrNull;
    if (!srcs.contains(newSource)) newSource = srcs.firstOrNull;
    if (!dsts.contains(newDestination)) newDestination = dsts.firstOrNull;
    return Card(
      color: Neon.panel,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Heading('Modulation links'),
          const Text('Connect an enabled envelope, LFO, macro or velocity to a synth destination.',
              style: TextStyle(color: Neon.dim, fontSize: 12)),
          const SizedBox(height: 8),
          if (current.isEmpty) const Text('No modulation links yet.', style: TextStyle(color: Neon.dim, fontSize: 13)),
          for (final route in current) ...[
            Row(children: [
              Expanded(child: _choice(route.source, srcs, (v) => replace(route, source: v))),
              const Icon(Icons.arrow_forward, size: 15, color: Neon.dim),
              Expanded(child: _choice(route.destination, dsts, (v) => replace(route, destination: v))),
              IconButton(tooltip: 'Remove link', visualDensity: VisualDensity.compact, onPressed: () => remove(route),
                  icon: const Icon(Icons.close, size: 18, color: Neon.pink)),
            ]),
            Row(children: [
              const Text('Depth / polarity', style: TextStyle(color: Neon.dim, fontSize: 11)),
              Expanded(child: Slider(min: -1, max: 1, divisions: 200, value: route.amount.clamp(-1.0, 1.0),
                  onChanged: (v) => replace(route, amount: v))),
              SizedBox(width: 38, child: Text(route.amount.toStringAsFixed(2), style: Neon.code(size: 11))),
            ]),
          ],
          const Divider(color: Neon.line),
          const Text('Add link', style: TextStyle(color: Neon.text, fontSize: 13, fontWeight: FontWeight.w600)),
          Row(children: [
            Expanded(child: _choice(newSource, srcs, (v) => setState(() => newSource = v))),
            const Icon(Icons.arrow_forward, size: 15, color: Neon.dim),
            Expanded(child: _choice(newDestination, dsts, (v) => setState(() => newDestination = v))),
          ]),
          Row(children: [
            const Text('Depth', style: TextStyle(color: Neon.dim, fontSize: 11)),
            Expanded(child: Slider(min: -1, max: 1, divisions: 200, value: newAmount,
                onChanged: (v) => setState(() => newAmount = v))),
            SizedBox(width: 38, child: Text(newAmount.toStringAsFixed(2), style: Neon.code(size: 11))),
            IconButton(tooltip: 'Add modulation link', onPressed: srcs.isEmpty || dsts.isEmpty ? null : add,
                icon: const Icon(Icons.add_circle, color: Neon.green)),
          ]),
        ]),
      ),
    );
  }

  Widget _choice(String? value, List<String> choices, ValueChanged<String> changed) => DropdownButton<String>(
    isExpanded: true, value: choices.contains(value) ? value : null,
    hint: const Text('Unavailable', style: TextStyle(color: Neon.yellow, fontSize: 12)),
    underline: const SizedBox.shrink(), dropdownColor: Neon.panel,
    style: const TextStyle(color: Neon.text, fontSize: 12),
    items: [for (final v in choices) DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis))],
    onChanged: choices.isEmpty ? null : (v) { if (v != null) changed(v); },
  );
}

class _SidechainCreator extends StatefulWidget {
  const _SidechainCreator({required this.sources, required this.onCreate});
  final List<SignalOption> sources;
  final Future<void> Function(String, double) onCreate;
  @override
  State<_SidechainCreator> createState() => _SidechainCreatorState();
}

class _SidechainCreatorState extends State<_SidechainCreator> {
  String? source;
  double amount = 0.8;
  @override
  Widget build(BuildContext context) {
    source ??= widget.sources.firstOrNull?.value;
    if (!widget.sources.any((s) => s.value == source)) source = widget.sources.firstOrNull?.value;
    return Card(
      color: Neon.panel,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Heading('Sidechain'),
          const Text('Create a dedicated ducking effect after this module on each track that uses it.',
              style: TextStyle(color: Neon.dim, fontSize: 12)),
          const SizedBox(height: 8),
          if (widget.sources.isEmpty)
            const Text('No exported signals are available. Add an export to a module used by a track first.',
                style: TextStyle(color: Neon.yellow, fontSize: 12))
          else ...[
            DropdownButton<String>(
              isExpanded: true, value: source, dropdownColor: Neon.panel,
              style: const TextStyle(color: Neon.text, fontSize: 13),
              items: [for (final s in widget.sources) DropdownMenuItem(value: s.value, child: Text(s.label, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => source = v),
            ),
            Row(children: [
              const Text('Amount', style: TextStyle(color: Neon.dim, fontSize: 12)),
              Expanded(child: Slider(min: 0, max: 1, divisions: 100, value: amount, onChanged: (v) => setState(() => amount = v))),
              SizedBox(width: 38, child: Text(amount.toStringAsFixed(2), style: Neon.code(size: 11))),
            ]),
            Align(alignment: Alignment.centerRight, child: FilledButton.icon(
              onPressed: source == null ? null : () => widget.onCreate(source!, amount),
              icon: const Icon(Icons.add, size: 16), label: const Text('Add sidechain'),
            )),
          ],
        ]),
      ),
    );
  }
}

class _SidechainRoute extends StatelessWidget {
  const _SidechainRoute({required this.current, required this.sources, required this.onChanged, required this.onRemove});
  final String current;
  final List<SignalOption> sources;
  final Future<void> Function(String) onChanged;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) {
    final values = sources.map((s) => s.value).toList();
    return Card(
      color: Neon.panel,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Heading('Sidechain route'),
          const Text('This effect ducks its input when the selected exported signal rises. Amount is in Controls.',
              style: TextStyle(color: Neon.dim, fontSize: 12)),
          DropdownButton<String>(
            isExpanded: true, value: values.contains(current) ? current : null,
            hint: Text('Missing source: $current', style: const TextStyle(color: Neon.yellow, fontSize: 12)),
            dropdownColor: Neon.panel, style: const TextStyle(color: Neon.text, fontSize: 13),
            items: [for (final s in sources) DropdownMenuItem(value: s.value, child: Text(s.label, overflow: TextOverflow.ellipsis))],
            onChanged: (v) { if (v != null) onChanged(v); },
          ),
          Align(alignment: Alignment.centerRight, child: TextButton.icon(
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline, color: Neon.pink, size: 16),
            label: const Text('Remove sidechain', style: TextStyle(color: Neon.pink)),
          )),
        ]),
      ),
    );
  }
}
