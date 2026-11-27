// Field values: the JSON-shaped data a node's fields hold, with the checks, equality and copies ops need.
import 'dart:convert';

import 'limits.dart';

/// A field value is null, a bool, an int, a finite double, a String, a List of values or a Map from String to
/// values: what JSON can hold, so the binary and JSON codecs carry exactly the same values.
///
/// Returns why [value] is not one within [limits], or null when it is.
String? valueProblem(Object? value, [CollabLimits limits = CollabLimits.standard]) => _problem(value, limits, 0);

String? _problem(Object? v, CollabLimits limits, int depth) {
  if (v == null || v is bool || v is int) return null;
  if (v is double) return v.isFinite ? null : 'a number that is not finite';
  if (v is String) return stringProblem(v, limits.maxStringBytes);
  if (v is List || v is Map) {
    if (depth + 1 > limits.maxDepth) return 'nesting deeper than ${limits.maxDepth}';
    if (v is List) {
      if (v.length > limits.maxEntries) return 'a list over ${limits.maxEntries} entries';
      for (final e in v) {
        final p = _problem(e, limits, depth + 1);
        if (p != null) return p;
      }
      return null;
    }
    final m = v as Map;
    if (m.length > limits.maxEntries) return 'a map over ${limits.maxEntries} entries';
    for (final e in m.entries) {
      final k = e.key;
      if (k is! String) return 'a map key that is not a string';
      final p = stringProblem(k, limits.maxStringBytes) ?? _problem(e.value, limits, depth + 1);
      if (p != null) return p;
    }
    return null;
  }
  return 'a ${v.runtimeType}, which is not a JSON value';
}

/// Why [s] is not well-formed UTF-16 of at most [maxBytes] UTF-8 bytes, or null when it is. A lone surrogate is
/// refused: UTF-8 can't carry it, so the two codecs would disagree about the value.
String? stringProblem(String s, int maxBytes) {
  final n = utf8Length(s);
  if (n < 0) return 'a string with a lone surrogate';
  return n > maxBytes ? 'a string over $maxBytes bytes' : null;
}

/// UTF-8 length of [s] without encoding it, or -1 when [s] holds a lone surrogate.
int utf8Length(String s) {
  var n = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x80) {
      n += 1;
    } else if (c < 0x800) {
      n += 2;
    } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length && (s.codeUnitAt(i + 1) & 0xfc00) == 0xdc00) {
      n += 4;
      i++;
    } else if (c >= 0xd800 && c <= 0xdfff) {
      return -1;
    } else {
      n += 3;
    }
  }
  return n;
}

/// Deep equality of two values. An int and a double are different values, even when numerically equal, because
/// the codecs keep them apart.
bool valueEquals(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!valueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || !valueEquals(e.value, b[e.key])) return false;
    }
    return true;
  }
  if (a is double && b is double) return a == b || (a.isNaN && b.isNaN);
  if ((a is int) != (b is int)) return false;
  return a == b;
}

/// An unmodifiable deep copy of [v], so a stored value can't change behind the tree's back.
Object? freezeValue(Object? v) {
  if (v is List) return List<Object?>.unmodifiable(v.map(freezeValue));
  if (v is Map) return Map<String, Object?>.unmodifiable({for (final e in v.entries) e.key as String: freezeValue(e.value)});
  return v;
}

/// Canonical JSON of [v]: map keys sorted, so equal values give equal text (snapshots and hashes compare by it).
String canonicalJson(Object? v) => jsonEncode(_sorted(v));

Object? _sorted(Object? v) {
  if (v is List) return [for (final e in v) _sorted(e)];
  if (v is Map) {
    final keys = v.keys.cast<String>().toList()..sort();
    return {for (final k in keys) k: _sorted(v[k])};
  }
  return v;
}
