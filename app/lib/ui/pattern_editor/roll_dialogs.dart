// The pattern editor's dialogs: the generators' settings, vibrato and tremolo with their previews, and the quantize sheet.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/pattern_doc.dart';
import '../theme.dart';
import '../widgets.dart';
import '../haptics.dart';
import '../feedback.dart';
import '../pattern_editor.dart';

/// The settings a generator asks for, as named numbers; the last values are kept for the next time.
class RollGenDialog extends StatefulWidget {
  const RollGenDialog({super.key, required this.id, required this.rate});
  final String id;

  /// The roll's grid: Tremolo's repeats come this often.
  final Steps rate;

  static final Map<String, double> _last = {};

  @override
  State<RollGenDialog> createState() => _GenDialogState();
}

class _GenDialogState extends State<RollGenDialog> {
  late final List<(String key, String label, double min, double max, double init, List<String>? names)> _fields =
      switch (widget.id) {
    'roll.gen.euclid' => [
        ('pulses', 'Hits', 1, 32, 3, null),
        ('steps', 'Steps (at the grid size)', 1, 32, 8, null),
        ('rotate', 'Rotate', 0, 31, 0, null),
      ],
    'roll.gen.random' => [
        ('density', 'Density %', 5, 100, 50, null),
        ('range', 'Range ± semitones', 1, 24, 7, null),
        ('bars', 'Bars', 1, 8, 1, null),
      ],
    'roll.gen.arpeggiate' => [('order', 'Order', 0, 2, 0, ['Up', 'Down', 'Up and down'])],
    'roll.gen.humanize' => [
        ('timing', 'Timing ± % of a step', 0, 50, 10, null),
        ('velocity', 'Velocity ± %', 0, 50, 10, null),
      ],
    'roll.gen.connect' => [('glide', 'Glide into the next note, % of each note', 0, 100, 25, null)],
    'roll.gen.tremolo' => [
        ('mode', 'As', 0, 1, 0, ['Volume', 'Repeats at ${noteLengthLabel(widget.rate)}']),
        ('wave', 'Wave', 0, 2, 0, ['Sine', 'Triangle', 'Square']),
        ('cycle', 'Speed', 0, 3, 2, [for (final c in rollTremoloCycles) 'Every ${noteLengthLabel(c)}']),
        ('depth', 'Depth %', 0, 100, 50, null),
      ],
    _ => [('seventh', 'Chord', 0, 1, 0, ['Triad', 'Seventh'])],
  };
  late final Map<String, double> _v = {
    for (final f in _fields) f.$1: (RollGenDialog._last['${widget.id}.${f.$1}'] ?? f.$5).clamp(f.$3, f.$4)
  };

