// What a sample's file and folder names say: its tempo ("loop 120bpm", "_120_"), key ("Am", "F# min"), type and instrument.
import 'music_key.dart';

/// One-shot or loop.
enum SampleKind { oneShot, loop }

/// The instrument words the browser filters by.
enum SampleInstrument {
  kick('Kick'),
  snare('Snare'),
  hat('Hat'),
  clap('Clap'),
  cymbal('Cymbal'),
  perc('Perc'),
  drums('Drums'),
  bass('Bass'),
  pad('Pad'),
  lead('Lead'),
  pluck('Pluck'),
  keys('Keys'),
  synth('Synth'),
  guitar('Guitar'),
  strings('Strings'),
  brass('Brass'),
  vox('Vox'),
  fx('FX');

  const SampleInstrument(this.label);
  final String label;

  /// A single hit of a drum (a bare number in its name is a sample number, not a tempo).
  bool get isHit => const {kick, snare, hat, clap, cymbal, perc}.contains(this);

  static SampleInstrument? byName(Object? n) => values.where((v) => v.name == n).firstOrNull;
}

/// What the names gave. Every field may be null: nothing was found.
class NameGuess {
  const NameGuess({this.bpm, this.key, this.kind, this.instrument, this.rootNote, this.tags = const []});
  final double? bpm;
  final MusicalKey? key;
  final SampleKind? kind;
  final SampleInstrument? instrument;

  /// A one-shot's note ("C3" in "Bass C3"): MIDI number, C4 = 60.
  final int? rootNote;

  /// Words the browser lets you filter by (the type and instrument words found, "808").
  final List<String> tags;
}

const _instrumentWords = <String, SampleInstrument>{
  'kick': SampleInstrument.kick, 'kicks': SampleInstrument.kick, 'kik': SampleInstrument.kick, 'bd': SampleInstrument.kick,
  'bassdrum': SampleInstrument.kick,
  'snare': SampleInstrument.snare, 'snares': SampleInstrument.snare, 'snr': SampleInstrument.snare,
  'sd': SampleInstrument.snare, 'rim': SampleInstrument.snare, 'rimshot': SampleInstrument.snare,
  'hat': SampleInstrument.hat, 'hats': SampleInstrument.hat, 'hihat': SampleInstrument.hat, 'hihats': SampleInstrument.hat,
  'hh': SampleInstrument.hat, 'ohh': SampleInstrument.hat, 'chh': SampleInstrument.hat,
  'clap': SampleInstrument.clap, 'claps': SampleInstrument.clap, 'snap': SampleInstrument.clap,
  'crash': SampleInstrument.cymbal, 'ride': SampleInstrument.cymbal, 'cymbal': SampleInstrument.cymbal,
  'cymbals': SampleInstrument.cymbal,
  'perc': SampleInstrument.perc, 'percs': SampleInstrument.perc, 'percussion': SampleInstrument.perc,
  'shaker': SampleInstrument.perc, 'tom': SampleInstrument.perc, 'toms': SampleInstrument.perc,
  'conga': SampleInstrument.perc, 'bongo': SampleInstrument.perc, 'cowbell': SampleInstrument.perc,
  'tamb': SampleInstrument.perc, 'tambourine': SampleInstrument.perc,
  'drum': SampleInstrument.drums, 'drums': SampleInstrument.drums, 'beat': SampleInstrument.drums,
  'beats': SampleInstrument.drums, 'breakbeat': SampleInstrument.drums, 'break': SampleInstrument.drums,
  'top': SampleInstrument.drums, 'tops': SampleInstrument.drums,
  'bass': SampleInstrument.bass, 'basses': SampleInstrument.bass, 'sub': SampleInstrument.bass,
  'reese': SampleInstrument.bass, 'bassline': SampleInstrument.bass,
  'pad': SampleInstrument.pad, 'pads': SampleInstrument.pad, 'atmos': SampleInstrument.pad,
  'atmosphere': SampleInstrument.pad, 'drone': SampleInstrument.pad,
  'lead': SampleInstrument.lead, 'leads': SampleInstrument.lead,
  'pluck': SampleInstrument.pluck, 'plucks': SampleInstrument.pluck,
  'keys': SampleInstrument.keys, 'piano': SampleInstrument.keys, 'rhodes': SampleInstrument.keys,
  'organ': SampleInstrument.keys, 'chord': SampleInstrument.keys, 'chords': SampleInstrument.keys,
  'synth': SampleInstrument.synth, 'synths': SampleInstrument.synth, 'arp': SampleInstrument.synth,
  'guitar': SampleInstrument.guitar, 'gtr': SampleInstrument.guitar, 'guitars': SampleInstrument.guitar,
  'strings': SampleInstrument.strings, 'string': SampleInstrument.strings, 'violin': SampleInstrument.strings,
  'cello': SampleInstrument.strings,
  'brass': SampleInstrument.brass, 'horn': SampleInstrument.brass, 'horns': SampleInstrument.brass,
  'trumpet': SampleInstrument.brass, 'sax': SampleInstrument.brass,
  'vox': SampleInstrument.vox, 'vocal': SampleInstrument.vox, 'vocals': SampleInstrument.vox,
  'voice': SampleInstrument.vox, 'acapella': SampleInstrument.vox, 'chant': SampleInstrument.vox,
  'fx': SampleInstrument.fx, 'sfx': SampleInstrument.fx, 'riser': SampleInstrument.fx, 'risers': SampleInstrument.fx,
  'sweep': SampleInstrument.fx, 'impact': SampleInstrument.fx, 'downlifter': SampleInstrument.fx,
  'uplifter': SampleInstrument.fx, 'noise': SampleInstrument.fx, 'foley': SampleInstrument.fx,
};

