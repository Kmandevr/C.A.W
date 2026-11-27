// The schema a tree checks ops against: node kinds, their fields' types and the lists they hold; and the coarse
// project schema, where a track is one node whose single field is its whole JSON.
import 'dart:convert';

import 'package:caw_services/sha256.dart';

import 'values.dart';

/// What a field may hold.
enum FieldType {
  /// Any value (a coarse node's `json`).
  json,

  /// A whole text, written by `text` ops (or cleared by a `set` of null).
  text,
  string,
  integer,

  /// An int or a double.
  number,
  boolean,
}

/// One field's type and, for numbers, its range.
class FieldSpec {
  const FieldSpec(this.type, {this.min, this.max});
  final FieldType type;
  final num? min;
  final num? max;

  /// Why [value] doesn't fit, or null when it does. Null always fits: it clears the field.
  String? problem(Object? value) {
    if (value == null) return null;
    final ok = switch (type) {
      FieldType.json => true,
      FieldType.text || FieldType.string => value is String,
      FieldType.integer => value is int,
      FieldType.number => value is num,
      FieldType.boolean => value is bool,
    };
    if (!ok) return 'not a ${type.name}';
    if (value is num && ((min != null && value < min!) || (max != null && value > max!))) return 'out of range';
    return null;
  }

  Map<String, Object?> describe() => {'type': type.name, if (min != null) 'min': min, if (max != null) 'max': max};
}

/// One node kind: its known fields and the lists of children it holds, each naming the kinds it accepts.
///
/// A field the kind doesn't name is kept as it is, never dropped (the design's rule that the tree preserves
/// unknown fields), and only the generic value limits apply to it.
class KindSpec {
  const KindSpec(this.name, {this.fields = const {}, this.lists = const {}});
  final String name;
  final Map<String, FieldSpec> fields;
  final Map<String, Set<String>> lists;

  Map<String, Object?> describe() => {
        'fields': {for (final e in fields.entries) e.key: e.value.describe()},
        'lists': {for (final e in lists.entries) e.key: (e.value.toList()..sort())},
      };
}

/// The kinds a tree accepts, the root's kind and a version.
class Schema {
  Schema({required this.version, required this.rootKind, required List<KindSpec> kinds})
      : kinds = {for (final k in kinds) k.name: k} {
    if (!this.kinds.containsKey(rootKind)) throw ArgumentError('the root kind $rootKind is not a kind');
  }

  final int version;
  final String rootKind;
  final Map<String, KindSpec> kinds;

  /// Why a [childKind] node can't sit in a [parentKind] node's [list], or null when it can.
  String? childProblem(String parentKind, String list, String childKind) {
    final accepts = kinds[parentKind]?.lists[list];
    if (accepts == null) return '$parentKind has no list $list';
    if (!accepts.contains(childKind)) return '$list in $parentKind does not take $childKind';
    return null;
  }

  /// Why [value] can't be [field] of a [kind] node, or null when it can.
  String? fieldProblem(String kind, String field, Object? value) {
    final spec = kinds[kind]?.fields[field];
    if (spec == null) return null;
    final p = spec.problem(value);
    return p == null ? null : '$kind.$field is $p';
  }

  /// Whether [field] of a [kind] node is a text field (one a `text` op may write).
  bool isText(String kind, String field) => kinds[kind]?.fields[field]?.type == FieldType.text;

  /// The schema's canonical description: the same schema always gives the same text.
  String describe() => canonicalJson({
        'version': version,
        'root': rootKind,
        'kinds': {for (final k in kinds.values) k.name: k.describe()},
      });

  /// SHA-256 of [describe], for the session handshake's schema hash.
  String get hash => sha256Hex(utf8.encode(describe()));
}

/// The coarse project schema: the root `project` keeps everything not yet mapped as one `json` field, and its
/// `tracks` list holds `track` nodes whose single field is the track's whole JSON. Later steps refine it kind by
/// kind (devices, then params, clips, sends, automation points).
///
/// Assumption: the design describes coarse nodes ("a track's whole JSON") but names no kinds or lists; `project`,
/// `tracks` and `track` are the simplest that say it, and the app's adapter maps them later.
final Schema coarseProjectSchema = Schema(version: 1, rootKind: 'project', kinds: const [
  KindSpec('project', fields: {'json': FieldSpec(FieldType.json)}, lists: {'tracks': {'track'}}),
  KindSpec('track', fields: {'json': FieldSpec(FieldType.json)}),
]);
