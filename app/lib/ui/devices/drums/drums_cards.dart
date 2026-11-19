// The drums' visual cards (one look for every layer and kit effect): a picture of what the knobs do, the few that matter most, the rest behind More, and every setting that is not heard now dimmed with what it needs.
import 'package:flutter/material.dart';

import '../../../engine/component_info.dart';
import '../../../model/device_target.dart';
import '../../../model/drums.dart';
import '../../../model/drums_needs.dart';
import '../../feedback.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../kit/controls.dart' show DeviceToggle;
import '../device_scope.dart';
import '../flagship/flagship_panels.dart' show FPanel;
import '../kit/feel.dart';
import '../kit/param_watch.dart';
import 'drums_pads.dart';
import 'drums_samples.dart';
import 'drums_visuals.dart';
import 'drums_voice.dart';

/// The cards of the three panels (a phone's swipes; wide, three columns), in order. `penv` lives in the Body card,
/// `macro` in the strip at the bottom.
const drumSoundCards = ['body', 'sub', 'click', 'noise', 'metal', 'res', 'fm', 'phys', 'tex', 'smp'];
const drumShapeCards = ['drive', 'filter', 'eq', 'dyn', 'space', 'fx', 'pad'];
const drumGrooveCards = ['groove', 'var', 'press'];

/// Every pad card, in panel order (each layer of the descriptor but `penv` and `macro` has one).
const drumCardOrder = [...drumSoundCards, ...drumShapeCards, ...drumGrooveCards];

/// The settings a card shows on its face (plug and play); the rest of its layer is behind More.
const drumMain = <String, List<String>>{
  'body': ['body_wave', 'penv_mode', 'body_freq', 'body_pitch', 'body_decay', 'body_level'],
  'sub': ['sub_wave', 'sub_oct', 'sub_decay', 'sub_follow', 'sub_level'],
  'click': ['click_type', 'click_tone', 'click_length', 'click_level'],
  'noise': ['noise_mode', 'noise_color', 'noise_filter', 'noise_freq', 'noise_decay', 'noise_level'],
  'metal': ['metal_mode', 'metal_set', 'metal_freq', 'metal_tone', 'metal_decay', 'metal_open'],
  'res': ['res_model', 'res_freq', 'res_decay', 'res_bright', 'res_pos'],
  'fm': ['fm_freq', 'fm_ratio', 'fm_index', 'fm_idecay', 'fm_decay', 'fm_level'],
  'phys': ['phys_model', 'phys_freq', 'phys_decay', 'phys_damp', 'phys_pick'],
  'tex': ['tex_mode', 'tex_freq', 'tex_spread', 'tex_density', 'tex_decay', 'tex_level'],
  'smp': ['smp_start', 'smp_end', 'smp_tune', 'smp_decay', 'smp_level'],
  'drive': ['drive_type', 'drive', 'drive_mix'],
  'filter': ['flt', 'cutoff', 'flt_res', 'flt_env'],
  'eq': ['eq_low', 'eq_mid', 'eq_freq', 'eq_high'],
  'dyn': ['tr_attack', 'tr_sustain', 'comp', 'clip'],
  'space': ['width', 'room_send'],
  'fx': ['ring_mix', 'ring_freq', 'echo_send', 'bus_send'],
  'pad': ['level', 'pan', 'tune', 'choke'],
  'groove': ['groove', 'swing', 'humanize', 'accent', 'flam'],
  'var': ['vel_level', 'vel_tone', 'rnd_pitch', 'rnd_decay'],
  'press': ['press_damp', 'press_tone', 'press_pitch'],
};

/// The colour of a layer's card: the sources warm, the effects cool, the performance violet.
Color drumCardColor(DeviceScope scope, String layer) {
  if (drumSoundCards.contains(layer)) return scope.accent;
  if (drumShapeCards.contains(layer)) return scope.secondary;
  return Neon.violet;
}

/// A setting that is not heard now (its needs fail): dimmed, with what it needs under it.
class DrumHeard extends StatelessWidget {
  const DrumHeard({super.key, required this.suffix, required this.child, this.pad});
  final int? pad;
  final String suffix;
  final Widget child;

  @override
  Widget build(BuildContext context) => watchDevice(context, (context) {
    final t = DeviceScope.of(context).target;
    final layout = drumsLayout(t);
    final n = drumUnmetNeed(t, layout, pad, suffix);
    if (n == null) return child;
    final hint = drumNeedText(t, layout, pad, n);
    return Tooltip(message: 'Not heard now: $hint', child: Column(mainAxisSize: MainAxisSize.min, children: [
      AnimatedOpacity(duration: Motion.fade(Motion.small, Motion.of(context)), opacity: 0.35, child: child),
      SizedBox(width: 72, child: Text(hint, key: ValueKey('drum-needs-$suffix'), maxLines: 2, textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 8, height: 1.1, color: Neon.yellow))),
    ]));
  });
}