/// Drum-machine and other numbers that look like tempos but never are one.
const _notTempos = {101, 202, 303, 404, 505, 606, 707, 727, 808, 909};

/// Words in a name: split at spaces, punctuation and case changes ("KickHard" → kick, hard; "Am_Loop" → Am, loop).
/// Original case is kept (keys need it). At most 64 words of at most 40 characters.
List<String> nameWords(String name) {
  final out = <String>[];
  for (final part in name.split(RegExp(r'[\s_\-.,()\[\]{}+&@!~]+'))) {
    if (part.isEmpty) continue;
    // camelCase and letter/digit boundaries ("120bpm" stays whole: digits then letters is a unit word).
    for (final w in part.split(RegExp(r'(?<=[a-z])(?=[A-Z][a-z])'))) {
      if (w.isNotEmpty) out.add(w.length > 40 ? w.substring(0, 40) : w);
      if (out.length >= 64) return out;
    }
  }
  return out;
}

final _bpmAfter = RegExp(r'(?<![\d.])(\d{2,3}(?:\.\d{1,2})?)\s*[-_ ]?\s*bpm', caseSensitive: false);
final _bpmBefore = RegExp(r'bpm\s*[-_: ]?\s*(\d{2,3}(?:\.\d{1,2})?)(?![\d.])', caseSensitive: false);
final _bareNumber = RegExp(r'(?:^|[\s_\-\[\(])(\d{2,3})(?=$|[\s_\-\]\)])');

/// A tempo named in [name]: "120bpm", "120 BPM", "95_bpm", "BPM 128", or a bare delimited number ("Loop_120_Am",
/// "Groove - 96") when [allowBare]. A bare number is skipped when it is a drum machine's (808, 909, …), has a leading
/// zero (a sample number, "Kick 012"), or more than one could be the tempo; 40–300 BPM only.
double? tempoInName(String name, {bool allowBare = true}) {
  double? ok(String? s) {
    final v = s == null ? null : double.tryParse(s);
    return v != null && v >= 40 && v <= 300 ? v : null;
  }

  final a = ok(_bpmAfter.firstMatch(name)?.group(1));
  if (a != null) return a;
  final b = ok(_bpmBefore.firstMatch(name)?.group(1));
  if (b != null) return b;
  if (!allowBare) return null;
  final found = <double>[];
  for (final m in _bareNumber.allMatches(name)) {
    final s = m.group(1)!;
    if (s.startsWith('0')) continue;
    final n = int.parse(s);
    if (_notTempos.contains(n) || n < 60 || n > 200) continue;
    // "120 Hz", "200k", "100%": a unit right after is not a tempo.
    final rest = name.substring(m.end).trimLeft().toLowerCase();
    if (RegExp(r'^(hz|khz|k\b|%|ms|bit|kbps|st\b|cents?)').hasMatch(rest)) continue;
    found.add(n.toDouble());
  }
  return found.length == 1 ? found.first : null;
}

final _keyWord = RegExp(r'^([A-G])([#b♯♭]?)(m|min|minor|maj|major|M)?$');
final _modeWord = RegExp(r'^(m|min|minor|maj|major)$', caseSensitive: false);
final _noteWord = RegExp(r'^([A-G])([#b♯♭]?)(-?[0-8])$');

