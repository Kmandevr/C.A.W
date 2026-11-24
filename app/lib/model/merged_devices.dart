// The FX consolidation's merged devices (1.0.8): each old effect id as its merged device's id and variant, as the engine has them.
//
// The engine's table is the source (engine/src/fx_migrate_*.cpp, docs/engine.md "Merged devices"); the app opens an
// old project through the engine's caw_migrate_component ([ProjectDoc.resolveComponents]) and uses this copy only to
// know, without a call, which old effect a variant was (its device page and its display layout are the old effect's
// for now), whether a saved project needs the file version that holds merged devices, and where a user preset keyed
// by an old id now belongs.

/// One old effect id: the merged device it became and its `variant` there. A variant that no old effect was (the
/// Compressor's Duck, 1.0.8) has a page id of its own in [oldId] and [retired] false: it names the page and display
/// layout the app gives that variant and is never read from a file.
class MergedVariant {
  const MergedVariant(this.oldId, this.id, this.variant, {this.retired = true});
  final String oldId, id;
  final int variant;
  final bool retired;
}

/// The reserved choice parameter that picks a merged device's variant. Set by hand only: not automatable,
/// modulatable or MIDI-learnable (owner, 2026-11-18).
const variantParam = 'variant';

/// A rack's layout version (`rack_layout`, the engine's kRackLayoutCurrent): the app always saves it on a rack. 3
/// since 1.1.0's Talon/Hatch/Duck split (a Compressor child's variants are Talon's), 4 since 1.1.0's appended
/// sidechain filters and Limiter target (later children's flat route indices moved; the engine re-points older racks).
const rackLayoutParam = 'rack_layout';
const rackLayoutCurrent = 4.0;

/// The Compressor's layout marker (`talon_layout`, the engine's fx_dyn_common.h, 1.1.0): the app always saves it on
/// an org.caw.compressor entry. An entry without it is from 1.0.8 or 1.0.9, whose variants 2 (Gate), 3 (Shape) and
/// 4 (Duck) the engine moves to org.caw.gate 0, org.caw.tremolo 2 and org.caw.duck 0 ([talonMoves]).
const talonLayoutParam = 'talon_layout';
const talonLayoutCurrent = 1.0;
const talonId = 'org.caw.compressor';

class MergedDevices {
  MergedDevices._();

  /// Every merged device's id (the first variant of a reused id is its old effect under the same id).
  static const ids = [
    'org.caw.compressor', 'org.caw.gate', 'org.caw.duck', 'org.caw.limiter', 'org.caw.transient', 'org.caw.drive', 'org.caw.bits', 'org.caw.eq',
    'org.caw.filter', 'org.caw.utility', 'org.caw.chorus', 'org.caw.phaser', 'org.caw.tremolo', 'org.caw.delay',
    'org.caw.reverb', 'org.caw.shift', 'org.caw.convolver',
  ];

  /// The merged ids that no build before 1.0.8 knows (the others reuse an old effect's id as variant 0).
  static const newIds = {'org.caw.drive', 'org.caw.bits', 'org.caw.delay', 'org.caw.reverb', 'org.caw.shift', 'org.caw.duck'};

