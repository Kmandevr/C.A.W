// Standard MIDI Files (SMF format 0, 1 and 2; MIDI 1.0) read and written in Dart: notes with per-note pitch bend,
// pressure and timbre (CC74, MPE style), tempo and meter. Files are untrusted: reading is bounded and fails closed.
//
// Reading:
// - every chunk, length and variable-length number is checked against the bytes there are; a file that ends early or
//   breaks the format throws a [MidiFileException] naming the problem, never a RangeError
// - running status, note-on with velocity 0 as a note-off, overlapping notes of one key (the first note-off ends the
//   earliest of them), all-notes-off/all-sound-off, the pitch bend range (RPN 0) and the MPE Configuration Message
//   (RPN 6, which makes member channels' default range 48 semitones)
// - controller changes other than those the reader uses itself (bank and data entry 0/6/32/38, CC74, NRPN/RPN
//   98-101, channel mode 120-127) are kept per track as [MidiControl]s
// - sysex and meta events other than tempo, time signature and track name are skipped
// - SMPTE time division: ticks are read as if the file ran at 120 BPM (its tempo events don't time it)
// Writing: a format 1 file, a conductor track (tempo and meter) and one track per [MidiTrack]. Notes with any bend,
// pressure or timbre make the whole track MPE (lower zone: channel 1 manages, 2-16 each carry one note at a time with
// its own bend, channel pressure and CC74); otherwise notes are plain, on their own channels. A track's controller
// changes ([MidiTrack.controls], such as automation lanes as CCs) go out on their own channels (MPE's manager channel
// is channel 1, so a control on channel 0 reaches the whole zone).
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// The biggest file read (the engine's limit too, engine/src/midifile.h).
const int kMaxMidiFileBytes = 16 << 20;

/// Events (channel, meta and sysex) read from one file.
const int kMaxMidiEvents = 1 << 21;

/// Notes read from one file.
const int kMaxMidiNotes = 1 << 20;

/// Expression points (bend, pressure and timbre changes inside notes) read from one file.
const int kMaxMidiCurvePoints = 1 << 22;

/// Ticks per quarter note in written files.
const int kMidiExportPpq = 960;

/// Why a MIDI file couldn't be read.
class MidiFileException extends FormatException {
  const MidiFileException(String message, [int? offset]) : super(message, null, offset);
  @override
  String toString() => offset == null ? message : '$message (at byte $offset)';
}

/// A value set at [tick]: semitones for a bend, 0..1 for pressure and timbre. MIDI holds it until the next one.
class MidiPoint {
  const MidiPoint(this.tick, this.value);
  final int tick;
  final double value;

  @override
  String toString() => '$tick:$value';
}

/// One note. Its curves list the values set while it sounds, in time order; a bend list, when there is one, starts at
/// [on] with the bend sounding when the note began. Pressure and timbre lists are empty when the file sets none for
/// the note.
class MidiNote {
  MidiNote({
    this.channel = 0,
    required this.key,
    required this.velocity,
    required this.on,
    required this.off,
    List<MidiPoint>? bend,
    List<MidiPoint>? pressure,
    List<MidiPoint>? timbre,
  })  : bend = bend ?? [],
        pressure = pressure ?? [],
        timbre = timbre ?? [];

  final int channel; // 0..15
  final int key; // 0..127
  final int velocity; // 1..127
  int on, off; // ticks, off >= on
  final List<MidiPoint> bend, pressure, timbre;

  bool get expressive => bend.any((p) => p.value != 0) || pressure.isNotEmpty || timbre.isNotEmpty;

  @override
  String toString() => 'MidiNote(ch $channel key $key vel $velocity $on-$off'
      '${bend.isEmpty ? '' : ' bend $bend'}${pressure.isEmpty ? '' : ' press $pressure'}'
      '${timbre.isEmpty ? '' : ' timbre $timbre'})';
}

/// A controller change (Control Change [controller] 0..127 to [value] 0..127) on [channel] 0..15 at [tick].
class MidiControl {
  const MidiControl(this.tick, this.controller, this.value, [this.channel = 0]);
  final int tick, controller, value, channel;

  @override
  bool operator ==(Object other) =>
      other is MidiControl &&
      other.tick == tick &&
      other.controller == controller &&
      other.value == value &&
      other.channel == channel;
  @override
  int get hashCode => Object.hash(tick, controller, value, channel);
  @override
  String toString() => 'CC$controller=$value@$tick${channel == 0 ? '' : ' ch $channel'}';
}

