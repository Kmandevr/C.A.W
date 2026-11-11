// The frame's pieces: the section bar (phone portrait), the rail (landscape, tablet, desktop), the bottom transport
// (play, stop, record, undo; drag to scrub) and the slim top status row.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/automation_writer.dart';
import '../../model/live_midi.dart';
import '../audio_record_ui.dart';
import '../feedback.dart';
import '../glass.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import '../widgets.dart' show LiveIsland;
import 'live_keys.dart';
import 'record_tools.dart';
import 'sections.dart';
import '../pointer_input.dart';

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

/// A top bar that tucks away upwards when [shown] turns false and slides back down when it turns true (a short
/// slide; at once when motion is reduced or off). While the bars' handle is pulled it follows the finger, fading as it
/// goes ([SectionController.barsPull]).
class TuckAway extends StatelessWidget {
  const TuckAway({super.key, required this.shown, required this.child});
  final bool shown;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final pull = SectionController.maybeOf(context)?.barsPull;
    Widget at(double? p) {
      final hidden = p ?? (shown ? 0.0 : 1.0);
      return ClipRect(
        child: AnimatedAlign(
          duration: p != null ? Duration.zero : Motion.move(Motion.standard, Motion.of(context)),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          heightFactor: 1 - hidden,
          // An Opacity only while it fades: at 1 it would still cost a layer on every repaint of the bar.
          child: hidden > 0 ? Opacity(opacity: (1 - 0.7 * hidden).clamp(0.0, 1.0), child: child) : child,
        ),
      );
    }

    // A bar held open (the keyboard is up, a setting is showing) doesn't follow a pull.
    if (pull == null || shown && !(SectionController.maybeOf(context)?.barsShown.value ?? true)) return at(null);
    return ValueListenableBuilder<double?>(valueListenable: pull, builder: (context, p, _) => at(p));
  }
}

/// The phone's bottom bar: Build, Files, Arrange. A downward drag on it brings the top row within reach.
class SectionBar extends StatelessWidget {
  const SectionBar({super.key, required this.sections, this.onReach, this.bottomInset = 0});
  final SectionController sections;
  final VoidCallback? onReach;

  /// The system navigation bar's height: the bar's background reaches under it, its buttons stay above it.
  final double bottomInset;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 200) onReach?.call();
        },
        child: Container(
          height: 48 + bottomInset,
          padding: EdgeInsets.only(bottom: bottomInset),
          decoration: _barDecoration(top: true),
          child: Row(children: [
            for (final s in sectionOrder)
              Expanded(child: _SectionButton(section: s, selected: sections.current == s, onTap: () => sections.show(s))),
          ]),
        ),
      );
}

class _SectionButton extends StatelessWidget {
  const _SectionButton({required this.section, required this.selected, required this.onTap, this.label = true});
  final Section section;
  final bool selected, label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, name) = sectionLook(section);
    final color = selected ? Neon.green : Neon.dim;
    final button = Semantics(
      button: true,
      selected: selected,
      label: name,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('section-${section.name}'),
        onTap: () {
          Haptics.tap();
          onTap();
        },
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Pressable(radius: 12, child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            decoration: BoxDecoration(
              color: selected ? Neon.green.withValues(alpha: 0.16) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: label ? 19 : 18, color: color),
          )),
          if (label) ...[
            const SizedBox(height: 1),
            Text(name, style: TextStyle(fontSize: 10, color: color, fontWeight: selected ? FontWeight.w700 : null)),
          ],
        ]),
      ),
    );
    // Without its label the name shows on hold (or hover).
    return label ? button : Tooltip(message: name, child: button);
  }
}

/// The slim rail on the left in landscape, on tablets and on desktop.
class SectionRail extends StatelessWidget {
  const SectionRail({super.key, required this.current, required this.onSelect, this.top, this.bottom,
      this.compact = false, this.inset = EdgeInsets.zero});
  final Section? current;
  final ValueChanged<Section> onSelect;
  final Widget? top, bottom;

  /// Phone landscape (owner, 2026-11-10): a narrow rail of icons without labels (names on hold).
  final bool compact;

  /// The screen's edge insets on the rail's side (a camera cutout, the system bars): the rail's background reaches
  /// under them, its buttons stay clear.
  final EdgeInsets inset;

  @override
  Widget build(BuildContext context) => Container(
        width: (compact ? 44 : 56) + inset.left,
        padding: EdgeInsets.only(left: inset.left, top: inset.top, bottom: inset.bottom),
        decoration: BoxDecoration(
          color: Glass.active ? Neon.panel.withValues(alpha: 0.6) : Neon.panel,
          border: Border(right: BorderSide(color: Glass.active ? Colors.white.withValues(alpha: 0.08) : Neon.line)),
        ),
        child: Column(children: [
          ?top,
          const SizedBox(height: 4),
          for (final s in sectionOrder)
            SizedBox(height: compact ? 44 : 56,
              child: _SectionButton(section: s, selected: current == s, onTap: () => onSelect(s), label: !compact)),
          const Spacer(),
          ?bottom,
        ]),
      );
}

