// Smart freeze (1.1.0, suggest only): when the CPU meter stays near the phone's limit while playing, measure each track once and suggest freezing the heaviest, once; it never freezes by itself.
import 'package:flutter/foundation.dart';

import 'app_state.dart';
import 'arrange_fx.dart';
import 'freeze.dart';
import 'mixer_fx.dart' show engineLayerId;
import 'project.dart';

/// The suggestion shown: freeze [layerId] ([name]), with its measured share of one core when the engine had one.
class FreezeSuggestion {
  const FreezeSuggestion({required this.layerId, required this.name, this.share});
  final String layerId, name;
  final double? share;
}

/// Watches the meters ([poll], from the app's meter poller) and, once the CPU has stayed at or above [near] (or the
/// engine muted a track for an overload) for [hold] while playing, reads each candidate track's cost for [measure]
/// a few times a second (each read keeps the engine timing that track's slots for 2 s), then offers the heaviest
/// in [suggestion]. Without measurements it ranks by the components' cost hints. Shown once per run of the app:
/// [dismiss] (or a freeze from it) ends it for good. It never freezes: the screens ask, and only a tap freezes.
class FreezeHint {
  FreezeHint({this.near = 0.85, this.calm = 0.75, this.hold = const Duration(seconds: 4),
      this.measure = const Duration(milliseconds: 1500)});

  /// The CPU share of the callback's budget counted as near the limit, and the one below which it has calmed.
  final double near, calm;
  final Duration hold, measure;

  final ValueNotifier<FreezeSuggestion?> suggestion = ValueNotifier(null);

  bool _done = false;
  int? _highSinceUs, _measureFromUs;
  int _lastReadUs = 0;
  final Map<String, double> _shares = {};

  /// Whether it has been shown and dismissed (or acted on): it says nothing again this run.
  bool get done => _done;

  /// One meter reading at [nowUs]. [tracks] gives the tracks that may be frozen now; [share] a track's measured share
  /// of one core (null until measured); [hint] its components' cost hints (any scale; larger is heavier).
  void poll(int nowUs, {required double cpu, required bool playing, required bool overloaded,
      required List<LayerDoc> Function() tracks, required double? Function(LayerDoc) share,
      required double Function(LayerDoc) hint}) {
    if (_done || suggestion.value != null) return;
    final high = playing && (cpu >= near || overloaded);
    if (!playing || (!high && cpu < calm)) {
      _highSinceUs = _measureFromUs = null;
      _shares.clear();
      return;
    }
    if (!high && _measureFromUs == null) return;
    _highSinceUs ??= nowUs;
    if (_measureFromUs == null) {
      if (nowUs - _highSinceUs! < hold.inMicroseconds) return;
      _measureFromUs = nowUs;
    }
    final list = tracks();
    if (list.isEmpty) return;
    if (nowUs - _lastReadUs >= 250000) {
      _lastReadUs = nowUs;
      for (final l in list) {
        final v = share(l);
        if (v != null) _shares[l.id] = v;
      }
    }
    if (nowUs - _measureFromUs! < measure.inMicroseconds) return;
    LayerDoc? best;
    double? bestShare;
    if (_shares.isNotEmpty) {
      for (final l in list) {
        final v = _shares[l.id];
        if (v != null && (bestShare == null || v > bestShare)) (best, bestShare) = (l, v);
      }
    }
    if (best == null) {
      var most = 0.0;
      for (final l in list) {
        final v = hint(l);
        if (v > most) (best, most) = (l, v);
      }
    }
    _measureFromUs = _highSinceUs = null;
    _shares.clear();
    if (best != null) suggestion.value = FreezeSuggestion(layerId: best.id, name: best.name, share: bestShare);
  }

  /// The suggestion goes and is not offered again this run.
  void dismiss() {
    _done = true;
    suggestion.value = null;
  }

  void dispose() => suggestion.dispose();
}

/// The tracks a freeze suggestion may name: those that can be frozen and aren't, with an instrument or effects.
List<LayerDoc> freezeCandidates(AppState s) => [
      for (final l in s.project.layers)
        if (!l.frozen && s.canRenderTrack(l) && (l.instrument != null || l.components.isNotEmpty)) l,
    ];

/// [l]'s measured share of one core: its instrument's and effects' slot costs summed (null while none is measured
/// yet). Each read keeps the engine timing that chain for 2 s.
double? measuredTrackShare(AppState s, LayerDoc l) {
  final e = s.engine;
  if (e == null) return null;
  double? sum;
  void add(String? layer, int index) {
    final c = e.componentCost(layer, index)?.cpuShare;
    if (c != null) sum = (sum ?? 0) + c;
  }

  final inst = l.instrument;
  if (inst != null && s.componentPlayable(inst.id)) add(l.id, ProjectDoc.instrumentIndex);
  for (var k = 0; k < l.components.length; k++) {
    final i = s.engineComponentIndex(l, k);
    if (i != null) add(engineLayerId(l), i);
  }
  return sum;
}

/// [l]'s cost from its components' hints (light 1, unspecified 2, medium 3, heavy 9): the ranking without
/// measurements.
double hintedTrackCost(AppState s, LayerDoc l) {
  double of(ComponentUseDoc? u) => u == null ? 0 : switch (s.componentInfo(u.id)?.cpuClass) {
        'light' => 1.0,
        'medium' => 3.0,
        'heavy' => 9.0,
        _ => 2.0,
      };
  return of(l.instrument) + l.components.fold(0.0, (a, u) => a + of(u));
}
