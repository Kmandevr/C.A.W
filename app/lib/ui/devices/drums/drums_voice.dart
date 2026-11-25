// The drums' picked pad: its header (type, dice, mutate, menu), its hero, the Character strip of macro knobs, and the note map's note picker and Learn.
import 'package:flutter/material.dart';

import '../../../engine/component_info.dart';
import '../kit/param_watch.dart';
import '../../../model/device_target.dart';
import '../../../model/drums.dart';
import '../../feedback.dart';
import '../../glass.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/feel.dart';
import 'drums_hero.dart';
import 'drums_kinds.dart';
import 'drums_pads.dart';

/// A knob's label inside its card: the descriptor's name without the pad ("A1 ") and the layer's own word.
String drumKnobLabel(ComponentParameterInfo p) {
  var s = p.label.replaceFirst(RegExp(r'^[A-D]\d+ '), '');
  for (final w in const ['Body ', 'Sub ', 'Click ', 'Noise ', 'Metal ', 'Resonator ', 'Sample ', 'Pressure to ',
    'Velocity to ', 'Random ', 'Drive ', 'EQ ', 'Filter ', 'Compressor ', 'Transient ', 'Clipper ', 'FM ', 'Physical ',
    'Texture ']) {
    if (s.startsWith(w) && s.length > w.length) {
      s = s.substring(w.length);
      break;
    }
  }
  return s.isEmpty ? p.label : s[0].toUpperCase() + s.substring(1);
}

/// The picked pad's header row: its name and type, then Randomize (dice), Mutate, the Randomness knob and its menu.
class DrumVoiceHeader extends StatelessWidget {
  const DrumVoiceHeader({super.key, required this.pad});
  final int pad;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final layout = drumsLayout(t);
    final p = DrumPadView(t, layout, pad);
    final c = p.used ? drumTypeColor(p.v('type').round()) : scope.accent;
    return SizedBox(height: 44, child: Row(children: [
      Container(
        width: 40, height: 32, alignment: Alignment.center,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(9), color: c.withValues(alpha: 0.18),
          border: Border.all(color: c), boxShadow: [BoxShadow(color: c.withValues(alpha: 0.3), blurRadius: 8)]),
        child: Text(padLabel(pad), key: const ValueKey('drum-voice-pad'),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Neon.text))),
      const SizedBox(width: 8),
      Expanded(child: Align(alignment: Alignment.centerLeft, child: DeviceChoice(p.id('type'), color: c))),
      _DiceButton(key: const ValueKey('drum-randomize'), icon: Icons.casino_outlined, tooltip: 'Randomize ${padLabel(pad)}',
        color: c, onTap: () {
          if (!randomizePad(t, layout, pad)) drumsToast(context, 'Randomize needs the engine');
        }),
      _DiceButton(key: const ValueKey('drum-mutate'), icon: Icons.auto_fix_high, tooltip: 'Mutate ${padLabel(pad)}',
        color: c, onTap: () {
          if (!mutatePad(t, layout, pad)) drumsToast(context, 'Mutate needs the engine');
        }),
      const DrumRandomnessKnob(),
      Builder(builder: (context) => IconButton(
        key: const ValueKey('drum-pad-menu'),
        tooltip: 'Pad menu',
        icon: const Icon(Icons.more_vert, size: 20),
        onPressed: () {
          final box = context.findRenderObject() as RenderBox;
          showDrumPadMenu(context, t, pad, box.localToGlobal(box.size.center(Offset.zero)));
        })),
    ]));
  }
}

class _DiceButton extends StatelessWidget {
  const _DiceButton({super.key, required this.icon, required this.tooltip, required this.color, required this.onTap});
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(glow: color, circle: true, child: IconButton(
    tooltip: tooltip,
    iconSize: 20,
    color: color,
    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    onPressed: () {
      DeviceFeel.tap();
      onTap();
    },
    icon: Icon(icon, shadows: [Shadow(color: color, blurRadius: 6)])));
}

