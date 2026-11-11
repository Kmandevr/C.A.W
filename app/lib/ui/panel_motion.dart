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
    transitionsBuilder: (context, anim, _, child) => _PanelTransition(animation: anim, reduced: level != MotionLevel.full, child: child),
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

/// The transition for a window or menu over the page (a device's floating window, a long-press menu): in with the
/// theme's entrance kind, out with its exit kind (a fade with Reduced motion); its route's duration decides Off.
Widget popupTransition(BuildContext context, Animation<double> animation, Widget child) =>
    _PanelTransition(animation: animation, reduced: Motion.of(context) != MotionLevel.full, popup: true, child: child);

/// A pushed page coming in with the theme's entrance kind and going out (Back, Esc, the mouse's Back button) with
/// its exit kind: it follows the route's animation status, so the exit runs whichever way the page is closed.
class _PanelTransition extends StatefulWidget {
  const _PanelTransition({required this.animation, required this.reduced, required this.child, this.popup = false});
  final Animation<double> animation;
  final bool reduced;
  final Widget child;

  /// A window or menu over the page (Standard: a small scale and fade) rather than a page (Standard: a slide).
  final bool popup;

  @override
  State<_PanelTransition> createState() => _PanelTransitionState();
}

class _PanelTransitionState extends State<_PanelTransition> {
  late bool _leaving = widget.animation.status == AnimationStatus.reverse;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_status);
  }

  @override
  void didUpdateWidget(_PanelTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_status);
      widget.animation.addStatusListener(_status);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_status);
    super.dispose();
  }

  void _status(AnimationStatus s) {
    final leaving = s == AnimationStatus.reverse;
    if (leaving != _leaving && mounted) setState(() => _leaving = leaving);
  }

  @override
  Widget build(BuildContext context) => EditMotion.transition(widget.animation, widget.child,
      enter: !_leaving,
      fadeOnly: widget.reduced,
      standard: widget.popup
          ? (a, c) => FadeTransition(opacity: a, child: ScaleTransition(
              scale: Tween(begin: widget.reduced ? 1.0 : 0.95, end: 1.0)
                  .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: EditMotion.exitCurve)),
              child: c))
          : (a, c) => SlideTransition(
          position: Tween(begin: const Offset(0.12, 0), end: Offset.zero)
              .animate(CurvedAnimation(parent: a, curve: EditMotion.curveOr(Curves.easeOutCubic), reverseCurve: EditMotion.exitCurve)),
          child: FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOut), child: c)));
}