/// Controllers the reader interprets itself (data entry, MPE timbre, RPN/NRPN, channel mode), so not kept as controls.
bool _readerOwns(int cc) => cc == 0 || cc == 6 || cc == 32 || cc == 38 || cc == 74 || (cc >= 98 && cc <= 101) || cc >= 120;

class MidiTempo {
  const MidiTempo(this.tick, this.bpm);
  final int tick;
  final double bpm;
}

/// A time signature event: from [tick] on, [numerator] over [denominator].
class MidiMeter {
  const MidiMeter(this.tick, this.numerator, this.denominator);
  final int tick, numerator, denominator;
}

class MidiTrack {
  MidiTrack({this.name = '', required this.notes, this.endTick, this.controls = const []});
  final String name;
  final List<MidiNote> notes;

  /// Controller changes in time order (automation lanes as CCs when written; a file's other CCs when read).
  final List<MidiControl> controls;

  /// Where the track ends (its End of Track event); null when writing means just after the last note.
  final int? endTick;
}

class MidiFile {
  MidiFile({
    this.format = 1,
    this.ppq = kMidiExportPpq,
    this.tempos = const [],
    this.meterNumerator,
    this.meterDenominator,
    this.meters = const [],
    required this.tracks,
    this.mpe = false,
  });

  final int format; // 0, 1 or 2 as read; written files are format 1
  final int ppq; // ticks per quarter note
  final List<MidiTempo> tempos; // in time order
  final int? meterNumerator, meterDenominator; // the first time signature, e.g. 6 and 8

  /// Every time signature event in time order (one a tick, the last read wins). Written in place of the meter above
  /// when not empty.
  final List<MidiMeter> meters;
  final List<MidiTrack> tracks; // in file order (a format 1 conductor track without notes is kept, empty)
  final bool mpe; // the file sent an MPE Configuration Message

  /// The tempo at the start (the first tempo event at tick 0, else the first one); null when the file sets none.
  double? get firstBpm => tempos.isEmpty ? null : tempos.first.bpm;

  bool get tempoChanges => tempos.map((t) => t.bpm).toSet().length > 1;

  int get noteCount => tracks.fold(0, (n, t) => n + t.notes.length);
}

// ---------------------------------------------------------------------------------------------------------------
// Reading

/// Reads a Standard MIDI File. Throws a [MidiFileException] for anything that isn't a well-formed one within the limits.
MidiFile readMidiFile(Uint8List data) {
  if (data.length > kMaxMidiFileBytes) throw const MidiFileException('the file is bigger than 16 MB');
  if (data.length < 14 || !_tag(data, 0, 'MThd')) {
    throw const MidiFileException('not a Standard MIDI File (no MThd header)');
  }
  final headerLength = _u32(data, 4);
  if (headerLength < 6 || 8 + headerLength > data.length) throw const MidiFileException('the file header is cut off', 4);
  final format = _u16(data, 8), declared = _u16(data, 10), division = _u16(data, 12);
  if (format > 2) throw MidiFileException('unknown MIDI file format $format', 8);
  if (declared == 0) throw const MidiFileException('the file has no tracks', 10);
  int ppq, scale = 1;
  if (division & 0x8000 != 0) {
    // SMPTE: frames per second (negative) and ticks per frame. A quarter note is taken as half a second (120 BPM).
    final fps = 256 - (division >> 8), perFrame = division & 0xFF;
    if (!const [24, 25, 29, 30].contains(fps) || perFrame == 0) {
      throw const MidiFileException('the file\'s SMPTE time division is invalid', 12);
    }
    ppq = (fps == 29 ? 30 : fps) * perFrame;
    scale = 2;
  } else {
    ppq = division;
    if (ppq == 0) throw const MidiFileException('the file\'s time division is 0', 12);
  }
  final r = _Reader(data, scale);
  var pos = 8 + headerLength;
  final tracks = <MidiTrack>[];
  while (tracks.length < declared && pos + 8 <= data.length) {
    final length = _u32(data, pos + 4);
    final start = pos + 8, end = start + length;
    if (_tag(data, pos, 'MTrk')) {
      if (end > data.length) throw MidiFileException('track ${tracks.length + 1} is cut off', pos);
      tracks.add(r.track(start, end, tracks.length + 1));
    } else if (end > data.length) {
      break; // an unknown chunk at the end, cut off: nothing of ours is lost
    }
    pos = end;
  }
  if (tracks.length < declared) {
    throw MidiFileException('the file says it has $declared tracks but holds ${tracks.length}; it may be cut off');
  }
  r.tempos.sort((a, b) => a.tick.compareTo(b.tick));
  return MidiFile(
    format: format,
    ppq: ppq,
    tempos: scale == 1 ? List.unmodifiable(r.tempos) : const [],
    meterNumerator: r.meter?.$2,
    meterDenominator: r.meter?.$3,
    meters: scale == 1 ? List.unmodifiable(r.meters.values.toList()..sort((a, b) => a.tick.compareTo(b.tick))) : const [],
    tracks: List.unmodifiable(tracks),
    mpe: r.mpe,
  );
}

