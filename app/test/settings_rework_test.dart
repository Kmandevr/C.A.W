// The settings rework's new settings (#244): saved and read back with limits, new-track defaults, pause when unplugged, keeping the screen awake, remembering each project's zoom, and the left-handed transport.
import 'dart:async';

import 'package:caw/engine/engine.dart' show AudioStatus;
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/output_watch.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/record_start.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/track_defaults.dart';
import 'package:caw/platform/output_events.dart';
import 'package:caw/ui/frame/frame_widgets.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// An app state whose transport can be on without an engine.
class _Playing extends AppState {
  _Playing();
  bool on = false;
  int toggles = 0;

  @override
  bool get transportOn => on;

  @override
  void togglePlay({int countInBars = 0}) {
    toggles++;
    on = !on;
  }
}

class _Unplug implements OutputUnplug {
  final events = StreamController<void>.broadcast();
  @override
  Stream<void> get unplugged => events.stream;
  @override
  bool get watchesStatus => false;
}

class _Awake implements ScreenAwake {
  final asked = <bool>[];
  @override
  Future<void> keepOn(bool on) async => asked.add(on);
}

void main() {
  test('the new settings are saved and read back; the mono check never is', () {
    final s = Settings()
      ..pauseOnUnplug = false
      ..safetyLimiter = false
      ..monoCheck = true
      ..keepAwake = KeepAwake.always
      ..newTrackMonitor = 'on'
      ..newTrackInstrument = 'org.caw.drum.kit'
      ..trackColors = TrackColorScheme.byKind
      ..trackNaming = TrackNaming.byInstrument
      ..rememberZoom = false
      ..leftHanded = true
      ..bufferTuning = true
      ..rememberProjectView('p1', (zoom: 12.5, left: 64, top: 30));
    final j = s.toJson();
    expect(j.containsKey('mono_check'), isFalse, reason: 'a listening switch, off at every start');
    final t = Settings()..fromJson(j);
    expect(t.pauseOnUnplug, isFalse);
    expect(t.safetyLimiter, isFalse);
    expect(t.monoCheck, isFalse);
    expect(t.keepAwake, KeepAwake.always);
    expect(t.newTrackMonitor, 'on');
    expect(t.newTrackInstrument, 'org.caw.drum.kit');
    expect(t.trackColors, TrackColorScheme.byKind);
    expect(t.trackNaming, TrackNaming.byInstrument);
    expect(t.rememberZoom, isFalse);
    expect(t.leftHanded, isTrue);
    expect(t.bufferTuning, isTrue);
    expect(t.projectViews['p1'], (zoom: 12.5, left: 64.0, top: 30.0));
    // The defaults: pause, the limiter, Keep awake while playing, Auto monitoring, Flagship, remember zoom.
    final d = Settings();
    expect((d.pauseOnUnplug, d.safetyLimiter, d.monoCheck, d.keepAwake, d.newTrackMonitor, d.rememberZoom, d.leftHanded),
        (true, true, false, KeepAwake.playing, 'auto', true, false));
    expect(d.newTrackInstrument, kRecordTrackInstrument);
    expect(d.bufferTuning, isFalse, reason: 'the buffer tuner stays off by default');
  });

  test('damaged values are refused, and only the newest 64 project views are kept', () {
    final s = Settings()
      ..fromJson({
        'new_track_monitor': 'loud',
        'keep_awake': 'sometimes',
        'project_views': {
          'ok': [10, 0, 0],
          'nan': [double.nan, 0, 0],
          'neg': [10, -5, 0],
          'short': [10, 0],
          'zero': [0, 0, 0],
        },
      });
    expect(s.newTrackMonitor, 'auto');
    expect(s.keepAwake, KeepAwake.playing);
    expect(s.projectViews.keys, ['ok']);
    for (var i = 0; i < 70; i++) {
      s.rememberProjectView('p$i', (zoom: 1, left: 0, top: 0));
    }
    expect(s.projectViews, hasLength(Settings.maxProjectViews));
    expect(s.projectViews.containsKey('p69'), isTrue);
    expect(s.projectViews.containsKey('ok'), isFalse, reason: 'the oldest went first');
  });

  group('new tracks', () {
    test('colours cycle, or one colour per kind', () {
      final s = AppState()..project = ProjectDoc(id: 'p', name: 'P', layers: []);
      expect(s.addEmptyTrack().color, 0);
      expect(s.addEmptyTrack().color, 1);
      expect(s.addAudioTrack().color, 2);
      s.settings.trackColors = TrackColorScheme.byKind;
      expect(s.addEmptyTrack().color, trackKindColors[NewTrackKind.midi]);
      expect(s.addAudioTrack().color, trackKindColors[NewTrackKind.audio]);
      expect(s.addEmptyTrack(kind: NewTrackKind.sampler).color, trackKindColors[NewTrackKind.sampler]);
    });

    test('a new audio input takes the monitoring default', () {
      final s = AppState()..project = ProjectDoc(id: 'p', name: 'P', layers: []);
      expect(s.addAudioTrack().input!.monitor, 'auto');
      s.settings.newTrackMonitor = 'off';
      expect(s.addAudioTrack().input!.monitor, 'off');
    });

    test('Record\'s MIDI track plays the chosen instrument, named by it when asked', () {
      final s = AppState()..project = ProjectDoc(id: 'p', name: 'P', layers: []);
      var made = s.planRecord(keyboard: true);
      expect(made.layer.instrument?.id, kRecordTrackInstrument);
      expect(made.layer.name, 'MIDI 1');
      s.settings
        ..trackNaming = TrackNaming.byInstrument
        ..newTrackInstrument = 'org.caw.drum.kit';
      s.selectedLayerId = null;
      made = s.planRecord(keyboard: true);
      expect(made.layer.instrument?.id, 'org.caw.drum.kit');
      expect(made.layer.name, 'Drum kit 1');
      s.selectedLayerId = null;
      expect(s.planRecord(keyboard: true).layer.name, 'Drum kit 2', reason: 'the next number free');
      s.settings.newTrackInstrument = '';
      s.selectedLayerId = null;
      made = s.planRecord(keyboard: true);
      expect(made.layer.instrument, isNull);
      expect(made.layer.name, startsWith('MIDI'), reason: 'no instrument: kind and number');
    });
  });

  group('pause when unplugged', () {
    test('the platform\'s event pauses a playback, only while the setting is on', () {
      final s = _Playing();
      final unplug = _Unplug();
      final w = OutputWatch(s, unplug: unplug, awake: _Awake());
      w.unplugged();
      expect(s.toggles, 0, reason: 'nothing plays');
      s.on = true;
      w.unplugged();
      expect((s.on, s.toggles, w.pauses), (false, 1, 1));
      s
        ..on = true
        ..settings.pauseOnUnplug = false;
      w.unplugged();
      expect(s.on, isTrue);
      w.dispose();
    });

    test('desktop: a removed output is read from the audio status', () {
      const playing = AudioStatus(running: true, device: 'Headphones (USB)');
      expect(outputRemoved('Headphones (USB)', playing), isFalse);
      expect(outputRemoved('Headphones (USB)', const AudioStatus(running: false)), isTrue);
      expect(outputRemoved('Headphones (USB)', const AudioStatus(running: true, device: 'Speakers (Realtek)')), isTrue);
      expect(outputRemoved('Headphones (USB)', const AudioStatus(running: true, device: 'Headphones (USB)', fallback: true)),
          isTrue);
      expect(outputRemoved('', const AudioStatus(running: false)), isFalse, reason: 'nothing was playing');
    });
  });

  test('keep the screen awake: off, while playing, or always while in front', () {
    final s = _Playing();
    final awake = _Awake();
    final w = OutputWatch(s, unplug: _Unplug(), awake: awake);
    w.update();
    expect(awake.asked, [false]);
    s.on = true;
    w.update();
    expect(awake.asked, [false, true]);
    w.update();
    expect(awake.asked, [false, true], reason: 'asked only on a change');
    s.foreground.value = false;
    w.update();
    expect(awake.asked.last, isFalse, reason: 'behind the app the screen may sleep');
    s
      ..foreground.value = true
      ..on = false
      ..settings.keepAwake = KeepAwake.always;
    w.update();
    expect(awake.asked.last, isTrue);
    s.settings.keepAwake = KeepAwake.off;
    w.update();
    expect(awake.asked.last, isFalse);
    s.suspendForStress();
    w.update();
    expect(awake.asked.last, isTrue, reason: 'a Benchmark keeps the screen on whatever the setting');
    s.resumeAfterStress();
    w.update();
    expect(awake.asked.last, isFalse);
  });

  test('remember zoom per project: the arranger\'s view kept by project id, and given back', () {
    final s = AppState()..project = ProjectDoc(id: 'song', name: 'Song', layers: []);
    ArrangeView? view = (zoom: 30, left: 128, top: 44);
    ArrangeView? applied;
    s
      ..readArrangeView = (() => view)
      ..applyArrangeView = ((v) => applied = v);
    s.rememberArrangeView();
    expect(s.settings.projectViews['song'], (zoom: 30.0, left: 128.0, top: 44.0));
    expect(s.savedArrangeView, view);
    s.applyArrangeView!(s.savedArrangeView!);
    expect(applied, view);
    s.settings.rememberZoom = false;
    view = (zoom: 2, left: 0, top: 0);
    s.rememberArrangeView();
    expect(s.settings.projectViews['song']!.zoom, 30, reason: 'off: nothing new is kept');
    expect(s.savedArrangeView, isNull);
  });

  testWidgets('left-handed: the transport is mirrored, Play and Record on the left', (tester) async {
    final s = AppState();
    Future<(double, double)> place() async {
      await tester.pumpWidget(MaterialApp(theme: Neon.theme(),
          home: Scaffold(body: Align(alignment: Alignment.bottomCenter,
              child: SizedBox(width: 390, child: BottomTransport(state: s))))));
      return (tester.getCenter(find.byKey(const ValueKey('transport-play'))).dx,
          tester.getCenter(find.byKey(const ValueKey('transport-undo'))).dx);
    }

    final (play, undo) = await place();
    expect(play, greaterThan(undo));
    s.settings.leftHanded = true;
    final (lPlay, lUndo) = await place();
    expect(lPlay, lessThan(lUndo));
    expect(tester.takeException(), isNull);
  });
}