  @override
  Widget build(BuildContext context) {
    final name = switch (widget.id) { 'roll.gen.connect' => 'connect notes', final id => id.replaceFirst('roll.gen.', '') };
    return AlertDialog(
      backgroundColor: Neon.panel,
      title: Text(name[0].toUpperCase() + name.substring(1)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.id == 'roll.gen.tremolo')
          // The preview follows the controls: a two-bar note's volume, or its hits' velocities.
          SizedBox(
            key: const ValueKey('tremolo-preview'),
            height: 56,
            width: double.infinity,
            child: CustomPaint(
              painter: _TremoloPreview(
                wave: TremoloWave.values[_v['wave']!.round()],
                cycle: rollTremoloCycles[_v['cycle']!.round()],
                depth: _v['depth']! / 100,
                rate: _v['mode']!.round() == 1 ? widget.rate : null,
              ),
            ),
          ),
        for (final f in _fields)
          if (f.$6 != null)
            Wrap(spacing: 6, children: [
              for (var i = 0; i < f.$6!.length; i++)
                ChoiceChip(
                  label: Text(f.$6![i]),
                  selected: _v[f.$1]!.round() == i,
                  onSelected: (_) {
                    Haptics.tick();
                    setState(() => _v[f.$1] = i.toDouble());
                  },
                ),
            ])
          else
            ValueSlider(
              label: f.$2,
              min: f.$3,
              max: f.$4,
              reset: f.$5,
              divisions: (f.$4 - f.$3).round(),
              value: _v[f.$1]!,
              onChanged: (x) => setState(() => _v[f.$1] = x.roundToDouble()),
            ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            _v.forEach((k, x) => RollGenDialog._last['${widget.id}.$k'] = x);
            Navigator.pop(context, _v);
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// The Vibrato dialog's settings: [cents] deep, one cycle every [cycle] steps (synced) or [freeHz], [fade] 0..1.
class RollVibrato {
  const RollVibrato({required this.cents, required this.cycle, required this.freeHz, required this.fade});
  final double cents, freeHz, fade;
  final Steps? cycle; // null: the free rate

  /// The rate in Hz, a synced one at [secPerStep] seconds a step (the engine takes 0.1 to 30 Hz).
  double hz(double secPerStep) {
    final c = cycle;
    return (c == null ? freeHz : 1 / (c.toDouble() * secPerStep)).clamp(0.1, 30).toDouble();
  }
}

/// Vibrato: depth in cents, a rate synced to 1/4..1/32 or free in Hz, a fade-in; the preview follows each control.
class RollVibratoDialog extends StatefulWidget {
  const RollVibratoDialog({super.key, required this.secPerStep});
  final double secPerStep;

  static RollVibrato last = RollVibrato(cents: 30, cycle: Steps.one, freeHz: 5.5, fade: 0.3);

  @override
  State<RollVibratoDialog> createState() => _VibratoDialogState();
}

class _VibratoDialogState extends State<RollVibratoDialog> {
  late double _cents = RollVibratoDialog.last.cents, _hz = RollVibratoDialog.last.freeHz, _fade = RollVibratoDialog.last.fade;
  late Steps? _cycle = RollVibratoDialog.last.cycle;

  RollVibrato get _v => RollVibrato(cents: _cents, cycle: _cycle, freeHz: _hz, fade: _fade);

  @override
  Widget build(BuildContext context) {
    final v = _v;
    return AlertDialog(
      backgroundColor: Neon.panel,
      title: const Text('Vibrato'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            key: const ValueKey('vibrato-preview'),
            height: 56,
            child: CustomPaint(
                painter: _VibratoPreview(cents: v.cents, hz: v.hz(widget.secPerStep), fade: v.fade,
                    span: 32 * widget.secPerStep)),
          ),
          const Heading('Rate'),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final c in [...rollTremoloCycles, null])
              ChoiceChip(
                label: Text(c == null ? 'Free (Hz)' : noteLengthLabel(c)),
                selected: _cycle == c,
                onSelected: (_) {
                  Haptics.tick();
                  setState(() => _cycle = c);
                },
              ),
          ]),
          if (_cycle == null)
            ValueSlider(label: 'Rate', value: _hz, min: 0.5, max: 12, reset: 5.5, decimals: 1, unit: ' Hz',
                sliderKey: const ValueKey('vibrato-hz'), onChanged: (x) => setState(() => _hz = x))
          else
            Text('${v.hz(widget.secPerStep).toStringAsFixed(2)} Hz at this tempo',
                style: TextStyle(color: Neon.dim, fontSize: 12)),
          const Heading('Shape'),
          ValueSlider(label: 'Depth', value: _cents, min: 0, max: 200, reset: 30, unit: ' cents', divisions: 200,
              sliderKey: const ValueKey('vibrato-depth'), onChanged: (x) => setState(() => _cents = x)),
          ValueSlider(label: 'Fade-in', value: _fade, min: 0, max: 1, reset: 0.3, scale: 100, unit: '%',
              sliderKey: const ValueKey('vibrato-fade'), onChanged: (x) => setState(() => _fade = x)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            Haptics.drop();
            RollVibratoDialog.last = v;
            Navigator.pop(context, v);
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// The vibrato's pitch over two bars of a note: the wave growing in over the fade-in.
class _VibratoPreview extends CustomPainter {
  _VibratoPreview({required this.cents, required this.hz, required this.fade, required this.span});
  final double cents, hz, fade, span; // span: seconds shown

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
        Paint()..color = Neon.bg.withValues(alpha: 0.6));
    final mid = size.height / 2;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = Neon.line);
    final e = NoteExpression(vibDepth: cents / 100, vibRate: hz, vibFade: fade);
    final path = Path();
    final n = math.max(128, size.width.round() * 2);
    for (var i = 0; i <= n; i++) {
      final u = i / n;
      // Full scale is 2 semitones (200 cents) each way.
      final y = mid - e.pitchAt(u, u * span) / 2 * (mid - 4);
      i == 0 ? path.moveTo(u * size.width, y) : path.lineTo(u * size.width, y);
    }
    canvas.drawPath(path, Paint()
      ..color = Neon.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_VibratoPreview o) => o.cents != cents || o.hz != hz || o.fade != fade || o.span != span;
}

/// Tremolo speeds: one cycle every 1/4, 1/8, 1/16 or 1/32 note (in steps).
final List<Steps> rollTremoloCycles = [Steps(4), Steps(2), Steps.one, Steps(1, 2)];

/// The tremolo generator's preview: the wave's level over two bars of a note, as a line (volume) or as bars (repeats
/// every [rate]).
class _TremoloPreview extends CustomPainter {
  _TremoloPreview({required this.wave, required this.cycle, required this.depth, this.rate});
  final TremoloWave wave;
  final Steps cycle;
  final double depth;
  final Steps? rate;

  static const _span = 32.0; // two bars of 4/4, in steps

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = Neon.bg.withValues(alpha: 0.6);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)), bg);
    final c = cycle.toDouble();
    double y(double level) => size.height - 4 - level * (size.height - 8);
    final r = rate;
    if (r != null) {
      final step = r.toDouble();
      final w = size.width * step / _span;
      final bar = Paint()..color = Neon.green;
      for (var t = 0.0; t < _span - 1e-9; t += step) {
        final level = PatternDoc.tremoloLevel(wave, t / c, depth);
        final x = t / _span * size.width;
        canvas.drawRect(Rect.fromLTRB(x + w * 0.15, y(level), x + w * 0.85, size.height - 4), bar);
      }
      return;
    }
    final path = Path();
    final n = math.max(64, size.width.round());
    for (var i = 0; i <= n; i++) {
      final t = i / n * _span;
      final p = Offset(i / n * size.width, y(PatternDoc.tremoloLevel(wave, t / c, depth)));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, Paint()
      ..color = Neon.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_TremoloPreview o) => o.wave != wave || o.cycle != cycle || o.depth != depth || o.rate != rate;
}