bool _tag(Uint8List d, int at, String tag) {
  for (var i = 0; i < 4; i++) {
    if (d[at + i] != tag.codeUnitAt(i)) return false;
  }
  return true;
}

int _u16(Uint8List d, int at) => d[at] << 8 | d[at + 1];
int _u32(Uint8List d, int at) => d[at] << 24 | d[at + 1] << 16 | d[at + 2] << 8 | d[at + 3];

/// One channel's state while a track is read.
class _Channel {
  int bend = 8192; // 14-bit
  double range = 2; // pitch bend range in semitones
  int rpnMsb = 127, rpnLsb = 127;
  int pressureTick = -1, timbreTick = -1;
  double pressure = 0, timbre = 0;
  final List<MidiNote> open = [];

  double get bendSemitones => (bend - 8192) / 8192 * range;
}

class _Reader {
  _Reader(this.d, this.scale);
  final Uint8List d;
  final int scale; // ticks are multiplied by this (2 for SMPTE files)
  final List<MidiTempo> tempos = [];
  (int, int, int)? meter; // tick, numerator, denominator: the earliest
  final Map<int, MidiMeter> meters = {}; // every one, by tick
  bool mpe = false;
  int events = 0, notes = 0, points = 0;

  late int _pos, _end, _track;

  Never _fail(String what) => throw MidiFileException('track $_track: $what', _pos);

  int _byte() {
    if (_pos >= _end) _fail('it ends in the middle of an event');
    return d[_pos++];
  }

  int _vlq() {
    var v = 0;
    for (var i = 0; i < 4; i++) {
      final b = _byte();
      v = v << 7 | (b & 0x7F);
      if (b & 0x80 == 0) return v;
    }
    _fail('a variable-length number is longer than 4 bytes');
  }

  int _data() {
    final b = _byte();
    if (b & 0x80 != 0) {
      _pos--;
      _fail('a status byte 0x${b.toRadixString(16)} came where a data byte belongs');
    }
    return b;
  }

