// The frame's pieces: the section bar (phone portrait), the rail (landscape, tablet, desktop), the bottom transport
// (play, stop, record, undo; drag to scrub) and the slim top status row.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/app_state.dart';
import '../../model/live_midi.dart';
import '../glass.dart';
import '../theme.dart';
import 'sections.dart';

/// The icon and name of each section.
(IconData, String) sectionLook(Section s) => switch (s) {
      Section.build => (Icons.code, 'Build'),
      Section.files => (Icons.folder_open, 'Files'),
      Section.arrange => (Icons.view_timeline, 'Arrange'),
    };

/// The sections in the order the bar and the rail show them.
const sectionOrder = [Section.build, Section.files, Section.arrange];

BoxDecoration _barDecoration({required bool top}) {
  final edge = BorderSide(color: Glass.active ? Colors.white.withValues(alpha: 0.08) : Neon.line);
  return BoxDecoration(
    color: Glass.active ? Neon.panel.withValues(alpha: 0.6) : Neon.panel,
    border: top ? Border(top: edge) : Border(bottom: edge),
  );
}

/// The phone's bottom bar: Build, Files, Arrange. A downward drag on it brings the top row within reach.
class SectionBar extends StatelessWidget {
  const SectionBar({super.key, required this.sections, this.onReach});
  final SectionController sections;
  final VoidCallback? onReach;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 200) onReach?.call();
        },
        child: Container(
          height: 48,
          decoration: _barDecoration(top: true),
          child: Row(children: [
            for (final s in sectionOrder)
              Expanded(child: _SectionButton(section: s, selected: sections.current == s, onTap: () => sections.show(s))),
          ]),
        ),
      );
}

class _SectionButton extends StatelessWidget {
  const _SectionButton({required this.section, required this.selected, required this.onTap});
  final Section section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, name) = sectionLook(section);
    final color = selected ? Neon.green : Neon.dim;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('section-${section.name}'),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            decoration: BoxDecoration(
              color: selected ? Neon.green.withValues(alpha: 0.16) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 19, color: color),
          ),
          const SizedBox(height: 1),
          Text(name, style: TextStyle(fontSize: 10, color: color, fontWeight: selected ? FontWeight.w700 : null)),
        ]),
      ),
    );
  }
}

/// The slim rail on the left in landscape, on tablets and on desktop.
class SectionRail extends StatelessWidget {
  const SectionRail({super.key, required this.current, required this.onSelect, this.top, this.bottom});
  final Section? current;
  final ValueChanged<Section> onSelect;
  final Widget? top, bottom;

  @override
  Widget build(BuildContext context) => Container(
        width: 56,
        decoration: BoxDecoration(
          color: Glass.active ? Neon.panel.withValues(alpha: 0.6) : Neon.panel,
          border: Border(right: BorderSide(color: Glass.active ? Colors.white.withValues(alpha: 0.08) : Neon.line)),
        ),
        child: Column(children: [
          ?top,
          const SizedBox(height: 4),
          for (final s in sectionOrder)
            SizedBox(height: 56, child: _SectionButton(section: s, selected: current == s, onTap: () => onSelect(s))),
          const Spacer(),
          ?bottom,
        ]),
      );
}

/// Play, stop, record and undo within thumb reach. A sideways drag on it scrubs the playhead (one bar per 48 px).
class BottomTransport extends StatefulWidget {
  const BottomTransport({super.key, required this.state, this.midi, this.compact = false});
  final AppState state;
  final bool compact;

  /// The MIDI keyboard input; Record is on while a keyboard is connected or a take is running.
  final LiveMidi? midi;

  @override
  State<BottomTransport> createState() => _BottomTransportState();
}

class _BottomTransportState extends State<BottomTransport> {
  double? _scrubFrom, _scrubAt;
  double _dx = 0;

  AppState get s => widget.state;

  static const _pxPerBar = 48.0;

  void _start(DragStartDetails _) {
    _scrubFrom = s.playheadStep;
    _dx = 0;
  }

  void _update(DragUpdateDetails d) {
    final from = _scrubFrom;
    if (from == null) return;
    _dx += d.delta.dx;
    final bar = s.project.stepsPerBar.toDouble();
    // Whole bars while scrubbing, so the drop lands on a downbeat.
    final at = ((from + _dx / _pxPerBar * bar) / bar).round() * bar;
    final clamped = at.clamp(0.0, (s.project.engineLoopSteps - 1).toDouble()).toDouble();
    if (clamped != _scrubAt) {
      _scrubAt = clamped;
      HapticFeedback.selectionClick();
      setState(() {});
    }
  }

