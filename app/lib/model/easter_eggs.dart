// The app's few hidden surprises as plain rules (their triggers and the clock they read), and the events the UI shows; harmless by design.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// What a surprise asks the UI to show.
enum EggKind { hatch, timeFlies, parrotFlash, parrotUnlocked, caw }

/// One surprise, numbered so the same kind twice is still a change.
@immutable
class EggEvent {
  const EggEvent(this.kind, this.seq);
  final EggKind kind;
  final int seq;
}

/// The crow's dress on the startup screen for a date.
enum CrowSeason { none, scarf, partyHat, pumpkin }

/// The day of C.A.W's first release (1.0.0-alpha.1, CHANGELOG.md): the crow's birthday.
const birthdayMonth = 11, birthdayDay = 13;

/// Between 2 and 5 am the crow in empty states sleeps.
bool crowSleepsAt(DateTime t) => t.hour >= 2 && t.hour < 5;

/// December: a scarf; the birthday: a party hat; 31 October: a pumpkin.
CrowSeason crowSeasonOn(DateTime t) {
  if (t.month == birthdayMonth && t.day == birthdayDay) return CrowSeason.partyHat;
  if (t.month == 10 && t.day == 31) return CrowSeason.pumpkin;
  if (t.month == 12) return CrowSeason.scarf;
  return CrowSeason.none;
}

/// How rarely the startup crow blinks: one launch in [startupBlinkOdds].
const startupBlinkOdds = 40;
bool startupBlinks(math.Random r) => r.nextInt(startupBlinkOdds) == 0;

/// A tempo the transport reads as "leet" for a moment.
bool isLeetTempo(double bpm) => (bpm - 133.7).abs() < 0.005;

/// An export of 4:33 (to the half second) that is silent throughout.
bool isCageSilence({required double seconds, required double peakDb}) =>
    (seconds - 273).abs() <= 0.5 && peakDb <= -90;

/// A project named after a group of crows.
bool isMurderName(String name) => name.trim().toLowerCase() == 'murder';

bool isAprilFirst(DateTime t) => t.month == 4 && t.day == 1;

/// How many taps on the version unlock the hidden theme, and how long a pause starts the count again.
const versionTapsToUnlock = 7;
const versionTapGap = Duration(seconds: 2);

/// Undos in a row that make the app remark on it.
const undoStreakRemark = 50;

/// B-A-D-E-G-G as pitch classes.
const _badEgg = [11, 9, 2, 4, 7, 7];