  MidiTrack track(int start, int end, int number) {
    _pos = start;
    _end = end;
    _track = number;
    final ch = List.generate(16, (_) => _Channel());
    final done = <MidiNote>[];
    final controls = <MidiControl>[];
    var name = '';
    var tick = 0;
    int? running;

    void close(_Channel c, MidiNote n) {
      n.off = math.max(tick, n.on);
      c.open.remove(n);
      done.add(n);
    }

    void addPoint(List<MidiPoint> list, MidiNote n, double before, double value) {
      if (list.isNotEmpty && list.last.tick == tick) {
        list[list.length - 1] = MidiPoint(tick, value);
        return;
      }
      if (++points > kMaxMidiCurvePoints) {
        throw const MidiFileException('the file has more than $kMaxMidiCurvePoints expression changes');
      }
      if (list.isEmpty && tick > n.on) list.add(MidiPoint(n.on, before));
      list.add(MidiPoint(tick, value));
    }

    while (_pos < _end) {
      if (++events > kMaxMidiEvents) throw const MidiFileException('the file has more than $kMaxMidiEvents events');
      tick += _vlq() * scale;
      var status = _byte();
      if (status & 0x80 == 0) {
        _pos--;
        if (running == null) _fail('a data byte came with no status before it (running status)');
        status = running;
      }
      if (status == 0xFF) {
        running = null; // meta and sysex events cancel running status
        final type = _byte(), length = _vlq();
        if (length > _end - _pos) _fail('a meta event runs past the end of the track');
        final at = _pos;
        _pos += length;
        switch (type) {
          case 0x2F:
            _pos = _end; // End of Track; anything after it is ignored
          case 0x51 when length >= 3:
            final us = d[at] << 16 | d[at + 1] << 8 | d[at + 2];
            if (us > 0) tempos.add(MidiTempo(tick, 60000000 / us));
          case 0x58 when length >= 2:
            final m = meter;
            if (d[at] > 0 && d[at + 1] <= 6 && (m == null || tick < m.$1)) meter = (tick, d[at], 1 << d[at + 1]);
            if (d[at] > 0 && d[at + 1] <= 6) meters[tick] = MidiMeter(tick, d[at], 1 << d[at + 1]);
          case 0x03 when name.isEmpty:
            name = _text(d.sublist(at, at + length));
        }
        continue;
      }
      if (status == 0xF0 || status == 0xF7) {
        running = null;
        final length = _vlq();
        if (length > _end - _pos) _fail('a system exclusive message runs past the end of the track');
        _pos += length;
        continue;
      }
      if (status >= 0xF0) _fail('status byte 0x${status.toRadixString(16)} has no place in a MIDI file');
      running = status;
      final kind = status >> 4, c = ch[status & 0x0F];
      final a = _data(), b = kind == 0xC || kind == 0xD ? 0 : _data();
      switch (kind) {
        case 0x9 when b > 0:
          if (++notes > kMaxMidiNotes) throw const MidiFileException('the file has more than $kMaxMidiNotes notes');
          final bend = c.bendSemitones;
          final n = MidiNote(channel: status & 0x0F, key: a, velocity: b, on: tick, off: tick, bend: [
            if (bend != 0) MidiPoint(tick, bend),
          ], pressure: [
            if (c.pressureTick == tick) MidiPoint(tick, c.pressure),
          ], timbre: [
            if (c.timbreTick == tick) MidiPoint(tick, c.timbre),
          ]);
          c.open.add(n);
        case 0x8 || 0x9:
          // The earliest sounding note of this key ends (first in, first out).
          final n = c.open.where((n) => n.key == a).firstOrNull;
          if (n != null) close(c, n);
        case 0xA:
          for (final n in c.open.where((n) => n.key == a)) {
            addPoint(n.pressure, n, 0, b / 127);
          }
        case 0xD:
          for (final n in c.open) {
            addPoint(n.pressure, n, c.pressure, a / 127);
          }
          c.pressure = a / 127;
          c.pressureTick = tick;
        case 0xE:
          final before = c.bendSemitones;
          c.bend = b << 7 | a;
          for (final n in c.open) {
            addPoint(n.bend, n, before, c.bendSemitones);
          }
        case 0xB when !_readerOwns(a):
          controls.add(MidiControl(tick, a, b, status & 0x0F));
        case 0xB:
          _controller(c, ch, status & 0x0F, a, b, (value) {
            for (final n in c.open) {
              addPoint(n.timbre, n, c.timbre, value);
            }
            c.timbre = value;
            c.timbreTick = tick;
          }, () {
            for (final n in List.of(c.open)) {
              close(c, n);
            }
          }, (bend) {
            final before = c.bendSemitones;
            c.bend = bend;
            for (final n in c.open) {
              if (before != c.bendSemitones) addPoint(n.bend, n, before, c.bendSemitones);
            }
          });
      }
    }
    // Notes still sounding at the end of the track end there.
    for (final c in ch) {
      for (final n in List.of(c.open)) {
        close(c, n);
      }
    }
    done.sort((x, y) => x.on != y.on ? x.on.compareTo(y.on) : x.key.compareTo(y.key));
    return MidiTrack(name: name, notes: done, endTick: tick, controls: controls);
  }

  void _controller(_Channel c, List<_Channel> all, int channel, int cc, int v, void Function(double) timbre,
      void Function() allOff, void Function(int) bend) {
    switch (cc) {
      case 74:
        timbre(v / 127);
      case 101:
        c.rpnMsb = v;
      case 100:
        c.rpnLsb = v;
      case 99 || 98: // an NRPN deselects the RPN
        c.rpnMsb = c.rpnLsb = 127;
      case 6 when c.rpnMsb == 0 && c.rpnLsb == 0:
        c.range = v.toDouble();
      case 38 when c.rpnMsb == 0 && c.rpnLsb == 0:
        c.range = c.range.floorToDouble() + math.min(v, 99) / 100;
      case 6 when c.rpnMsb == 0 && c.rpnLsb == 6 && (channel == 0 || channel == 15):
        // MPE Configuration Message: the zone's member channels get MPE's default bend range of 48 semitones.
        mpe = mpe || v > 0;
        for (var i = 1; i <= math.min(v, 15); i++) {
          all[channel == 0 ? i : 15 - i].range = 48;
        }
      case 120 || 123:
        allOff();
      case 121: // reset all controllers
        bend(8192);
        c.pressure = 0;
    }
  }
}

