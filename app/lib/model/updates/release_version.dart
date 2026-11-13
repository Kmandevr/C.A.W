// Semantic versions (semver.org 2.0.0) as C.A.W tags them: v1.0.0-alpha.1, v1.0.0-beta.2, v1.0.0; ordered with
// pre-releases, so for one version number alpha < beta < the full release.
class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(this.major, this.minor, this.patch, [this.pre = const []]);

  final int major, minor, patch;

  /// The pre-release identifiers (`alpha`, `1`), empty for a full release. Build metadata (`+2`) is dropped: semver
  /// ignores it in ordering.
  final List<String> pre;

  static final _pattern = RegExp(
      r'^v?(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z.-]+)?$');

  /// Reads `1.2.3`, `v1.2.3-beta.1` or `1.2.3-alpha.1+4`; null for anything else (a short or odd tag, too long).
  static ReleaseVersion? tryParse(String text) {
    final t = text.trim();
    if (t.length > 64) return null;
    final m = _pattern.firstMatch(t);
    if (m == null) return null;
    return ReleaseVersion(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), m[4]?.split('.') ?? const []);
  }

  bool get isFull => pre.isEmpty;

  /// The first pre-release word, lower case (`alpha`, `beta`), or '' for a full release.
  String get stage => pre.isEmpty ? '' : pre.first.toLowerCase();

  @override
  int compareTo(ReleaseVersion o) {
    for (final (a, b) in [(major, o.major), (minor, o.minor), (patch, o.patch)]) {
      if (a != b) return a.compareTo(b);
    }
    if (pre.isEmpty || o.pre.isEmpty) return pre.isEmpty == o.pre.isEmpty ? 0 : (pre.isEmpty ? 1 : -1);
    for (var i = 0; i < pre.length && i < o.pre.length; i++) {
      final c = _comparePart(pre[i], o.pre[i]);
      if (c != 0) return c;
    }
    return pre.length.compareTo(o.pre.length);
  }

  static int _comparePart(String a, String b) {
    final x = int.tryParse(a), y = int.tryParse(b);
    if (x != null && y != null) return x.compareTo(y);
    if (x != null) return -1; // numbers sort before words
    if (y != null) return 1;
    return a.compareTo(b);
  }

  bool operator <(ReleaseVersion o) => compareTo(o) < 0;
  bool operator >(ReleaseVersion o) => compareTo(o) > 0;

  @override
  bool operator ==(Object other) => other is ReleaseVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, pre.join('.'));

  @override
  String toString() => '$major.$minor.$patch${pre.isEmpty ? '' : '-${pre.join('.')}'}';
}