  /// The old ids the merged devices retired, with what they became (engine/src/fx_migrate_*.cpp), and each reused
  /// id's own variant 0.
  static const variants = <MergedVariant>[
    // 1.1.0's split (engine/src/builtin_fx_merged_dynamics.cpp): Compressor (Talon) Down, Dynamics, Up, Bus; Gate
    // (Hatch) Gate, Expand, Pedal gate; Ducker (Duck) Duck, Level, Carve; Shape went to Tremolo/Pan.
    MergedVariant('org.caw.compressor', 'org.caw.compressor', 0),
    MergedVariant('org.caw.dynamics', 'org.caw.compressor', 1),
    MergedVariant('org.caw.compressor.up', 'org.caw.compressor', 2, retired: false),
    MergedVariant('org.caw.compressor.bus', 'org.caw.compressor', 3, retired: false),
    MergedVariant('org.caw.gate', 'org.caw.gate', 0),
    MergedVariant('org.caw.gate.expand', 'org.caw.gate', 1, retired: false),
    MergedVariant('org.caw.gate.pedal', 'org.caw.gate', 2, retired: false),
    MergedVariant(duckPageId, 'org.caw.duck', 0, retired: false),  // Duck (engine/src/builtin_fx_duck.cpp)
    MergedVariant('org.caw.duck.level', 'org.caw.duck', 1, retired: false),
    MergedVariant('org.caw.duck.carve', 'org.caw.duck', 2, retired: false),
    MergedVariant('org.caw.limiter', 'org.caw.limiter', 0),
    MergedVariant('org.caw.transient', 'org.caw.transient', 0),
    MergedVariant('org.caw.distortion', 'org.caw.drive', 0),
    MergedVariant('org.caw.saturator', 'org.caw.drive', 1),
    MergedVariant('org.caw.clipper', 'org.caw.drive', 2),
    MergedVariant('org.caw.phasedist', 'org.caw.drive', 3),
    // 1.1.0's new modes (engine/src/builtin_fx_*_modes.cpp, _bits_bitwise, _cab, _eq_plume, _filters_wah): each a
    // mode of its family's page (the Convolver's Cab a page of its own).
    MergedVariant('org.caw.drive.amp', 'org.caw.drive', 4, retired: false),
    MergedVariant('org.caw.drive.pedal', 'org.caw.drive', 5, retired: false),
    MergedVariant('org.caw.drive.bands', 'org.caw.drive', 6, retired: false),
    MergedVariant('org.caw.bitcrush', 'org.caw.bits', 0),
    MergedVariant('org.caw.bits.bitwise', 'org.caw.bits', 1, retired: false),
    MergedVariant('org.caw.eq', 'org.caw.eq', 0),
    MergedVariant('org.caw.geq', 'org.caw.eq', 1),
    MergedVariant('org.caw.eq.dj', 'org.caw.eq', 2),
    MergedVariant('org.caw.tilt', 'org.caw.eq', 3),
    MergedVariant('org.caw.eq.linear', 'org.caw.eq', 4, retired: false),
    MergedVariant('org.caw.eq.match', 'org.caw.eq', 5, retired: false),
    MergedVariant('org.caw.filter', 'org.caw.filter', 0),
    MergedVariant('org.caw.ladder', 'org.caw.filter', 1),
    MergedVariant('org.caw.nlfilter', 'org.caw.filter', 2),
    MergedVariant('org.caw.filter.wah', 'org.caw.filter', 3, retired: false),
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
    MergedVariant('org.caw.ducker', 'org.caw.tremolo', 2),  // Shape (1.0.8-1.0.9: the Compressor's variant 3)
    MergedVariant('org.caw.delay.pro', 'org.caw.delay', 0),
    MergedVariant('org.caw.delay.pingpong', 'org.caw.delay', 1),
    MergedVariant('org.caw.delay.tape', 'org.caw.delay', 2, retired: false),
    MergedVariant('org.caw.delay.reverse', 'org.caw.delay', 3, retired: false),
    MergedVariant('org.caw.delay.multitap', 'org.caw.delay', 4, retired: false),
    MergedVariant('org.caw.reverb.pro', 'org.caw.reverb', 0),
    MergedVariant('org.caw.shimmer', 'org.caw.reverb', 1),
    MergedVariant('org.caw.reverb.room', 'org.caw.reverb', 2, retired: false),
    MergedVariant('org.caw.reverb.plate', 'org.caw.reverb', 3, retired: false),
    MergedVariant('org.caw.reverb.spring', 'org.caw.reverb', 4, retired: false),
    MergedVariant('org.caw.reverb.gated', 'org.caw.reverb', 5, retired: false),
    MergedVariant('org.caw.reverb.reverse', 'org.caw.reverb', 6, retired: false),
    MergedVariant('org.caw.pitchshift', 'org.caw.shift', 0),
    MergedVariant('org.caw.freqshift', 'org.caw.shift', 1),
    MergedVariant('org.caw.shift.harmonizer', 'org.caw.shift', 2, retired: false),  // Soar (builtin_fx_shift_voices.cpp)
    MergedVariant('org.caw.shift.octaver', 'org.caw.shift', 3, retired: false),
    MergedVariant('org.caw.convolver', 'org.caw.convolver', 0),
    MergedVariant('org.caw.convolver.cab', 'org.caw.convolver', 1, retired: false),
  ];

