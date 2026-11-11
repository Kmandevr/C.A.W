// The effect browser's registry: each built-in effect's category, one-line description, icon and search keywords.
import 'package:flutter/material.dart';

import '../../../engine/component_info.dart';
import '../../theme.dart';
import 'creative/creative_catalog.dart' as fx_creative;  // fx-creative
import 'dynamics/catalog.dart' as fx_dynamics;  // fx-dynamics
import 'filters/filters_shared.dart' as fx_filters show filtersBrowserEntries;  // fx-filters

/// The browser's tabs (owner, 2026-11-11), in order.
enum EffectCategory {
  dynamics('Dynamics', Icons.compress),
  eqFilter('EQ & Filter', Icons.graphic_eq),
  drive('Drive', Icons.whatshot_outlined),
  modulation('Modulation', Icons.waves),
  space('Space', Icons.blur_on),
  pitchTime('Pitch & Time', Icons.timelapse),
  creative('Creative', Icons.auto_awesome),
  utility('Utility', Icons.tune),
  racks('Racks', Icons.view_agenda_outlined);

  const EffectCategory(this.label, this.icon);
  final String label;
  final IconData icon;

  /// The tab named [label] (a group catalog's category string), or null for a name that is no tab.
  static EffectCategory? byLabel(String label) {
    for (final c in values) {
      if (c.label.toLowerCase() == label.trim().toLowerCase()) return c;
    }
    return null;
  }

  /// The tab's colour (the device families' palette).
  Color get color => switch (this) {
        EffectCategory.dynamics => Neon.green,
        EffectCategory.eqFilter => Neon.blue,
        EffectCategory.drive => Neon.pink,
        EffectCategory.modulation => Neon.violet,
        EffectCategory.space => Color.lerp(Neon.blue, Neon.violet, 0.5)!,
        EffectCategory.pitchTime => Neon.yellow,
        EffectCategory.creative => Color.lerp(Neon.pink, Neon.yellow, 0.5)!,
        EffectCategory.utility => Neon.dim,
        EffectCategory.racks => Color.lerp(Neon.green, Neon.blue, 0.5)!,
      };
}

/// One effect in the browser. [icon] is its small picture; [keywords] are extra search words (what it is also called).
class EffectEntry {
  const EffectEntry(this.id, this.category, this.description, this.icon, {this.keywords = const []});
  final String id;
  final EffectCategory category;
  final String description;
  final IconData icon;
  final List<String> keywords;

  /// Whether [query] (lower case, trimmed) finds it by [name], description, keywords or id.
  bool matches(String query, String name) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return name.toLowerCase().contains(q) || description.toLowerCase().contains(q) || id.toLowerCase().contains(q) ||
        keywords.any((k) => k.toLowerCase().contains(q)) || category.label.toLowerCase().contains(q);
  }
}

/// The registry. To add an effect, append an [EffectEntry] to the list of your group below (in a `// fx-<group>`
/// block, so parallel branches merge cleanly), or call [register] at start-up. docs/ui.md, "The effect browser".
class EffectCatalog {
  EffectCatalog._();

  static final Map<String, EffectEntry> _byId = () {
    final m = {for (final e in _entries) e.id: e};
    for (final g in _groups) {
      for (final (id, category, description, icon) in g) {
        final c = EffectCategory.byLabel(category);
        assert(c != null, '$id: "$category" is not a browser tab');
        m[id] = EffectEntry(id, c ?? EffectCategory.utility, description, icon, keywords: m[id]?.keywords ?? const []);
      }
    }
    return m;
  }();

  /// The groups' own catalogs, each as (id, category label, description, icon). A group's entry replaces the
  /// description and icon of an effect listed above and keeps its keywords. To plug in a group, add one line in a
  /// `// fx-<group>` block. docs/ui.md, "The effect browser".
  static final List<Iterable<(String, String, String, IconData)>> _groups = [
    [for (final e in fx_dynamics.fxDynamicsCatalog) (e.id, e.category, e.description, e.icon)],  // fx-dynamics
    [for (final e in fx_creative.creativeCatalog) (e.id, e.category, e.description, e.icon)],  // fx-creative
    [for (final e in fx_filters.filtersBrowserEntries) (e.id, e.category, e.description, e.icon)],  // fx-filters
  ];