String _text(List<int> bytes) {
  final s = utf8.decode(bytes, allowMalformed: true).replaceAll(RegExp(r'[\x00-\x1F\x7F#]'), ' ').trim();
  return s.length > 64 ? s.substring(0, 64).trim() : s;
}

// ---------------------------------------------------------------------------------------------------------------
// Writing

/// Writes [file] as a format 1 Standard MIDI File at its [MidiFile.ppq]: a conductor track with its tempos (120 BPM
/// when there are none) and meter, then one track per [MidiFile.tracks]. Notes are clamped to the MIDI ranges.
Uint8List writeMidiFile(MidiFile file) {
  final out = BytesBuilder(copy: false);
  void u16(int v) => out.add([v >> 8 & 0xFF, v & 0xFF]);
  void u32(int v) => out.add([v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF]);
  out.add(ascii.encode('MThd'));
  u32(6);
  u16(1);
  u16(file.tracks.length + 1);
  u16(file.ppq.clamp(1, 0x7FFF));

  void chunk(List<_Event> events, String name, int? endTick) {
    // List.sort isn't stable: ties keep the order they were made in (an RPN's controllers must stay in sequence).
    final seq = {for (final (i, e) in events.indexed) e: i};
    events.sort((a, b) => a.tick != b.tick
        ? a.tick.compareTo(b.tick)
        : a.order != b.order
            ? a.order.compareTo(b.order)
            : seq[a]!.compareTo(seq[b]!));
    final body = BytesBuilder(copy: false);
    if (name.isNotEmpty) {
      final n = utf8.encode(name);
      body.add([0x00, 0xFF, 0x03, ..._vlqBytes(n.length), ...n]);
    }
    var last = 0;
    for (final e in events) {
      body.add(_vlqBytes(e.tick - last));
      body.add(e.bytes);
      last = e.tick;
    }
    body.add([..._vlqBytes(math.max(0, (endTick ?? last) - last)), 0xFF, 0x2F, 0x00]);
    out.add(ascii.encode('MTrk'));
    u32(body.length);
    out.add(body.takeBytes());
  }

  final tempos = file.tempos.isEmpty ? const [MidiTempo(0, 120)] : file.tempos;
  final num = (file.meterNumerator ?? 4).clamp(1, 255), den = file.meterDenominator ?? 4;
  final denPower = math.max(0, math.min(6, (math.log(den) / math.ln2).round()));
  final end = file.tracks.fold<int>(0, (m, t) => math.max(m, t.endTick ?? _lastTick(t)));
  int power(int den) => math.max(0, math.min(6, (math.log(den) / math.ln2).round()));
  chunk([
    if (file.meters.isEmpty) _Event(0, 0, [0xFF, 0x58, 0x04, num, denPower, 24, 8]),
    for (final m in file.meters)
      _Event(math.max(0, m.tick), 0, [0xFF, 0x58, 0x04, m.numerator.clamp(1, 255), power(m.denominator), 24, 8]),
    for (final t in tempos)
      if (t.bpm.isFinite && t.bpm > 0)
        _Event(math.max(0, t.tick), 0, [0xFF, 0x51, 0x03, ..._u24((60000000 / t.bpm).round().clamp(1, 0xFFFFFF))]),
  ], '', end);
  for (final t in file.tracks) {
    chunk([
      ...t.notes.any((n) => n.expressive) ? _mpeEvents(t.notes) : _plainEvents(t.notes),
      for (final c in t.controls)
        _Event(math.max(0, c.tick), 2, [0xB0 | c.channel & 0x0F, c.controller.clamp(0, 127), c.value.clamp(0, 127)]),
    ], t.name, t.endTick);
  }
  return out.takeBytes();
}

/// Where a track's last note or control is.
int _lastTick(MidiTrack t) => t.controls.fold(t.notes.fold(0, (e, n) => math.max(e, n.off)), (e, c) => math.max(e, c.tick));

List<int> _u24(int v) => [v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];

List<int> _vlqBytes(int v) {
  v = v.clamp(0, 0x0FFFFFFF);
  final b = <int>[v & 0x7F];
  while ((v >>= 7) > 0) {
    b.insert(0, 0x80 | (v & 0x7F));
  }
  return b;
}

