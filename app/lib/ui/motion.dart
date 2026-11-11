// Motion and feel: the motion setting, distance-aware settle durations, the small-overshoot curve, snapping maths.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'haptics.dart';

/// How much the app moves (owner, 2026-11-04): Full; Reduced keeps fades but no movement or springs; Off keeps only
/// the motion that helps use the app (owner, 2026-11-11: drag ghosts, snapping, press feedback; [Motion.usability]).
enum MotionLevel {
  full('Full'),
  reduced('Reduced: fades only'),
  off('Off: only drags, snapping and presses');

  const MotionLevel(this.label);
  final String label;
}

/// The shared motion rules ([UI plan](docs/ui-plan.md), "Feel"). Settings sets the statics, like `Neon`.
class Motion {
  Motion._();

  /// The user's choice. [effective] combines it with the performance profile and the system setting.
  static MotionLevel setting = MotionLevel.full;

  /// Haptics on or off (on by default, owner): the same switch as [Haptics.enabled].
  static bool get haptics => Haptics.enabled;
  static set haptics(bool on) => Haptics.enabled = on;

  /// True while the Minimal performance profile is on: it turns motion off.
  static bool minimalProfile = false;

  /// Small feedback (press, a handle growing), standard changes (toolbar parts, selection, lanes) and panels/sheets,
  /// as designed; [move] and [fade] scale them by the theme's pace ([EditMotion.feel]).
  static const small = Duration(milliseconds: 80);
  static const standard = Duration(milliseconds: 160);
  static const panel = Duration(milliseconds: 240);

  /// The level in force: Minimal means Off, and the system's reduce-motion setting caps it at Reduced.
  static MotionLevel effective({bool systemReduce = false}) {
    if (minimalProfile || setting == MotionLevel.off) return MotionLevel.off;
    if (systemReduce || setting == MotionLevel.reduced) return MotionLevel.reduced;
    return MotionLevel.full;
  }

  /// [effective] for the widget tree under [context] (reads the platform's disable-animations flag).
  static MotionLevel of(BuildContext context) =>
      effective(systemReduce: MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  /// How long a settle takes for [distancePx]: longer moves go faster, growing logarithmically (owner).
  /// 80 ms + 40 ms per doubling of (1 + d/8), between 80 and 240 ms: about 120 ms for 8 px, 210 ms for 64 px.
  static Duration settle(double distancePx) {
    final d = distancePx.isNaN ? 0.0 : distancePx.abs();
    final ms = (80 + 40 * math.log(1 + d / 8) / math.ln2).clamp(80.0, 240.0);
    return Duration(microseconds: (ms * 1000).round());
  }

  /// The overshoot as a fraction of the distance: at most 2 px, or 4% of the distance if that is smaller.
  static double overshoot(double distancePx) {
    final d = distancePx.isNaN ? 0.0 : distancePx.abs();
    return d <= 0 ? 0 : math.min(2 / d, 0.04);
  }

  /// The level that motion which helps use the app runs at (drag ghosts, snap settles, press and grab feedback,
  /// drop targets; owner, 2026-11-11): the Off switch leaves it on as Full, and Reduced (or the system's
  /// reduce-motion setting) still turns its movement into a fade. Pass the result to [move], [fade] and
  /// [settleCurve] in place of the plain level.
  static MotionLevel usability(MotionLevel level) => level == MotionLevel.off ? MotionLevel.full : level;

  /// [usability] for the widget tree under [context].
  static MotionLevel usabilityOf(BuildContext context) => usability(of(context));

  /// A movement's duration at [level]: zero unless motion is full (Reduced and Off don't move things).
  static Duration move(Duration d, MotionLevel level) => level == MotionLevel.full ? paced(d) : Duration.zero;

  /// A fade's duration at [level]: fades stay in Reduced, and Off has none.
  static Duration fade(Duration d, MotionLevel level) => level == MotionLevel.off ? Duration.zero : paced(d);

  /// [d] at the theme's pace (Quick, Normal or Relaxed; [EditMotion.feel]).
  static Duration paced(Duration d) => EditMotion.feel.pace == MotionPace.normal ? d : d * EditMotion.feel.pace.scale;

  /// The curve a settle over [distancePx] uses at [level].
  static Curve settleCurve(double distancePx, MotionLevel level) =>
      level == MotionLevel.full ? OvershootCurve(overshoot(distancePx)) : Curves.linear;

  /// A light tick when something snaps, clicks into a detent, or a note is placed ([Haptics.tick], rate-limited).
  static void tick() => Haptics.tick();
}

/// Ease-out that passes the end by [amount] (a fraction of the distance) and settles back on it.
/// It is the ease-out-back family `1 + (s+1)(t-1)^3 + s(t-1)^2`, with `s` chosen so the peak is exactly 1 + amount.
class OvershootCurve extends Curve {
  OvershootCurve(double amount) : amount = amount.clamp(0.0, 0.1), _s = _strength(amount.clamp(0.0, 0.1));

