// The FX consolidation's merged devices (1.0.8): each old effect id as its merged device's id and variant, as the engine has them.
//
// The engine's table is the source (engine/src/fx_migrate_*.cpp, docs/engine.md "Merged devices"); the app opens an
// old project through the engine's caw_migrate_component ([ProjectDoc.resolveComponents]) and uses this copy only to
// know, without a call, which old effect a variant was (its device page and its display layout are the old effect's
// for now), whether a saved project needs the file version that holds merged devices, and where a user preset keyed
// by an old id now belongs.

/// One old effect id: the merged device it became and its `variant` there.
class MergedVariant {
  const MergedVariant(this.oldId, this.id, this.variant);
  final String oldId, id;
  final int variant;
}

/// The reserved choice parameter that picks a merged device's variant. Set by hand only: not automatable,
/// modulatable or MIDI-learnable (owner, 2026-11-18).
const variantParam = 'variant';

/// A rack's layout version (`rack_layout`, the engine's kRackLayoutCurrent): the app always saves it on a rack.
const rackLayoutParam = 'rack_layout';
const rackLayoutCurrent = 2.0;

class MergedDevices {
  MergedDevices._();

  /// Every merged device's id (the first variant of a reused id is its old effect under the same id).
  static const ids = [
    'org.caw.compressor', 'org.caw.limiter', 'org.caw.transient', 'org.caw.drive', 'org.caw.bits', 'org.caw.eq',
    'org.caw.filter', 'org.caw.utility', 'org.caw.chorus', 'org.caw.phaser', 'org.caw.tremolo', 'org.caw.delay',
    'org.caw.reverb', 'org.caw.shift',
  ];

  /// The merged ids that no build before 1.0.8 knows (the others reuse an old effect's id as variant 0).
  static const newIds = {'org.caw.drive', 'org.caw.bits', 'org.caw.delay', 'org.caw.reverb', 'org.caw.shift'};

  /// The old ids the merged devices retired, with what they became (engine/src/fx_migrate_*.cpp), and each reused
  /// id's own variant 0.
  static const variants = <MergedVariant>[
    MergedVariant('org.caw.compressor', 'org.caw.compressor', 0),
    MergedVariant('org.caw.dynamics', 'org.caw.compressor', 1),
    MergedVariant('org.caw.gate', 'org.caw.compressor', 2),
    MergedVariant('org.caw.ducker', 'org.caw.compressor', 3),
    MergedVariant('org.caw.limiter', 'org.caw.limiter', 0),
    MergedVariant('org.caw.transient', 'org.caw.transient', 0),
    MergedVariant('org.caw.distortion', 'org.caw.drive', 0),
    MergedVariant('org.caw.saturator', 'org.caw.drive', 1),
    MergedVariant('org.caw.clipper', 'org.caw.drive', 2),
    MergedVariant('org.caw.phasedist', 'org.caw.drive', 3),
    MergedVariant('org.caw.bitcrush', 'org.caw.bits', 0),
    MergedVariant('org.caw.eq', 'org.caw.eq', 0),
    MergedVariant('org.caw.geq', 'org.caw.eq', 1),
    MergedVariant('org.caw.eq.dj', 'org.caw.eq', 2),
    MergedVariant('org.caw.tilt', 'org.caw.eq', 3),
    MergedVariant('org.caw.filter', 'org.caw.filter', 0),
    MergedVariant('org.caw.ladder', 'org.caw.filter', 1),
    MergedVariant('org.caw.nlfilter', 'org.caw.filter', 2),
    MergedVariant('org.caw.utility', 'org.caw.utility', 0),
    MergedVariant('org.caw.stereo.width', 'org.caw.utility', 1),
    MergedVariant('org.caw.stereo.balance', 'org.caw.utility', 2),
    MergedVariant('org.caw.imager', 'org.caw.utility', 3),
    MergedVariant('org.caw.haas', 'org.caw.utility', 4),
    MergedVariant('org.caw.channelmixer', 'org.caw.utility', 5),
    MergedVariant('org.caw.chorus', 'org.caw.chorus', 0),
    MergedVariant('org.caw.ensemble', 'org.caw.chorus', 1),
    MergedVariant('org.caw.doubler', 'org.caw.chorus', 2),
    MergedVariant('org.caw.flanger', 'org.caw.chorus', 3),
    MergedVariant('org.caw.vibrato', 'org.caw.chorus', 4),
    MergedVariant('org.caw.rotary', 'org.caw.chorus', 5),
    MergedVariant('org.caw.phaser', 'org.caw.phaser', 0),
    MergedVariant('org.caw.tremolo', 'org.caw.tremolo', 0),
    MergedVariant('org.caw.autopan', 'org.caw.tremolo', 1),
    MergedVariant('org.caw.delay.pro', 'org.caw.delay', 0),
    MergedVariant('org.caw.delay.pingpong', 'org.caw.delay', 1),
    MergedVariant('org.caw.reverb.pro', 'org.caw.reverb', 0),
    MergedVariant('org.caw.shimmer', 'org.caw.reverb', 1),
    MergedVariant('org.caw.pitchshift', 'org.caw.shift', 0),
    MergedVariant('org.caw.freqshift', 'org.caw.shift', 1),
  ];

