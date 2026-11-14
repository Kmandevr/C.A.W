// Goldens of Arrange with a tempo ramp, a 3/4 change and three sections (#207), at phone and desktop sizes: the
// section bar, the ruler's signature flags and bars, the tempo lane and the grid following the bars.
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/tempo_map.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

/// Intro (4 bars of 4/4), Verse (4 bars of 3/4) and Chorus (4 bars of 4/4), at 110 BPM ramping to 140 through the
/// verse and settling at 128 for the chorus, with a marker at the drop.
ProjectDoc tempoSong() => ProjectDoc(id: 'p', name: 'Tempo song', bpm: 110,
    tempoMap: const [TempoPoint(0, 110), TempoPoint(16, 110), TempoPoint(28, 140, ramp: true), TempoPoint(44, 128)],
    timeSignatures: const [TimeSignature(0, 0, 4, 4), TimeSignature(4, 0, 3, 4), TimeSignature(8, 0, 4, 4)],
    modules: [
      ModuleDoc(id: 'keys', name: 'Chords', source: '---\nkind: pattern\nlength: 16\n---\n0 C4 4 1\n0 E4 4 1\n8 G4 4 1\n'),
      ModuleDoc(id: 'beat', name: 'Beat', source: '---\nkind: pattern\nlength: 16\n---\n0 C2 1 1\n4 D2 1 1\n8 C2 1 1\n12 D2 1 1\n'),
      ModuleDoc(id: 'waltz', name: 'Waltz', source: '---\nkind: pattern\nlength: 12\n---\n0 C3 2 1\n4 E3 2 1\n8 G3 2 1\n'),
    ],
    layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [
        ClipDoc(id: 'k1', patternId: 'keys', startSteps: 0, lengthSteps: 64),
        ClipDoc(id: 'k2', patternId: 'waltz', startSteps: 64, lengthSteps: 48),
        ClipDoc(id: 'k3', patternId: 'keys', startSteps: 112, lengthSteps: 64),
      ]),
      LayerDoc(id: 'b', name: 'Drums', color: 4, clips: [
        ClipDoc(id: 'd1', patternId: 'beat', startSteps: 0, lengthSteps: 64),
        ClipDoc(id: 'd3', patternId: 'beat', startSteps: 112, lengthSteps: 64),
      ]),
    ],
    markers: [
      MarkerDoc(id: 'intro', name: 'Intro', startSteps: 0, endSteps: 64, color: 1),
      MarkerDoc(id: 'verse', name: 'Verse', startSteps: 64, endSteps: 112, color: 3),
      MarkerDoc(id: 'chorus', name: 'Chorus', startSteps: 112, endSteps: 176, color: 5),
      MarkerDoc(id: 'drop', name: 'Drop', startSteps: 112, color: 6),
    ]);

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = tempoSong();
  });
  tearDown(() => s.dispose());

  for (final size in ['phone', 'desktop']) {
    testWidgets('golden: Arrange with a tempo ramp, a 3/4 change and three sections, $size', (tester) async {
      await pumpGolden(tester, Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))),
          goldenSizes[size]!);
      await tester.tap(find.byKey(const ValueKey('arrange-zoom')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('arrange-zoom-fit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('arrange-tempo')), findsOneWidget);
      expect(find.byKey(const ValueKey('sig-flag-4')), findsOneWidget);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/arrange_tempo_$size.png'));
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
