// The phone's system bars: edge to edge in portrait, hidden (they come back with a swipe) in phone landscape.
import 'package:flutter/services.dart';

/// Phone landscape fills the whole screen, under the camera cutout too (owner, 2026-11-10); portrait draws edge to
/// edge behind transparent status and navigation bars. Desktop platforms ignore these calls.
class SystemBars {
  SystemBars._();

  static bool? _fullScreen;

  /// Shows the system bars over the app ([fullScreen] false) or hides them until a swipe from the edge.
  static void apply({required bool fullScreen}) {
    if (_fullScreen == fullScreen) return;
    _fullScreen = fullScreen;
    SystemChrome.setEnabledSystemUIMode(fullScreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Color(0x00000000),
      systemNavigationBarColor: Color(0x00000000),
      systemNavigationBarContrastEnforced: false,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
  }
}
