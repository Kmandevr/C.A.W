// The on-screen keys and pads (owner, 2026-11-10: "Piano keys + pads toggle"): a slide-up glass panel over the
// transport with a piano of scrollable octaves or a 4x4 pad grid (General MIDI drums on drum tracks, the project's
// scale otherwise). Velocity comes from where the key is touched; notes go through LiveMidi, as a USB keyboard's.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/live_midi.dart';
import '../../model/project.dart';
import '../arrange/track_color.dart';
import '../haptics.dart';
import '../theme.dart';
import 'frame_widgets.dart' show SlideIn;

/// MIDI note names ("C3" is 48, as in the pattern text).
String noteName(int n) => '${const ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'][n % 12]}${n ~/ 12 - 1}';

/// The pads on a drum track, bottom row first (left to right): General MIDI percussion notes, MPC-style.
const drumPads = [
  (36, 'Kick'), (38, 'Snare'), (42, 'Hat'), (46, 'Open'),
  (37, 'Rim'), (39, 'Clap'), (44, 'Pedal'), (49, 'Crash'),
  (41, 'Tom 1'), (45, 'Tom 2'), (48, 'Tom 3'), (51, 'Ride'),
  (54, 'Tamb'), (56, 'Cowbell'), (57, 'Crash 2'), (53, 'Bell'),
];

/// Whether [layer] plays drums: a drum instrument, or a drum-like name.
bool isDrumTrack(LayerDoc? layer) {
  if (layer == null) return false;
  final id = layer.instrument?.id ?? '';
  return id.contains('drum') || RegExp(r'drum|kick|snare|hat|perc|beat', caseSensitive: false).hasMatch(layer.name);
}

/// The 16 pad notes on a melodic track: the project's key (C major without one) up from [octave]'s root.
List<int> scalePads(ProjectDoc p, int octave) {
  final (root, scale) = p.keyNumbers ?? (0, 0);
  final steps = scale == 1 ? const [0, 2, 3, 5, 7, 8, 10] : const [0, 2, 4, 5, 7, 9, 11];
  return [for (var i = 0; i < 16; i++) 12 * (octave + 1) + root + 12 * (i ~/ 7) + steps[i % 7]];
}

/// Velocity from where a key is touched: soft at the top, full at the bottom (where a finger presses hardest); a
/// [fixed] velocity (Settings › MIDI and input, above 0) instead.
double velocityAt(double y, double height, {double fixed = 0}) => fixed > 0
    ? fixed.clamp(0.05, 1.0).toDouble()
    : height <= 0 ? 0.8 : (0.3 + 0.7 * (y / height)).clamp(0.3, 1.0);

class LiveKeysPanel extends StatefulWidget {
  const LiveKeysPanel({super.key, required this.midi, required this.state, this.compact = false});
  final LiveMidi midi;
  final AppState state;

  /// Phone landscape: a shorter panel.
  final bool compact;

  @override
  State<LiveKeysPanel> createState() => _LiveKeysPanelState();
}

class _LiveKeysPanelState extends State<LiveKeysPanel> {
  bool _pads = false;
  bool? _padsChosen; // the user's switch; else pads open by themselves on a drum track

  /// The leftmost white key (C1 is 0), and the pads' octave: both open on Settings' octave (C3 by default).
  late double _offset = 7.0 * (widget.state.settings.keysOctave - 1).clamp(0, 6);
  late int _padOctave = widget.state.settings.keysOctave;