  static const List<EffectEntry> _entries = [
    // The effects suite (#173) and the Library's stereo tools.
    EffectEntry('org.caw.compressor', EffectCategory.dynamics, 'Evens out levels; soft knee, look-ahead and a sidechain',
        Icons.compress, keywords: ['comp', 'glue', 'sidechain', 'squash']),
    EffectEntry('org.caw.limiter', EffectCategory.dynamics, 'A brickwall ceiling with look-ahead and true peak',
        Icons.vertical_align_top, keywords: ['maximizer', 'loudness', 'clip']),
    EffectEntry('org.caw.gate', EffectCategory.dynamics, 'Closes on quiet parts; expander, hold and an external key',
        Icons.door_sliding_outlined, keywords: ['noise gate', 'expander']),
    EffectEntry('org.caw.transient', EffectCategory.dynamics, 'More or less attack and sustain, whatever the level',
        Icons.show_chart, keywords: ['shaper', 'punch', 'snap']),
    EffectEntry('org.caw.ducker', EffectCategory.dynamics, 'Ducks to a drawn shape from a key, notes or the tempo',
        Icons.call_received, keywords: ['sidechain', 'pump', 'volume shaper', 'duck']),
    EffectEntry('org.caw.eq', EffectCategory.eqFilter, 'Eight bands with a live spectrum; mid/side per band',
        Icons.graphic_eq, keywords: ['equalizer', 'parametric', 'shelf', 'bell']),
    EffectEntry('org.caw.filter', EffectCategory.eqFilter, 'A resonant multimode filter with its own LFO and envelope',
        Icons.filter_alt_outlined, keywords: ['low-pass', 'high-pass', 'band-pass', 'cutoff', 'wah']),
    EffectEntry('org.caw.saturator', EffectCategory.drive, 'Tape, tube, clip, fold or crush, oversampled',
        Icons.whatshot_outlined, keywords: ['distortion', 'warmth', 'bitcrush', 'overdrive']),
    EffectEntry('org.caw.distortion', EffectCategory.drive, 'Drive, hard clip, fold or crush per channel',
        Icons.bolt_outlined, keywords: ['fuzz', 'clip', 'bitcrush']),
    EffectEntry('org.caw.chorus', EffectCategory.modulation, 'Two swept voices a quarter cycle apart: wide and lush',
        Icons.waves, keywords: ['ensemble', 'detune']),
    EffectEntry('org.caw.phaser', EffectCategory.modulation, 'Swept all-pass notches with feedback',
        Icons.waves, keywords: ['phase', 'swirl']),
    EffectEntry('org.caw.flanger', EffectCategory.modulation, 'A short swept delay with feedback: jet sweeps',
        Icons.waves, keywords: ['jet', 'comb']),
    EffectEntry('org.caw.reverb.pro', EffectCategory.space, 'A smooth hall to small room with ducking and freeze',
        Icons.blur_on, keywords: ['hall', 'room', 'plate', 'ambience']),
    EffectEntry('org.caw.delay.pro', EffectCategory.space, 'Synced stereo, ping-pong or dual echoes, drive in the loop',
        Icons.blur_linear, keywords: ['echo', 'tape delay', 'ping pong']),
    EffectEntry('org.caw.delay.pingpong', EffectCategory.space, 'A simple synced ping-pong echo',
        Icons.blur_linear, keywords: ['echo', 'ping pong']),
    EffectEntry('org.caw.utility', EffectCategory.utility, 'Gain, phase, width, pan, mono bass and DC block',
        Icons.tune, keywords: ['gain', 'trim', 'mono', 'invert']),
    EffectEntry('org.caw.stereo.width', EffectCategory.utility, 'Mid/side width from mono to extra wide',
        Icons.swap_horiz, keywords: ['stereo', 'imager', 'mono']),
    EffectEntry('org.caw.stereo.balance', EffectCategory.utility, 'Left/right balance',
        Icons.swap_horiz, keywords: ['pan', 'stereo']),
    // fx-racks begin
    EffectEntry('org.caw.rack.fx', EffectCategory.racks, 'Up to 8 effects in one device, with LFOs, envelopes and macros',
        Icons.view_agenda_outlined, keywords: ['snap heap', 'chain', 'container', 'macro', 'modulation']),
    EffectEntry('org.caw.rack.multiband', EffectCategory.racks, 'Split into up to 5 bands, each with its own effects',
        Icons.view_week_outlined, keywords: ['multipass', 'multiband', 'crossover', 'split']),
    // fx-racks end
  ];

  /// Adds or replaces [entry] (an effect defined outside the lists above).
  static void register(EffectEntry entry) => _byId[entry.id] = entry;

  static EffectEntry? of(String id) => _byId[id];

  static Iterable<EffectEntry> get all => _byId.values;

  /// [info]'s entry, or one made from its role for an effect the registry doesn't list (a project's C++ effect).
  static EffectEntry describe(NativeComponentInfo info) =>
      _byId[info.id] ??
      EffectEntry(info.id, EffectCategory.utility,
          info.role == 'analyzer' ? 'An analyzer' : (info.isInstrument ? 'An instrument' : 'A native effect'),
          Icons.extension_outlined);
}
