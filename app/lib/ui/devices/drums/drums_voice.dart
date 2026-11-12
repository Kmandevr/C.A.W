// The drums' voice under the grid: the picked pad's header (type, dice, mutate), the hero, the Character strip of macro knobs, and its layers as cards that open in place, each with its on/off.
import 'package:flutter/material.dart';

import '../../../engine/component_info.dart';
import '../../../model/device_target.dart';
import '../../../model/drums.dart';
import '../../feedback.dart';
import '../../glass.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../flagship/flagship_editor.dart' show LabeledRow;
import '../kit/controls.dart';
import '../kit/feel.dart';
import 'drums_hero.dart';
import 'drums_pads.dart';
import 'drums_samples.dart';

/// The cards under the Character strip, in the owner's order (2026-11-11), the pad's own settings first.
const drumCardOrder = ['pad', 'body', 'penv', 'sub', 'click', 'noise', 'metal', 'res', 'smp', 'drive', 'filter', 'eq',
  'dyn', 'space', 'press', 'var'];

/// A knob's label inside its card: the descriptor's name without the pad ("A1 ") and the layer's own word.
String drumKnobLabel(ComponentParameterInfo p) {
  var s = p.label.replaceFirst(RegExp(r'^[A-D]\d+ '), '');
  for (final w in const ['Body ', 'Sub ', 'Click ', 'Noise ', 'Metal ', 'Resonator ', 'Sample ', 'Pressure to ',
    'Velocity to ', 'Random ', 'Drive ', 'EQ ', 'Filter ', 'Compressor ', 'Transient ', 'Clipper ']) {
    if (s.startsWith(w) && s.length > w.length) {
      s = s.substring(w.length);
      break;
    }
  }
  return s.isEmpty ? p.label : s[0].toUpperCase() + s.substring(1);
}

/// The picked pad's header row: its name and type, then Randomize (dice), Mutate and its menu.
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
      DrumHero(pad: pad, height: heroHeight),
      DrumCharacterStrip(pad: pad),
    ]);
}

/// The last non-Off choice of a choice-switched layer (drive type, filter), so its power button brings it back.
final Map<String, double> _lastOn = {};

/// One layer of [pad] as a card that opens in place: its power, what it is set to, a dice and a mutate for the layer
/// alone, and its controls.
class DrumLayerCard extends StatelessWidget {
  const DrumLayerCard({super.key, required this.pad, required this.layer});
  final int pad;
  final DrumLayer layer;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final layout = drumsLayout(t);
    final p = DrumPadView(t, layout, pad);
    final on = p.layerOn(layer);
    final c = layer.id == 'pad' ? scope.accent : (layer.id == 'press' || layer.id == 'var' ? scope.secondary : scope.accent);
    final power = layer.power;
    return DeviceExpandCard(
      key: ValueKey('drum-layer-${layer.id}'),
      storageId: 'drums-layer-${layer.id}',
      title: layer.name.toUpperCase(),
      summary: _summary(t, p, layer),
      color: c,
      dimmed: !on,
      initiallyOpen: layer.id == 'body',
      leading: power == null ? null : (power.endsWith('_on') ? DevicePower(p.id(power), color: c)
          : _ChoicePower(id: p.id(power), color: c)),
      actions: layer.id == 'pad' ? const [] : [
        _LayerDice(pad: pad, layer: layer, mutate: false),
        _LayerDice(pad: pad, layer: layer, mutate: true),
      ],
      child: _LayerBody(pad: pad, layer: layer),
    );
  }

  static String _summary(DeviceTarget t, DrumPadView p, DrumLayer layer) {
    String f(String s) => formatParamValue(t.param(p.id(s)), p.v(s));
    String parts(List<String> s) => [for (final x in s) f(x)].join(' · ');
    if (!p.layerOn(layer)) return 'Off';
    return switch (layer.id) {
      'pad' => '${f('note')} · ch ${f('chan')} · choke ${f('choke')}',
      'body' => parts(['body_wave', 'body_freq', 'body_decay']),
      'penv' => p.v('penv_mode').round() == 1 ? 'Points · ${f('penv_t1')} · ${f('penv_t2')} · ${f('penv_t3')}'
          : 'Curve · ${f('body_pitch')} over ${f('body_ptime')}',
      'sub' => parts(['sub_wave', 'sub_oct', 'sub_decay']),
      'click' => parts(['click_type', 'click_tone', 'click_length']),
      'noise' => parts(['noise_mode', 'noise_color', 'noise_decay']),
      'metal' => parts(['metal_mode', 'metal_set', 'metal_decay']),
      'res' => parts(['res_model', 'res_freq', 'res_decay']),
      'smp' => padSample(t, p.pad)?.label ?? 'No sample',
      'drive' => parts(['drive_type', 'drive']),
      'filter' => parts(['flt', 'cutoff']),
      'eq' => 'Low ${f('eq_low')} · Mid ${f('eq_mid')} · High ${f('eq_high')}',
      'dyn' => 'Comp ${f('comp')} · Clip ${f('clip')}',
      'space' => 'Width ${f('width')} · Room ${f('room_send')}',
      'press' => 'Damp ${f('press_damp')} · Tone ${f('press_tone')}',
      'var' => 'Vel ${f('vel_level')} · Random ${f('rnd_pitch')}',
      _ => '',
    };
  }
}

