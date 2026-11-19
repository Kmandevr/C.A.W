// A device knob's hold menu (device shell): type a value, its modulation, Automate, React to… (another track's loudness or notes), MIDI learn and reset.
import 'package:flutter/material.dart';

import '../../engine/component_info.dart';
import '../../model/device_target.dart';
import '../../model/live_midi.dart';
import '../../model/react_to.dart';
import '../../model/routing_edit.dart' show RoutingEdit;
import '../arrange/automate_control.dart';
import '../arrange/long_press_menu.dart';
import '../panel_motion.dart';
import '../theme.dart';
import 'kit/feel.dart';
import 'device_scope.dart' show formatParamValue;
import 'midi_learn.dart';

/// What the knob menu was closed with: a typed value, or an entry the knob acts on after it closes.
sealed class KnobMenuResult {
  const KnobMenuResult();
}

class KnobValue extends KnobMenuResult {
  const KnobValue(this.value);
  final double value;
}

class KnobModulation extends KnobMenuResult {
  const KnobModulation();
}

class KnobReact extends KnobMenuResult {
  const KnobReact();
}

/// Opens [p]'s menu over the knob; [modulations] counts what moves it (a "Modulation…" entry when it has any or
/// the device has a mod matrix: [canModulate]). [typing] puts the cursor in the value field (a keyboard's type key).
Future<KnobMenuResult?> showKnobMenu(BuildContext context, DeviceTarget t, ComponentParameterInfo p,
    {int modulations = 0, bool canModulate = false, bool canReact = false, bool typing = false}) {
  DeviceFeel.tap();
  return showDialog<KnobMenuResult>(context: context, animationStyle: dialogAnimation(context),
      builder: (c) => _KnobMenu(target: t, param: p, modulations: modulations, canModulate: canModulate,
          canReact: canReact, typing: typing));
}

class _KnobMenu extends StatefulWidget {
  const _KnobMenu({required this.target, required this.param, required this.modulations, required this.canModulate,
    required this.canReact, required this.typing});
  final DeviceTarget target;
  final ComponentParameterInfo param;
  final int modulations;
  final bool canModulate, canReact, typing;

  @override
  State<_KnobMenu> createState() => _KnobMenuState();
}

class _KnobMenuState extends State<_KnobMenu> {
  late final _field = TextEditingController(text: widget.target.value(widget.param.id)
      .toStringAsFixed(widget.param.max - widget.param.min > 20 ? 1 : 3));

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _set() {
    final v = double.tryParse(_field.text.trim());
    Navigator.of(context).pop(v == null ? null : KnobValue(v));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.param, t = widget.target;
    final midi = LiveMidi.current;
    Widget entry(String key, IconData icon, String label, VoidCallback? onPressed, {String? hint}) => Tooltip(
      message: hint ?? '',
      child: TextButton.icon(key: ValueKey(key), onPressed: onPressed, icon: Icon(icon, size: 16),
        style: TextButton.styleFrom(alignment: Alignment.centerLeft, visualDensity: VisualDensity.compact),
        label: Text(label)));
    return AlertDialog(
      key: const ValueKey('knob-menu'),
      title: Text(p.label, style: const TextStyle(fontSize: 14)),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: Theme(data: Theme.of(context).copyWith(visualDensity: VisualDensity.compact),
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!p.isChoice) Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: TextField(
          key: const ValueKey('dknob-type'),
          controller: _field,
          autofocus: widget.typing,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: InputDecoration(labelText: 'Type a value', suffixText: p.unit, helperText: '${p.min} .. ${p.max}'),
          onSubmitted: (_) => _set(),
        )),
        const SizedBox(height: 6),
        if (widget.modulations > 0 || widget.canModulate)
          entry('knob-menu-mod', Icons.waves, widget.modulations > 0 ? 'Modulation (${widget.modulations})…' : 'Modulation…',
              () => Navigator.of(context).pop(const KnobModulation())),
        Align(alignment: Alignment.centerLeft, child: AutomateButton(target: t, paramId: p.id)),
        if (widget.canReact)
          entry('knob-menu-react', Icons.multitrack_audio, 'React to…', () => Navigator.of(context).pop(const KnobReact()),
              hint: 'Another track\'s loudness or notes moves this knob'),
        Align(alignment: Alignment.centerLeft, child: midi == null || midi.input == null
            ? entry('knob-menu-midi', Icons.settings_input_component_outlined, 'MIDI learn', null,
                hint: 'Connect a MIDI controller to learn one of its controls')
            : MidiLearnButton(target: t, paramId: p.id)),
        entry('knob-menu-reset', Icons.restart_alt, 'Reset to ${formatParamValue(p, p.defaultValue)}',
            () => Navigator.of(context).pop(KnobValue(p.defaultValue))),
      ]))),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        if (!p.isChoice) TextButton(key: const ValueKey('dknob-set'), onPressed: _set, child: const Text('Set')),
      ],
    );
  }
}

/// React to…: picks a track, then Loudness or Notes, and links a project modulator keyed from it to [t]'s knob
/// [paramId] (react_to.dart). Says why when it can't (a loop, a full project).
Future<void> pickReactTo(BuildContext context, DeviceTarget t, String paramId) async {
  final s = t.state;
  final tracks = s.reactSources(ReactKind.loudness);
  final track = await showLongPressMenu<String>(context, at: menuAnchorOf(context), title: 'React to…', actions: [
    for (final l in tracks)
      MenuAction(l.id, l.id == t.layerId ? '${l.name} (this track)' : l.name, l.isFolder ? Icons.merge_type : Icons.graphic_eq,
          section: 'Track', hint: l.id == t.layerId ? 'Its notes only: its own loudness would loop' : null),
  ]);
  if (track == null || !context.mounted) return;
  final layer = s.layerById(track);
  final notes = layer != null && !layer.isFolder;
  final kind = await showLongPressMenu<ReactKind>(context, at: menuAnchorOf(context),
      title: '${layer?.name ?? 'Track'}: react to its…', actions: [
    MenuAction(ReactKind.loudness, 'Loudness', Icons.graphic_eq, enabled: track != t.layerId,
        hint: track == t.layerId ? 'The knob changes this track: it would hear itself' : 'An envelope follower on its audio'),
    MenuAction(ReactKind.notes, 'Notes', Icons.piano, enabled: notes,
        hint: notes ? 'An envelope each of its notes starts' : 'A bus has no notes of its own'),
  ]);
  if (kind == null || !context.mounted) return;
  final r = s.reactTo(t, paramId, track, kind);
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (r.link == null) {
    messenger?.showSnackBar(SnackBar(duration: const Duration(seconds: 3),
      content: Text(r.why ?? 'That can\'t be linked', style: const TextStyle(color: Neon.pink))));
    return;
  }
  DeviceFeel.detent();
  messenger?.showSnackBar(SnackBar(duration: const Duration(seconds: 3),
    content: Text('${t.param(paramId)?.label ?? paramId} reacts to ${layer?.name ?? 'the track'}\'s ${kind.label.toLowerCase()}'),
    action: SnackBarAction(label: 'Undo', onPressed: () => s.undoReactTo(r.made))));
}
