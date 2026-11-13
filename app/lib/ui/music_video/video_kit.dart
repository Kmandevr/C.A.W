// The music video sheets' small parts in the device kit's look: sections, notes, choice tiles, on/off pills and a
// reveal that animates what it shows through the theme's motion tokens (Off and Reduced respected).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/music_video.dart';

import '../motion.dart';
import '../theme.dart';
import '../feedback.dart';

/// The music video's accent (its sheet's title stripe, chosen tiles and pills).
Color get videoAccent => Neon.pink;

/// Shows [child] (or nothing) and animates the change: the height eases and the content fades, in the theme's
/// motion tokens (instant with motion Off). [switchKey] marks a swap between two children of the same kind.
class VideoReveal extends StatelessWidget {
  const VideoReveal(this.child, {super.key, this.switchKey});
  final Widget? child;
  final Object? switchKey;

  @override
  Widget build(BuildContext context) {
    final d = Motion.fade(Motion.standard, Motion.of(context));
    return AnimatedSize(
      duration: d,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: d,
        child: KeyedSubtree(key: ValueKey(switchKey ?? child != null), child: child ?? const SizedBox(width: double.infinity)),
      ),
    );
  }
}

class VideoSection extends StatelessWidget {
  const VideoSection(this.title, {super.key, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(title,
              style: TextStyle(fontSize: 10, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: videoAccent))),
          ...children,
        ]),
      );
}

class VideoNote extends StatelessWidget {
  const VideoNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text, style: const TextStyle(color: Neon.dim, fontSize: 11)),
      );
}

/// A row of choice tiles (the device kit's mode tiles), as the Export sheet's.
class VideoTiles<T> extends StatelessWidget {
  const VideoTiles({super.key, required this.keyPrefix, required this.values, required this.selected, required this.label,
      required this.onPick, this.icon, this.enabled, this.height = 54});
  final String keyPrefix;
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final IconData Function(T)? icon;
  final bool Function(T)? enabled;
  final void Function(T) onPick;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: Row(children: [
          for (var k = 0; k < values.length; k++)
            Expanded(child: Padding(
              padding: EdgeInsets.only(right: k < values.length - 1 ? 4 : 0),
              child: _tile(context, values[k]),
            )),
        ]),
      );

  Widget _tile(BuildContext context, T v) {
    final on = v == selected;
    final ok = enabled?.call(v) ?? true;
    final c = videoAccent;
    return Semantics(
      button: true,
      selected: on,
      enabled: ok,
      label: label(v),
      child: GestureDetector(
        key: ValueKey('$keyPrefix-${v is Enum ? v.name : v}'),
        behavior: HitTestBehavior.opaque,
        onTap: ok && !on ? () => onPick(v) : null,
        child: Pressable(enabled: ok, glow: c, child: AnimatedContainer(
          duration: Motion.fade(Motion.small, Motion.of(context)),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: on ? c.withValues(alpha: 0.2) : Colors.white.withValues(alpha: ok ? 0.03 : 0.0),
            border: Border.all(color: on ? c : Neon.line.withValues(alpha: ok ? 1 : 0.4), width: on ? 1.5 : 1),
            boxShadow: on ? [BoxShadow(color: c.withValues(alpha: 0.25), blurRadius: 10)] : null,
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) Icon(icon!(v), size: 18, color: on ? c : (ok ? Neon.dim : Neon.dim.withValues(alpha: 0.4))),
            // The whole label ("TRACK COLOURS"), a little smaller where five tiles share a phone's width.
            Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: FittedBox(fit: BoxFit.scaleDown,
                child: Text(label(v).toUpperCase(), maxLines: 1,
                    style: TextStyle(fontSize: 9.5, letterSpacing: 0.3, fontWeight: FontWeight.w800,
                        color: on ? Neon.text : (ok ? Neon.dim : Neon.dim.withValues(alpha: 0.4)))))),
          ]),
        )),
      ),
    );
  }
}

/// An on/off pill (the device kit's toggle).
class VideoPill extends StatelessWidget {
  const VideoPill({super.key, required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(toggled: on, label: label, child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Pressable(glow: videoAccent, radius: 18, child: AnimatedContainer(
          duration: Motion.fade(Motion.small, Motion.of(context)),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: on ? videoAccent.withValues(alpha: 0.22) : Colors.white.withValues(alpha: 0.03),
            border: Border.all(color: on ? videoAccent : Neon.line),
            boxShadow: on ? [BoxShadow(color: videoAccent.withValues(alpha: 0.3), blurRadius: 10)] : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(on ? Icons.check_circle : Icons.circle_outlined, size: 15, color: on ? videoAccent : Neon.dim),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 10, letterSpacing: 1, fontWeight: FontWeight.w800,
                color: on ? Neon.text : Neon.dim)),
          ]),
        )),
      ));
}

/// Each view's colour on the lane and in the list (theme accents, so it follows the theme).
Color videoViewColor(VideoShot v) => switch (v) {
      VideoShot.flythrough => Neon.pink,
      VideoShot.mixer => Neon.green,
      VideoShot.pianoRoll => Neon.blue,
      VideoShot.devices => Neon.yellow,
      VideoShot.falling => Neon.violet,
    };

IconData videoViewIcon(VideoShot v) => switch (v) {
      VideoShot.flythrough => Icons.view_timeline_outlined,
      VideoShot.mixer => Icons.tune,
      VideoShot.pianoRoll => Icons.piano_outlined,
      VideoShot.devices => Icons.settings_input_component_outlined,
      VideoShot.falling => Icons.south,
    };

/// A song position as bar.beat (both from 1).
String videoBarBeat(double step, int stepsPerBar) {
  final st = math.max(0.0, step);
  final bar = (st / stepsPerBar).floor() + 1;
  final beat = ((st % stepsPerBar) / 4).floor() + 1;
  final sixteenth = (st % 4);
  return sixteenth.abs() < 1e-6 ? '$bar.$beat' : '$bar.$beat.${sixteenth.floor() + 1}';
}

/// A length as bars and beats ("2 bars", "1 bar 2 beats", "3 steps").
String videoLength(double steps, int stepsPerBar) {
  final bars = (steps / stepsPerBar).floor();
  final rest = steps - bars * stepsPerBar;
  final beats = (rest / 4).floor();
  final st = (rest - beats * 4).round();
  String n(int v, String w) => '$v $w${v == 1 ? '' : 's'}';
  return [if (bars > 0) n(bars, 'bar'), if (beats > 0) n(beats, 'beat'), if (st > 0) n(st, 'step')].join(' ').ifEmpty('0 steps');
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// Fades its child in the first time it is built (a new shot, effect or panel), in the theme's motion.
class VideoAppear extends StatelessWidget {
  const VideoAppear({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final d = Motion.fade(Motion.standard, Motion.of(context));
    if (d == Duration.zero) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: d,
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Opacity(opacity: v, child: child),
      child: child,
    );
  }
}
