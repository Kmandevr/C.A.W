// Tests that the Settings pages' newer settings persist, migrate from a version-1 file and change what they say:
// MIDI filters and curves, pre-roll and the recording offset, new-project defaults, restore points kept, the
// exporter's defaults and file names, and (with CAW_LIB) the click's volume and the device choice in the engine.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/live_midi.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/storage.dart';
import 'package:caw/platform/midi_input.dart';
import 'package:caw/ui/code_prefs.dart';
import 'package:caw/ui/exporter_screen.dart';
import 'package:caw/ui/frame/live_keys.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'live_midi_test.dart' show FakeMidi, WatchedState, twoTracks;

bool get _haveEngine {
  final lib = Platform.environment['CAW_LIB'];
  return lib != null && lib.isNotEmpty && File(lib).existsSync();
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('caw_settings_wiring'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('every new setting is saved and read back', () async {
    final s = await Settings.open(base: dir);
    await s.update((x) {
      x.audioDevice = 'USB Audio';
      x.audioDeviceId = '{0.0.0.00000000}.{a1}';
      x.sampleRate = 96000;
      x.bufferFrames = 128;
      x.exclusiveAudio = true;
      x.midiDevice = 'Keystation';
      x.midiChannel = 10;
      x.velocityCurve = VelocityCurve.fixed;
      x.midiFixedVelocity = 0.6;
      x.midiThru = false;
      x.keysVelocity = 0.7;
      x.keysOctave = 5;
      x.clickSound = ClickSound.tick;
      x.clickVolume = 0.4;
      x.preRollBars = 2;
      x.recordOffsetMs = 30;
      x.rollGrid = 32;
      x.rollSnap = false;
      x.rollTool = StartTool.select;
      x.rollNoteSteps = 4;
      x.followPlayhead = false;
      x.wheelZooms = true;
      x.confirmDelete = true;
      x.codeFontSize = 18;
      x.codeTabWidth = 2;
      x.codeLineNumbers = false;
      x.codeWrap = true;
      x.autosaveMs = 5000;
      x.restorePointsKept = 7;
      x.newProjectBpm = 96;
      x.newProjectBeatsPerBar = 3;
      x.newProjectTemplate = 'builtin:first-loop';
      x.exportKind = 'free';
      x.exportSampleRate = 44100;
      x.exportFloat32 = true;
      x.exportSeconds = 30;
      x.exportNaming = ExportNaming.dated;
    });
    expect(CodePrefs.fontSize, 18, reason: 'the editors read it at once');
    final b = await Settings.open(base: dir);
    expect(b.loadedVersion, Settings.version);
    expect([b.audioDevice, b.audioDeviceId, b.sampleRate, b.bufferFrames, b.exclusiveAudio],
        ['USB Audio', '{0.0.0.00000000}.{a1}', 96000, 128, true]);
    expect([b.midiDevice, b.midiChannel, b.velocityCurve, b.midiFixedVelocity, b.midiThru],
        ['Keystation', 10, VelocityCurve.fixed, 0.6, false]);
    expect([b.keysVelocity, b.keysOctave, b.clickSound, b.clickVolume], [0.7, 5, ClickSound.tick, 0.4]);
    expect([b.preRollBars, b.recordOffsetMs], [2, 30]);
    expect([b.rollGrid, b.rollSnap, b.rollTool, b.rollNoteSteps], [32, false, StartTool.select, 4.0]);
    expect([b.followPlayhead, b.wheelZooms, b.confirmDelete], [false, true, true]);
    expect([b.codeFontSize, b.codeTabWidth, b.codeLineNumbers, b.codeWrap], [18, 2, false, true]);
    expect([b.autosaveMs, b.restorePointsKept, b.newProjectBpm, b.newProjectBeatsPerBar, b.newProjectTemplate],
        [5000, 7, 96, 3, 'builtin:first-loop']);
    expect([b.exportKind, b.exportSampleRate, b.exportFloat32, b.exportSeconds, b.exportNaming],
        ['free', 44100, true, 30, ExportNaming.dated]);
    CodePrefs.fontSize = 15;
  });

  test('a version-1 settings file keeps its values and gets the new defaults', () async {
    File('${dir.path}/settings.json').writeAsStringSync(jsonEncode({
      'theme': 'Calm neon',
      'audio_buffer': 'lowLatency',
      'sound_quality': 'eco',
      'metronome': 'always',
      'count_in_bars': 2,
      'vim_code': true,
      'roll': {'row_height': 22},
      'light_mode': true,
    }));
    final s = await Settings.open(base: dir);
    expect(s.loadedVersion, 1);
    expect([s.audioBuffer, s.soundQuality, s.metronome, s.countInBars, s.vimCode, s.roll.rowHeight],
        [AudioBuffer.lowLatency, SoundQuality.eco, Metronome.always, 2, true, 22.0]);
    expect(s.performanceMode, PerformanceMode.lightweight, reason: 'the older light_mode migration still runs');
    // The new settings start where the app behaved before them.
    expect([s.bufferFrames, s.sampleRate, s.audioDevice, s.clickVolume, s.autosaveMs, s.restorePointsKept],
        [0, 48000, '', 1.0, 500, 20]);
    expect([s.newProjectBpm, s.newProjectBeatsPerBar, s.exportKind, s.exportSampleRate, s.rollGrid, s.rollSnap],
        [140.0, 4, 'loop', 48000, 16, true]);
    await s.save();
    final j = jsonDecode(File('${dir.path}/settings.json').readAsStringSync()) as Map<String, dynamic>;
    expect(j['settings_version'], 2);
    expect(j['audio_buffer'], 'lowLatency', reason: 'version-1 keys keep their names for older builds');
  });

  test('damaged values fall back or are clamped', () {
    final s = Settings()
      ..fromJson({
        'sample_rate': 12345,
        'buffer_frames': 100,
        'midi_channel': 99,
        'click_volume': 7,
        'record_offset_ms': -5,
        'code_font_size': 200,
        'code_tab_width': 3,
        'autosave_ms': 1,
        'restore_points_kept': 0,
        'new_project_bpm': 9999,
        'keys_octave': 40,
        'export_kind': 'mp3',
      });
    expect([s.sampleRate, s.bufferFrames, s.midiChannel, s.clickVolume, s.recordOffsetMs],
        [48000, 0, 16, 1.0, 0.0]);
    expect([s.codeFontSize, s.codeTabWidth, s.autosaveMs, s.restorePointsKept, s.newProjectBpm, s.keysOctave, s.exportKind],
        [24.0, 4, 500, 1, 400.0, 6, 'loop']);
    CodePrefs.fontSize = 15;
  });

  test('MIDI: the chosen keyboard and channel, the velocity curve and MIDI thru', () {
    final s = WatchedState()..project = twoTracks();
    final midi = FakeMidi();
    final live = LiveMidi(s, midi);
    s.settings
      ..midiDevice = 'Keystation'
      ..midiChannel = 2;
    midi.notes.add(const MidiMessage(0x91, 60, 127, 'Other keyboard'));
    midi.notes.add(const MidiMessage(0x90, 61, 127, 'Keystation')); // channel 1
    expect(s.device, isEmpty);
    midi.notes.add(const MidiMessage(0x91, 62, 127, 'Keystation')); // channel 2
    expect(s.device.single.$2, [0x91, 62, 127], reason: 'a device plays through the engine\'s device input');
    live.keyDown(70, 0.5); // the on-screen keys always pass, at their own velocity
    expect(s.on.last.$3, closeTo(64 / 127, 1e-9));
    s.settings
      ..midiChannel = 0
      ..velocityCurve = VelocityCurve.hard;
    midi.notes.add(const MidiMessage(0x90, 63, 64, 'Keystation'));
    expect(s.device.last.$2[2], ((64 / 127) * (64 / 127) * 127).round());
    s.settings
      ..velocityCurve = VelocityCurve.fixed
      ..midiFixedVelocity = 0.3;
    midi.notes.add(const MidiMessage(0x90, 64, 120, 'Keystation'));
    expect(s.device.last.$2[2], (0.3 * 127).round());
    s.settings.midiThru = false;
    final before = s.device.length;
    midi.notes.add(const MidiMessage(0x90, 65, 120, 'Keystation'));
    expect(s.device.length, before, reason: 'thru off: nothing sounds outside a recording');
    live.toggleRecord(s.project.layers.first.id);
    midi.notes.add(const MidiMessage(0x90, 66, 120, 'Keystation'));
    expect(s.device.length, before + 1, reason: 'the armed track still hears it');
    live.dispose();
  });

  test('the on-screen keys: a fixed velocity and the octave they open on', () {
    expect(velocityAt(0, 100), 0.3);
    expect(velocityAt(0, 100, fixed: 0.9), 0.9);
  });

  test('recording: the offset writes notes earlier and the pre-roll is heard, not recorded', () {
    final s = WatchedState()..project = (twoTracks()..bpm = 120);
    s.settings
      ..recordOffsetMs = 125 // one sixteenth at 120 BPM
      ..preRollBars = 1;
    final midi = FakeMidi();
    final live = LiveMidi(s, midi);
    final layer = s.project.layers.first;
    final bar = s.project.stepsPerBar;
    s.pausedStep = 2.0 * bar;
    live.toggleRecord(layer.id);
    expect(s.pausedStep, bar.toDouble(), reason: 'play starts a bar earlier');
    s.pausedStep = bar + 4.0; // in the pre-roll
    midi.notes.add(const MidiMessage(0x90, 60, 100));
    s.pausedStep = bar + 6.0;
    midi.notes.add(const MidiMessage(0x80, 60, 0));
    s.pausedStep = 2.0 * bar + 3; // recorded
    midi.notes.add(const MidiMessage(0x90, 64, 100));
    s.pausedStep = 2.0 * bar + 5;
    midi.notes.add(const MidiMessage(0x80, 64, 0));
    live.toggleRecord();
    final clip = layer.clips.last;
    expect(clip.startSteps, 2 * bar);
    final notes = PatternDoc.parse(s.project.module(clip.patternId)!.source).doc!.notes;
    expect(notes.single.pitch, 64);
    expect(notes.single.at, Steps(2), reason: 'played at 3, written a sixteenth earlier');
    live.dispose();
  });

  test('new project: Settings\' tempo and time signature, or the First loop template', () async {
    final s = AppState();
    s.settings
      ..newProjectBpm = 96
      ..newProjectBeatsPerBar = 3;
    final p = s.blankProject();
    expect([p.bpm, p.beatsPerBar, p.layers.length], [96.0, 3, 0]);
    s.dispose();
  });

  test('restore points: only the newest kept', () async {
    final storage = ProjectStorage(dir);
    final p = ProjectDoc(id: 'p1', name: 'A');
    for (var i = 0; i < 5; i++) {
      await storage.createRestorePoint(p, keep: 3);
    }
    expect((await storage.listRestorePoints('p1')).length, 3);
  });

  test('storage use is measured and caches cleared', () async {
    final support = Directory('${dir.path}/support')..createSync();
    Directory('${support.path}/projects/restore-points/p1').createSync(recursive: true);
    File('${support.path}/projects/p1.json').writeAsStringSync('x' * 100);
    File('${support.path}/projects/restore-points/p1/a.json').writeAsStringSync('x' * 40);
    File('${support.path}/settings.json').writeAsStringSync('x' * 10);
    final temp = Directory('${dir.path}/temp')..createSync();
    File('${temp.path}/render.wav').writeAsStringSync('x' * 1000);
    final use = await StorageUse.measure(support, temp);
    expect([use.projects, use.restorePoints, use.other, use.caches], [100, 40, 10, 1000]);
    expect(await StorageUse.clearCaches(temp), 1000);
    expect(temp.listSync(), isEmpty);
    expect(File('${support.path}/projects/p1.json').existsSync(), isTrue);
  });

  testWidgets('the exporter opens with Settings\' defaults and names files as chosen', (tester) async {
    final s = AppState();
    s.project = ProjectDoc(id: 'p', name: 'Song');
    s.settings
      ..exportKind = 'free'
      ..exportSampleRate = 44100
      ..exportFloat32 = true
      ..exportSeconds = 30
      ..exportNaming = ExportNaming.detailed;
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ExporterScreen(state: s))));
    expect(find.text('Song_140bpm_30s.wav'), findsOneWidget, reason: 'free length, 30 s');
    expect(find.text('44.1 kHz'), findsOneWidget);
    expect(find.text('32-bit float'), findsOneWidget);
    s.settings.exportNaming = ExportNaming.project;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ExporterScreen(key: UniqueKey(), state: s))));
    expect(find.text('Song.wav'), findsOneWidget);
    s.dispose();
  });

  test('with the engine: the click volume reaches it, the device choice is kept, the test tone sounds', () async {
    final s = AppState();
    s.useAudioDevice = false;
    s.engine = Engine.create(sampleRate: 44100);
    expect(s.engine!.sampleRate, 44100);
    s.project = ProjectDoc(id: 'p', name: 'Click')..bpm = 120;
    double loudest(double volume) {
      s.settings.update((x) => x.clickVolume = volume);
      s.applyAudioSettings();
      s.engine!.playCountIn(0, 1);
      final out = s.engine!.pullForTest(4096); // the count-in's first click
      s.engine!.stop();
      s.engine!.pullForTest(48000);
      return out.fold<double>(0, (m, v) => v.abs() > m ? v.abs() : m);
    }
    final full = loudest(1), half = loudest(0.5);
    expect(full, greaterThan(0), reason: 'the click is heard');
    expect(half, closeTo(full / 2, full * 0.1));
    s.settings.update((x) {
      x.audioDevice = 'Speakers';
      x.audioDeviceId = 'speakers-2';
      x.bufferFrames = 256;
      x.exclusiveAudio = true;
    });
    s.applyAudioSettings();
    await s.audioConfigured; // the reopen runs on a background isolate
    final status = s.engine!.audioStatus();
    expect([status.requestedDevice, status.requestedDeviceId, status.requestedFrames, status.exclusiveRequested],
        ['Speakers', 'speakers-2', 256, true]);
    expect(s.engine!.audioOn, isFalse, reason: 'audioOn follows the native device, which this build has none of');
    expect(s.playTestTone(), isNull);
    expect(s.engine!.testToneSounding, isTrue);
    s.dispose();
  }, skip: !_haveEngine);

  test('with the engine: device choices reach it off the UI isolate, in the order made', () async {
    final e = Engine.create();
    final first = e.configureAudio(device: 'A', periodFrames: 64);
    final second = e.configureAudio(deviceId: 'id-b', device: 'B', periodFrames: 128, exclusive: true);
    expect(await first, AudioConfigured.ok, reason: 'nothing runs, so nothing reopens');
    expect(await second, AudioConfigured.ok);
    final st = e.audioStatus();
    expect([st.requestedDevice, st.requestedDeviceId, st.requestedFrames, st.exclusiveRequested], ['B', 'id-b', 128, true]);
    expect(e.audioOn, isFalse);
    final late = e.configureAudio(device: 'C');
    e.dispose(); // the engine outlives the call in flight
    expect(await late, AudioConfigured.ok);
  }, skip: !_haveEngine);
}

