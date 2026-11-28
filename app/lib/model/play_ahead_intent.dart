// The app's play-ahead intent (docs/engine.md "Play-ahead"): who holds which tracks live (a device page, a finger on a track's controls, a held key, an armed or monitored input, an automation write) and one-shot touches before an edit, sent to the engine so a track is live before its value changes.
import '../engine/engine.dart';
import 'mixer_fx.dart' show masterLayerId;

/// Holds and one-shot touches for the engine's play-ahead (caw_engine_play_ahead_intent). Each owner (a page's
/// State, a pointer, the recorder) holds a set of tracks; the engine counts the holds, so one owner letting go
/// never releases another's. Tracks only: the master and unknown ids are passed over by the engine.
class PlayAheadIntent {
  PlayAheadIntent(this._engine);

  final Engine? Function() _engine;
  final Map<Object, Set<String>> _held = {};

  /// Holds [layerId] for [owner] (beside what it already holds) until [release].
  void hold(Object owner, String layerId) => holdSet(owner, {...?_held[owner], layerId});

  /// Ends everything [owner] holds; the 3 s before a track may go ahead again start now.
  void release(Object owner) => holdSet(owner, const {});

  /// [owner] now holds exactly [layerIds]: the new ones are held, the ones it no longer names released.
  void holdSet(Object owner, Set<String> layerIds) {
    if (layerIds.contains(masterLayerId)) layerIds = {...layerIds}..remove(masterLayerId);
    final had = _held[owner] ?? const <String>{};
    if (had.length == layerIds.length && had.containsAll(layerIds)) return;
    final e = _engine();
    for (final id in layerIds) {
      if (!had.contains(id)) e?.playAheadIntent(id, AheadIntent.hold);
    }
    for (final id in had) {
      if (!layerIds.contains(id)) e?.playAheadIntent(id, AheadIntent.release);
    }
    if (layerIds.isEmpty) {
      _held.remove(owner);
    } else {
      _held[owner] = Set.of(layerIds);
    }
  }

  /// A one-shot touch: an edit to [layerId]'s instrument or inserts is about to reach the engine.
  void edit(String? layerId) {
    if (layerId != null && layerId != masterLayerId) _engine()?.playAheadIntent(layerId, AheadIntent.edit);
  }

  /// The tracks held now, by any owner (tests).
  Set<String> get held => {for (final s in _held.values) ...s};
}
