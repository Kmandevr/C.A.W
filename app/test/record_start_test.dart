// "Record just works" (owner, 2026-11-17): Record with nothing armed arms the selected track when it can take the
// input there is, else makes a track (MIDI for a keyboard, audio for the microphone), then records; the tip shows
// once. And a loop recording makes a take of every pass, MIDI and audio, for the take lanes (#209).
import 'package:caw/engine/audio_engine.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/platform/midi_input.dart';
import 'package:caw/platform/mic_permission.dart';
import 'package:caw/model/audio_record.dart';
import 'package:caw/model/comping.dart';
import 'package:caw/model/live_midi.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/record_start.dart';
import 'package:caw/ui/frame/frame_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';
import 'live_midi_test.dart' show FakeMidi, WatchedState;

ProjectDoc _project() => ProjectDoc(id: 'prec', name: 'Rec', layers: [
      LayerDoc(id: 'synth', name: 'Synth', color: 0, instrument: ComponentUseDoc('org.caw.synth.flagship')),
      LayerDoc(id: 'vox', name: 'Vox', color: 1, input: AudioInputDoc()),
      LayerDoc(id: 'empty', name: 'Empty', color: 2),
    ]);

void main() {
  late WatchedState s;
  late FakeMidi midi;
  late LiveMidi live;

  setUp(() {
    s = WatchedState()..project = _project();
    midi = FakeMidi();
    live = LiveMidi(s, midi);
  });

  tearDown(() {
    if (live.recording) live.toggleRecord();
    live.dispose();
  });

  LayerDoc layer(String id) => s.project.layers.firstWhere((l) => l.id == id);

  group('what Record arms with nothing armed', () {
    test('a keyboard: the selected track when it plays an instrument, else a new MIDI track under it', () {
      s.selectedLayerId = 'synth';
      expect(s.planRecord(keyboard: true), (layer: layer('synth'), audio: false, created: false));
      s.selectedLayerId = 'vox';
      final made = s.planRecord(keyboard: true);
      expect(made.created, isTrue);
      expect(made.audio, isFalse);
      expect(made.layer.instrument?.id, kRecordTrackInstrument);
      expect(s.project.layers.indexOf(made.layer), s.project.layers.indexOf(layer('vox')) + 1);
      expect(s.selectedLayerId, made.layer.id);
    });

    test('no keyboard: the selected audio or empty track takes the microphone, else a new audio track', () {
      s.selectedLayerId = 'vox';
      expect(s.planRecord(keyboard: false), (layer: layer('vox'), audio: true, created: false));
      s.selectedLayerId = 'empty';
      expect(s.planRecord(keyboard: false), (layer: layer('empty'), audio: true, created: false));
      s.selectedLayerId = 'synth';
      final made = s.planRecord(keyboard: false);
      expect(made.created, isTrue);
      expect(made.audio, isTrue);
      expect(made.layer.input, isNotNull);
      expect(s.project.layers.indexOf(made.layer), 1);
      s.selectedLayerId = null;
      expect(s.planRecord(keyboard: false).layer, s.project.layers.last, reason: 'none selected: one at the end');
    });

    test('Record arms the track, opens its input and records; pressed again it stops', () async {
      s.selectedLayerId = 'vox';
      final plan = await s.pressRecord(live);
      expect(plan?.layer.id, 'vox');
      expect(layer('vox').input!.armed, isTrue);
      expect(live.recording, isTrue);
      expect(live.keysOpen, isFalse, reason: 'an armed audio track records its input; the keys stay closed');
      expect(await s.pressRecord(live), isNull);
      expect(live.recording, isFalse);
    });

    test('with an armed track, Record records it as before and makes nothing', () async {
      layer('vox').input!.armed = true;
      s.selectedLayerId = 'synth';
      final before = s.project.layers.length;
      expect(await s.pressRecord(live), isNull);
      expect(live.recording, isTrue);
      expect(s.project.layers, hasLength(before));
    });

    test('a microphone that will not open says why and records nothing', () async {
      s.audioIo = FakeAudioIo();
      final rec = AudioRecorder(s, permission: _Denied(), prefs: AudioInputPrefs());
      addTearDown(rec.dispose);
      s.selectedLayerId = 'vox';
      final said = <String>[];
      await s.pressRecord(live, audio: rec, say: said.add);
      expect(said, hasLength(1));
      expect(live.recording, isFalse);
      expect(layer('vox').input!.armed, isFalse);
    });
  });

  testWidgets('the Record button\'s tip on the arm button shows once', (tester) async {
    s.selectedLayerId = 'synth';
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: RecordButton(midi: live, state: s)))));
    await tester.tap(find.byKey(const ValueKey('transport-record')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('record-tip')), findsOneWidget);
    expect(find.textContaining('new audio track'), findsOneWidget);
    expect(s.settings.recordTipShown, isTrue);
    await tester.tap(find.byKey(const ValueKey('transport-record')));  // stop
    await tester.pump();
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).clearSnackBars();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('transport-record')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('record-tip')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('transport-record')));
    await tester.pump(const Duration(seconds: 8));
  });

  group('loop recording makes a take of every pass (#209)', () {
    test('MIDI: one clip whose takes are the passes, an empty pass included, an unplayed last one not', () {
      final l = layer('synth');
      s.pausedStep = 2;
      live.toggleRecord(l.id);
      midi.notes.add(const MidiMessage(0x90, 60, 100));  // pass 0
      s.pausedStep = 6;
      midi.notes.add(const MidiMessage(0x80, 60, 0));
      s.pausedStep = 60;
      midi.notes.add(const MidiMessage(0x90, 62, 100));  // held over the wrap
      s.pausedStep = 4;  // pass 1: only that note's end
      midi.notes.add(const MidiMessage(0x80, 62, 0));
      s.pausedStep = 60;
      midi.notes.add(const MidiMessage(0x90, 64, 100));
      midi.notes.add(const MidiMessage(0x80, 64, 0));
      s.pausedStep = 8;  // pass 2
      midi.notes.add(const MidiMessage(0x90, 67, 100));
      s.pausedStep = 10;
      midi.notes.add(const MidiMessage(0x80, 67, 0));
      s.pausedStep = 1;  // pass 3 just begun, nothing in it
      live.toggleRecord();
      final clip = l.clips.single;
      expect(clip.takes, hasLength(3));
      expect(clip.patternId, clip.takes.last, reason: 'the newest plays');
      List<double> notes(String id) =>
          [for (final n in PatternDoc.parse(s.project.module(id)!.source).doc!.notes) n.pitch];
      expect(notes(clip.takes[0]), hasLength(2));
      expect(notes(clip.takes[1]), hasLength(1));
      expect(notes(clip.takes[2]), hasLength(1));
      expect(takeLaneCount(l), 3);
    });

    test('audio: the passes of a loop recording are one clip\'s takes, a lane each', () {
      s.audioIo = FakeAudioIo();
      final rec = AudioRecorder(s, prefs: AudioInputPrefs());
      addTearDown(rec.dispose);
      final takes = [
        for (var i = 1; i <= 3; i++)
          RecordedAudioTake(layer: 'vox', take: i, path: '/abs/vox-take$i.wav', startFrame: 0, startSteps: 0,
              frames: 48000, seconds: 1, sampleRate: 48000, channels: 1, bpm: 120),
      ];
      rec.placeTakes(takes);
      final clip = layer('vox').audioClips.single;
      expect(clip.takes, hasLength(3));
      expect(clip.assetId, clip.takes.last);
      expect(takeLaneCount(layer('vox')), 3);
      expect(audioComp(clip), [CompPartDoc(clip.takes.last, 0)]);
    });
  });
}

class _Denied implements MicPermission {
  @override
  Future<bool> granted() async => false;
  @override
  Future<bool> request() async => false;
  @override
  Future<bool> inputSilenced() async => false;
}