/// [ids] (whole parameter ids; [suffixOf] gives each one's suffix for its needs) as choices first, then a wrap of
/// knobs, each dimmed when it is not heard.
class DrumControls extends StatelessWidget {
  const DrumControls({super.key, required this.ids, required this.suffixOf, this.pad, this.size = 40, this.color});
  final List<String> ids;
  final String Function(String id) suffixOf;
  final int? pad;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final params = [for (final id in ids) ?t.param(id)];
    final toggles = [for (final p in params) if (p.isChoice && p.choices.length == 2 && p.choices.first == 'Off') p];
    final choices = [for (final p in params) if (p.isChoice && !toggles.contains(p)) p];
    final knobs = [for (final p in params) if (!p.isChoice) p];
    Widget heard(ComponentParameterInfo p, Widget w) => DrumHeard(pad: pad, suffix: suffixOf(p.id), child: w);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      for (final p in choices)
        Padding(padding: const EdgeInsets.only(top: 4), child: heard(p, Row(children: [
          SizedBox(width: 74, child: Text(drumKnobLabel(p).toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 9, letterSpacing: 0.6, fontWeight: FontWeight.w700, color: Neon.dim))),
          Flexible(child: Align(alignment: Alignment.centerLeft,
            child: DeviceChoice(p.id, maxSegments: p.choices.length <= 4 ? 4 : 0, color: color))),
        ]))),
      if (toggles.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 6, runSpacing: 6, children: [
          for (final p in toggles) heard(p, DeviceToggle(p.id, label: drumKnobLabel(p))),
        ])),
      if (knobs.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 4), child: Wrap(alignment: WrapAlignment.spaceEvenly, spacing: 2, runSpacing: 4,
          children: [for (final p in knobs) heard(p, DeviceKnob(p.id, size: size, label: drumKnobLabel(p), color: color))])),
    ]);
  }
}

/// The last non-Off choice of a choice-switched layer (drive type, filter), so its power button brings it back.
final Map<String, double> _lastOn = {};

/// One layer of [pad]: its power, name, what it is set to, Randomize and Mutate for the layer alone, its picture,
/// its main settings, and More with the rest.
class DrumCard extends StatelessWidget {
  const DrumCard({super.key, required this.pad, required this.layer});
  final int pad;
  final String layer;

  // The card rebuilds only when its power moves (its own watch); its picture, summary and settings watch their own.
  @override
  Widget build(BuildContext context) => watchDevice(context, (context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final layout = drumsLayout(t);
    final l = layout.byId[layer];
    if (l == null) return const SizedBox.shrink();
    final p = DrumPadView(t, layout, pad);
    final c = drumCardColor(scope, layer);
    final on = p.layerOn(l);
    final power = l.power;
    // Body's card holds the pitch shape too.
    final all = [...l.suffixes, if (layer == 'body') ...?layout.byId['penv']?.suffixes];
    final main = [for (final s in drumMain[layer] ?? const <String>[]) if (all.contains(s) && s != power) s];
    final more = [for (final s in all) if (s != power && !main.contains(s) && !(layer == 'pad' && (s == 'note' || s == 'chan'))) s];
    String suffixOf(String id) => id.substring(id.indexOf('_') + 1);
    return FPanel(
      key: ValueKey('drum-card-$layer'),
      title: l.name.toUpperCase(),
      color: c,
      dimmed: !on,
      leading: power == null ? null : Padding(padding: const EdgeInsets.only(left: 2), child: power.endsWith('_on')
          ? DevicePower(p.id(power), color: c) : _ChoicePower(id: p.id(power), color: c)),
      trailing: [
        Flexible(child: watchDevice(context, (_) => Text(_summary(t, p, layer, p.layerOn(l)), maxLines: 1,
          overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Neon.dim)))),
        if (layer != 'pad') ...[
          _LayerDice(pad: pad, layer: l, mutate: false, color: c),
          _LayerDice(pad: pad, layer: l, mutate: true, color: c),
        ],
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        DrumVisual(kind: layer, pad: pad, color: c, height: layer == 'body' || layer == 'groove' ? 72 : 56),
        if (layer == 'smp') _SampleRow(pad: pad),
        if (layer == 'pad') Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 6, runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center, children: [
            DrumNoteButton(pad: pad),
            DrumLearnButton(pad: pad),
            DeviceChoice(p.id('chan'), maxSegments: 0),
          ])),
        DrumControls(ids: [for (final s in main) p.id(s)], suffixOf: suffixOf, pad: pad, color: c),
        if (more.isNotEmpty) _More(id: layer, color: c, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min,
          children: [
            if (layer == 'body') const Padding(padding: EdgeInsets.only(bottom: 2), child: Text(
              'Pitch shape Points: drag its four points on the picture above the cards (double-tap it to switch).',
              style: TextStyle(fontSize: 10, color: Neon.dim))),
            if (layer == 'pad') const Text('Out 2–9 play past the kit\'s glue, drive and room; the track has one stereo '
                'output for now, so they still land on it.', style: TextStyle(fontSize: 10, color: Neon.dim)),
            DrumControls(ids: [for (final s in more) p.id(s)], suffixOf: suffixOf, pad: pad, color: c, size: 36),
          ])),
      ]),
    );
  });

  static String _summary(DeviceTarget t, DrumPadView p, String layer, bool on) {
    String f(String s) => formatParamValue(t.param(p.id(s)), p.v(s));
    String parts(List<String> s) => [for (final x in s) f(x)].join(' · ');
    if (!on) return 'Off';
    return switch (layer) {
      'pad' => '${f('note')} · ch ${f('chan')}',
      'body' => parts(['body_wave', 'body_freq']),
      'sub' => parts(['sub_wave', 'sub_oct']),
      'click' => parts(['click_type', 'click_tone']),
      'noise' => parts(['noise_mode', 'noise_color']),
      'metal' => parts(['metal_mode', 'metal_set']),
      'res' => parts(['res_model', 'res_freq']),
      'fm' => parts(['fm_freq', 'fm_ratio']),
      'phys' => parts(['phys_model', 'phys_freq']),
      'tex' => parts(['tex_mode', 'tex_freq']),
      'smp' => padSample(t, p.pad)?.label ?? 'No sample',
      'drive' => parts(['drive_type', 'drive']),
      'filter' => parts(['flt', 'cutoff']),
      'groove' => p.v('groove') > 0 ? f('groove') : (p.v('swing') > 0 ? 'Swing ${f('swing')}' : 'Straight'),
      _ => '',
    };
  }
}