/// A key in a name's words: "Am", "F#m", "C#maj", "Gb", "Bbmin", or a letter followed by a mode word ("A min",
/// "C major"). A plain capital letter alone ("Kick A") is a variation, not a key; "key" before one ("key C") counts.
MusicalKey? keyInWords(List<String> words) {
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    final m = _keyWord.firstMatch(w);
    if (m == null) continue;
    final accidental = m.group(2) ?? '';
    final mode = m.group(3);
    final next = i + 1 < words.length ? words[i + 1] : '';
    final nextMode = _modeWord.hasMatch(next) ? next.toLowerCase() : null;
    final prev = i > 0 ? words[i - 1].toLowerCase() : '';
    if (mode == null && accidental.isEmpty && nextMode == null && prev != 'key') continue;
    final pc = MusicalKey.pitchClass(m.group(1)!, accidental);
    if (pc == null) continue;
    final minor = mode != null ? (mode == 'm' || mode.startsWith('min')) : (nextMode?.startsWith('m') == true && nextMode != 'maj' && nextMode != 'major');
    return MusicalKey(pc, minor: minor);
  }
  return null;
}

/// Reads one name (a file's, without its extension, or a folder's).
NameGuess guessFromName(String name, {bool allowBareTempo = true}) {
  final words = nameWords(name);
  SampleInstrument? instrument;
  SampleKind? kind;
  int? root;
  final tags = <String>[];
  for (var i = 0; i < words.length; i++) {
    final lower = words[i].toLowerCase();
    if (lower == 'loop' || lower == 'loops' || lower == 'looped') {
      kind = SampleKind.loop;
      if (!tags.contains('loop')) tags.add('loop');
    } else if (lower == 'oneshot' || lower == 'oneshots' || lower == 'hit' || lower == 'shot' && i > 0 &&
        words[i - 1].toLowerCase() == 'one') {
      kind = SampleKind.oneShot;
      if (!tags.contains('one shot')) tags.add('one shot');
    }
    final inst = _instrumentWords[lower];
    if (inst != null) {
      instrument ??= inst;
      if (!tags.contains(inst.name)) tags.add(inst.name);
    }
    if (lower == '808' && !tags.contains('808')) tags.add('808');
    final n = _noteWord.firstMatch(words[i]);
    if (n != null && root == null) {
      final pc = MusicalKey.pitchClass(n.group(1)!, n.group(2) ?? '');
      final octave = int.parse(n.group(3)!);
      if (pc != null) root = (octave + 1) * 12 + pc;
    }
  }
  // "one shot" as two words, or "one-shot".
  if (kind == null && RegExp(r'one[\s_-]?shot', caseSensitive: false).hasMatch(name)) {
    kind = SampleKind.oneShot;
    tags.add('one shot');
  }
  // A drum hit's bare number is a sample number unless the name says loop; a folder's is never a tempo.
  final bare = allowBareTempo && (!(instrument?.isHit ?? false) || kind == SampleKind.loop);
  return NameGuess(bpm: tempoInName(name, allowBare: bare), key: keyInWords(words), kind: kind,
      instrument: instrument, rootNote: root, tags: tags);
}

/// A file's name and its folders (nearest first) together: the file name wins, then each folder in turn. A folder's
/// bare number is never taken for a tempo ("Pack 2024", "Vol 120").
NameGuess guessFromPath(String fileName, List<String> folders) {
  final base = fileName.replaceFirst(RegExp(r'\.[A-Za-z0-9]{1,5}$'), '');
  final file = guessFromName(base);
  var bpm = file.bpm, key = file.key, kind = file.kind, instrument = file.instrument;
  final tags = [...file.tags];
  for (final f in folders.take(8)) {
    final g = guessFromName(f, allowBareTempo: false);
    bpm ??= g.bpm;
    key ??= g.key;
    kind ??= g.kind;
    instrument ??= g.instrument;
    for (final t in g.tags) {
      if (!tags.contains(t)) tags.add(t);
    }
  }
  // A folder of loops makes a file loop unless the file says otherwise; a bare tempo in the file name of a loop
  // counts now too.
  if (bpm == null && kind == SampleKind.loop) bpm = tempoInName(base);
  return NameGuess(bpm: bpm, key: key, kind: kind, instrument: instrument, rootNote: file.rootNote, tags: tags);
}
