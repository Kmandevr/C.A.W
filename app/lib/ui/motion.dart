// Motion and feel: the motion setting, distance-aware settle durations, the small-overshoot curve, snapping maths.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'haptics.dart';

/// How much the app moves (owner, 2026-11-04): Full; Reduced keeps fades but no movement or springs; Off.
enum MotionLevel {
  full('Full'),
  reduced('Reduced: fades only'),
  off('Off');

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

  /// Small feedback (press, a handle growing), standard changes (toolbar parts, selection, lanes) and panels/sheets.
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

  /// A movement's duration at [level]: zero unless motion is full (Reduced and Off don't move things).
  static Duration move(Duration d, MotionLevel level) => level == MotionLevel.full ? d : Duration.zero;

  /// A fade's duration at [level]: fades stay in Reduced, and Off has none.
  static Duration fade(Duration d, MotionLevel level) => level == MotionLevel.off ? Duration.zero : d;

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

/// How edit animations feel (owner, 2026-11-11: the user's choice, Subtle by default).
enum EditMotionStyle {
  subtle('Subtle'),
  playful('Playful');

  const EditMotionStyle(this.label);
  final String label;
}

/// Edit animations: what appears, disappears, moves or resizes because of an edit. Separate from the motion that
/// helps use the app (drag ghosts, snapping, press feedback, which [Motion] keeps even when everything else is Off).
/// Settings sets the statics.
class EditMotion {
  EditMotion._();

  static EditMotionStyle style = EditMotionStyle.subtle;

  /// The kinds turned on (all by default).
  static Set<EditMotionKind> kinds = {...EditMotionKind.values};

  /// How long an edit animation of [kind] runs under [context], or null when it doesn't run: Motion Off (or the
  /// Minimal profile), the kind turned off. Reduced motion keeps it as a fade ([fadeOnly]).
  static Duration? of(BuildContext context, EditMotionKind kind) =>
      durationFor(Motion.of(context), kind);

  static Duration? durationFor(MotionLevel level, EditMotionKind kind) {
    if (level == MotionLevel.off || !kinds.contains(kind)) return null;
    return switch (style) {
      EditMotionStyle.subtle => const Duration(milliseconds: 160),
      EditMotionStyle.playful => const Duration(milliseconds: 260),
    };
  }

  /// True when only a fade may run (Reduced motion): no scaling, sliding or springs.
  static bool fadeOnly(BuildContext context) => Motion.of(context) == MotionLevel.reduced;

  /// The curve for things appearing or moving: an ease-out for Subtle, a small overshoot for Playful.
  static Curve get curve => style == EditMotionStyle.playful ? Curves.easeOutBack : Curves.easeOutCubic;

  /// The curve for things going away.
  static const Curve exitCurve = Curves.easeInCubic;
}