/// The quantize sheet's settings.
class RollQuantize {
  const RollQuantize(this.grid, this.what, this.strength, this.swing, this.timing, this.velocity);
  final Steps grid;
  final QuantizeWhat what;
  final double strength, swing, timing, velocity; // 0..1; timing in steps
}

/// Quantize (REAPER's Quantize events, UG 13.23): the grid (the roll's by default), what moves, strength, swing and
/// humanize, each previewed on the roll as it moves; Bypass shows the notes as they were. The last applied settings
/// (all but the grid) stay for next time.
class RollQuantizeSheet extends StatefulWidget {
  const RollQuantizeSheet({super.key, required this.res, required this.triplet, required this.count, required this.onPreview});
  final int res, count;
  final bool triplet;
  final ValueChanged<RollQuantize?> onPreview;

  static ({QuantizeWhat what, double strength, double swing, double timing, double velocity})? _last;

  @override
  State<RollQuantizeSheet> createState() => _QuantizeSheetState();
}

class _QuantizeSheetState extends State<RollQuantizeSheet> {
  late int _res = widget.res;
  late bool _triplet = widget.triplet;
  QuantizeWhat _what = RollQuantizeSheet._last?.what ?? QuantizeWhat.starts;
  double _strength = RollQuantizeSheet._last?.strength ?? 100, _swing = RollQuantizeSheet._last?.swing ?? 0;
  double _timing = RollQuantizeSheet._last?.timing ?? 0, _velocity = RollQuantizeSheet._last?.velocity ?? 0;
  bool _bypass = false;

  RollQuantize get _q => RollQuantize(_triplet ? Steps(32, _res * 3) : Steps(16, _res), _what, _strength / 100, _swing / 100,
      _timing / 100, _velocity / 100);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  void _changed() => widget.onPreview(_bypass ? null : _q);

  void _set(VoidCallback f) {
    setState(f);
    _changed();
  }

  Widget _chips<T>(List<(T, String)> items, T value, ValueChanged<T> on) => Wrap(spacing: 6, runSpacing: 2, children: [
        for (final (v, label) in items)
          ChoiceChip(
            label: Text(label),
            selected: v == value,
            onSelected: (_) {
              Haptics.tick();
              _set(() => on(v));
            },
          ),
      ]);

  Widget _slider(String key, String label, double value, double max, ValueChanged<double> on, {double reset = 0}) =>
      ValueSlider(
        sliderKey: ValueKey('quantize-$key'),
        label: label,
        unit: '%',
        min: 0,
        max: max,
        reset: reset,
        divisions: max.round(),
        value: value,
        onChanged: (x) {
          if (x.roundToDouble() != value) Haptics.tick();
          _set(() => on(x.roundToDouble()));
        },
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Neon.panel,
      title: Text('Quantize ${widget.count == 1 ? '1 note' : '${widget.count} notes'}'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Grid'),
          const SizedBox(height: 4),
          _chips([for (final r in const [4, 8, 16, 32]) (r, '1/$r')], _res, (v) => _res = v),
          Row(children: [
            Expanded(child: Text('Triplets', style: TextStyle(color: _triplet ? Neon.text : Neon.dim))),
            Switch(value: _triplet, onChanged: (v) => _set(() => _triplet = v)),
          ]),
          const Text('Move'),
          const SizedBox(height: 4),
          _chips([(QuantizeWhat.starts, 'Starts'), (QuantizeWhat.ends, 'Ends'), (QuantizeWhat.both, 'Both')], _what,
              (v) => _what = v),
          const SizedBox(height: 8),
          _slider('strength', 'Strength', _strength, 100, (v) => _strength = v, reset: 100),
          _slider('swing', 'Swing', _swing, 100, (v) => _swing = v),
          _slider('timing', 'Humanize timing ± % of a step', _timing, 50, (v) => _timing = v),
          _slider('velocity', 'Humanize velocity ± %', _velocity, 50, (v) => _velocity = v),
          Row(children: [
            const Expanded(child: Text('Bypass (hear the notes as they were)')),
            Switch(key: const ValueKey('quantize-bypass'), value: _bypass, onChanged: (v) => _set(() => _bypass = v)),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        Pressable(
          child: FilledButton(
            onPressed: () {
              Haptics.drop();
              RollQuantizeSheet._last = (
                what: _what,
                strength: _strength,
                swing: _swing,
                timing: _timing,
                velocity: _velocity,
              );
              Navigator.pop(context, _q);
            },
            child: const Text('Apply'),
          ),
        ),
      ],
    );
  }
}
