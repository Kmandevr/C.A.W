// The pattern templates Build's "Open an example" lists (the note-clip text form, #158), bundled with the app as the
// C++ starters are (cpp_starters.dart). They match examples/acid-line.caw and examples/chords.caw
// (test/pattern_templates_test.dart), so the engine's .caw template API isn't needed for them (#160).
import '../engine/engine.dart' show Template;

const List<Template> patternTemplates = [
  Template('acid-line.caw', '''---
caw: 1
kind: pattern
name: Acid line
summary: One bar of A minor acid with two slides, a ratchet and a note that plays half the time
length: 16
---
// at = start in 16ths, len = length in 16ths, vel = 0..1
// extras: slide (glide into the next note), ratchet N (repeat N times), prob P (chance it plays)
// at  note  len  vel  extras
0      A1    2    1
2      A2    1    0.7
3      A1    1    0.8  slide
4      C2    2    0.9
6      A1    1    0.6  prob 0.5
8      E2    2    1    ratchet 2
10     G1    1    0.7
11     A1    1    0.8  slide
12     A2    2    0.9
14     G2    1    0.6
15     E2    1    0.8
'''),
  Template('chords.caw', '''---
caw: 1
kind: pattern
name: Chords
summary: Four bars of A minor, F, C and G chords for any synth to play
length: 4 bars
---
// A chord is several notes joined by commas; each note gets its own voice.
// at  notes      len  vel
0      A3,C4,E4   16   0.8
16     F3,A3,C4   16   0.75
32     C3,E3,G3   16   0.8
48     G3,B3,D4   14   0.7
62     G3,B3,D4   1/2  0.5  ratchet 2
'''),
];
