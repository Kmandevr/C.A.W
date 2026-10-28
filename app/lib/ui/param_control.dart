// One inspector row for a param or global: a slider (with steps), a toggle or a dropdown, with its tip on long-press or hover.
import 'package:flutter/material.dart';

import '../engine/engine.dart';
import 'theme.dart';
import 'widgets.dart';

class ParamControl extends StatelessWidget {
  const ParamControl({super.key, required this.param, required this.value, required this.color, required this.onChanged});
  final ParamInfo param;
  final double value;
  final Color color;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = param;
    final v = value.clamp(p.min, p.max).toDouble();
    final label = Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis, style: Neon.code(size: 14))),
      if (p.global) ...[
        const SizedBox(width: 4),
        const Icon(Icons.public, size: 14, color: Neon.blue),
      ],
    ]);
    final Widget control;
    switch (p.kind) {
      case ParamKind.toggle:
        control = Align(
          alignment: Alignment.centerLeft,
          child: Switch(value: v >= 0.5, activeThumbColor: color, onChanged: (on) => onChanged(on ? 1 : 0)),
        );
      case ParamKind.choice:
        final idx = v.round().clamp(0, p.choices.length - 1);
        control = p.choices.length <= 4
            ? Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [
                    for (var i = 0; i < p.choices.length; i++) ButtonSegment(value: i, label: Text(p.choices[i])),
                  ],
                  selected: {idx},
                  onSelectionChanged: (s) => onChanged(s.first.toDouble()),
                ),
              )
            : DropdownButton<int>(
                value: idx,
                items: [for (var i = 0; i < p.choices.length; i++) DropdownMenuItem(value: i, child: Text(p.choices[i]))],
                onChanged: (i) => onChanged((i ?? 0).toDouble()),
              );
      case ParamKind.number:
        final divisions = p.step > 0 ? ((p.max - p.min) / p.step).round() : null;
        control = Row(children: [
          Expanded(
            child: Slider(
              min: p.min,
              max: p.max,
              divisions: divisions != null && divisions > 0 && divisions <= 1000 ? divisions : null,
              activeColor: color,
              value: v,
              onChanged: onChanged,
            ),
          ),
          GestureDetector(
            onDoubleTap: () => onChanged(p.defaultValue),
            child: SizedBox(
              width: 60,
              child: Text(formatParam(v, p), textAlign: TextAlign.right, style: Neon.code(size: 14, color: color)),
            ),
          ),
        ]);
    }
    final row = Row(children: [SizedBox(width: 96, child: label), Expanded(child: control)]);
    return p.help.isEmpty
        ? row
        : Tooltip(message: p.help, triggerMode: TooltipTriggerMode.longPress, waitDuration: const Duration(milliseconds: 400), child: row);
  }
}

/// A list of controls grouped under their `// --- Header ---` names.
class ParamGroups extends StatelessWidget {
  const ParamGroups({super.key, required this.params, required this.valueOf, required this.color, required this.onChanged});
  final List<ParamInfo> params;
  final double Function(ParamInfo) valueOf;
  final Color color;
  final void Function(ParamInfo, double) onChanged;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    String? header;
    for (final p in params) {
      if (p.header != header) {
        header = p.header;
        if (header.isNotEmpty) children.add(Heading(header));
      }
      children.add(ParamControl(param: p, value: valueOf(p), color: color, onChanged: (v) => onChanged(p, v)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}
