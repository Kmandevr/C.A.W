// The fallback device page for a component with no editor of its own: every parameter as the FX stack's knobs and choices.
import 'package:flutter/material.dart';

import '../../model/arrange_fx.dart' show isBuiltinComponent;
import '../arrange/knob.dart';
import '../theme.dart';
import 'device_scope.dart';

/// The same knobs the FX card shows (owner: "strictly a fallback if there's no UI built in"), on a full page.
class GenericDevicePage extends StatelessWidget {
  const GenericDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final info = t.info;
    final use = t.use;
    if (info == null || use == null) return const SizedBox.shrink();
    if (info.parameters.isEmpty) {
      return const Center(child: Text('No knobs', style: TextStyle(color: Neon.dim)));
    }
    final color = isBuiltinComponent(use.id) ? Neon.blue : Neon.green;
    return SingleChildScrollView(
      key: const ValueKey('device-fallback'),
      padding: const EdgeInsets.all(12),
      child: Wrap(spacing: 2, runSpacing: 4, children: [
        for (final p in info.parameters)
          if (p.isChoice)
            SizedBox(width: 96, height: 62, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              DropdownButton<int>(
                value: (t.value(p.id) - p.min).round().clamp(0, p.choices.length - 1),
                isDense: true,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                style: const TextStyle(fontSize: 11, color: Neon.text),
                items: [for (var k = 0; k < p.choices.length; k++) DropdownMenuItem(value: k, child: Text(p.choices[k],
                  maxLines: 1, overflow: TextOverflow.ellipsis))],
                onChanged: (k) { if (k != null) t.set(p.id, p.min + k); },
              ),
              Text(p.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9, color: Neon.dim)),
            ]))
          else
            Knob(key: ValueKey('knob-${use.id}-${p.id}'), value: t.value(p.id),
              min: p.min, max: p.max, step: p.step, defaultValue: p.defaultValue, label: p.label,
              exponential: p.exponential,
              enabled: !use.bypass,
              color: color,
              valueText: (v) => '${v.toStringAsFixed(p.max - p.min > 20 ? 0 : 2)}${p.unit.isEmpty ? '' : ' ${p.unit}'}',
              onChanged: (v) => t.setLive(p.id, v),
              onChangeEnd: t.commit),
      ]),
    );
  }
}
