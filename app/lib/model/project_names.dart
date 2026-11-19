// Generated project names (Settings › Projects and export › New projects): two short evocative words, "Low Roost" or "Copper Wing", never one already taken.
import 'dart:math' as math;

const _first = [
  'Low', 'Copper', 'Silver', 'Late', 'Early', 'Quiet', 'Bright', 'Hollow', 'Velvet', 'Amber', 'Dusky', 'Glass',
  'Paper', 'Iron', 'Soft', 'Wild', 'Slow', 'Golden', 'Faded', 'Northern', 'Winter', 'Summer', 'Midnight', 'Rusty',
  'Lucky', 'Distant', 'Little', 'Blue', 'Second', 'Open',
];

const _second = [
  'Roost', 'Wing', 'Feather', 'Branch', 'Nest', 'Flight', 'Perch', 'Echo', 'Field', 'Rook', 'Raven', 'Signal',
  'Hollow', 'Harbour', 'Orbit', 'Lantern', 'Tide', 'Ember', 'Static', 'Garden', 'Circuit', 'Meadow', 'Pulse', 'Drift',
  'Canopy', 'Thermal', 'Crest', 'Murmur', 'Quill', 'Horizon',
];

/// How many names the lists can make.
int get projectNameCount => _first.length * _second.length;

/// A name not in [taken] (compared ignoring case), from [random]. Two words that repeat ("Hollow Hollow") are
/// skipped; when every name is taken, a number follows one ("Low Roost 2").
String generateProjectName(Iterable<String> taken, {math.Random? random}) {
  final r = random ?? math.Random();
  final used = {for (final t in taken) t.trim().toLowerCase()};
  for (var tries = 0; tries < 64; tries++) {
    final a = _first[r.nextInt(_first.length)], b = _second[r.nextInt(_second.length)];
    if (a == b) continue;
    final name = '$a $b';
    if (!used.contains(name.toLowerCase())) return name;
  }
  final base = '${_first[r.nextInt(_first.length)]} ${_second[r.nextInt(_second.length)]}';
  var n = 2;
  while (used.contains('$base $n'.toLowerCase())) {
    n++;
  }
  return '$base $n';
}