/// A layer switched by a choice whose first value is Off (drive type, filter type): off, or back to its last type.
class _ChoicePower extends StatelessWidget {
  const _ChoicePower({required this.id, required this.color});
  final String id;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final v = t.value(id);
    final on = v >= 0.5;
    return IconButton(
      key: ValueKey('dpower-$id'),
      tooltip: on ? 'Turn off' : 'Turn on',
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      color: on ? color : Neon.dim,
      onPressed: () {
        DeviceFeel.tap();
        if (on) _lastOn[id] = v;
        t.set(id, on ? 0 : (_lastOn[id] ?? 1));
      },
      icon: Icon(Icons.power_settings_new, shadows: on ? [Shadow(color: color, blurRadius: 6)] : null));
  }
}

/// Randomize or mutate one layer of a pad: the engine's new sound for the pad, applied to that layer's knobs only.
class _LayerDice extends StatelessWidget {
  const _LayerDice({required this.pad, required this.layer, required this.mutate});
  final int pad;
  final DrumLayer layer;
  final bool mutate;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return Pressable(glow: scope.accent, radius: 16, child: ActionChip(
      key: ValueKey('drum-layer-${mutate ? 'mutate' : 'dice'}-${layer.id}'),
      avatar: Icon(mutate ? Icons.auto_fix_high : Icons.casino_outlined, size: 15, color: scope.accent),
      label: Text(mutate ? 'Mutate' : 'Randomize', style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      backgroundColor: Colors.transparent,
      side: BorderSide(color: scope.accent.withValues(alpha: 0.45)),
      onPressed: () {
        DeviceFeel.tap();
        final layout = drumsLayout(t);
        final ok = mutate ? mutatePad(t, layout, pad, layer: layer) : randomizePad(t, layout, pad, layer: layer);
        if (!ok) drumsToast(context, '${mutate ? 'Mutate' : 'Randomize'} needs the engine');
      }));
  }
}

/// A layer's controls: its choices as segments or menus, its Off/On switches as pills, its knobs in rows; the pad's
/// own settings add the note map with Learn, the pitch shape its four points, the sample its picker.
class _LayerBody extends StatelessWidget {
  const _LayerBody({required this.pad, required this.layer});
  final int pad;
  final DrumLayer layer;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final layout = drumsLayout(t);
    String id(String s) => layout.id(pad, s);
    final skip = {?layer.power, if (layer.id == 'pad') ...['note', 'chan']};
    final params = [for (final s in layer.suffixes) if (!skip.contains(s)) ?t.param(id(s))];
    final children = <Widget>[];
    if (layer.id == 'pad') {
      children.addAll([
        LabeledRow('NOTE', Row(mainAxisSize: MainAxisSize.min, children: [
          DrumNoteButton(pad: pad),
          const SizedBox(width: 6),
          DrumLearnButton(pad: pad),
        ])),
        LabeledRow('CHANNEL', DeviceChoice(id('chan'), maxSegments: 0)),
      ]);
    }
    if (layer.id == 'penv') {
      children.add(LabeledRow('SHAPE', DeviceChoice(id('penv_mode'))));
      children.add(const Padding(padding: EdgeInsets.only(bottom: 2), child: Text(
        'Points: drag them on the hero (double-tap it to switch). Curve: the Body\'s pitch envelope, time and curve.',
        style: TextStyle(fontSize: 10, color: Neon.dim))));
      for (var i = 1; i <= 4; i++) {
        children.add(KnobRow([id('penv_t$i'), id('penv_p$i'), id('penv_c$i')], size: 40,
          labels: {id('penv_t$i'): 'Time $i', id('penv_p$i'): 'Pitch $i', id('penv_c$i'): 'Curve $i'}));
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);
    }
    if (layer.id == 'smp') {
      final sample = padSample(t, pad);
      children.add(Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
        Expanded(child: Text(sample?.label ?? 'No sample loaded', maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: sample == null ? Neon.dim : Neon.text))),
        Pressable(child: OutlinedButton.icon(
          key: const ValueKey('drum-sample-load'),
          onPressed: () => showDrumSamplePicker(context, t, pad),
          icon: const Icon(Icons.graphic_eq, size: 16),
          label: const Text('Load sample…'))),
      ])));
    }
    final toggles = [for (final p in params) if (p.isChoice && p.choices.length == 2 && p.choices.first == 'Off') p];
    final choices = [for (final p in params) if (p.isChoice && !toggles.contains(p)) p];
    final knobs = [for (final p in params) if (!p.isChoice) p];
    for (final p in choices) {
      children.add(LabeledRow(drumKnobLabel(p).toUpperCase(), DeviceChoice(p.id, maxSegments: p.choices.length <= 4 ? 4 : 0)));
    }
    if (toggles.isNotEmpty) {
      children.add(Padding(padding: const EdgeInsets.only(top: 6, bottom: 2), child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (final p in toggles) DeviceToggle(p.id, label: drumKnobLabel(p)),
      ])));
    }
    if (knobs.isNotEmpty) {
      children.add(KnobRow([for (final p in knobs) p.id], size: 42, labels: {for (final p in knobs) p.id: drumKnobLabel(p)}));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);
  }
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