/// Play, stop, record and undo within thumb reach, with Automate and the on-screen keys (which slide up above it).
/// A sideways drag on it scrubs the playhead (one bar per 48 px).
class BottomTransport extends StatefulWidget {
  const BottomTransport({super.key, required this.state, this.midi, this.automation, this.compact = false,
      this.extras = const [], this.inset = EdgeInsets.zero});
  final AppState state;
  final bool compact;

  /// More readouts after the position (phone landscape: the tempo and CPU, which have no status row there).
  final List<Widget> extras;

  /// The screen's edge insets under and beside the bar: its background reaches under them, its buttons stay clear.
  final EdgeInsets inset;

  /// The MIDI keyboard input and the on-screen keys.
  final LiveMidi? midi;

  /// The Automate button's writer (AutomationWriter.current when omitted).
  final AutomationWriter? automation;

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
    Haptics.grab();
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
      Haptics.tick();
      setState(() {});
    }
  }

  void _end(DragEndDetails _) {
    final at = _scrubAt;
    _scrubFrom = _scrubAt = null;
    if (at != null) {
      s.seekTo(at);
      Haptics.drop();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final playing = s.transportOn;
    final p = s.project;
    final small = BoxConstraints(minWidth: 40, minHeight: 40);
    final narrow = BoxConstraints(minWidth: 34, minHeight: 40);
    final midi = widget.midi;
    final writer = widget.automation ?? AutomationWriter.current;
    final bar = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _start,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      child: Container(
        height: (widget.compact ? 40 : 50) + widget.inset.bottom,
        padding: EdgeInsets.fromLTRB(6 + widget.inset.left, 0, 6 + widget.inset.right, widget.inset.bottom),
        decoration: _barDecoration(top: true),
        child: Row(children: [
          Pressable(child: IconButton(
            key: const ValueKey('transport-undo'),
            tooltip: 'Undo (Ctrl+Z)',
            iconSize: 19,
            constraints: small,
            color: Neon.text,
            icon: const Icon(Icons.undo),
            onPressed: s.canUndo ? s.undo : null,
          )),
          Pressable(child: IconButton(
            key: const ValueKey('transport-redo'),
            tooltip: 'Redo (Ctrl+Shift+Z)',
            iconSize: 19,
            constraints: small,
            color: Neon.text,
            icon: const Icon(Icons.redo),
            onPressed: s.canRedo ? s.redo : null,
          )),
          Expanded(
            // A live island (widgets.dart): the position changes about 30 times a second while playing.
            child: SizedBox.expand(child: LiveIsland(child: Center(
              child: _scrubAt != null
                  ? Text('→ ${(_scrubAt! ~/ p.stepsPerBar) + 1}.1', style: Neon.code(size: 13, color: Neon.blue))
                  : ValueListenableBuilder<int>(
                      valueListenable: s.tick,
                      builder: (context, _, _) => Text(midi != null && midi.countInLeft > 0 ? 'Count ${midi.countInLeft}' : _position(),
                          style: Neon.code(size: 13, color: s.meters.playing ? Neon.text : Neon.dim)),
                    ),
            ))),
          ),
          ...widget.extras,
          if (writer != null) AutomateButton(writer: writer, state: s, size: 34),
          if (midi != null) KeysButton(midi: midi, constraints: narrow),
          Pressable(child: IconButton(
            key: const ValueKey('transport-stop'),
            tooltip: 'Stop, back to the start (Shift+Space)',
            iconSize: 21,
            constraints: small,
            color: Neon.green,
            icon: const Icon(Icons.stop),
            onPressed: playing || s.pausedStep != null ? s.stopPlayback : null,
          )),
          const SizedBox(width: 4),
          Tooltip(
            message: playing ? 'Pause (Space)' : s.pausedStep != null ? 'Resume (Space)' : 'Play (Space)',
            child: InkResponse(
              key: const ValueKey('transport-play'),
              radius: 24,
              onTap: () {
                Haptics.tap();
                s.togglePlay();
              },
              child: Pressable(circle: true, child: AnimatedContainer(
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
              )),
            ),
          ),
          const SizedBox(width: 4),
          // Record plays a USB keyboard or the on-screen keys, and records the armed audio tracks (audio_record.dart).
          RecordButton(midi: widget.midi, state: s, constraints: small),
        ]),
      ),
    );
    if (midi == null) return bar;
    return TakeToast(
      midi: midi,
      child: AudioRecordFeedback(state: s, child: Column(mainAxisSize: MainAxisSize.min, children: [
        LiveKeysPanel(midi: midi, state: s, compact: widget.compact),
        bar,
      ])),
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

/// Records into the armed (else selected) track from a USB keyboard or the on-screen keys, which open when no
/// keyboard is connected; a long-press sets the metronome and the count-in.
class RecordButton extends StatelessWidget {
  const RecordButton({super.key, required this.midi, this.state, this.constraints});
  final LiveMidi? midi;
  final AppState? state;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    final m = midi;
    Widget button(bool recording) => GestureDetector(
          onLongPressStart: m == null || state == null ? null : (d) => showRecordOptions(context, state!, m, d.globalPosition),
          onSecondaryTapUp: m == null || state == null ? null : (d) => showRecordOptions(context, state!, m, d.globalPosition),
          child: Pressable(glow: Neon.pink, child: IconButton(
            key: const ValueKey('transport-record'),
            tooltip: recording
                ? 'Stop recording'
                : 'Record into the selected track and the armed audio tracks (${PointerInput.hold}: metronome, count-in)',
            iconSize: 19,
            constraints: constraints,
            color: Neon.pink,
            isSelected: recording,
            selectedIcon: const Icon(Icons.stop_circle),
            icon: const Icon(Icons.fiber_manual_record),
            onPressed: m == null
                ? null
                : () {
                    Haptics.tap();
                    m.toggleRecord();
                  },
          )),
        );
    if (m == null) return button(false);
    return ListenableBuilder(listenable: m, builder: (context, _) => button(m.recording));
  }
}

/// The sections, one in front (an [IndexedStack], so each keeps its state). Switching shows the new one with a short
/// fade and a slight rise (owner, 2026-11-10: a transition when switching sections, snappy), an edit animation of
/// panels: that look with Subtle, longer with a small overshoot with Playful; a fade only when motion is reduced, and
/// nothing when it is off or panels are turned off.
class SectionSwitcher extends StatefulWidget {
  const SectionSwitcher({super.key, required this.index, required this.children});
  final int index;
  final List<Widget> children;

  @override
  State<SectionSwitcher> createState() => _SectionSwitcherState();
}

class _SectionSwitcherState extends State<SectionSwitcher> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this, duration: Motion.standard, value: 1);
  late final Animation<double> _fade = CurvedAnimation(parent: _in, curve: Curves.easeOutCubic);
  late final Animation<Offset> _rise = Tween(begin: const Offset(0, 0.015), end: Offset.zero)
      .animate(CurvedAnimation(parent: _in, curve: _RiseCurve()));

  @override
  void didUpdateWidget(SectionSwitcher old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;
    final d = EditMotion.scaled(Motion.of(context), EditMotionKind.panels, Motion.standard);
    if (d == null) {
      _in.value = 1;
    } else {
      _in.duration = d;
      _in.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The sections behind keep their state but don't rebuild, and their animations stop, until they come forward.
    final stack = IndexedStack(index: widget.index, children: [
      for (var i = 0; i < widget.children.length; i++) Dormant(awake: i == widget.index, child: widget.children[i]),
    ]);
    final fade = FadeTransition(opacity: _fade, child: stack);
    return Motion.of(context) == MotionLevel.full ? SlideTransition(position: _rise, child: fade) : fade;
  }
}