/// The surprises' state: what was played, tapped and undone lately, and the events for the UI.
class EasterEggs {
  EasterEggs({DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  /// The app's one instance.
  static EasterEggs instance = EasterEggs();

  DateTime Function() clock;

  /// The latest surprise to show, or null before the first.
  final events = ValueNotifier<EggEvent?>(null);
  int _seq = 0;

  void _fire(EggKind k) => events.value = EggEvent(k, ++_seq);

  // ---- notes: B-A-D-E-G-G on any keyboard, the Konami code on the on-screen keys ----

  final List<int> _notes = [], _screenNotes = [];

  /// A note played on a keyboard ([onScreen]: the on-screen keys or pads).
  void notePlayed(int note, {bool onScreen = false}) {
    _notes.add(note);
    if (_notes.length > _badEgg.length) _notes.removeAt(0);
    if (_notes.length == _badEgg.length && [for (var i = 0; i < _notes.length; i++) _notes[i] % 12 == _badEgg[i]].every((x) => x)) {
      _notes.clear();
      _fire(EggKind.hatch);
    }
    if (!onScreen) return;
    _screenNotes.add(note);
    if (_screenNotes.length > 11) _screenNotes.removeAt(0);
    if (isKonami(_screenNotes)) {
      _screenNotes.clear();
      _fire(EggKind.parrotFlash);
    }
  }

  /// Up, up, down, down, left, right, left, right, B, A on a keyboard: eleven notes whose first nine move up, up,
  /// down, down, down (left), up (right), down, up, then a B and an A.
  static bool isKonami(List<int> n) {
    if (n.length != 11) return false;
    const moves = [1, 1, -1, -1, -1, 1, -1, 1];
    for (var i = 0; i < moves.length; i++) {
      final d = n[i + 1] - n[i];
      if (d == 0 || d.sign != moves[i]) return false;
    }
    return n[9] % 12 == 11 && n[10] % 12 == 9;
  }

  // ---- the version in About ----

  int _taps = 0;
  DateTime? _lastTap;

  /// A tap on the version; true when it unlocks the hidden theme (the seventh tap in a row).
  bool versionTapped() {
    final now = clock();
    final last = _lastTap;
    _taps = last != null && now.difference(last) <= versionTapGap ? _taps + 1 : 1;
    _lastTap = now;
    if (_taps < versionTapsToUnlock) return false;
    _taps = 0;
    _fire(EggKind.parrotUnlocked);
    return true;
  }

  // ---- undo ----

  int _undos = 0;

  /// One undo went through; at [undoStreakRemark] in a row the app remarks on it (once per streak).
  void undone() {
    if (++_undos == undoStreakRemark) _fire(EggKind.timeFlies);
  }

  /// Anything else that ends a streak of undos (an edit, a redo, another project).
  void streakBroken() => _undos = 0;

  // ---- sound ----

  bool _cawedToday = false;
  DateTime? _cawDay;

  /// The long-pressed crow in About.
  void caw() => _fire(EggKind.caw);

  /// A count-in started: on 1 April the first one of the day caws.
  void countInStarted() {
    final now = clock();
    if (!isAprilFirst(now)) return;
    final day = DateTime(now.year, now.month, now.day);
    if (_cawDay != day) {
      _cawDay = day;
      _cawedToday = false;
    }
    if (_cawedToday) return;
    _cawedToday = true;
    _fire(EggKind.caw);
  }
}

/// A short caw made from scratch (no recording): two raspy, falling, nasal bursts as 16-bit mono WAV bytes.
Uint8List synthCawWav({int sampleRate = 44100}) {
  final length = (sampleRate * 0.42).round();
  final samples = Int16List(length);
  final r = math.Random(7);
  var phase = 0.0;
  for (var i = 0; i < length; i++) {
    final t = i / sampleRate;
    // Two calls: 0 to 0.17 s and 0.22 to 0.42 s, each a quick attack and a falling pitch.
    final local = t < 0.2 ? t : t - 0.22;
    final on = t < 0.17 || (t >= 0.22);
    if (!on || local < 0) continue;
    final dur = t < 0.2 ? 0.17 : 0.2;
    final env = math.min(1.0, local / 0.012) * math.pow(1 - (local / dur).clamp(0.0, 1.0), 1.4);
    final f = 620 - 260 * (local / dur);
    phase += 2 * math.pi * f / sampleRate;
    // A pulse-like tone (odd harmonics) roughened by noise and a fast flutter: a crow's rasp.
    var s = 0.0;
    for (var h = 1; h <= 9; h += 2) {
      s += math.sin(phase * h) / h;
    }
    s *= 0.8 + 0.2 * math.sin(2 * math.pi * 70 * t);
    s += (r.nextDouble() * 2 - 1) * 0.35;
    samples[i] = (s * env * 0.45 * 32767).clamp(-32767, 32767).round();
  }
  final data = samples.buffer.asUint8List();
  final b = BytesBuilder();
  void u32(int v) => b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  void u16(int v) => b.add([v & 255, (v >> 8) & 255]);
  b.add('RIFF'.codeUnits);
  u32(36 + data.length);
  b.add('WAVEfmt '.codeUnits);
  u32(16);
  u16(1);
  u16(1);
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  b.add('data'.codeUnits);
  u32(data.length);
  b.add(data);
  return b.toBytes();
}
