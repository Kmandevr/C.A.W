// Tests play, pause and stop on the real engine (needs CAW_LIB): a pause resumes where it stopped, a stop goes back to
// the start, and Space and Shift+Space do the same.
import 'dart:io';

import 'package:caw/actions/actions.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/ui/key_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  AppState app() {
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    s.ready = true;
    s.starting = false;
    s.useAudioDevice = false;
    return s;
  }

  // What AppState sends the engine, sent here at once instead of after its short debounce.
  Future<void> send(AppState s) async => s.info = await s.engine!.setProject(s.project.toEngineJson());

  /// Samples per sixteenth step in the engine's loop now.
  double stepLen(AppState s) {
    final m = s.engine!.meters();
    return m.loopLength / s.project.engineLoopSteps;
  }

  test('a pause resumes where it stopped; a stop starts again from the beginning', () async {
    final s = app();
    addTearDown(s.dispose);
    await send(s);
    final e = s.engine!;
    s.togglePlay();
    e.pullForTest(24000);
    s.togglePlay(); // pause
    expect(s.transportOn, isFalse);
    final paused = s.pausedStep!;
    expect(paused * stepLen(s), closeTo(24000, 512));
    e.pullForTest(48000); // the stop's fade, then silence
    expect(e.meters().playing, isFalse);

    s.togglePlay(); // resume
    expect(s.pausedStep, isNull);
    e.pullForTest(512);
    expect(e.meters().position, (paused * stepLen(s)).round() + 512);

    s.stopPlayback();
    expect(s.pausedStep, isNull);
    e.pullForTest(48000);
    s.togglePlay();
    e.pullForTest(512);
    expect(e.meters().position, 512, reason: 'after a stop, play starts from the top');
  }, skip: skip);

  test('a quick second press pauses even before the engine has started', () async {
    final s = app();
    addTearDown(s.dispose);
    await send(s);
    s.togglePlay();
    s.togglePlay(); // no audio block in between
    expect(s.transportOn, isFalse);
    expect(s.pausedStep, isNotNull);
    s.engine!.pullForTest(4800);
    expect(s.engine!.meters().playing, isFalse);
    s.togglePlay();
    s.stopPlayback(); // likewise for a stop right after a play
    s.engine!.pullForTest(4800);
    expect(s.engine!.meters().playing, isFalse);
    expect(s.pausedStep, isNull);
  }, skip: skip);

  test('a tempo change while paused resumes on the same beat', () async {
    final s = app();
    addTearDown(s.dispose);
    await send(s);
    final e = s.engine!;
    s.togglePlay();
    e.pullForTest(30000);
    s.togglePlay();
    final paused = s.pausedStep!;
    e.pullForTest(4800);
    s.project.bpm = s.project.bpm / 2;
    await send(s);
    s.togglePlay();
    e.pullForTest(64);
    expect(e.meters().position / stepLen(s), closeTo(paused, 64 / stepLen(s) + 1e-6));
  }, skip: skip);

  testWidgets('Space plays and pauses, Shift+Space stops', (tester) async {
    final s = app();
    await tester.runAsync(() => send(s));
    await tester.pumpWidget(MaterialApp(home: KeyRouter(state: s, screenArea: Area.arranger, onView: (_) {},
      child: const Scaffold(body: Focus(autofocus: true, child: SizedBox.expand())))));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(s.transportOn, isTrue);
    s.engine!.pullForTest(4096);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(s.pausedStep, isNotNull);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(s.pausedStep, isNull);
    expect(s.transportOn, isFalse);
    s.dispose(); // its meter poller stops before the test's timers are checked
    await tester.pump(const Duration(milliseconds: 100));
  }, skip: skip);
}