/// The section switch's rise: the ease-out it always had (Subtle), or Playful's overshoot, read as it runs.
class _RiseCurve extends Curve {
  @override
  double transformInternal(double t) => EditMotion.curveOr(Curves.easeOutCubic).transform(t);
}

/// A part of the screen that is out of sight (a section behind, a dock tab not shown): while not [awake] it keeps
/// showing the child it last had, so an app-state change rebuilds only what is on screen, and its tickers stop.
/// Awake again, it takes the current child and catches up in one build.
class Dormant extends StatefulWidget {
  const Dormant({super.key, required this.awake, required this.child});
  final bool awake;
  final Widget child;

  @override
  State<Dormant> createState() => _DormantState();
}

class _DormantState extends State<Dormant> {
  late Widget _shown = widget.child;

  @override
  Widget build(BuildContext context) {
    // The same widget instance as last time is not rebuilt: that is what keeps a sleeping subtree still.
    if (widget.awake) _shown = widget.child;
    return TickerMode(enabled: widget.awake, child: _shown);
  }
}

/// Builds [builder] again only when [select] gives a different value: a frame bar rebuilt with the shell keeps its
/// last widget when nothing it shows changed (an app-state change elsewhere), so it doesn't rebuild at all. [select]
/// must cover everything [builder] reads from outside (the widgets built read the theme and the like themselves).
class Selected extends StatefulWidget {
  const Selected({super.key, required this.select, required this.builder});
  final Object? Function() select;
  final WidgetBuilder builder;

