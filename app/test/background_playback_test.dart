// Background playback (owner, 2026-11-12): the playback service starts and stops with the transport and recording, never
// starts from behind the app, its notification's Play/Pause and Stop drive the transport, and the Android channel carries
// all of it (the transport cases need CAW_LIB).
import 'dart:async';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/audio_record.dart';
import 'package:caw/model/background_playback.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/mic_permission.dart';
import 'package:caw/platform/playback_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';

class FakePlaybackService implements PlaybackService {
  final calls = <String>[];
  final actionsIn = StreamController<PlaybackAction>.broadcast();
  bool allowed = false, refuse = false;
  int asked = 0;
  ({bool playing, bool recording})? showing;

  @override
  Future<bool> show({required bool playing, required bool recording}) async {
    calls.add('show playing=$playing recording=$recording');
    if (refuse) return false;
    showing = (playing: playing, recording: recording);
    return true;
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
    showing = null;
  }

  @override
  Future<bool> notificationsAllowed() async => allowed;
  @override
  Future<bool> requestNotifications() async {
    asked++;
    return allowed = true;
  }

  @override
  Stream<PlaybackAction> get actions => actionsIn.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lib = Platform.environment['CAW_LIB'];
  final noEngine = lib == null || lib.isEmpty;

  AppState app() {
    final s = AppState(settings: Settings());
    s.engine = Engine.create();
    s.project = s.demoProject();
    s.ready = true;
    s.starting = false;
    s.useAudioDevice = false;
    return s;
  }

  Future<void> settle(BackgroundPlayback b) async {
    await b.settled();
    await Future<void>.delayed(Duration.zero);
    await b.settled();
  }

  test('the service starts with play, follows pause and stop, and asks for notifications once', () async {
    final s = app();
    final svc = FakePlaybackService();
    final b = BackgroundPlayback(s, svc, recorder: () => null);
    addTearDown(() {
      b.dispose();
      s.dispose();
    });
    expect(svc.calls, isEmpty, reason: 'nothing plays');
    s.togglePlay();
    await settle(b);
    expect(svc.showing, (playing: true, recording: false));
    expect(svc.asked, 1, reason: 'Android 13+: the notification permission, asked the first time something plays');
    s.togglePlay();  // pause in front: playback stopped, so the service stops
    await settle(b);
    expect(svc.showing, isNull);
    s.togglePlay();
    await settle(b);
    expect(svc.showing, (playing: true, recording: false));
    s.stopPlayback();
    await settle(b);
    expect(svc.showing, isNull);
    expect(svc.calls, ['show playing=true recording=false', 'hide', 'show playing=true recording=false', 'hide']);
    expect(svc.asked, 1, reason: 'once a run');
  }, skip: noEngine);

  test('it starts only while the app is in front, and keeps running behind it', () async {
    final s = app();
    final svc = FakePlaybackService();
    final b = BackgroundPlayback(s, svc, recorder: () => null);
    addTearDown(() {
      b.dispose();
      s.dispose();
    });
    s.lifecycle(foreground: false);
    s.togglePlay();  // e.g. a MIDI key behind the app: Android 12+ would refuse a start from here
    await settle(b);
    expect(svc.calls, isEmpty);
    s.lifecycle(foreground: true);
    await settle(b);
    expect(svc.showing, (playing: true, recording: false), reason: 'started on return');
    s.lifecycle(foreground: false);
    await settle(b);
    expect(svc.showing, isNotNull, reason: 'playing behind the app: the service keeps it running');
    expect(s.engine!.audioOn || !s.useAudioDevice, isTrue);
  }, skip: noEngine);