  /// The page id of the Ducker's Duck variant (org.caw.duck 0; 1.0.8-1.0.9 the Compressor's variant 4), which no
  /// old effect was. Its string stays as 1.0.8 named it.
  static const duckPageId = 'org.caw.compressor.duck';

  /// A 1.0.8 or 1.0.9 Compressor variant (an entry without [talonLayoutParam]) that left it in 1.1.0: its old index
  /// to its device and variant now (the engine's fx_migrate_dynamics.cpp). Variants 0 and 1 stay.
  static const talonMoves = <int, ({String id, int variant})>{
    2: (id: 'org.caw.gate', variant: 0),
    3: (id: 'org.caw.tremolo', variant: 2),
    4: (id: 'org.caw.duck', variant: 0),
  };

  /// Whether an entry is an org.caw.compressor older than 1.1.0 (no [talonLayoutParam]): the engine migrates it.
  static bool isLegacyTalon(String id, Map<String, double> params) =>
      id == talonId && !params.containsKey(talonLayoutParam);

  static final Map<String, MergedVariant> _byOld = {for (final v in variants) if (v.retired) v.oldId: v};
  static final Map<String, MergedVariant> _byVariant = {for (final v in variants) '${v.id}#${v.variant}': v};

  /// Merged instruments: Timber (1.1.0) and Starling (1.1.3), whose `variant` ("Model") picks the model that runs. Not
  /// effects, so the effect catalog's [ids] leave them out; no old id became one.
  static const instrumentIds = ['org.caw.timber', 'org.caw.starling'];

  /// Whether [id] is a merged device (an effect or an instrument).
  static bool isMerged(String id) => ids.contains(id) || instrumentIds.contains(id);

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

  /// The old effect [id]'s variant [variant] plays (its device page and display layout; a new variant's page id, the
  /// Duck's [duckPageId]), or [id] itself for any other id.
  static String pageId(String id, int variant) => _byVariant['$id#$variant']?.oldId ?? id;

  /// The engine's caw_migrate_component (`Engine.resolveComponent`), once the engine has loaded (AppState sets it);
  /// null without one.
  static Map<String, dynamic>? Function(Map<String, dynamic> entry)? resolver;

  /// A stored entry outside a project (a user preset's device) in its merged form: a retired id as its merged device
  /// and `variant`, a rack without `rack_layout` migrated by the engine (left as it is without one). Null when there
  /// is nothing to change. `keepsState` false: the old saved state does not carry over.
  static ({String id, Map<String, double> params, bool keepsState})? resolveEntry(String id, Map<String, double> params) {
    final rack = id.startsWith('org.caw.rack.') && (params[rackLayoutParam] ?? 0) < rackLayoutCurrent;
    final talon = isLegacyTalon(id, params);
    if (!rack && !talon && !isRetired(id)) return null;
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
    if (talon) {
      final old = params[variantParam];
      final index = old == null || !old.isFinite || old < 0 ? 0 : old.round().clamp(0, 4);
      final to = talonMoves[index];
      if (to == null) return (id: id, params: {...params, talonLayoutParam: talonLayoutCurrent}, keepsState: true);
      return (id: to.id, params: {...params, variantParam: to.variant.toDouble()}, keepsState: true);
    }
    final v = _byOld[id]!;
    return (id: v.id, params: {...params, variantParam: v.variant.toDouble()}, keepsState: true);
  }

  /// The old effect a component entry's values play: [pageId] of its variant.
  static String pageIdOf(String id, Map<String, double> params, {String prefix = ''}) =>
      isMerged(id) ? pageId(id, variantOf(id, params, prefix: prefix)) : id;
}
