// The device header's ⋯ menu (device shell): copy and paste settings, randomize by an amount, this device's undo history, auto gain and reset.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/device_history.dart';
import '../../../model/device_slot_audio.dart';
import '../../../model/device_target.dart';
import '../../../model/merged_devices.dart' show MergedDevices, variantParam;
import '../../../model/variant_edit.dart';
import '../../arrange/knob.dart' show Taper;
import '../../arrange/long_press_menu.dart';
import '../../panel_motion.dart';
import '../../theme.dart';
import '../device_registry.dart';
import 'feel.dart';
import 'presets.dart';

/// Settings copied from a device: its component and values. Paste takes them into a device of the same component
/// (a merged device's variant comes with them).
class DeviceClipboard {
  DeviceClipboard._();
  static ({String componentId, String label, Map<String, double> values})? _copied;

  static void copy(DeviceTarget t) {
    final info = t.info, id = t.componentId;
    if (info == null || id == null) return;
    _copied = (componentId: id, label: t.label, values: {for (final p in info.parameters) p.id: t.value(p.id)});
  }

  /// Why [t] can't take the copied settings, or null when it can.
  static String? whyNoPaste(DeviceTarget t) {
    final c = _copied;
    if (c == null) return 'Copy a device\'s settings first';
    if (c.componentId != t.componentId) return 'The copied settings are ${c.label}\'s';
    return null;
  }

  /// Pastes into [t] as one undo step; false when it can't ([whyNoPaste]).
  static bool paste(DeviceTarget t) {
    final c = _copied;
    if (c == null || whyNoPaste(t) != null) return false;
    t.state.endUndoStep();
    // A merged device's variant first (it decides which knobs there are), then the values.
    final v = c.values[variantParam];
    if (v != null && MergedDevices.isMerged(c.componentId) && (t.value(variantParam) - v).abs() > 1e-9) {
      t.state.setDeviceVariant(t, v.round());
    }
    t.setAll({for (final e in c.values.entries) if (e.key != variantParam) e.key: e.value});
    t.state.endUndoStep();
    return true;
  }

  @visibleForTesting
  static void clear() => _copied = null;
}

/// How far Randomize moves the knobs (0..1 of each knob's travel), kept for the next time.
double randomizeAmount = 0.3;

/// Moves every sound parameter of [t] up to [amount] of its travel from where it is (a choice changes with that
/// chance), as one undo step. A merged device's variant, view-only parameters and what the device's editor keeps
/// ([DeviceEditorEntry.randomKeeps]: Flagship's matrix, power switches and volume) stay.
void randomizeDevice(DeviceTarget t, double amount, {math.Random? random}) {
  final info = t.info, id = t.componentId;
  if (info == null || id == null) return;
  final keeps = DeviceEditors.of(id, info).randomKeeps;
  final r = random ?? math.Random();
  final next = <String, double>{};
  for (final p in info.parameters) {
    if (p.id == variantParam || DevicePresets.viewOnly.contains(p.id) || p.id.endsWith('.$variantParam')) continue;
    if (keeps != null && keeps(p.id)) continue;
    if (!p.automatable && !p.modulatable) continue;
    final now = t.value(p.id);
    if (p.isChoice || p.step > 0) {
      if (r.nextDouble() >= amount) continue;
      final n = ((p.max - p.min) / (p.step > 0 ? p.step : 1)).round();
      if (n <= 0) continue;
      next[p.id] = p.min + r.nextInt(n + 1) * (p.step > 0 ? p.step : 1);
      continue;
    }
    final taper = Taper(p.min, p.max, exponential: p.exponential);
    final pos = (taper.position(now) + (r.nextDouble() * 2 - 1) * amount).clamp(0.0, 1.0);
    next[p.id] = taper.value(pos);
  }
  t.state.endUndoStep();
  t.setAll(next);
  t.state.endUndoStep();
}

/// The header's ⋯ › Reset: the device's own when its editor has one (Flagship: Init), else every knob to its
/// default; one undo step.
void resetDevice(DeviceTarget t) {
  final id = t.componentId;
  final own = id == null ? null : DeviceEditors.of(id, t.info).reset;
  if (own != null) return own(t);
  t.state.endUndoStep();
  t.resetAll();
  t.state.endUndoStep();
}

void _say(BuildContext context, String text) => ScaffoldMessenger.maybeOf(context)
  ?..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(duration: const Duration(seconds: 2), content: Text(text)));