  test('the notification: Pause behind the app keeps it with Play, Play resumes, Stop ends it and releases', () async {
    final s = app();
    final svc = FakePlaybackService();
    final b = BackgroundPlayback(s, svc, recorder: () => null);
    addTearDown(() {
      b.dispose();
      s.dispose();
    });
    s.togglePlay();
    await settle(b);
    s.lifecycle(foreground: false);
    svc.actionsIn.add(PlaybackAction.playPause);
    await settle(b);
    expect(s.transportOn, isFalse);
    expect(svc.showing, (playing: false, recording: false), reason: '"paused", with Play');
    svc.actionsIn.add(PlaybackAction.playPause);
    await settle(b);
    expect(s.transportOn, isTrue);
    expect(svc.showing, (playing: true, recording: false));
    svc.actionsIn.add(PlaybackAction.stop);
    await settle(b);
    expect(s.transportOn, isFalse);
    expect(s.pausedStep, isNull, reason: 'a stop, not a pause');
    expect(svc.showing, isNull);
    expect(s.engine!.audioOn, isFalse, reason: 'behind the app and stopped: the device closes, as before');
    // Paused from the notification, then back in front: in front a pause ends the service as usual.
    s.lifecycle(foreground: true);
    s.togglePlay();
    await settle(b);
    s.lifecycle(foreground: false);
    svc.actionsIn.add(PlaybackAction.playPause);
    await settle(b);
    expect(svc.showing, isNotNull);
    s.lifecycle(foreground: true);
    await settle(b);
    expect(svc.showing, isNull);
  }, skip: noEngine);

  test('a recording runs the service too, as "recording"', () async {
    final s = AppState(settings: Settings());
    s.project = ProjectDoc(id: 'p', name: 'P', bpm: 120, loopBars: 4, layers: [
      LayerDoc(id: 'v', name: 'Vox', color: 0, input: AudioInputDoc()..armed = true),
    ]);
    s.audioIo = FakeAudioIo();
    final rec = AudioRecorder(s, permission: const NoMicPrompt(), prefs: AudioInputPrefs());
    final svc = FakePlaybackService();
    final b = BackgroundPlayback(s, svc, recorder: () => rec);
    addTearDown(() {
      b.dispose();
      rec.dispose();
      s.dispose();
    });
    expect(await rec.start(), isTrue);
    await settle(b);
    expect(svc.showing, (playing: false, recording: true));
    await rec.stop();
    await settle(b);
    expect(svc.showing, isNull);
  });

  test('a refused start is tried again on the next change', () async {
    final s = AppState(settings: Settings());
    s.project = ProjectDoc(id: 'p', name: 'P', bpm: 120, loopBars: 4, layers: [
      LayerDoc(id: 'v', name: 'Vox', color: 0, input: AudioInputDoc()..armed = true),
    ]);
    s.audioIo = FakeAudioIo();
    final rec = AudioRecorder(s, permission: const NoMicPrompt(), prefs: AudioInputPrefs());
    final svc = FakePlaybackService()..refuse = true;
    final b = BackgroundPlayback(s, svc, recorder: () => rec);
    addTearDown(() {
      b.dispose();
      rec.dispose();
      s.dispose();
    });
    await rec.start();
    await settle(b);
    expect(b.shown, isFalse);
    svc.refuse = false;
    await rec.stop();
    await rec.start();
    await settle(b);
    expect(b.shown, isTrue);
  });

  test('the Android channel: show and hide with their arguments, and the buttons come back as actions', () async {
    const channel = MethodChannel('caw/playback_service_test');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) { 'show' => true, 'notificationsAllowed' => false, 'requestNotifications' => true, _ => null };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final svc = AndroidPlaybackService(channel: channel);
    expect(await svc.show(playing: true, recording: true), isTrue);
    await svc.hide();
    expect(await svc.notificationsAllowed(), isFalse);
    expect(await svc.requestNotifications(), isTrue);
    expect(calls.map((c) => c.method), ['show', 'hide', 'notificationsAllowed', 'requestNotifications']);
    expect(calls.first.arguments, {'playing': true, 'recording': true});
    final got = <PlaybackAction>[];
    final sub = svc.actions.listen(got.add);
    addTearDown(sub.cancel);
    Future<void> press(String which) => messenger.handlePlatformMessage(channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall('action', which)), (_) {});
    await press('playPause');
    await press('stop');
    await press('unknown');
    await Future<void>.delayed(Duration.zero);
    expect(got, [PlaybackAction.playPause, PlaybackAction.stop]);
    // Without the plugin (desktop tests), nothing runs and nothing throws.
    messenger.setMockMethodCallHandler(channel, null);
    expect(await svc.show(playing: true, recording: false), isFalse);
    expect(await const NoPlaybackService().show(playing: true, recording: false), isFalse);
  });
}
