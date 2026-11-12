// Whether a device painter's inputs changed, for shouldRepaint: values compared, anything that could change in place repaints.
import 'dart:ui' show Color, Offset, Rect, Size;

import '../../../model/device_display.dart' show DeviceDisplayFrame;

/// True when [now] differs from [before], field by field (beta plan B4.5: device painters repainted on every
/// rebuild). Numbers, strings, colours, geometry, enums and display frames (made afresh for new data) compare by
/// value; lists and maps made afresh compare by their elements. Anything else — a function, a history buffer, a
/// list or map kept and changed in place (the same object) — counts as changed, so a painter is never left stale.
bool paintInputsChanged(List<Object?> before, List<Object?> now) {
  if (before.length != now.length) return true;
  for (var i = 0; i < now.length; i++) {
    if (!_same(before[i], now[i])) return true;
  }
  return false;
}

bool _same(Object? a, Object? b) {
  if (a == null || b == null) return a == b;
  if (_value(a)) return a == b;
  if (a is DeviceDisplayFrame) return identical(a, b);
  if (identical(a, b)) return false; // kept and perhaps changed in place
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_element(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || !_element(e.value, b[e.key])) return false;
    }
    return true;
  }
  return false;
}

// A collection's element: a plain value compares by value; anything else only when it is the same object.
bool _element(Object? a, Object? b) {
  if (a == null || b == null) return a == b;
  if (_value(a)) return a == b;
  return identical(a, b) && a is DeviceDisplayFrame;
}

bool _value(Object v) =>
    v is num || v is bool || v is String || v is Color || v is Offset || v is Rect || v is Size || v is Enum;