/// One event; at one tick they go out by [order]: setup, note offs, controllers, note ons.
class _Event {
  _Event(this.tick, this.order, this.bytes);
  final int tick, order;
  final List<int> bytes;
}

int _key(int k) => k.clamp(0, 127);
int _vel(int v) => v.clamp(1, 127);
int _seven(double v) => (v * 127).round().clamp(0, 127);
(int, int) _off(MidiNote n) => (n.on, math.max(n.off, n.on + 1));

List<_Event> _plainEvents(List<MidiNote> notes) => [
      for (final n in notes) ...[
        _Event(n.on, 3, [0x90 | n.channel & 0x0F, _key(n.key), _vel(n.velocity)]),
        _Event(_off(n).$2, 1, [0x80 | n.channel & 0x0F, _key(n.key), 0x40]),
      ],
    ];

/// The bend ranges written, smallest first: the narrowest that holds every bend keeps the most resolution.
const List<int> _bendRanges = [2, 12, 24, 48, 96];

List<_Event> _mpeEvents(List<MidiNote> notes) {
  final widest = notes.fold<double>(0, (m, n) => n.bend.fold(m, (w, p) => math.max(w, p.value.abs())));
  final range = _bendRanges.firstWhere((r) => widest <= r, orElse: () => _bendRanges.last);
  // An RPN set on channel [c], then deselected.
  List<_Event> rpn(int c, int lsb, List<(int, int)> data) => [
        for (final (cc, v) in [(101, 0), (100, lsb), ...data, (101, 127), (100, 127)]) _Event(0, 0, [0xB0 | c, cc, v]),
      ];
  final ev = <_Event>[
    // MPE Configuration Message on the manager channel (1): RPN 6 = 15 member channels.
    ...rpn(0, 6, [(6, 15)]),
    // Each member channel's bend range (RPN 0).
    for (var c = 1; c < 16; c++) ...rpn(c, 0, [(6, range), (38, 0)]),
  ];
  int bend14(double semis) => (8192 + semis / range * 8192).round().clamp(0, 16383);
  final busy = List.filled(16, -1); // when each member channel's last note ends
  final sorted = [...notes]..sort((a, b) => a.on.compareTo(b.on));
  for (final n in sorted) {
    final (on, off) = _off(n);
    // A free channel, the one free longest (its release tail has faded most); else the one that frees soonest.
    var c = 1;
    for (var i = 2; i < 16; i++) {
      if (busy[i] < busy[c]) c = i;
    }
    busy[c] = math.max(busy[c], off);
    var lastBend = bend14(n.bend.isEmpty || n.bend.first.tick > on ? 0 : n.bend.first.value);
    ev.add(_Event(on, 2, [0xE0 | c, lastBend & 0x7F, lastBend >> 7]));
    var lastPress = -1, lastTimbre = -1;
    if (n.pressure.isNotEmpty && n.pressure.first.tick <= on) {
      lastPress = _seven(n.pressure.first.value);
      ev.add(_Event(on, 2, [0xD0 | c, lastPress]));
    }
    if (n.timbre.isNotEmpty && n.timbre.first.tick <= on) {
      lastTimbre = _seven(n.timbre.first.value);
      ev.add(_Event(on, 2, [0xB0 | c, 74, lastTimbre]));
    }
    ev.add(_Event(on, 3, [0x90 | c, _key(n.key), _vel(n.velocity)]));
    for (final p in n.bend) {
      if (p.tick <= on || p.tick >= off) continue;
      final b = bend14(p.value);
      if (b != lastBend) ev.add(_Event(p.tick, 2, [0xE0 | c, b & 0x7F, b >> 7]));
      lastBend = b;
    }
    for (final p in n.pressure) {
      if (p.tick < on || p.tick >= off || (p.tick == on && lastPress >= 0)) continue;
      final v = _seven(p.value);
      if (v != lastPress) ev.add(_Event(p.tick, 2, [0xD0 | c, v]));
      lastPress = v;
    }
    for (final p in n.timbre) {
      if (p.tick < on || p.tick >= off || (p.tick == on && lastTimbre >= 0)) continue;
      final v = _seven(p.value);
      if (v != lastTimbre) ev.add(_Event(p.tick, 2, [0xB0 | c, 74, v]));
      lastTimbre = v;
    }
    ev.add(_Event(off, 1, [0x80 | c, _key(n.key), 0x40]));
  }
  return ev;
}