  @override
  State<Selected> createState() => _SelectedState();
}

class _SelectedState extends State<Selected> {
  Object? _value;
  Widget? _built;

  @override
  Widget build(BuildContext context) {
    final v = widget.select();
    if (_built == null || v != _value) {
      _value = v;
      _built = widget.builder(context);
    }
    return _built!;
  }
}

/// A [ListenableBuilder] that sleeps while its part of the screen is [Dormant] (its tickers off): a notification
/// then only marks it stale, and it rebuilds once when it is shown again. For screens that listen to the app state
/// themselves, so a section behind doesn't rebuild on every change.
class AwakeListenableBuilder extends StatefulWidget {
  const AwakeListenableBuilder({super.key, required this.listenable, required this.builder, this.child});
  final Listenable listenable;
  final TransitionBuilder builder;
  final Widget? child;

  @override
  State<AwakeListenableBuilder> createState() => _AwakeListenableBuilderState();
}

class _AwakeListenableBuilderState extends State<AwakeListenableBuilder> {
  ValueListenable<TickerModeData>? _awake;
  bool _stale = false;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final awake = TickerMode.getValuesNotifier(context);
    if (awake == _awake) return;
    _awake?.removeListener(_woke);
    _awake = awake..addListener(_woke);
  }

  @override
  void didUpdateWidget(AwakeListenableBuilder old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    _awake?.removeListener(_woke);
    super.dispose();
  }

  void _changed() {
    if (_awake?.value.enabled ?? true) {
      setState(() {});
    } else {
      _stale = true;
    }
  }

  void _woke() {
    if ((_awake?.value.enabled ?? true) && _stale) {
      _stale = false;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.child);
}

/// A panel that slides into place when it first appears: from [from] (a fraction of its own size) with a fade,
/// over [Motion.panel] on an ease-out curve (owner, 2026-11-10: panels slide into place), an edit animation of panels
/// (longer with a small overshoot with Playful); a fade only with Reduced motion, nothing with Off or panels off.
class SlideIn extends StatefulWidget {
  const SlideIn({super.key, required this.child, this.from = const Offset(0, 0.1)});
  final Widget child;
  final Offset from;

  @override
  State<SlideIn> createState() => _SlideInState();
}

class _SlideInState extends State<SlideIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.panel);
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  late final Animation<double> _slide = CurvedAnimation(parent: _c, curve: _RiseCurve());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_c.isDismissed) return;
    final d = EditMotion.scaled(Motion.of(context), EditMotionKind.panels, Motion.panel);
    if (d == null) {
      _c.value = 1;
    } else {
      _c.duration = d;
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = FadeTransition(opacity: _t, child: widget.child);
    if (Motion.of(context) != MotionLevel.full) return fade;
    return SlideTransition(position: Tween(begin: widget.from, end: Offset.zero).animate(_slide), child: fade);
  }
}

/// A horizontal scroller with soft fades at the edges that have more past them, so hidden buttons are findable.
class ScrollFade extends StatefulWidget {
  const ScrollFade({super.key, required this.child});
  final SingleChildScrollView child;

  @override
  State<ScrollFade> createState() => _ScrollFadeState();
}

class _ScrollFadeState extends State<ScrollFade> {
  bool _left = false, _right = false;

  bool _onMetrics(ScrollMetrics m) {
    final l = m.pixels > m.minScrollExtent + 1, r = m.pixels < m.maxScrollExtent - 1;
    if (l != _left || r != _right) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() { _left = l; _right = r; });
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    Widget fade(bool left) => Positioned(
          top: 0, bottom: 0, left: left ? 0 : null, right: left ? null : 0, width: 28,
          child: IgnorePointer(child: DecoratedBox(
            key: ValueKey(left ? 'scroll-fade-left' : 'scroll-fade-right'),
            decoration: BoxDecoration(gradient: LinearGradient(
              begin: left ? Alignment.centerRight : Alignment.centerLeft,
              end: left ? Alignment.centerLeft : Alignment.centerRight,
              colors: [Neon.bg.withValues(alpha: 0), Neon.bg.withValues(alpha: 0.85)],
            )),
            child: Align(
              alignment: left ? Alignment.centerLeft : Alignment.centerRight,
              child: Icon(left ? Icons.chevron_left : Icons.chevron_right, size: 14, color: Neon.dim),
            ),
          )),
        );
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _onMetrics(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => _onMetrics(n.metrics),
        child: Stack(children: [
          widget.child,
          if (_left) fade(true),
          if (_right) fade(false),
        ]),
      ),
    );
  }
}
