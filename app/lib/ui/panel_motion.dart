// Edit animations for panels, menus and pages (EditMotionKind.panels): the pushed page's route and the sheet's style.
import 'package:flutter/material.dart';

import 'motion.dart';
import 'page_closer.dart';

/// How long a pushed page's transition runs with Subtle (Material's own page transition).
const pageTransition = Duration(milliseconds: 300);

/// How long a bottom sheet takes to rise with Subtle (Material's own), and to go.
const sheetEnter = Duration(milliseconds: 250), sheetExit = Duration(milliseconds: 200);

/// A route for a pushed page (a Settings section, the theme editor), animated as an edit animation of panels:
/// Material's own page transition with the app's own feel ([MotionFeel.subtle]) and full motion (as before edit
/// styles); otherwise the theme's pace, curve and entrance and exit kinds ([EditMotion.transition]; Playful slides in
/// with a small overshoot); a fade with Reduced motion, and none with motion Off or panels turned off. Esc and the
/// mouse's Back button close it ([closablePage]).
Route<T> panelRoute<T>(BuildContext context, WidgetBuilder builder) {
  final level = Motion.of(context);
  final d = EditMotion.scaled(level, EditMotionKind.panels, pageTransition);
  if (d != null && level == MotionLevel.full && EditMotion.feel == MotionFeel.subtle) {
    return MaterialPageRoute<T>(settings: closablePage, builder: builder);
  }
  return PageRouteBuilder<T>(
    settings: closablePage,
    pageBuilder: (context, _, _) => builder(context),
    transitionDuration: d ?? Duration.zero,
    reverseTransitionDuration: d == null ? Duration.zero : Motion.paced(pageTransition),
    transitionsBuilder: (context, anim, _, child) {
      final reduced = level != MotionLevel.full;
      // Coming in, the entrance kind; going out (the route's animation running back), the exit kind.
      final leaving = anim.status == AnimationStatus.reverse;
      return EditMotion.transition(anim, child, enter: !leaving, fadeOnly: reduced,
          standard: (a, c) => SlideTransition(
              position: Tween(begin: const Offset(0.12, 0), end: Offset.zero)
                  .animate(CurvedAnimation(parent: a, curve: EditMotion.curveOr(Curves.easeOutCubic), reverseCurve: EditMotion.exitCurve)),
              child: FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOut), child: c)));
    },
  );
}

/// The animation style for a bottom sheet under [context]: Material's own with the app's own feel and full motion
/// (null); otherwise the theme's pace and curve (Playful a longer rise with a small overshoot); none with Reduced or
/// Off motion or panels turned off (a sheet's rise is movement, which Reduced leaves out).
AnimationStyle? sheetAnimation(BuildContext context) {
  final level = Motion.of(context);
  final d = EditMotion.scaled(level, EditMotionKind.panels, sheetEnter);
  if (d == null || level != MotionLevel.full) return AnimationStyle.noAnimation;
  if (EditMotion.feel == MotionFeel.subtle) return null;
  return AnimationStyle(
      duration: d, reverseDuration: Motion.paced(sheetExit), curve: EditMotion.curveOr(Curves.easeOutCubic));
}
