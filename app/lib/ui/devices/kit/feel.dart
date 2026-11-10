// The device editors' one haptic hook and finger count: a light tick on grab, detent and tap; fine adjust under two fingers or Shift.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../haptics.dart';

/// What a haptic is for.
enum DeviceFeelKind { grab, detent, tap, release }

/// The single place device controls ask for haptics. The default plays the app's semantic haptics ([Haptics]: the
/// phone's fine primitives, the on/off and Strength settings, the rate limit): a grab, a detent's tick, a tap, and a
/// drop on release.
class DeviceFeel {
  DeviceFeel._();

  static void Function(DeviceFeelKind kind) hook = _default;

  static void _default(DeviceFeelKind kind) => switch (kind) {
        DeviceFeelKind.grab => Haptics.grab(),
        DeviceFeelKind.detent => Haptics.tick(),
        DeviceFeelKind.tap => Haptics.tap(),
        DeviceFeelKind.release => Haptics.drop(),
      };

  static void grab() => hook(DeviceFeelKind.grab);
  static void detent() => hook(DeviceFeelKind.detent);
  static void tap() => hook(DeviceFeelKind.tap);
  static void release() => hook(DeviceFeelKind.release);
}

/// How many fingers are on a device editor now (its root listens), for FabFilter's fine adjust: a second finger held
/// anywhere while dragging slows the drag to a fifth. Shift does the same with a mouse.
class DeviceFingers {
  DeviceFingers._();
  static final Set<int> _down = {};

  static int get count => _down.length;

  /// The factor a drag is scaled by now: 0.2 under a second finger or Shift, else 1.
  static double get fine => count >= 2 || HardwareKeyboard.instance.isShiftPressed ? 0.2 : 1.0;

  /// Wraps an editor so its fingers are counted.
  static Widget counter({required Widget child}) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => _down.add(e.pointer),
        onPointerUp: (e) => _down.remove(e.pointer),
        onPointerCancel: (e) => _down.remove(e.pointer),
        child: child,
      );
}