  LiveMidi get m => widget.midi;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([m, widget.state]),
        builder: (context, _) {
          if (!m.keysOpen) return const SizedBox.shrink();
          final layer = widget.state.project.layers.where((l) => l.id == m.targetLayerId).firstOrNull;
          final drums = isDrumTrack(layer);
          _pads = _padsChosen ?? drums;
          final height = widget.compact ? 92.0 : 132.0;
          return SlideIn(
            from: const Offset(0, 0.3),
            child: Container(
              key: const ValueKey('live-keys'),
              decoration: BoxDecoration(
                color: Neon.panel.withValues(alpha: 0.82),
                border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
              ),
              padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _header(layer, drums),
                SizedBox(
                  height: height,
                  child: _pads
                      ? _PadGrid(
                          key: const ValueKey('live-pads'),
                          pads: drums
                              ? [for (final p in drumPads) (p.$1, p.$2)]
                              : [for (final n in scalePads(widget.state.project, _padOctave)) (n, noteName(n))],
                          color: layer == null ? Neon.blue : trackColor(widget.state, layer),
                          midi: m)
                      : _Keyboard(key: const ValueKey('live-piano'), offset: _offset, midi: m),
                ),
              ]),
            ),
          );
        },
      );

  Widget _header(LayerDoc? layer, bool drums) {
    final rec = m.recording;
    final count = m.countInLeft;
    Widget chip(String label, bool on, VoidCallback tap, Key key) => InkWell(
          key: key,
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            Haptics.tap();
            tap();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: on ? Neon.blue.withValues(alpha: 0.18) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: on ? Neon.blue : Neon.line),
            ),
            child: Text(label, style: TextStyle(fontSize: 11, color: on ? Neon.blue : Neon.dim, fontWeight: FontWeight.w700)),
          ),
        );
    final octave = _pads ? _padOctave : (_offset / 7).floor() + 1;
    return SizedBox(
      height: 30,
      child: Row(children: [
        chip('Keys', !_pads, () => setState(() => _padsChosen = false), const ValueKey('live-keys-piano')),
        const SizedBox(width: 4),
        chip('Pads', _pads, () => setState(() => _padsChosen = true), const ValueKey('live-keys-pads')),
        const SizedBox(width: 6),
        if (layer != null) ...[
          Container(width: 8, height: 8, decoration: BoxDecoration(color: trackColor(widget.state, layer), shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Flexible(child: Text(layer.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Neon.text))),
        ],
        if (rec) ...[
          const SizedBox(width: 6),
          Text(count > 0 ? 'COUNT $count' : 'REC', key: const ValueKey('live-keys-rec'),
              style: Neon.code(size: 10, color: Neon.pink)),
        ],
        const Spacer(),
        if (!(_pads && drums)) ...[
          _arrow(Icons.chevron_left, 'Octave down', () => setState(() {
                if (_pads) {
                  _padOctave = (_padOctave - 1).clamp(0, 7);
                } else {
                  _offset = (_offset - 7).clamp(0, _Keyboard.whites - 7);
                }
              })),
          SizedBox(width: 26, child: Center(child: Text('C$octave', style: Neon.code(size: 11, color: Neon.dim)))),
          _arrow(Icons.chevron_right, 'Octave up', () => setState(() {
                if (_pads) {
                  _padOctave = (_padOctave + 1).clamp(0, 7);
                } else {
                  _offset = (_offset + 7).clamp(0, _Keyboard.whites - 7);
                }
              })),
        ],
        if (!_pads)
          // The octave strip: the whole range in miniature; drag it to scroll the keys.
          _OctaveStrip(offset: _offset, onScroll: (v) => setState(() => _offset = v)),
        _arrow(Icons.close, 'Hide the keys', () => m.keysOpen = false),
      ]),
    );
  }

  Widget _arrow(IconData icon, String tip, VoidCallback onTap) => IconButton(
        tooltip: tip,
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        padding: EdgeInsets.zero,
        color: Neon.dim,
        icon: Icon(icon),
        onPressed: onTap,
      );
}

/// The whole keyboard's range in miniature with the visible part lit; a drag scrolls the keys.
class _OctaveStrip extends StatelessWidget {
  const _OctaveStrip({required this.offset, required this.onScroll});
  final double offset;
  final ValueChanged<double> onScroll;

  static const width = 44.0;