/// The ⋯ menu of [t]'s header.
Future<void> showDeviceMenu(BuildContext context, DeviceTarget t, Color color) async {
  final paste = DeviceClipboard.whyNoPaste(t);
  final audio = DeviceSlotAudio.current;
  final gain = DeviceSlotAudio.autoGainFor(t);
  final v = await showLongPressMenu<String>(context, at: menuAnchorOf(context), title: t.label, actions: [
    const MenuAction('copy', 'Copy settings', Icons.copy),
    MenuAction('paste', 'Paste settings', Icons.content_paste, enabled: paste == null, hint: paste),
    const MenuAction('random', 'Randomize…', Icons.casino_outlined),
    const MenuAction('history', 'Undo history…', Icons.history),
    if (gain) MenuAction('gain', 'Auto gain', Icons.hearing, checked: audio!.autoGain(t)),
    const MenuAction('reset', 'Reset', Icons.restart_alt),
  ]);
  if (v == null || !context.mounted) return;
  DeviceFeel.tap();
  switch (v) {
    case 'copy':
      DeviceClipboard.copy(t);
      _say(context, 'Copied ${t.label}\'s settings');
    case 'paste':
      if (DeviceClipboard.paste(t)) _say(context, 'Pasted into ${t.label}');
    case 'random':
      await showRandomize(context, t, color);
    case 'history':
      await showDeviceHistory(context, t, color);
    case 'gain':
      DeviceSlotAudio.toggleAutoGain(t);
    case 'reset':
      resetDevice(t);
  }
}

/// Randomize: an amount slider and a button that rolls again (each roll one undo step).
Future<void> showRandomize(BuildContext context, DeviceTarget t, Color color) => showDialog<void>(
  context: context, animationStyle: dialogAnimation(context),
  builder: (context) => StatefulBuilder(builder: (context, setState) => AlertDialog(
    key: const ValueKey('device-randomize'),
    title: Text('Randomize ${t.label}', style: const TextStyle(fontSize: 15)),
    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Text('Amount', style: TextStyle(fontSize: 12, color: Neon.dim)),
        const Spacer(),
        Text('${(randomizeAmount * 100).round()}%', key: const ValueKey('device-randomize-amount'),
          style: Neon.code(size: 12, color: color)),
      ]),
      Slider(
        key: const ValueKey('device-randomize-slider'),
        value: randomizeAmount,
        activeColor: color,
        onChanged: (x) => setState(() => randomizeAmount = x),
      ),
      const Text('Small amounts nudge the sound; 100% can land anywhere. Each roll is one undo step.',
        style: TextStyle(fontSize: 11, color: Neon.dim)),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      FilledButton.icon(
        key: const ValueKey('device-randomize-go'),
        style: FilledButton.styleFrom(backgroundColor: color.withValues(alpha: 0.85), foregroundColor: Neon.bg),
        onPressed: () {
          DeviceFeel.detent();
          randomizeDevice(t, randomizeAmount);
        },
        icon: const Icon(Icons.casino_outlined, size: 16),
        label: const Text('Roll')),
    ],
  )),
);

/// This device's steps in the project's undo history, newest first; a tap brings the device back to how it was
/// before that step (one new undo step; the rest of the project stays as it is).
Future<void> showDeviceHistory(BuildContext context, DeviceTarget t, Color color) {
  t.state.endUndoStep();  // an edit still settling is the last change, its own step
  final steps = deviceHistory(t);
  final info = t.info;
  String names(List<String> ids) {
    final labels = [for (final id in ids) info?.param(id)?.label ?? id];
    return labels.length <= 3 ? labels.join(', ') : '${labels.take(3).join(', ')} +${labels.length - 3}';
  }
  return showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: sheetAnimation(context),
    showDragHandle: true,
    backgroundColor: Neon.panel,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (context) => SafeArea(child: Column(key: const ValueKey('device-history'), mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 6), child: Text('${t.label}: undo history',
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800))),
      if (steps.isEmpty) const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 24), child: Text(
        'No changes to this device in the undo history yet.', style: TextStyle(color: Neon.dim)))
      else Flexible(child: ListView(shrinkWrap: true, children: [
        for (final (i, s) in steps.indexed) ListTile(
          key: ValueKey('device-history-$i'),
          dense: true,
          leading: Icon(i == 0 ? Icons.undo : Icons.history, size: 18, color: color),
          title: Text(i == 0 ? 'Before the last change' : 'Before change ${i + 1}',
            style: const TextStyle(fontSize: 13)),
          subtitle: Text('${names(s.changed)} · ${s.stepsBack} step${s.stepsBack == 1 ? '' : 's'} back',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Neon.dim)),
          onTap: () {
            DeviceFeel.tap();
            final i = t.info;
            if (i != null) {
              t.state.endUndoStep();
              t.setAll({for (final p in i.parameters) if (p.id != variantParam) p.id: s.values[p.id] ?? p.defaultValue});
              t.state.endUndoStep();
            }
            Navigator.of(context).maybePop();
          },
        ),
      ])),
    ])),
  );
}
