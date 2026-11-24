// New tracks' defaults (Settings › Editing › New tracks, #244): a new track's name and colour, an audio track's input monitoring, and the instrument Record's new MIDI track plays.
import 'arrange_fx.dart';
import 'app_state.dart';
import 'audio_clips.dart';
import 'device_names.dart';
import 'project.dart';
import 'settings.dart';

/// A new track's kind, for its colour and name.
enum NewTrackKind { midi, audio, sampler, folder }

/// The track colour each kind gets with [TrackColorScheme.byKind] (indexes into the theme's `layer1`..`layer8`).
const Map<NewTrackKind, int> trackKindColors = {
  NewTrackKind.midi: 0,
  NewTrackKind.audio: 2,
  NewTrackKind.sampler: 4,
  NewTrackKind.folder: 6,
};

extension TrackDefaults on AppState {
  /// The colour a new track of [kind] gets: the next one along (the track count, wrapping), or its kind's.
  int newTrackColor(NewTrackKind kind) => switch (settings.trackColors) {
        TrackColorScheme.cycle => project.layers.length % LayerDoc.trackColors,
        TrackColorScheme.byKind => trackKindColors[kind]!,
      };

  /// A new track's name: [numbered] (the kind and number the caller gives, "Track 3", "Audio 3"), or with
  /// [TrackNaming.byInstrument] its instrument's short name and the next number free for it ("Kestrel 2").
  String newTrackName(String numbered, {String? instrumentId}) {
    if (settings.trackNaming != TrackNaming.byInstrument || instrumentId == null || instrumentId.isEmpty) return numbered;
    final label = componentInfo(instrumentId)?.shortLabel ?? DeviceNames.name(instrumentId, componentLabel(instrumentId));
    if (label.isEmpty) return numbered;
    var n = 1;
    final names = {for (final l in project.layers) l.name};
    while (names.contains('$label $n')) {
      n++;
    }
    return '$label $n';
  }

  /// A new audio input: the monitoring Settings › New tracks names.
  AudioInputDoc newTrackInput() => AudioInputDoc(monitor: settings.newTrackMonitor);

  /// The instrument Record's new MIDI track plays (null: none).
  ComponentUseDoc? newMidiTrackInstrument() =>
      settings.newTrackInstrument.isEmpty ? null : ComponentUseDoc(settings.newTrackInstrument);
}