  final double amount;
  final double _s;

  @override
  double transformInternal(double t) {
    final u = t - 1;
    return 1 + (_s + 1) * u * u * u + _s * u * u;
  }

  /// The peak of the curve for strength [s]: `4s^3 / (27(s+1)^2)` above 1, at t = 1 - 2s/(3(s+1)).
  static double peakFor(double s) => 4 * s * s * s / (27 * (s + 1) * (s + 1));

  static double _strength(double amount) {
    if (amount <= 0) return 0;
    var lo = 0.0, hi = 4.0;
    for (var i = 0; i < 40; i++) {
      final mid = (lo + hi) / 2;
      if (peakFor(mid) < amount) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }
}

/// Snapping maths shared by notes, clips, curves and lanes.
class Snap {
  Snap._();

  /// [v] on the nearest multiple of [grid]; [grid] <= 0 means no snapping.
  static double to(double v, double grid) => grid <= 0 ? v : (v / grid).roundToDouble() * grid;

  /// How close [v] is to its snap target, from 0 (at least [reach] away) to 1 (on it), to light the target line.
  /// All three values are in the same unit (pixels, usually).
  static double nearness(double v, double grid, double reach) {
    if (grid <= 0 || reach <= 0) return 0;
    final off = (v - to(v, grid)).abs();
    return (1 - off / reach).clamp(0.0, 1.0);
  }
}

/// What an edit animation is for (owner, 2026-11-11): each kind can be turned off on its own.
enum EditMotionKind {
  notes('Notes added, deleted and moved'),
  clips('Clips added, deleted and moved'),
  tracks('Tracks added, deleted and reordered'),
  lengths('Lengths and sizes changing'),
  panels('Panels, menus and pages');

  const EditMotionKind(this.label);
  final String label;
}

/// How edit animations feel (owner, 2026-11-11: the user's choice, Subtle by default). Since the theme's motion
/// tokens ([MotionFeel]) these are two of its looks: Subtle is [MotionFeel.subtle], Playful [MotionFeel.playful].
enum EditMotionStyle {
  subtle('Subtle'),
  playful('Playful');

  const EditMotionStyle(this.label);
  final String label;
}

/// How long the theme's animations run (owner, 2026-11-11: the animation style is a theme property).
enum MotionPace {
  quick('Quick', 0.7),
  normal('Normal', 1),
  relaxed('Relaxed', 1.5);

  const MotionPace(this.label, this.scale);
  final String label;
  final double scale;
}

/// The theme's curve family: Smooth (an ease-out), Snappy (fast out, slow in), Bouncy (a small overshoot) or Linear.
enum MotionCurve {
  smooth('Smooth'),
  snappy('Snappy'),
  bouncy('Bouncy'),
  linear('Linear');

  const MotionCurve(this.label);
  final String label;
}

/// How pages, panels and things added come in and go out. Standard keeps each one's own (Material's page
/// transition, the sheet's rise, an edit's own grow or slide).
enum MotionTransition {
  standard('Standard'),
  fade('Fade'),
  scale('Scale'),
  slide('Slide'),
  fadeScale('Fade + scale');

  const MotionTransition(this.label);
  final String label;
}

/// The theme's animation style: pace, curve, and how things enter and exit. Reduced motion still means fades only,
/// and Off keeps only the motion that helps use the app, whatever these say.
class MotionFeel {
  const MotionFeel(
      {this.pace = MotionPace.normal,
      this.curve = MotionCurve.smooth,
      this.enter = MotionTransition.standard,
      this.exit = MotionTransition.standard});

  final MotionPace pace;
  final MotionCurve curve;
  final MotionTransition enter, exit;

  /// The app's own look, as before the tokens (and Subtle).
  static const subtle = MotionFeel();

