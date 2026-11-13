// The phone's system bars: edge to edge in portrait, hidden (they come back with a swipe) in phone landscape.
import 'package:flutter/services.dart';

/// Phone landscape fills the whole screen, under the camera cutout too (owner, 2026-11-10); portrait draws edge to
/// edge behind transparent status and navigation bars. Desktop platforms ignore these calls.
class SystemBars {
  SystemBars._();

  static bool? _fullScreen, _lightTheme;

  /// Shows the system bars over the app ([fullScreen] false) or hides them until a swipe from the edge. Their icons
  /// are dark over a light theme ([lightTheme]) and light over a dark one, so the clock and battery stay readable.
  static void apply({required bool fullScreen, bool lightTheme = false}) {
    if (_fullScreen == fullScreen && _lightTheme == lightTheme) return;
    _fullScreen = fullScreen;
    _lightTheme = lightTheme;
    final icons = lightTheme ? Brightness.dark : Brightness.light;
    SystemChrome.setEnabledSystemUIMode(fullScreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: const Color(0x00000000),
      systemNavigationBarColor: const Color(0x00000000),
      systemNavigationBarContrastEnforced: false,
      statusBarIconBrightness: icons,
      systemNavigationBarIconBrightness: icons,
    ));
  }
}