  static final Map<String, MergedVariant> _byOld = {for (final v in variants) v.oldId: v};
  static final Map<String, MergedVariant> _byVariant = {for (final v in variants) '${v.id}#${v.variant}': v};

  /// Whether [id] is a merged device.
  static bool isMerged(String id) => ids.contains(id);

  /// Whether [id] is an old effect id a merged device retired (not a reused id, which is still a device).
  static bool isRetired(String id) {
    final v = _byOld[id];
    return v != null && v.id != id;
  }

  /// What the old effect [oldId] became (a reused id: itself, variant 0), or null for any other id.
  static MergedVariant? of(String oldId) => _byOld[oldId];

  /// The variant a merged device's [params] choose (0 when absent; rounded and held to its variants, as the engine).
  static int variantOf(String id, Map<String, double> params, {String prefix = ''}) {
    final v = params['$prefix$variantParam'];
    final count = variants.where((x) => x.id == id).length;
    if (v == null || !v.isFinite || v < 0 || count == 0) return 0;
    return v.round().clamp(0, count - 1);
  }

  /// The old effect [id]'s variant [variant] plays (its device page and display layout), or [id] itself for any
  /// other id.
  static String pageId(String id, int variant) => _byVariant['$id#$variant']?.oldId ?? id;

  /// The engine's caw_migrate_component (`Engine.resolveComponent`), once the engine has loaded (AppState sets it);
  /// null without one.
  static Map<String, dynamic>? Function(Map<String, dynamic> entry)? resolver;

  /// A stored entry outside a project (a user preset's device) in its merged form: a retired id as its merged device
  /// and `variant`, a rack without `rack_layout` migrated by the engine (left as it is without one). Null when there
  /// is nothing to change. `keepsState` false: the old saved state does not carry over.
  static ({String id, Map<String, double> params, bool keepsState})? resolveEntry(String id, Map<String, double> params) {
    final rack = id.startsWith('org.caw.rack.') && (params[rackLayoutParam] ?? 0) < rackLayoutCurrent;
    if (!rack && !isRetired(id)) return null;
    final r = resolver?.call({'id': id, 'params': params});
    if (r != null && r['id'] is String && r['migrated'] == true) {
      return (
        id: r['id'] as String,
        params: {
          for (final e in ((r['params'] as Map?) ?? const {}).entries)
            if (e.value is num && (e.value as num).isFinite) e.key as String: (e.value as num).toDouble(),
        },
        keepsState: r['keeps_state'] != false,
      );
    }
    if (rack || r != null) return null;
    // No engine: every old id keeps its parameters' ids and values (engine/src/fx_migrate_*.cpp move none).
    final v = _byOld[id]!;
    return (id: v.id, params: {...params, variantParam: v.variant.toDouble()}, keepsState: true);
  }

  /// The old effect a component entry's values play: [pageId] of its variant.
  static String pageIdOf(String id, Map<String, double> params, {String prefix = ''}) =>
      isMerged(id) ? pageId(id, variantOf(id, params, prefix: prefix)) : id;
}