  /// Playful: longer, with a small overshoot, pages sliding in.
  static const playful = MotionFeel(pace: MotionPace.relaxed, curve: MotionCurve.bouncy, enter: MotionTransition.slide);

  /// The presets (owner, 2026-11-11): Calm, Snappy, Bouncy, Minimal.
  static const presets = {
    'Calm': MotionFeel(pace: MotionPace.relaxed, curve: MotionCurve.smooth, enter: MotionTransition.fade, exit: MotionTransition.fade),
    'Snappy': MotionFeel(pace: MotionPace.quick, curve: MotionCurve.snappy, enter: MotionTransition.fadeScale, exit: MotionTransition.fade),
    'Bouncy': MotionFeel(pace: MotionPace.normal, curve: MotionCurve.bouncy, enter: MotionTransition.scale, exit: MotionTransition.fadeScale),
    'Minimal': MotionFeel(pace: MotionPace.quick, curve: MotionCurve.linear, enter: MotionTransition.fade, exit: MotionTransition.fade),
  };

  /// The preset this is, if any.
  String? get presetName => presets.entries.where((e) => e.value == this).firstOrNull?.key;

  MotionFeel copyWith({MotionPace? pace, MotionCurve? curve, MotionTransition? enter, MotionTransition? exit}) =>
      MotionFeel(pace: pace ?? this.pace, curve: curve ?? this.curve, enter: enter ?? this.enter, exit: exit ?? this.exit);

  /// As a profile value: `pace,curve,enter,exit` by name.
  String encode() => '${pace.name},${curve.name},${enter.name},${exit.name}';

  /// Reads [encode]'s text; null when it doesn't read.
  static MotionFeel? decode(String? text) {
    final p = (text ?? '').split(',').map((e) => e.trim()).toList();
    if (p.length != 4) return null;
    T? pick<T extends Enum>(List<T> values, String name) => values.where((v) => v.name == name).firstOrNull;
    final pace = pick(MotionPace.values, p[0]), curve = pick(MotionCurve.values, p[1]);
    final enter = pick(MotionTransition.values, p[2]), exit = pick(MotionTransition.values, p[3]);
    if (pace == null || curve == null || enter == null || exit == null) return null;
    return MotionFeel(pace: pace, curve: curve, enter: enter, exit: exit);
  }

  @override
  bool operator ==(Object other) =>
      other is MotionFeel && other.pace == pace && other.curve == curve && other.enter == enter && other.exit == exit;

  @override
  int get hashCode => Object.hash(pace, curve, enter, exit);
}

/// Edit animations: what appears, disappears, moves or resizes because of an edit. Separate from the motion that
/// helps use the app (drag ghosts, snapping, press feedback: [Motion.usability], kept even when motion is Off).
/// Settings sets the statics.
class EditMotion {
  EditMotion._();

  /// The theme's animation style (pace, curve, entrance and exit); Settings sets it.
  static MotionFeel feel = MotionFeel.subtle;

  /// Subtle or Playful, read from [feel] (Playful is any bouncy feel); setting one sets [feel] to it.
  static EditMotionStyle get style => feel.curve == MotionCurve.bouncy ? EditMotionStyle.playful : EditMotionStyle.subtle;
  static set style(EditMotionStyle s) => feel = s == EditMotionStyle.playful ? MotionFeel.playful : MotionFeel.subtle;

  /// The kinds turned on (all by default).
  static Set<EditMotionKind> kinds = {...EditMotionKind.values};

  /// How long an edit animation of [kind] runs under [context], or null when it doesn't run: Motion Off (or the
  /// Minimal profile), the kind turned off. Reduced motion keeps it as a fade ([fadeOnly]).
  static Duration? of(BuildContext context, EditMotionKind kind) =>
      durationFor(Motion.of(context), kind);

  static Duration? durationFor(MotionLevel level, EditMotionKind kind) {
    if (level == MotionLevel.off || !kinds.contains(kind)) return null;
    return feel == MotionFeel.playful ? const Duration(milliseconds: 260) : Motion.paced(const Duration(milliseconds: 160));
  }

  /// A note or clip moved by an edit (keys, a menu, a nudge, a paste in place, a quantize, a drag's last snap) slides
  /// there in this, before the theme's pace: shorter than other edits, so it feels snappy (owner, 2026-11-11).
  static const nudgeBase = Duration(milliseconds: 105);