  @override
  Widget build(BuildContext context) => GestureDetector(
        key: const ValueKey('live-keys-strip'),
        onHorizontalDragUpdate: (d) =>
            onScroll((offset + d.delta.dx / width * _Keyboard.whites).clamp(0.0, _Keyboard.whites - 7.0)),
        child: Container(
          width: width,
          height: 14,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(border: Border.all(color: Neon.line), borderRadius: BorderRadius.circular(3)),
          child: Stack(children: [
            Positioned(
              left: offset / _Keyboard.whites * width,
              width: 14 / _Keyboard.whites * width, // about the keys a phone shows
              top: 0,
              bottom: 0,
              child: Container(color: Neon.blue.withValues(alpha: 0.4)),
            ),
          ]),
        ),
      );
}

/// Multi-touch keys: each finger plays the key under it, sliding plays the next (a glissando), and how far down
/// the key it lands sets the velocity.
mixin _Fingers<T extends StatefulWidget> on State<T> {
  final Map<int, int> _fingers = {}; // pointer -> note
  LiveMidi get midi;

  int? noteAt(Offset p, Size size);

  void _down(PointerEvent e, Size size) {
    final n = noteAt(e.localPosition, size);
    if (n == null) return;
    _fingers[e.pointer] = n;
    midi.keyDown(n, velocityAt(e.localPosition.dy, size.height, fixed: midi.state.settings.keysVelocity));
    setState(() {});
  }

  void _move(PointerEvent e, Size size) {
    final was = _fingers[e.pointer];
    if (was == null) return;
    final n = noteAt(e.localPosition, size);
    if (n == null || n == was) return;
    midi.keyUp(was);
    _fingers[e.pointer] = n;
    midi.keyDown(n, velocityAt(e.localPosition.dy, size.height, fixed: midi.state.settings.keysVelocity));
    setState(() {});
  }

  void _up(PointerEvent e) {
    final n = _fingers.remove(e.pointer);
    if (n == null) return;
    if (!_fingers.containsValue(n)) midi.keyUp(n);
    setState(() {});
  }

  @override
  void dispose() {
    for (final n in _fingers.values.toSet()) {
      midi.keyUp(n);
    }
    super.dispose();
  }

  Widget fingers(Widget Function(Size size, Set<int> down) child) => LayoutBuilder(builder: (context, box) {
        final size = box.biggest;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => _down(e, size),
          onPointerMove: (e) => _move(e, size),
          onPointerUp: _up,
          onPointerCancel: _up,
          child: child(size, _fingers.values.toSet()),
        );
      });
}

class _Keyboard extends StatefulWidget {
  const _Keyboard({super.key, required this.offset, required this.midi});
  final double offset;
  final LiveMidi midi;

  /// C1 (24) to C8 (108): 50 white keys.
  static const lowest = 24, whites = 50;
  static const keyWidth = 30.0;
  static const _white = [0, 2, 4, 5, 7, 9, 11];

  static int whiteNote(int i) => lowest + 12 * (i ~/ 7) + _white[i % 7];

  /// White keys followed by a black one (C, D, F, G, A).
  static bool hasBlack(int i) => const {0, 1, 3, 4, 5}.contains(i % 7);

  @override
  State<_Keyboard> createState() => _KeyboardState();
}

class _KeyboardState extends State<_Keyboard> with _Fingers {
  @override
  LiveMidi get midi => widget.midi;

  @override
  int? noteAt(Offset p, Size size) {
    const w = _Keyboard.keyWidth;
    final x = p.dx / w + widget.offset;
    final i = x.floor();
    if (i < 0 || i >= _Keyboard.whites) return null;
    if (p.dy < size.height * 0.6) {
      // The black keys: 0.6 of a white key wide, over the line between two whites.
      final frac = x - i;
      if (frac > 0.7 && _Keyboard.hasBlack(i) && i + 1 < _Keyboard.whites) return _Keyboard.whiteNote(i) + 1;
      if (frac < 0.3 && i > 0 && _Keyboard.hasBlack(i - 1)) return _Keyboard.whiteNote(i - 1) + 1;
    }
    return _Keyboard.whiteNote(i);
  }

  @override
  Widget build(BuildContext context) =>
      fingers((size, down) => CustomPaint(size: size, painter: _KeysPainter(widget.offset, down)));
}

