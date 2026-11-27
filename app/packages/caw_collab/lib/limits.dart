// The bounds every decoded operation and the tree are held to, and the one error a decoder may throw.
//
// Assumption: the numbers below are this package's own choices (the design asks for size, depth and count caps on
// untrusted ops but names no values); a later step can tune them. maxOpBytes matches the engine's 8 MiB cap on a
// whole project's JSON, since a coarse node's value can be at most a whole project.

/// The caps a decoder applies to untrusted bytes or text before and while it reads them.
class CollabLimits {
  const CollabLimits({
    this.maxOpBytes = 8 * 1024 * 1024,
    this.maxBatchOps = 4096,
    this.maxDepth = 64,
    this.maxEntries = 65536,
    this.maxStringBytes = 8 * 1024 * 1024,
    this.maxKeyLength = 1024,
    this.maxFields = 1024,
  });

  /// The most bytes (binary) or UTF-16 code units (JSON) one encoded op or batch may take.
  final int maxOpBytes;

  /// The most ops in one batch.
  final int maxBatchOps;

  /// The deepest nesting of lists and maps inside a value (a value that is a list holding a list has depth 2).
  final int maxDepth;

  /// The most entries in one list or map inside a value.
  final int maxEntries;

  /// The most UTF-8 bytes in one string.
  final int maxStringBytes;

  /// The longest fractional key.
  final int maxKeyLength;

  /// The most fields an insert may carry.
  final int maxFields;

  static const standard = CollabLimits();
}

/// The caps a tree holds itself to, whatever its ops say.
class TreeLimits {
  const TreeLimits({this.maxNodes = 200000, this.maxDepth = 64});

  /// The most nodes, tombstones included (they stay until compaction).
  final int maxNodes;

  /// The deepest a node may sit below the root (the root's children are at depth 1).
  final int maxDepth;

  static const standard = TreeLimits();
}

/// The only error a decoder throws: the input was malformed, over a limit or failed a check.
class CollabDecodeError implements Exception {
  const CollabDecodeError(this.message);
  final String message;

  @override
  String toString() => 'CollabDecodeError: $message';
}