/// The Character macros (Punch, Tone, Snap, Length, Dirt, Pitch) of [pad], in one row of knobs.
class DrumCharacterStrip extends StatelessWidget {
  const DrumCharacterStrip({super.key, required this.pad, this.size = 38});
  final int pad;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final layout = drumsLayout(t);
    final ids = [for (final m in drumMacros) layout.id(pad, m)];
    return Container(
      key: const ValueKey('drum-character'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: Neon.ink.withValues(alpha: 0.03),
        border: Border.all(color: Neon.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const Text('CHARACTER', style: TextStyle(fontSize: 9, letterSpacing: 1.4, fontWeight: FontWeight.w900, color: Neon.dim)),
        // One row of six on any phone: scaled down a little below about 360 dp rather than wrapped.
        FittedBox(fit: BoxFit.scaleDown, child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < ids.length; i++) DeviceKnob(ids[i], size: size, label: _macroLabels[i]),
        ])),
      ]),
    );
  }

  static const _macroLabels = ['Punch', 'Tone', 'Snap', 'Length', 'Dirt', 'Pitch'];
}

/// The voice of [pad] above its cards: header, hero and Character strip.
class DrumVoiceTop extends StatelessWidget {
  const DrumVoiceTop({super.key, required this.pad, this.heroHeight = 190});
  final int pad;
  final double heroHeight;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min,
    children: [
      DrumVoiceHeader(pad: pad),
      watchDevice(context, (_) => DrumHero(pad: pad, height: heroHeight)), // its own watch (param_watch.dart)
      DrumCharacterStrip(pad: pad),
    ]);
}

/// The pad's note in the map: a chip that opens a picker of every key (and Auto, Off, Any other).
class DrumNoteButton extends StatelessWidget {
  const DrumNoteButton({super.key, required this.pad});
  final int pad;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final layout = drumsLayout(t);
    final id = layout.id(pad, 'note');
    final text = formatParamValue(t.param(id), t.value(id));
    final auto = t.value(id).round() == 0;
    return Pressable(glow: scope.accent, child: OutlinedButton(
      key: ValueKey('drum-note-$pad'),
      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: scope.accent),
      onPressed: () => showDrumNotePicker(context, t, pad),
      child: Text(auto ? 'Auto · ${noteName(padNote(t, layout, pad) ?? 0)}' : text)));
  }
}

/// A sheet of every note for pad [pad]'s map: Auto, Off, Any other, then the keys by octave.
Future<void> showDrumNotePicker(BuildContext context, DeviceTarget t, int pad) => showGlassSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) {
    final layout = drumsLayout(t);
    final id = layout.id(pad, 'note');
    final now = t.value(id).round();
    void pick(int v) {
      DeviceFeel.tap();
      t.set(id, v.toDouble());
      Navigator.of(context).maybePop();
    }
    Widget chip(int v, String label) => Padding(padding: const EdgeInsets.all(2), child: ChoiceChip(
      key: ValueKey('drum-note-pick-$v'),
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: now == v,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => pick(v)));
    return FractionallySizedBox(heightFactor: 0.6, child: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 16), children: [
      Text('NOTE · ${padLabel(pad)}', style: const TextStyle(fontSize: 12, letterSpacing: 1.4, fontWeight: FontWeight.w800)),
      Wrap(children: [chip(0, 'Auto'), chip(1, 'Off'), chip(2, 'Any other')]),
      for (var o = 0; o < 11; o++)
        Wrap(children: [for (var k = o * 12; k < o * 12 + 12 && k < 128; k++) chip(3 + k, noteName(k))]),
    ]));
  },
);

/// Learn: the pad listens for the next MIDI note and takes it as its note.
class DrumLearnButton extends StatelessWidget {
  const DrumLearnButton({super.key, required this.pad});
  final int pad;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final sel = DrumsSelection.of(t);
    return ValueListenableBuilder<int?>(valueListenable: sel.learning, builder: (context, learning, _) {
      final on = learning == pad;
      return Pressable(glow: Neon.yellow, child: OutlinedButton.icon(
        key: ValueKey('drum-learn-$pad'),
        style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact,
          foregroundColor: on ? Neon.yellow : Neon.dim, side: BorderSide(color: on ? Neon.yellow : Neon.line)),
        onPressed: () => toggleLearn(context, t, pad),
        icon: Icon(on ? Icons.hearing : Icons.hearing_outlined, size: 16),
        label: Text(on ? 'Listening…' : 'Learn')));
    });
  }
}
