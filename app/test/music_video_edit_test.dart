// The music video editor's model: the #183 note unroll, auto-cut triggers, snapping, lane and list edits, layout
// geometry, the effect stack, pitch bends, falling notes, and saving with the project (versioned, older projects load).
import 'package:caw/model/music_video_scene.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

const _quarters = '---\ncaw: 1\nkind: pattern\nname: Q\nlength: 1 bar\n---\n0 C4 1 1\n4 D4 1 1\n8 E4 1 1\n12 F4 1 1\n';
const _held = '---\ncaw: 1\nkind: pattern\nname: H\nlength: 1 bar\n---\n2 C4 4 1\n8 E4 2 1\n';

VideoScene _sceneOf(List<ClipDoc> clips, {String source = _quarters}) => buildVideoScene(
    ProjectDoc(id: 'p', name: 'p', bpm: 120, loopBars: 4, modules: [ModuleDoc(id: 'm', name: 'M', source: source)],
        layers: [LayerDoc(id: 't', name: 'T', color: 0, clips: clips)]),
    colorOf: (_) => 0xffffffff);

void main() {
  group('#183 notes in the arrangement shot', () {
    test('a looped clip with a source offset shows the notes after the loop wraps, as the engine plays them', () {
      // The engine plays source steps 4..16 at 0..12, wraps to 0..16 at 12..28, then 0..4 at 28..32.
      final s = _sceneOf([ClipDoc(id: 'c', patternId: 'm', lengthSteps: 32, sourceOffsetSteps: 4, loop: true)]);
      expect([for (final n in s.notes) n.start], [0, 4, 8, 12, 16, 20, 24, 28]);
      expect([for (final n in s.notes) n.pitch], [62, 64, 65, 60, 62, 64, 65, 60]);
    });

    test('a note already sounding where the clip starts in its source is kept from there (its tail)', () {
      final s = _sceneOf([ClipDoc(id: 'c', patternId: 'm', lengthSteps: 12, sourceOffsetSteps: 4, loop: false)], source: _held);
      expect([for (final n in s.notes) (n.start, n.end, n.pitch)], [(0.0, 2.0, 60.0), (4.0, 6.0, 64.0)]);
    });

    test('a clip that does not loop plays its source once and stops at the pattern end', () {
      final s = _sceneOf([ClipDoc(id: 'c', patternId: 'm', lengthSteps: 32, loop: false)]);
      expect([for (final n in s.notes) n.start], [0, 4, 8, 12]);
    });
  });
}
