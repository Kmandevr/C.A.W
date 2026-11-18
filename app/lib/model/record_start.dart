// "Record just works" (owner, 2026-11-17): Record with nothing armed arms the selected track when it can take the
// input there is (a MIDI keyboard, else the microphone), else makes a track for it (a MIDI track with the default
// synth, or an audio track), then counts in and records as before.
import 'track_defaults.dart';
import 'app_state.dart';
import 'audio_edit.dart';
import 'audio_record.dart';
import 'live_midi.dart';
import 'project.dart';

/// What Record records with nothing armed: [layer]'s MIDI ([audio] false) or its audio input; [created] when Record
/// made the track.
typedef RecordPlan = ({LayerDoc layer, bool audio, bool created});

/// The instrument a track Record makes for a MIDI keyboard plays.
const kRecordTrackInstrument = 'org.caw.synth.flagship'; // Settings.newTrackInstrument's default (#244)

extension RecordStart on AppState {
  /// Whether Record has an armed track to record: an armed audio track (a MIDI track is armed by Record itself).
  bool get recordArmed => armedAudioTracks.isNotEmpty;

  /// The track Record arms with nothing armed, made when the selected one can't take the input: with a MIDI
  /// [keyboard] the selected track unless it is an audio track, else a new MIDI track under it; without, the selected
  /// track when it holds audio or nothing, else a new audio track under it. A track made is selected (one undo step).
  RecordPlan planRecord({required bool keyboard}) {
    final sel = project.layers.where((l) => l.id == selectedLayerId && !l.isFolder).firstOrNull;
    if (keyboard) {
      if (sel != null && !sel.isAudio) return (layer: sel, audio: false, created: false);
      // Settings › Editing › New tracks (#244): its instrument (Flagship unless changed), name and colour.
      final instrument = newMidiTrackInstrument();
      final track = LayerDoc(id: newId('l'), name: newTrackName('MIDI ${project.layers.length + 1}', instrumentId: instrument?.id),
          color: newTrackColor(NewTrackKind.midi), parentId: sel?.parentId,
          lengthSteps: project.stepsPerBar, volume: 1, instrument: instrument);
      final at = sel == null ? project.layers.length : project.layers.indexOf(sel) + 1;
      endUndoStep();
      editProject((p) => p.layers.insert(at.clamp(0, p.layers.length), track));
      endUndoStep();
      selectLayer(track);
      return (layer: track, audio: false, created: true);
    }
    if (sel != null && (sel.isAudio || (sel.instrument == null && sel.clips.isEmpty))) {
      return (layer: sel, audio: true, created: false);
    }
    endUndoStep();
    final track = addAudioTrack(after: sel);
    endUndoStep();
    selectLayer(track);
    return (layer: track, audio: true, created: true);
  }

  /// Record pressed (the transport's button and its key): stops a recording; with a track armed records as before;
  /// with none, arms the one [planRecord] picks (an audio track opens the input first, asking for the microphone the
  /// first time) and records. [say] gets a one-line message when the input won't open; returns the plan used, or
  /// null when nothing was armed by it.
  Future<RecordPlan?> pressRecord(LiveMidi midi, {AudioRecorder? audio, void Function(String message)? say}) async {
    if (midi.recording || recordArmed) {
      midi.toggleRecord();
      return null;
    }
    final plan = planRecord(keyboard: midi.devices.isNotEmpty);
    if (plan.audio) {
      final rec = audio;
      var ok = true;
      if (rec == null) {
        setAudioArmed(plan.layer, true);
      } else {
        ok = await rec.arm(plan.layer, true);
      }
      if (!ok) {
        say?.call(rec?.message.value ?? 'Audio input did not open.');
        return plan;
      }
    }
    midi.toggleRecord(plan.layer.id);
    return plan;
  }
}
