// Rook's kit kinds up front (1.1.3): three cards over the pads, Synth, Produced and Acoustic; a tap switches to that kind's best kit, a tap on the kind playing opens its kits and builds a new one, and the Randomness knob beside Randomize.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/device_target.dart';
import '../../../model/drums.dart';
import '../../arrange/long_press_menu.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../../feedback.dart';
import '../kit/feel.dart';
import '../kit/presets.dart';
import 'drums_pads.dart';

/// Each kind's card: its icon and the line under its name when another kind plays.
const _kindIcons = [Icons.graphic_eq, Icons.equalizer, Icons.album_outlined];
const _kindBlurbs = ['808 to glitch', 'House to pop', 'Studio to jazz'];

/// The style a preset of [kind] names ("Acoustic kit: Studio" → "Studio"), or null.
String? drumKindStyle(int kind, String? preset) {
  final prefix = '${drumKitKinds[kind]} kit: ';
  return preset != null && preset.startsWith(prefix) ? preset.substring(prefix.length) : null;
}

/// Loads [kind]'s best kit ([drumKindDefaults]) as one undo step. False when the device has no such preset.
bool loadDrumKind(DeviceTarget t, int kind) => loadDrumPreset(t, drumKindDefaults[kind]);

/// Loads the engine preset [name] onto the instrument (one undo step).
bool loadDrumPreset(DeviceTarget t, String name) {
  final p = DevicePresets.factory(t).where((p) => p.name == name).firstOrNull;
  if (p == null) return false;
  DevicePresets.apply(t, p);
  return true;
}

/// The three kind cards in a row ([height] tall), the playing kind lit.
class DrumKindBar extends StatelessWidget {
  const DrumKindBar({super.key, this.height = 44});
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final kind = drumKindOf(t);
    final current = DevicePresets.current(t)?.name;
    return SizedBox(key: const ValueKey('drum-kinds'), height: height, child: Row(children: [
      for (var k = 0; k < drumKitKinds.length; k++)
        Expanded(child: Padding(padding: EdgeInsets.only(left: k == 0 ? 0 : 6), child: _KindCard(
          kind: k, selected: k == kind, style: k == kind ? drumKindStyle(k, current) : null))),
    ]));
  }
}

class _KindCard extends StatelessWidget {
  const _KindCard({required this.kind, required this.selected, this.style});
  final int kind;
  final bool selected;
  final String? style;

  static final _random = math.Random();

  Future<void> _kits(BuildContext context, DeviceTarget t) async {
    final box = context.findRenderObject() as RenderBox;
    final at = box.localToGlobal(box.size.bottomCenter(Offset.zero));
    final prefix = '${drumKitKinds[kind]} kit: ';
    final presets = [for (final p in DevicePresets.factory(t)) if (p.name.startsWith(prefix)) p.name];
    final styles = DrumsApi.current.builders()?[drumKitKinds[kind].toLowerCase()] ?? const <String>[];
    final pick = await showLongPressMenu<String>(context, at: at, title: '${drumKitKinds[kind]} kits', actions: [
      for (final name in presets)
        MenuAction(name, name.substring(prefix.length), _kindIcons[kind], checked: style == name.substring(prefix.length)),
      if (styles.isNotEmpty) MenuAction('#new', 'New ${drumKitKinds[kind]} kit from a random seed', Icons.auto_awesome),
    ]);
    if (pick == null || !context.mounted) return;
    if (pick == '#new') {
      final s = math.max(0, styles.indexOf(style ?? ''));
      final ok = buildDrumKit(t, kind: kind, style: s, seed: _random.nextInt(1 << 31));
      drumsToast(context, ok ? 'New ${drumKitKinds[kind]} kit (${styles[s]}) · Undo restores' : 'Needs the engine');
    } else {
      loadDrumPreset(t, pick);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final c = scope.accent;
    final level = Motion.of(context);
    final name = drumKitKinds[kind];
    return Semantics(button: true, selected: selected, label: '$name kit', child: GestureDetector(
      key: ValueKey('drum-kind-$kind'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        DeviceFeel.tap();
        if (selected) {
          _kits(context, t);
        } else if (!loadDrumKind(t, kind)) {
          drumsToast(context, 'No $name kit in this engine');
        }
      },
      child: Pressable(glow: c, child: AnimatedContainer(
        duration: Motion.fade(Motion.standard, level),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: selected ? c.withValues(alpha: 0.2) : Neon.ink.withValues(alpha: 0.03),
          border: Border.all(color: selected ? c : Neon.line, width: selected ? 1.5 : 1),
          boxShadow: selected ? [BoxShadow(color: c.withValues(alpha: 0.32), blurRadius: 10)] : null),
        child: Row(children: [
          AnimatedScale(
            duration: Motion.fade(Motion.standard, level),
            scale: selected ? 1.0 : 0.85,
            child: Icon(_kindIcons[kind], size: 18, color: selected ? c : Neon.dim)),
          const SizedBox(width: 6),
          Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name.toUpperCase(), maxLines: 1, overflow: TextOverflow.fade, softWrap: false,
              style: TextStyle(fontSize: 11, letterSpacing: 1.1, fontWeight: FontWeight.w900, color: selected ? Neon.text : Neon.dim)),
            AnimatedSwitcher(
              duration: Motion.fade(Motion.standard, level),
              child: Text(style ?? (selected ? 'Edited' : _kindBlurbs[kind]), key: ValueKey('drum-kind-style-$kind-${style ?? ''}'),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: selected ? c : Neon.dim))),
          ])),
          AnimatedOpacity(
            duration: Motion.fade(Motion.standard, level),
            opacity: selected ? 1 : 0,
            child: Icon(Icons.expand_more, size: 16, color: c)),
        ]),
      )),
    ));
  }
}

/// The Randomness knob (the kit's `randomness`): how far the dice move a pad.
class DrumRandomnessKnob extends StatelessWidget {
  const DrumRandomnessKnob({super.key, this.size = 26});
  final double size;

  @override
  Widget build(BuildContext context) =>
      DeviceKnob(drumRandomnessId, label: 'Randomness', size: size, labels: false, valueText: (v) => '${(v * 100).round()} %');
}
