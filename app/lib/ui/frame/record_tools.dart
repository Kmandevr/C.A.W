// The transport's recording and automation buttons (owner, 2026-11-10): Automate (tap on or off, long-press for the
// mode), the on-screen keys, Record's long-press options (metronome, count-in) and the "Keep take?" toast.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/automation_writer.dart';
import '../../model/live_midi.dart';
import '../../model/project.dart';
import '../../model/settings.dart';
import '../arrange/long_press_menu.dart';
import '../motion.dart';
import '../theme.dart';

const _modeNames = {
  AutomationMode.touch: ('Touch', 'T', 'Writes while you hold a control, then back to the lane'),
  AutomationMode.latch: ('Latch', 'L', 'Writes from the first touch until stop'),
  AutomationMode.write: ('Write', 'W', 'Overwrites every lane while playing, then Read'),
  AutomationMode.read: ('Read', 'R', 'Plays the lanes, writes nothing'),
};

/// Automate: off, an outlined lane icon; armed, red with the mode's letter; writing, filled red. A tap arms it, a
/// long-press (or right-click) picks Touch, Latch, Write or Read.
class AutomateButton extends StatelessWidget {
  const AutomateButton({super.key, required this.writer, required this.state, this.size = 36});
  final AutomationWriter writer;
  final AppState state;
  final double size;

  Future<void> _menu(BuildContext context, Offset at) async {
    final m = await showLongPressMenu<AutomationMode>(context, at: at, title: 'Automation mode',
        style: state.settings.longPressMenu, actions: [
      for (final e in _modeNames.entries)
        MenuAction(e.key, e.value.$1, switch (e.key) {
          AutomationMode.touch => Icons.touch_app_outlined,
          AutomationMode.latch => Icons.lock_clock_outlined,
          AutomationMode.write => Icons.edit_outlined,
          AutomationMode.read => Icons.play_arrow_outlined,
        }, checked: writer.mode == e.key, hint: e.value.$3),
    ]);
    if (m == null) return;
    writer.setMode(m);
    writer.setArmed(true);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: writer,
        builder: (context, _) {
          final armed = writer.armed;
          final (name, letter, _) = _modeNames[writer.mode]!;
          final hot = armed && writer.writing;
          final color = armed ? Neon.pink : Neon.dim;
          return Tooltip(
            message: armed ? 'Automate: on, $name (long-press for the mode)' : 'Automate: write control moves while playing',
            child: Semantics(
              button: true,
              toggled: armed,
              label: 'Automate, $name',
              excludeSemantics: true,
              child: GestureDetector(
                key: const ValueKey('transport-automate'),
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  Motion.tick();
                  writer.setArmed(!armed);
                },
                onLongPressStart: (d) => _menu(context, d.globalPosition),
                onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 30,
                      height: 24,
                      decoration: BoxDecoration(
                        color: hot ? Neon.pink : armed ? Neon.pink.withValues(alpha: 0.14) : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: color, width: armed ? 1.5 : 1),
                        boxShadow: hot ? Neon.glow(Neon.pink, strength: 0.5) : null,
                      ),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.show_chart, size: 14, color: hot ? Neon.bg : color),
                        if (armed)
                          Text(letter, style: Neon.code(size: 9, color: hot ? Neon.bg : color).copyWith(fontWeight: FontWeight.w800)),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
}

/// Opens and closes the on-screen keys and pads.
class KeysButton extends StatelessWidget {
  const KeysButton({super.key, required this.midi, this.constraints});
  final LiveMidi midi;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: midi,
        builder: (context, _) => IconButton(
          key: const ValueKey('transport-keys'),
          tooltip: midi.keysOpen ? 'Hide the keys' : 'Keys and pads: play the selected track',
          iconSize: 19,
          constraints: constraints,
          color: midi.keysOpen ? Neon.blue : Neon.dim,
          isSelected: midi.keysOpen,
          icon: const Icon(Icons.piano),
          onPressed: () {
            Motion.tick();
            midi.keysOpen = !midi.keysOpen;
          },
        ),
      );
}

/// Record's long-press: the metronome, the count-in and the keys.
Future<void> showRecordOptions(BuildContext context, AppState state, LiveMidi midi, Offset at) async {
  final s = state.settings;
  final v = await showLongPressMenu<String>(context, at: at, title: 'Recording', style: s.longPressMenu, actions: [
    MenuAction('m:off', 'Metronome off', Icons.timer_off_outlined, checked: s.metronome == Metronome.off),
    MenuAction('m:recording', 'Click while recording', Icons.timer_outlined, checked: s.metronome == Metronome.recording),
    MenuAction('m:always', 'Click whenever playing', Icons.av_timer, checked: s.metronome == Metronome.always),
    for (final bars in const [0, 1, 2])
      MenuAction('c:$bars', bars == 0 ? 'No count-in' : 'Count-in $bars bar${bars == 1 ? '' : 's'}', Icons.more_time,
          checked: s.countInBars == bars),
    MenuAction('keys', midi.keysOpen ? 'Hide the keys' : 'Show the keys and pads', Icons.piano),
  ]);
  if (v == null) return;
  if (v == 'keys') {
    midi.keysOpen = !midi.keysOpen;
  } else if (v.startsWith('m:')) {
    await s.setRecording(metronome: Metronome.values.byName(v.substring(2)));
  } else {
    await s.setRecording(countInBars: int.parse(v.substring(2)));
  }
}

/// Shows "Take kept" with Undo after each recording (REAPER asks which takes to keep; a toast is lighter).
class TakeToast extends StatefulWidget {
  const TakeToast({super.key, required this.midi, required this.child});
  final LiveMidi midi;
  final Widget child;

  @override
  State<TakeToast> createState() => _TakeToastState();
}

class _TakeToastState extends State<TakeToast> {
  RecordedTake? _shown;

  @override
  void initState() {
    super.initState();
    widget.midi.lastTake.addListener(_changed);
  }

  @override
  void dispose() {
    widget.midi.lastTake.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final t = widget.midi.lastTake.value;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (t == null || identical(t, _shown) || messenger == null) return;
    _shown = t;
    final layer = widget.midi.state.project.layers.where((l) => l.id == t.layerId).firstOrNull;
    final name = widget.midi.state.project.module(t.moduleIds.last)?.name ?? 'Take';
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        key: const ValueKey('take-toast'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        content: Text(t.takes > 1
            ? 'Keep take? $name on ${layer?.name ?? 'the track'} (${t.takes} takes: clip menu › Takes)'
            : 'Keep take? $name on ${layer?.name ?? 'the track'}'),
        action: SnackBarAction(label: 'Undo', onPressed: widget.midi.discardTake),
      ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The clip's Takes picker: every loop-recorded take, newest first, the one playing checked.
Future<void> showTakePicker(BuildContext context, AppState state, LayerDoc layer, ClipDoc clip, Offset at) async {
  final takes = [for (final id in clip.takes.reversed) ?state.project.module(id)];
  final v = await showLongPressMenu<String>(context, at: at, title: 'Takes', style: state.settings.longPressMenu, actions: [
    for (final (i, m) in takes.indexed)
      MenuAction(m.id, i == 0 ? '${m.name} (newest)' : m.name, Icons.layers_outlined, checked: clip.patternId == m.id),
  ]);
  if (v == null) return;
  if (clip.takes.contains(v)) state.editLayer(layer, (_) => clip.patternId = v);
}