  void _end(DragEndDetails _) {
    final at = _scrubAt;
    _scrubFrom = _scrubAt = null;
    if (at != null) s.seekTo(at);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final playing = s.transportOn;
    final p = s.project;
    final small = BoxConstraints(minWidth: 40, minHeight: 40);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _start,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      child: Container(
        height: widget.compact ? 44 : 50,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: _barDecoration(top: true),
        child: Row(children: [
          IconButton(
            key: const ValueKey('transport-undo'),
            tooltip: 'Undo (Ctrl+Z)',
            iconSize: 19,
            constraints: small,
            color: Neon.text,
            icon: const Icon(Icons.undo),
            onPressed: s.canUndo ? s.undo : null,
          ),
          IconButton(
            key: const ValueKey('transport-redo'),
            tooltip: 'Redo (Ctrl+Shift+Z)',
            iconSize: 19,
            constraints: small,
            color: Neon.text,
            icon: const Icon(Icons.redo),
            onPressed: s.canRedo ? s.redo : null,
          ),
          Expanded(
            child: Center(
              child: _scrubAt != null
                  ? Text('→ ${(_scrubAt! ~/ p.stepsPerBar) + 1}.1', style: Neon.code(size: 13, color: Neon.blue))
                  : ValueListenableBuilder<int>(
                      valueListenable: s.tick,
                      builder: (context, _, _) => Text(_position(),
                          style: Neon.code(size: 13, color: s.meters.playing ? Neon.text : Neon.dim)),
                    ),
            ),
          ),
          IconButton(
            key: const ValueKey('transport-stop'),
            tooltip: 'Stop, back to the start (Shift+Space)',
            iconSize: 21,
            constraints: small,
            color: Neon.green,
            icon: const Icon(Icons.stop),
            onPressed: playing || s.pausedStep != null ? s.stopPlayback : null,
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: playing ? 'Pause (Space)' : s.pausedStep != null ? 'Resume (Space)' : 'Play (Space)',
            child: InkResponse(
              key: const ValueKey('transport-play'),
              radius: 24,
              onTap: () {
                HapticFeedback.selectionClick();
                s.togglePlay();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: playing ? Neon.green : Colors.transparent,
                  border: Border.all(color: Neon.green, width: 2),
                  boxShadow: Neon.glow(Neon.green, strength: playing ? 0.6 : 0.2),
                ),
                child: Icon(playing ? Icons.pause : Icons.play_arrow, color: playing ? Neon.bg : Neon.green, size: 24),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Record takes a MIDI keyboard for now; audio recording needs the engine's audio input (#152).
          RecordButton(midi: widget.midi, constraints: small),
        ]),
      ),
    );
  }

  String _position() {
    final m = s.meters;
    final p = s.project;
    final step = s.playheadStep.floor().clamp(0, p.engineLoopSteps - 1);
    final text = '${step ~/ p.stepsPerBar + 1}.${(step % p.stepsPerBar) ~/ 4 + 1}';
    return m.playing ? text : s.pausedStep != null ? '$text ‖' : text;
  }
}

/// Records a MIDI keyboard into the selected track: on while a keyboard is connected (or a take is running).
class RecordButton extends StatelessWidget {
  const RecordButton({super.key, required this.midi, this.constraints});
  final LiveMidi? midi;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    final m = midi;
    Widget button(bool recording, bool can) => IconButton(
          key: const ValueKey('transport-record'),
          tooltip: recording
              ? 'Stop recording'
              : can
                  ? 'Record the MIDI keyboard into the selected track'
                  : 'Record: connect a MIDI keyboard (audio recording comes later)',
          iconSize: 19,
          constraints: constraints,
          color: Neon.pink,
          isSelected: recording,
          selectedIcon: const Icon(Icons.stop_circle),
          icon: const Icon(Icons.fiber_manual_record),
          onPressed: can || recording
              ? () {
                  HapticFeedback.selectionClick();
                  m!.toggleRecord();
                }
              : null,
        );
    if (m == null) return button(false, false);
    return ListenableBuilder(listenable: m, builder: (context, _) => button(m.recording, m.devices.isNotEmpty));
  }
}
