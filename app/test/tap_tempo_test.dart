import 'package:caw/model/app_state.dart';
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
}
