// Node ids, the project uid and author ids: their formats, checks and generators.
import 'dart:math';

/// The id of every tree's root node.
///
/// Assumption: the design gives the root no id; one fixed id that no generated id can equal keeps it simple.
const String rootId = 'root';

final _nodeId = RegExp(r'^[a-z]{1,4}[0-9a-z]{8}$');
final _projectUid = RegExp(r'^[0-9a-f]{32}$');
final _author = RegExp(r'^[0-9A-Za-z]{1,64}$');
final _name = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$');

/// Node ids: a lowercase prefix and 8 base-36 characters, the form the app's `newId` already makes
/// (`d` for device instances, `s` sends, `al` automation lanes, `ap` points, `cs` component samples, `n` notes).
///
/// Assumption: the prefix is 1 to 4 lowercase letters (the longest in use today is `cpp`).
abstract final class NodeIds {
  /// Whether [id] is a node id or [rootId].
  static bool isValid(String id) => id == rootId || _nodeId.hasMatch(id);

  /// A new id with [prefix], as the app's `newId` makes them (8 base-36 characters from a secure random source).
  static String create(String prefix, [Random? random]) {
    if (!RegExp(r'^[a-z]{1,4}$').hasMatch(prefix)) throw ArgumentError.value(prefix, 'prefix', 'Not 1-4 lowercase letters');
    final r = random ?? Random.secure();
    return '$prefix${List.generate(8, (_) => r.nextInt(36).toRadixString(36)).join()}';
  }
}

/// The project's 128-bit uid, which names it across devices and copies.
///
/// Assumption: written as 32 lowercase hexadecimal characters (the design gives its size, not its spelling).
abstract final class ProjectUids {
  static bool isValid(String uid) => _projectUid.hasMatch(uid);

  static String create([Random? random]) {
    final r = random ?? Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

/// Author ids: the device key id every op carries.
///
/// Assumption: 1 to 64 base-62 characters. Device keys arrive in a later step; until then this is only a format.
abstract final class AuthorIds {
  static bool isValid(String author) => _author.hasMatch(author);

  /// The short id the host appends to a tied fractional key: the first 6 characters.
  ///
  /// Assumption: the design says "the author's short id" without a length.
  static String short(String author) => author.length <= 6 ? author : author.substring(0, 6);
}

/// Field names and list names: an identifier of at most 64 characters.
///
/// Assumption: the design names fields (`json`, `source`) but sets no format; identifiers keep them safe in both
/// codecs and in a schema description.
bool isValidName(String name) => _name.hasMatch(name);
