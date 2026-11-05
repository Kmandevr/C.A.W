// Tests tap tempo's timing, reset and clamp, and the transport's typed tempo and bar.beat position.
import 'package:caw/model/app_state.dart';
import 'package:caw/ui/shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tap tempo averages recent taps and updates the project BPM', () {
    final state = AppState();
    final start = DateTime.utc(2026, 1, 1);
    state.tapTempo(at: start);
    expect(state.tempoTapCount, 1);
    state.tapTempo(at: start.add(const Duration(milliseconds: 500)));
    expect(state.project.bpm, 120);
    state.tapTempo(at: start.add(const Duration(milliseconds: 1000)));
    expect(state.project.bpm, 120);
    state.dispose();
  });

  test('a pause resets tap history before measuring again', () {
    final state = AppState();
    final start = DateTime.utc(2026, 1, 1);
    state.tapTempo(at: start);
    state.tapTempo(at: start.add(const Duration(milliseconds: 500)));
    expect(state.tempoTapCount, 2);
    state.tapTempo(at: start.add(const Duration(seconds: 3)));
    expect(state.tempoTapCount, 1);
    state.tapTempo(at: start.add(const Duration(milliseconds: 3500)));
    expect(state.project.bpm, 120);
    state.dispose();
  });

  test('tap tempo clamps to the supported BPM range', () {
    final state = AppState();
    final start = DateTime.utc(2026, 1, 1);
    state.tapTempo(at: start);
    state.tapTempo(at: start.add(const Duration(milliseconds: 10)));
    expect(state.project.bpm, 400);
    state.dispose();
  });

  test('a typed tempo is a finite number, clamped to 20..400 and rounded to 0.1', () {
    expect(parseBpm('128'), 128);
    expect(parseBpm(' 97,25 '), 97.3);
    expect(parseBpm('1000'), 400);
    expect(parseBpm('5'), 20);
    expect(parseBpm('fast'), isNull);
    expect(parseBpm('NaN'), isNull);
    expect(parseBpm('Infinity'), isNull);
  });

  test('the transport shows the playhead as bar.beat from 1.1', () {
    // A 4-bar loop of 64 steps over 6400 units: 100 units a step, 16 steps (4 beats) a bar.
    expect(transportPosition(0, 6400, 64, 16), '1.1');
    expect(transportPosition(399, 6400, 64, 16), '1.1');
    expect(transportPosition(400, 6400, 64, 16), '1.2');
    expect(transportPosition(1600, 6400, 64, 16), '2.1');
    expect(transportPosition(6399, 6400, 64, 16), '4.4');
    expect(transportPosition(1200, 6400, 64, 12), '2.1', reason: 'three beats to the bar');
    expect(transportPosition(5, 0, 64, 16), '1.1');
    expect(transportPosition(6400, 6400, 64, 16), '4.4', reason: 'a read on the wrap is still the last step');
    // A 4-bar loop under an 8-bar arrangement: the engine loops all 8 bars (engineLoopSteps 128).
    expect(transportPosition(4800, 6400, 128, 16), '7.1');
  });
}