/// More: the rest of a card's settings, folded (closed by default).
class _More extends StatefulWidget {
  const _More({required this.id, required this.child, required this.color});
  final String id;
  final Color color;
  final Widget child;

  @override
  State<_More> createState() => _MoreState();
}

class _MoreState extends State<_More> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      InkWell(
        key: ValueKey('drum-more-${widget.id}'),
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          DeviceFeel.tap();
          setState(() => _open = !_open);
        },
        child: SizedBox(height: 32, child: Row(children: [
          AnimatedRotation(turns: _open ? 0.25 : 0, duration: Motion.fade(Motion.small, Motion.of(context)),
            child: Icon(Icons.chevron_right, size: 16, color: c)),
          Text(_open ? 'LESS' : 'MORE', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: c)),
          const SizedBox(width: 6),
          Expanded(child: Container(height: 1, color: c.withValues(alpha: 0.2))),
        ])),
      ),
      foldSize(context, _open ? widget.child : const SizedBox(width: double.infinity)),
    ]);
  }
}

class _SampleRow extends StatelessWidget {
  const _SampleRow({required this.pad});
  final int pad;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final sample = padSample(t, pad);
    return Padding(padding: const EdgeInsets.only(top: 4), child: Row(children: [
      Expanded(child: Text(sample?.label ?? 'No sample loaded', maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: sample == null ? Neon.dim : Neon.text))),
      Pressable(child: OutlinedButton.icon(
        key: const ValueKey('drum-sample-load'),
        onPressed: () => showDrumSamplePicker(context, t, pad),
        icon: const Icon(Icons.graphic_eq, size: 16),
        label: const Text('Load sample…'))),
    ]));
  }
}

/// A layer switched by a choice whose first value is Off (drive type, filter): off, or back to its last type.
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
  const _LayerDice({required this.pad, required this.layer, required this.mutate, required this.color});
  final int pad;
  final DrumLayer layer;
  final bool mutate;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    return IconButton(
      key: ValueKey('drum-layer-${mutate ? 'mutate' : 'dice'}-${layer.id}'),
      tooltip: '${mutate ? 'Mutate' : 'Randomize'} ${layer.name}',
      iconSize: 16,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      color: color,
      onPressed: () {
        DeviceFeel.tap();
        final layout = drumsLayout(t);
        final ok = mutate ? mutatePad(t, layout, pad, layer: layer) : randomizePad(t, layout, pad, layer: layer);
        if (!ok) drumsToast(context, '${mutate ? 'Mutate' : 'Randomize'} needs the engine');
      },
      icon: Icon(mutate ? Icons.auto_fix_high : Icons.casino_outlined));
  }
}

/// One of the kit's effects as a card: its picture, its settings (dimmed when not heard), and its power when it
/// has one (a level at 0 is off).
class DrumKitCard extends StatelessWidget {
  const DrumKitCard({super.key, required this.id, required this.title, required this.ids, this.visual, this.color,
    this.note, this.on});
  final String id, title;
  final List<String> ids;
  final String? visual, note;
  final Color? color;

  /// The setting whose zero is off (glue, room, echo) or whose first choice is (kit drive, clip).
  final String? on;

  @override
  Widget build(BuildContext context) => watchDevice(context, (context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final c = color ?? Neon.violet;
    final off = on != null && t.value(on!) <= 0;
    return FPanel(
      key: ValueKey('drum-kit-$id'),
      title: title,
      color: c,
      dimmed: off,
      trailing: [if (off) const Text('Off', style: TextStyle(fontSize: 10, color: Neon.dim))],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (visual != null) DrumVisual(kind: visual!, color: c, height: 48),
        DrumControls(ids: ids, suffixOf: (s) => s, color: c, size: 38),
        if (note != null) Padding(padding: const EdgeInsets.only(top: 4),
          child: Text(note!, style: const TextStyle(fontSize: 10, color: Neon.dim))),
      ]),
    );
  });
}
