// Edit animations for panels, menus and pages (EditMotionKind.panels): the pushed page's route and the sheet's style.
import 'package:flutter/material.dart';

import 'motion.dart';

/// How long a pushed page's transition runs with Subtle (Material's own page transition).
const pageTransition = Duration(milliseconds: 300);

/// How long a bottom sheet takes to rise with Subtle (Material's own), and to go.
const sheetEnter = Duration(milliseconds: 250), sheetExit = Duration(milliseconds: 200);

/// A route for a pushed page (a Settings section, the theme editor), animated as an edit animation of panels:
/// Material's own page transition with Subtle and full motion (as before edit styles), a longer slide with a small
/// overshoot with Playful, a fade with Reduced motion, and none with motion Off or panels turned off.
Route<T> panelRoute<T>(BuildContext context, WidgetBuilder builder) {
  final level = Motion.of(context);
  final d = EditMotion.scaled(level, EditMotionKind.panels, pageTransition);
  if (d != null && level == MotionLevel.full && EditMotion.style == EditMotionStyle.subtle) {
    return MaterialPageRoute<T>(builder: builder);
  }
  return PageRouteBuilder<T>(
    pageBuilder: (context, _, _) => builder(context),
    transitionDuration: d ?? Duration.zero,
    reverseTransitionDuration: d == null ? Duration.zero : pageTransition,
    transitionsBuilder: (context, anim, _, child) {
      final fade = FadeTransition(opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut), child: child);
      if (level != MotionLevel.full) return fade;
      final t = CurvedAnimation(parent: anim, curve: EditMotion.playfulCurve, reverseCurve: EditMotion.exitCurve);
      return SlideTransition(position: Tween(begin: const Offset(0.12, 0), end: Offset.zero).animate(t), child: fade);
    },
  );
}

/// The animation style for a bottom sheet under [context]: Material's own with Subtle and full motion (null), a
/// longer rise with a small overshoot with Playful, and none with Reduced or Off motion or panels turned off (a
/// sheet's rise is movement, which Reduced leaves out).
AnimationStyle? sheetAnimation(BuildContext context) {
  final level = Motion.of(context);
  final d = EditMotion.scaled(level, EditMotionKind.panels, sheetEnter);
  if (d == null || level != MotionLevel.full) return AnimationStyle.noAnimation;
  if (EditMotion.style == EditMotionStyle.subtle) return null;
  return AnimationStyle(duration: d, reverseDuration: sheetExit, curve: EditMotion.playfulCurve);
}
