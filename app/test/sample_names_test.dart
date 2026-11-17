// The sample browser's name reader (#229): tempos ("120bpm", "_120_", not "808" or sample numbers), keys, types and instruments, and musical keys.
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/music_key.dart';
import 'package:caw/model/sample_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tempo in a name', () {
    test('marked tempos', () {
      expect(tempoInName('loop 120bpm'), 120);
      expect(tempoInName('Drums 120 BPM'), 120);
      expect(tempoInName('drums_95_bpm'), 95);
      expect(tempoInName('bass-128bpm-Am'), 128);
      expect(tempoInName('BPM 140 groove'), 140);
      expect(tempoInName('vox 97.5bpm'), 97.5);
      expect(tempoInName('fast 400bpm'), isNull);  // out of range
    });
    test('bare numbers only when delimited and alone', () {
      expect(tempoInName('Loop_120_Am'), 120);
      expect(tempoInName('Groove - 96 - Dry'), 96);
      expect(tempoInName('808 Bass'), isNull);  // a drum machine
      expect(tempoInName('TR-909 Kick'), isNull);
      expect(tempoInName('Kick 012'), isNull);  // a sample number with a leading zero
      expect(tempoInName('Loop 120 128'), isNull);  // two candidates: ambiguous
      expect(tempoInName('Sine 120 Hz'), isNull);  // a unit
      expect(tempoInName('Pad_45_dark'), isNull);  // too slow for a bare number
      expect(tempoInName('Loop_120_Am', allowBare: false), isNull);
    });
    test('a drum hit\'s number is a sample number', () {
      expect(guessFromName('Kick_120_hard').bpm, isNull);
      expect(guessFromName('Snare 100').bpm, isNull);
      expect(guessFromName('Kick loop 120').bpm, 120);  // a loop says it is
    });
    test('the import\'s guess uses the same reader', () {
      expect(AudioEdit.guessBpm('loop 120bpm.wav'), 120);
      expect(AudioEdit.guessBpm('Loop_124_Fm.wav'), 124);
      expect(AudioEdit.guessBpm('808 kick.wav'), isNull);
    });
  });

  group('key in a name', () {
    MusicalKey? key(String n) => guessFromName(n).key;
    test('the usual spellings', () {
      expect(key('Pad Am'), const MusicalKey(9, minor: true));
      expect(key('Lead_F#m_128'), const MusicalKey(6, minor: true));
      expect(key('Keys C#maj'), const MusicalKey(1));
      expect(key('Bass Gb'), const MusicalKey(6));
      expect(key('Pluck A min'), const MusicalKey(9, minor: true));
      expect(key('Strings C major'), const MusicalKey(0));
      expect(key('Synth Bbmin'), const MusicalKey(10, minor: true));
      expect(key('key C loop'), const MusicalKey(0));
    });
    test('a capital letter alone is not a key', () {
      expect(key('Kick A'), isNull);
      expect(key('Snare B 2'), isNull);
      expect(key('Ambient wash'), isNull);
      expect(key('FX riser'), isNull);
    });
  });

  group('type, instrument and root note', () {
    test('words, compounds and folders', () {
      final g = guessFromName('KickHard_01');
      expect(g.instrument, SampleInstrument.kick);
      expect(guessFromName('closed hat 3').instrument, SampleInstrument.hat);
      expect(guessFromName('Vocal Chop').instrument, SampleInstrument.vox);
      expect(guessFromName('Drum Loop 90').kind, SampleKind.loop);
      expect(guessFromName('Snare one shot').kind, SampleKind.oneShot);
      expect(guessFromName('Snare_OneShot').kind, SampleKind.oneShot);
      expect(guessFromName('Bass C3').rootNote, 48);
      final p = guessFromPath('Dark 01.wav', ['Am', 'Loops 120bpm', 'Pads']);
      expect(p.key, const MusicalKey(9, minor: true));
      expect(p.bpm, 120);
      expect(p.kind, SampleKind.loop);
      expect(p.instrument, SampleInstrument.pad);
      expect(p.tags, containsAll(['loop', 'pad']));
      // A folder's bare number is never a tempo; the file's own name wins over its folders.
      expect(guessFromPath('Hit.wav', ['Pack 2024', 'Vol 120']).bpm, isNull);
      expect(guessFromPath('Pad.wav', ['Loops Vol 120']).bpm, isNull);  // a loops folder's bare number either
      expect(guessFromPath('Groove 96.wav', ['Loops']).bpm, 96);  // but a loop's own bare number counts
      expect(guessFromPath('Loop 90bpm.wav', ['130 bpm']).bpm, 90);
    });
    test('names are bounded', () {
      final long = List.filled(500, 'word').join(' ');
      expect(nameWords(long).length, 64);
      expect(guessFromName('${'x' * 5000} 120bpm').bpm, 120);
    });
  });

  group('musical keys', () {
    test('parse metadata spellings, key-wheel and Open Key codes', () {
      expect(MusicalKey.parse('Am'), const MusicalKey(9, minor: true));
      expect(MusicalKey.parse('Dbm'), const MusicalKey(1, minor: true));
      expect(MusicalKey.parse('F# minor'), const MusicalKey(6, minor: true));
      expect(MusicalKey.parse('8A'), const MusicalKey(9, minor: true));
      expect(MusicalKey.parse('8B'), const MusicalKey(0));
      expect(MusicalKey.parse('9B'), const MusicalKey(7));
      expect(MusicalKey.parse('12B'), const MusicalKey(4));
      expect(MusicalKey.parse('1d'), const MusicalKey(0));
      expect(MusicalKey.parse('1m'), const MusicalKey(9, minor: true));
      expect(MusicalKey.parse('o'), isNull);
      expect(MusicalKey.parse('H'), isNull);
      expect(MusicalKey.parse('A' * 100), isNull);
    });
    test('names, relative and compatible keys', () {
      const am = MusicalKey(9, minor: true);
      expect(am.short, 'Am');
      expect(am.long, 'A minor');
      expect(am.camelot, '8A');
      expect(const MusicalKey(0).camelot, '8B');
      expect(const MusicalKey(7).camelot, '9B');
      expect(am.relative, const MusicalKey(0));
      expect(const MusicalKey(0).relative, am);
      expect(am.compatible, containsAll([am, const MusicalKey(0), const MusicalKey(4, minor: true), const MusicalKey(2, minor: true)]));
      for (final k in MusicalKey.all) {
        expect(MusicalKey.fromCode(k.code), k);
        expect(MusicalKey.parse(k.camelot), k);
        expect(MusicalKey.parse(k.short), k);
      }
      expect(MusicalKey.fromCode('13'), isNull);
      expect(MusicalKey.fromCode(7), isNull);
    });
  });
}
