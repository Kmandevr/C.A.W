// "Learn MIDI CC" on a knob's long-press sheet or value dialog: waits for a hardware control, maps it, shows the CC.
import 'package:flutter/material.dart';

import '../../model/device_target.dart';
import '../../model/live_midi.dart';
import '../haptics.dart';
import '../theme.dart';

/// Learn, waiting ("Move a control…", a tap cancels), or the mapped CC with a button to forget it. Nothing where no
/// MIDI device can be read or the parameter can't be mapped.
class MidiLearnButton extends StatefulWidget {
  const MidiLearnButton({super.key, required this.target, required this.paramId, this.color});
  final DeviceTarget target;
  final String paramId;
  final Color? color;

  @override
  State<MidiLearnButton> createState() => _MidiLearnButtonState();
}

class _MidiLearnButtonState extends State<MidiLearnButton> {
  LiveMidi? get _midi => LiveMidi.current;
  bool _waiting = false;

  bool get _mine {
    final l = _midi?.learning;
    return l != null && l.layerId == widget.target.layerId && l.slot == widget.target.slot && l.paramId == widget.paramId;
  }

  @override
  void initState() {
    super.initState();
    _midi?.addListener(_changed);
  }

  @override
  void dispose() {
    _midi?.removeListener(_changed);
    if (_mine) {
      // The sheet closed while waiting: stop, once this frame is done (listeners may be building now).
      final midi = _midi!, t = widget.target, id = widget.paramId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final l = midi.learning;
        if (l != null && l.layerId == t.layerId && l.slot == t.slot && l.paramId == id) midi.cancelLearn();
      });
    }
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final mapped = _midi?.mappingOf(widget.target.layerId, widget.target.slot, widget.paramId);
    if (_waiting && !_mine) {
      _waiting = false;
      if (mapped != null) Haptics.drop(); // it caught a control
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final midi = _midi;
    final p = widget.target.param(widget.paramId);
    if (midi == null || midi.input == null || p == null || !p.midiMappable) return const SizedBox.shrink();
    final c = widget.color ?? Neon.blue;
    final mapped = midi.mappingOf(widget.target.layerId, widget.target.slot, widget.paramId);
    if (_mine) {
      return TextButton.icon(
        key: const ValueKey('midi-learn-waiting'),
        onPressed: () {
          Haptics.tap();
          _waiting = false;
          midi.cancelLearn();
        },
        icon: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: c)),
        label: const Text('Move a control…'),
      );
    }
    if (mapped != null) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        TextButton.icon(
          key: const ValueKey('midi-learn'),
          onPressed: () => _learn(midi),
          icon: Icon(Icons.tune, size: 16, color: c),
          label: Text('CC ${mapped.cc} · ch ${mapped.channel + 1}', style: Neon.code(size: 12, color: c)),
        ),
        IconButton(
          key: const ValueKey('midi-forget'),
          tooltip: 'Forget the MIDI CC',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 16),
          onPressed: () {
            Haptics.tap();
            midi.forget(mapped);
          },
        ),
      ]);
    }
    return TextButton.icon(
      key: const ValueKey('midi-learn'),
      onPressed: () => _learn(midi),
      icon: Icon(Icons.settings_input_component_outlined, size: 16, color: c),
      label: const Text('Learn MIDI CC'),
    );
  }

  void _learn(LiveMidi midi) {
    Haptics.tap();
    _waiting = true;
    midi.learn(widget.target.layerId, widget.target.slot, widget.paramId);
  }
}