  /// How long a move of [kind] slides under [context], or null when it doesn't (motion Off or Reduced, the kind off).
  static Duration? nudge(BuildContext context, EditMotionKind kind) {
    final level = Motion.of(context);
    if (level != MotionLevel.full || !kinds.contains(kind)) return null;
    return Motion.paced(nudgeBase);
  }

  /// A move's curve: a fast ease-out in the theme's curve family.
  static Curve get nudgeCurve => switch (feel.curve) {
        MotionCurve.bouncy => playfulCurve,
        MotionCurve.linear => Curves.linear,
        _ => Curves.easeOutQuart,
      };

  /// True when only a fade may run (Reduced motion): no scaling, sliding or springs.
  static bool fadeOnly(BuildContext context) => Motion.of(context) == MotionLevel.reduced;

  /// For motion that already had its own length before edit styles (panels, sheets, pages, the section switch):
  /// [subtle] itself for Subtle (so Subtle looks as it did), [playfulScale] times longer for Playful, and null when
  /// it doesn't run (motion Off or the Minimal profile, or [kind] turned off).
  static const playfulScale = 1.5;
  static Duration? scaled(MotionLevel level, EditMotionKind kind, Duration subtle) {
    if (level == MotionLevel.off || !kinds.contains(kind)) return null;
    return Motion.paced(subtle); // Relaxed is Playful's [playfulScale]
  }

  /// The curve for motion that had its own before styles: [subtle] itself with Smooth, Playful's small overshoot
  /// with Bouncy, fast-out-slow-in with Snappy, linear with Linear.
  static Curve curveOr(Curve subtle) => switch (feel.curve) {
        MotionCurve.smooth => subtle,
        MotionCurve.bouncy => playfulCurve,
        MotionCurve.snappy => Curves.fastOutSlowIn,
        MotionCurve.linear => Curves.linear,
      };

  /// Playful's ease-out with a small overshoot: a gentler back curve than [Curves.easeOutBack], so a sheet or page
  /// passing its place by a few pixels doesn't uncover the edge behind it for long.
  static const Curve playfulCurve = Cubic(0.34, 1.32, 0.64, 1);

  /// The kinds as saved in settings and theme files (their names, in [EditMotionKind] order).
  static List<String> kindNames(Set<EditMotionKind> kinds) =>
      [for (final k in EditMotionKind.values) if (kinds.contains(k)) k.name];
  static Set<EditMotionKind> parseKinds(Iterable<Object?> names) =>
      {for (final k in EditMotionKind.values) if (names.contains(k.name)) k};

  /// The curve for things appearing or moving, by the theme's curve family.
  static Curve get curve => switch (feel.curve) {
        MotionCurve.smooth => Curves.easeOutCubic,
        MotionCurve.bouncy => Curves.easeOutBack,
        MotionCurve.snappy => Curves.fastOutSlowIn,
        MotionCurve.linear => Curves.linear,
      };

  /// The curve for things going away.
  static Curve get exitCurve => feel.curve == MotionCurve.linear ? Curves.linear : Curves.easeInCubic;

  /// [child] coming in ([enter]) or going out as [animation] runs from 0 to 1 (1 is fully shown), in the theme's
  /// [MotionFeel.enter] or [MotionFeel.exit] kind. With [fadeOnly] (Reduced motion) always a fade; Standard falls
  /// back to [standard] (the caller's own transition) or a fade.
  static Widget transition(Animation<double> animation, Widget child,
      {bool enter = true, bool fadeOnly = false, Widget Function(Animation<double>, Widget)? standard}) {
    final kind = fadeOnly ? MotionTransition.fade : (enter ? feel.enter : feel.exit);
    final t = CurvedAnimation(parent: animation, curve: curveOr(Curves.easeOutCubic), reverseCurve: exitCurve);
    Widget fade(Widget c) => FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut), child: c);
    Widget scale(Widget c) => ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(t), child: c);
    return switch (kind) {
      MotionTransition.standard => standard?.call(animation, child) ?? fade(child),
      MotionTransition.fade => fade(child),
      MotionTransition.scale => scale(child),
      MotionTransition.slide =>
        SlideTransition(position: Tween(begin: const Offset(0.12, 0), end: Offset.zero).animate(t), child: fade(child)),
      MotionTransition.fadeScale => fade(scale(child)),
    };
  }
}