class _KeysPainter extends CustomPainter {
  _KeysPainter(this.offset, this.down);
  final double offset;
  final Set<int> down;

  @override
  void paint(Canvas canvas, Size size) {
    const w = _Keyboard.keyWidth;
    final first = offset.floor(), last = (offset + size.width / w).ceil();
    final r = Radius.circular(4);
    for (var i = first; i <= last && i < _Keyboard.whites; i++) {
      final x = (i - offset) * w;
      final note = _Keyboard.whiteNote(i);
      final rect = RRect.fromRectAndCorners(Rect.fromLTWH(x + 1, 0, w - 2, size.height), bottomLeft: r, bottomRight: r);
      canvas.drawRRect(rect, Paint()..color = down.contains(note) ? Neon.blue : Neon.text.withValues(alpha: 0.86));
      if (note % 12 == 0) {
        final tp = TextPainter(
            text: TextSpan(text: noteName(note), style: TextStyle(fontSize: 9, color: Neon.bg.withValues(alpha: 0.7))),
            textDirection: TextDirection.ltr)
          ..layout();
        tp.paint(canvas, Offset(x + (w - tp.width) / 2, size.height - tp.height - 3));
      }
    }
    for (var i = first - 1; i <= last && i < _Keyboard.whites - 1; i++) {
      if (i < 0 || !_Keyboard.hasBlack(i)) continue;
      final x = (i + 1 - offset) * w - w * 0.3;
      final note = _Keyboard.whiteNote(i) + 1;
      final rect = RRect.fromRectAndCorners(Rect.fromLTWH(x, 0, w * 0.6, size.height * 0.6), bottomLeft: r, bottomRight: r);
      canvas.drawRRect(rect, Paint()..color = down.contains(note) ? Neon.blue : Neon.bg);
    }
  }

  @override
  bool shouldRepaint(_KeysPainter old) => old.offset != offset || old.down.length != down.length || !old.down.containsAll(down);
}

class _PadGrid extends StatefulWidget {
  const _PadGrid({super.key, required this.pads, required this.color, required this.midi});
  final List<(int, String)> pads; // bottom row first
  final Color color;
  final LiveMidi midi;

  @override
  State<_PadGrid> createState() => _PadGridState();
}

class _PadGridState extends State<_PadGrid> with _Fingers {
  @override
  LiveMidi get midi => widget.midi;

  int? _index(Offset p, Size size) {
    final col = (p.dx / size.width * 4).floor(), row = 3 - (p.dy / size.height * 4).floor();
    if (col < 0 || col > 3 || row < 0 || row > 3) return null;
    return row * 4 + col;
  }

  @override
  int? noteAt(Offset p, Size size) {
    final i = _index(p, size);
    return i == null || i >= widget.pads.length ? null : widget.pads[i].$1;
  }

  /// A pad's own velocity: where in the pad it is struck (its lower part is louder).
  @override
  void _down(PointerEvent e, Size size) {
    final n = noteAt(e.localPosition, size);
    if (n == null) return;
    final cellH = size.height / 4;
    _fingers[e.pointer] = n;
    midi.keyDown(n, velocityAt(e.localPosition.dy % cellH, cellH, fixed: midi.state.settings.keysVelocity));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => fingers((size, down) => Column(children: [
        for (var row = 3; row >= 0; row--)
          Expanded(
            child: Row(children: [
              for (var col = 0; col < 4; col++)
                Expanded(child: _pad(widget.pads[row * 4 + col], down.contains(widget.pads[row * 4 + col].$1))),
            ]),
          ),
      ]));

  Widget _pad((int, String) pad, bool on) => Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: on ? 0.7 : 0.16),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: widget.color.withValues(alpha: on ? 1 : 0.4)),
        ),
        child: Center(
          child: Text(pad.$2, maxLines: 1, overflow: TextOverflow.clip,
              style: TextStyle(fontSize: 10, color: on ? Neon.bg : Neon.text, fontWeight: FontWeight.w600)),
        ),
      );
}
