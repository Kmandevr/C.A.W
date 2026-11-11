// Esc and the mouse's Back button close the page in front when it is one of the closable pages (Settings, the theme editor, Export, a device editor, the full-screen piano roll, the project library, the Build tools).
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'pointer_input.dart';

/// The settings a closable page's route is pushed with: Esc or the mouse's Back button pops it while it is in front.
const closablePage = RouteSettings(name: 'caw-closable-page');

/// Follows the app navigator's routes, so [PageCloser] knows which one is in front.
class PageCloserObserver extends NavigatorObserver {
  final List<Route<dynamic>> _routes = [];

  /// The route in front, or null.
  Route<dynamic>? get top => _routes.lastOrNull;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _routes.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _routes.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _routes.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (newRoute == null) return;
    if (i < 0) {
      _routes.add(newRoute);
    } else {
      _routes[i] = newRoute;
    }
  }

  /// Pops the route in front if it is a closable page; true when it did.
  bool closeTop() {
    final r = top;
    if (r == null || r.settings.name != closablePage.name || !r.isCurrent) return false;
    r.navigator?.maybePop();
    return true;
  }
}

/// Wraps the app's navigator (MaterialApp's builder): a key event nothing under it handled, Esc, and a mouse's Back
/// button close a closable page in front. Touch is unaffected; Android's system Back already pops pages.
class PageCloser extends StatelessWidget {
  const PageCloser({super.key, required this.observer, required this.child});
  final PageCloserObserver observer;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          if (isMousePointer(e.kind) && e.buttons & kBackMouseButton != 0) observer.closeTop();
        },
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, e) => e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && observer.closeTop()
              ? KeyEventResult.handled
              : KeyEventResult.ignored,
          child: child,
        ),
      );
}
