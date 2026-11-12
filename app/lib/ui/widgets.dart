// Shared neon widgets: panels, the oscilloscope, level and progress meters, and small toggle buttons.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kDoubleTapTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../engine/engine.dart';
import '../model/app_state.dart';
import '../model/project.dart' show LayerDoc;
import 'motion.dart';
import 'theme.dart';
import 'glass.dart';
import 'haptics.dart';
import 'pointer_input.dart' show ClickCounter;
import 'panel_motion.dart';

class NeonPanel extends StatelessWidget {
  const NeonPanel({super.key, required this.child, this.color, this.padding = const EdgeInsets.all(12)});
  final Widget child;
  final Color? color;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          // No glow under a see-through card: it would show through and make the card look solid.
          boxShadow: color == null || Glass.active ? null : Neon.glow(color!, strength: 0.25),
        ),
        // A Material surface (not a coloured box) so list tiles and ink splashes inside draw correctly.
        // Glass: see-through, faintly tinted with the card's colour, with a solid outline.
        child: Material(
          color: Glass.active
              ? Color.lerp(Neon.panel, color ?? Neon.panel, 0.06)!.withValues(alpha: 0.55)
              : Neon.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
                color: Glass.active ? (color ?? Colors.white.withValues(alpha: 0.12)) : (color?.withValues(alpha: 0.7) ?? Neon.line)),
          ),
          child: Padding(padding: padding, child: child),
        ),
      );
}

/// Draws the latest samples of one engine output (a layer, the audition or the master).
class ScopeView extends StatefulWidget {
  const ScopeView({super.key, required this.state, required this.index, this.color = Neon.green, this.height = 96});
  final AppState state;
  final int index;
  final Color color;
  final double height;

  @override
  State<ScopeView> createState() => _ScopeViewState();
}

class _ScopeViewState extends State<ScopeView> {
  final Float32List _buf = Float32List(512);
  int _read = 0, _shown = -1; // the reads into [_buf] so far, and the tick last read

  @override
  void didUpdateWidget(ScopeView old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index || !identical(old.state, widget.state)) _shown = -1;
  }

  // A live island (beta plan B4.6): its 30 reads a second repaint only the scope, and a frame with no new read (a
  // rebuild from above) neither reads nor redraws it.
  @override
  Widget build(BuildContext context) => SizedBox(
        height: widget.height,
        child: LiveIsland(child: ValueListenableBuilder<int>(
          valueListenable: widget.state.tick,
          builder: (context, tick, _) {
            if (tick != _shown) {
              _shown = tick;
              widget.state.engine?.scope(widget.index, _buf);
              _read++;
            }
            return CustomPaint(painter: _ScopePainter(_buf, _read, widget.color, glow: Neon.performanceMode < 2),
                size: Size.infinite);
          },
        )),
      );
}

class _ScopePainter extends CustomPainter {
  _ScopePainter(this.samples, this.read, this.color, {required this.glow});
  final Float32List samples;

  /// Which read of [samples] this draws (the buffer is reused, so its contents can't be compared).
  final int read;
  final Color color;

  /// The blurred glow under the line: Full and Balanced only (Lightweight and Minimal draw the line alone).
  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = Neon.line);
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = i * size.width / (samples.length - 1);
      final y = mid - samples[i].clamp(-1.0, 1.0) * (mid - 2);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    if (glow) {
      canvas.drawPath(
          path,
          Paint()
            ..color = color.withValues(alpha: 0.35)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4);
  }

  @override
  bool shouldRepaint(covariant _ScopePainter old) =>
      old.read != read || !identical(old.samples, samples) || old.color != color || old.glow != glow;
}

/// A horizontal bar for a 0..1 value, drawn in neon. With glass on: a faint fill and a solid outline, for the
/// track and the value alike, a little taller so the outline reads.
class Bar extends StatelessWidget {
  const Bar({super.key, required this.value, required this.color, this.height = 4, this.glassMinHeight = 7});
  final double value;
  final Color color;
  final double height;

  /// The glass look draws the bar at least this tall (a stereo meter's two bars are thinner).
  final double glassMinHeight;

  @override
  Widget build(BuildContext context) => Glass.active ? _glass() : _plain();

  Widget _glass() {
    final h = height < glassMinHeight ? glassMinHeight : height;
    final r = BorderRadius.circular(h);
    return LayoutBuilder(
      builder: (context, c) => Container(
        height: h,
        decoration: BoxDecoration(
          color: Neon.line.withValues(alpha: 0.18),
          borderRadius: r,
          border: Border.all(color: Neon.line, width: 0.8),
        ),
        alignment: Alignment.centerLeft,
        child: Container(
          width: c.maxWidth * value.clamp(0.0, 1.0),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.35),
            borderRadius: r,
            border: value > 0 ? Border.all(color: color, width: 0.9) : null,
          ),
        ),
      ),
    );
  }

  Widget _plain() => LayoutBuilder(
        builder: (context, c) => Container(
          height: height,
          decoration: BoxDecoration(color: Neon.line, borderRadius: BorderRadius.circular(height)),
          alignment: Alignment.centerLeft,
          child: Container(
            width: c.maxWidth * value.clamp(0.0, 1.0),
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(height), boxShadow: Neon.glow(color, strength: 0.6)),
          ),
        ),
      );
}

/// A track's meter in the mixer, the arrangement or a track card: a stereo [PeakMeter] (left and right, from
/// `caw_engine_layer_meter_stereo`) for a stereo track ([LayerDoc.isStereo]: a native instrument or effect, or a
/// folder), and one bar for a mono .caw track, whose two sides differ only by its pan.
class TrackMeter extends StatelessWidget {
  const TrackMeter(
      {super.key, required this.state, required this.index, required this.stereo, required this.color, this.vertical = false});
  final AppState state;
  final int index; // the track's project index, as AppState.layerMeters lists it
  final bool stereo;
  final Color color;
  final bool vertical;

  LayerMeterValue? get _meter => index < state.audibleLayerMeters.length ? state.audibleLayerMeters[index] : null;

  /// A sideways meter's height: two 5 dp bars and a gap, or one bar (drawn at least 7 dp tall with glass).
  double get _sidewaysHeight => stereo ? 11 : Glass.active ? 7 : 4;

  @override
  Widget build(BuildContext context) {
    final meter = stereo
        ? PeakMeter(state: state, color: color, vertical: vertical,
            read: () => _meter?.peakL ?? 0.0, readRight: () => _meter?.peakR ?? 0.0)
        : PeakMeter(state: state, color: color, vertical: vertical, read: () => _meter?.peak ?? 0.0);
    // Sideways (a track header) it is a live island of a fixed size, so its 30 reads a second don't lay out and
    // repaint the list of tracks around it.
    return vertical ? meter : SizedBox(width: double.infinity, height: _sidewaysHeight, child: LiveIsland(child: meter));
  }
}

/// Something that changes about 30 times a second (a meter, the playhead, a readout), kept to itself: it rebuilds,
/// lays out and repaints alone. Give it a fixed size (tight constraints), which makes it a layout boundary; its own
/// LayoutBuilder is the build scope its updates run in, so they don't make a LayoutBuilder higher up lay out the
/// screen again (each LayoutBuilder is a build scope: a rebuild under it lays it out anew).
class LiveIsland extends StatelessWidget {
  const LiveIsland({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => RepaintBoundary(child: LayoutBuilder(builder: (_, _) => child));
}

/// A peak meter for one layer, folder or the master, on a dB scale, REAPER-like: the bar rises quickly to each
/// sample peak (over [attackSeconds], eased, never past it) and falls at [fallDbPerSecond] (the Meter fall
/// setting), but never below what the reads say: after a lower read it follows a line from the earlier read to the
/// later one over the time between them, so a steady tone shows a still bar and a fading tail a smooth fall at any
/// frame rate (the reads come about 30 times a second, the screen draws 30 to 240). A thin line holds the highest
/// peak for [holdSeconds]; at [clipDb] or over it turns pink for [clipSeconds]. With [readRight] it is a stereo
/// meter: two bars, left above right (side by side when [vertical]). Everything is worked out from wall-clock time
/// ([clock]), not frames. Its ticker runs only while a bar or the peak line moves; a held line or clip light waiting
/// to end sets a timer instead, so a settled meter asks for no frames.
class PeakMeter extends StatefulWidget {
  const PeakMeter({super.key, required this.state, required this.read, required this.color, this.vertical = false,
      this.readRight});
  final AppState state;

  /// The peak since the last read (the left channel of a stereo meter).
  final double Function() read;

  /// The right channel's peak: given, the meter shows two bars.
  final double Function()? readRight;
  final Color color;

  /// Upright, filling from the bottom (a mixer strip's meter), instead of a bar filling from the left.
  final bool vertical;

  /// The meter's range: [floorDb] (empty) to 0 dBFS (full).
  static const floorDb = -60.0;

  /// Set from Settings (`meter_fall`); 96 dB/s by default (owner: the old "Very fast" is the right medium).
  static double fallDbPerSecond = 96.0;

  static final _wall = Stopwatch()..start();

  /// The wall clock meters and readouts measure time between reads with; tests drive it from the test clock.
  @visibleForTesting
  static Duration Function() clock = () => _wall.elapsed;
  static const holdSeconds = 1.5;
  static const clipSeconds = 3.0;

  /// How long the bar takes to rise to a higher read (owner's bug, 2026-11-12: rising at once on each 30 Hz read and
  /// falling on every frame between them made the bar twitch at 120 Hz).
  static const attackSeconds = 0.015;
  static const clipDb = -0.1;

  /// A linear peak (1 = 0 dBFS) in dB, [floorDb] for silence.
  static double db(double peak) => peak <= 0 || !peak.isFinite ? floorDb : math.max(floorDb, 20 * math.log(peak) / math.ln10);

  /// Where [db] sits along the meter, 0..1.
  static double fraction(double db) => ((db - floorDb) / -floorDb).clamp(0.0, 1.0);

  /// A level for people: "-6.0 dB", "+1.2 dB" over full scale, "-∞ dB" for silence.
  static String label(double db) =>
      db <= floorDb ? '-∞ dB' : '${db > 0 ? '+' : ''}${db.toStringAsFixed(1)} dB';

  @override
  State<PeakMeter> createState() => PeakMeterState();
}

/// One channel's bar, held peak and clip light, on wall-clock seconds. Every step is worked out exactly from the
/// time, not the frame: the same reads give the same picture at any frame rate.
class _MeterChannel {
  double shownDb = PeakMeter.floorDb, holdDb = PeakMeter.floorDb;
  double _holdPeak = PeakMeter.floorDb, holdUntil = -1, clipUntil = -1; // seconds
  // The rise in progress: from [_riseFrom] at [_riseAt] to [_riseTo] (null: none).
  double? _riseTo;
  double _riseFrom = PeakMeter.floorDb, _riseAt = 0;
  // The floor the reads set: from [_floorFrom] at [_floorAt] to [_floorTo] over [_floorSpan] seconds.
  double _floorFrom = PeakMeter.floorDb, _floorTo = PeakMeter.floorDb, _floorAt = 0, _floorSpan = 0.033;
  double _lastReadAt = -1, _at = 0;
  bool clipped = false;

  /// A read's floor lasts this long past the read, in case the reads stop with sound left (the app paused them).
  static const _floorLasts = 0.15;

  // The floor's line at [t], ignoring its end.
  double _line(double t) => _floorFrom + (_floorTo - _floorFrom) * ((t - _floorAt) / _floorSpan).clamp(0.0, 1.0);

  double _floor(double t) =>
      _lastReadAt < 0 || t - _lastReadAt > _floorLasts ? PeakMeter.floorDb : _line(t);

  /// A read at [t] of [peak] (linear) since the last ([advance] to [t] first).
  void take(double peak, double t) {
    final d = PeakMeter.db(peak);
    // Down, the floor follows a line to the read; up, it is there at once (the bar's rise eases it in).
    final now = _floor(t);
    _floorFrom = d > now ? d : now;
    _floorTo = d;
    _floorSpan = _lastReadAt < 0 ? 0.033 : (t - _lastReadAt).clamp(0.01, 0.1).toDouble();
    _floorAt = t;
    _lastReadAt = t;
    if (d > shownDb + 0.01 && d > (_riseTo ?? PeakMeter.floorDb)) {
      _riseFrom = shownDb;
      _riseAt = t;
      _riseTo = d;
    }
    if (d >= holdDb && d > PeakMeter.floorDb) {
      _holdPeak = holdDb = d;
      holdUntil = t + PeakMeter.holdSeconds;
    }
    if (d >= PeakMeter.clipDb) clipUntil = t + PeakMeter.clipSeconds;
    clipped = t < clipUntil;
  }

  /// Moves on to [t].
  void advance(double t) {
    var a = _at;
    _at = t;
    if (t <= a) return;
    final rate = PeakMeter.fallDbPerSecond;
    final rise = _riseTo;
    if (rise != null) {
      final end = _riseAt + PeakMeter.attackSeconds;
      if (t < end) {
        final u = ((t - _riseAt) / PeakMeter.attackSeconds).clamp(0.0, 1.0);
        shownDb = _riseFrom + (rise - _riseFrom) * (1 - (1 - u) * (1 - u)); // eased out, never past the read
        _hold(t);
        return;
      }
      shownDb = rise;
      _riseTo = null;
      a = math.max(a, end);
    }
    // Falling at [rate] but never below the floor: the highest of the bar's own fall and, for each moment the
    // floor's line bends or ends in (a, t], the fall from the floor then.
    var s = shownDb - rate * (t - a);
    void from(double tau, double v) => s = math.max(s, v - rate * (t - tau));
    from(a, _floor(a));
    final bend = _floorAt + _floorSpan, end = _lastReadAt + _floorLasts;
    if (_lastReadAt >= 0 && bend > a && bend < t && bend <= end) from(bend, _line(bend));
    if (_lastReadAt >= 0 && end > a && end <= t) from(end, _line(end)); // the moment before it ends
    s = math.max(s, _floor(t));
    shownDb = math.max(PeakMeter.floorDb, s);
    _hold(t);
  }

  void _hold(double t) {
    // The peak line holds, then falls at the bar's rate, never below the bar.
    holdDb = t <= holdUntil ? math.max(_holdPeak, shownDb)
        : math.max(shownDb, _holdPeak - PeakMeter.fallDbPerSecond * (t - holdUntil));
    clipped = t < clipUntil;
  }

  /// Whether the bar or the line moves at [t] (it needs frames).
  bool moving(double t) {
    if (_riseTo != null) return true;
    final floorMoves = _lastReadAt >= 0 && t - _floorAt < _floorSpan && _floorFrom != _floorTo;
    if (floorMoves) return true;
    if (shownDb > _floor(t) + 1e-6 && shownDb > PeakMeter.floorDb) return true;
    return t > holdUntil && holdDb > shownDb + 1e-6;
  }

  /// When something still to come needs a step though nothing moves (the floor's end, the line's hold, the clip
  /// light), in seconds; null when nothing will.
  double? nextChange(double t) {
    final times = [
      if (_lastReadAt >= 0 && t - _lastReadAt <= _floorLasts && _floor(t) > PeakMeter.floorDb)
        _lastReadAt + _floorLasts,
      if (holdUntil > t && holdDb > shownDb + 1e-6) holdUntil,
      if (clipUntil > t) clipUntil,
    ];
    return times.isEmpty ? null : times.reduce(math.min);
  }
}

class PeakMeterState extends State<PeakMeter> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _step());
  double _at = -1; // the clock's seconds at the last step
  Timer? _wake;
  Object? _builtKey; // what the last build showed, to a 500th of the bar
  final _left = _MeterChannel(), _right = _MeterChannel();

  bool get _stereo => widget.readRight != null;

  /// The level the bar shows now, in dB (the left bar of a stereo meter; for tests).
  double get shownDb => _left.shownDb;

  /// The held peak line, in dB.
  double get holdDb => _left.holdDb;
  bool get clipped => _left.clipped || (_stereo && _right.clipped);

  /// The right bar's level, in dB (a stereo meter; for tests).
  double get shownRightDb => _right.shownDb;

  @override
  void initState() {
    super.initState();
    widget.state.tick.addListener(_read);
  }

  @override
  void didUpdateWidget(PeakMeter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.tick.removeListener(_read);
      widget.state.tick.addListener(_read);
    }
  }

  @override
  void dispose() {
    widget.state.tick.removeListener(_read);
    _wake?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  static double get _now => PeakMeter.clock().inMicroseconds / 1e6;

  // A meter read: the peak since the last one. The bars move on to now first.
  void _read() {
    _advance(_now);
    final t = _at;
    _left.take(widget.read(), t);
    if (_stereo) _right.take(widget.readRight?.call() ?? 0.0, t);
    _follow();
    _rebuild();
  }

  void _step() {
    _advance(_now);
    _follow();
    _rebuild();
  }

  void _advance(double t) {
    _at = t;
    _left.advance(t);
    if (_stereo) _right.advance(t);
  }

  // Frames while a bar or line moves; else a timer for the next thing to change (a hold ending), or nothing.
  void _follow() {
    final t = _at;
    final moving = _left.moving(t) || (_stereo && _right.moving(t));
    if (moving) {
      _wake?.cancel();
      _wake = null;
      if (!_ticker.isActive) _ticker.start();
      return;
    }
    if (_ticker.isActive) _ticker.stop();
    final next = [_left.nextChange(t), if (_stereo) _right.nextChange(t)].whereType<double>().fold<double?>(
        null, (a, b) => a == null || b < a ? b : a);
    _wake?.cancel();
    _wake = next == null ? null : Timer(Duration(microseconds: ((next - t) * 1e6).ceil() + 1000), () {
      _wake = null;
      if (mounted) _step();
    });
  }

  // Builds again only when the bars would show a change (a 500th of their height, or the clip light).
  void _rebuild() {
    int at(double db) => (PeakMeter.fraction(db) * 500).round();
    final key = (at(_left.shownDb), at(_left.holdDb), _left.clipped,
        _stereo ? (at(_right.shownDb), at(_right.holdDb), _right.clipped) : null);
    if (key == _builtKey || !mounted) return;
    _builtKey = key;
    setState(() {});
  }

  Widget _upright(_MeterChannel ch) {
    final color = ch.clipped ? Neon.pink : widget.color;
    final hold = PeakMeter.fraction(ch.holdDb);
    return Container(
      decoration: BoxDecoration(
        color: Neon.line.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: Neon.line, width: 0.8),
      ),
      child: LayoutBuilder(builder: (context, c) {
        final h = c.maxHeight.isFinite ? c.maxHeight : 0.0;
        return Stack(children: [
          Positioned(left: 0, right: 0, bottom: 0, height: h * PeakMeter.fraction(ch.shownDb),
            child: Container(color: color.withValues(alpha: 0.6))),
          if (hold > 0)
            Positioned(left: 0, right: 0, height: 1.5,
              bottom: (h * hold - 1.5).clamp(0.0, math.max(0.0, h - 1.5)),
              child: IgnorePointer(child: Container(color: color))),
        ]);
      }),
    );
  }

  Widget _sideways(_MeterChannel ch, {double height = 4}) {
    final color = ch.clipped ? Neon.pink : widget.color;
    final hold = PeakMeter.fraction(ch.holdDb);
    return LayoutBuilder(
      builder: (context, c) => Stack(alignment: Alignment.centerLeft, children: [
        Bar(value: PeakMeter.fraction(ch.shownDb), color: color, height: height, glassMinHeight: _stereo ? 5 : 7),
        if (hold > 0 && c.maxWidth.isFinite)
          Positioned(
            left: (c.maxWidth * hold - 1.5).clamp(0.0, math.max(0.0, c.maxWidth - 1.5)),
            top: 0,
            bottom: 0,
            child: IgnorePointer(child: Container(width: 1.5, color: color)),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Its own layer: a meter moving doesn't repaint the panel around it.
    if (widget.vertical) {
      return RepaintBoundary(child: _stereo
          ? Row(children: [Expanded(child: _upright(_left)), const SizedBox(width: 2), Expanded(child: _upright(_right))])
          : _upright(_left));
    }
    if (!_stereo) return RepaintBoundary(child: _sideways(_left));
    return RepaintBoundary(child: Column(mainAxisSize: MainAxisSize.min, children: [
      _sideways(_left, height: 5),
      const SizedBox(height: 1),
      _sideways(_right, height: 5),
    ]));
  }
}

/// The highest recent peak in dB, held for [PeakMeter.holdSeconds] so it can be read (the meter's number).
class PeakReadout extends StatefulWidget {
  const PeakReadout({super.key, required this.state, required this.read, this.style});
  final AppState state;
  final double Function() read;
  final TextStyle? style;

  @override
  State<PeakReadout> createState() => _PeakReadoutState();
}

class _PeakReadoutState extends State<PeakReadout> {
  double _db = PeakMeter.floorDb;
  Duration _heldAt = Duration.zero;
  // The meter reads stop about a second after the sound does, before the hold ends: this ends the hold anyway.
  Timer? _expire;

  @override
  void initState() {
    super.initState();
    widget.state.tick.addListener(_read);
  }

  @override
  void didUpdateWidget(PeakReadout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.tick.removeListener(_read);
      widget.state.tick.addListener(_read);
    }
  }

  @override
  void dispose() {
    widget.state.tick.removeListener(_read);
    _expire?.cancel();
    super.dispose();
  }

  void _show(double d) {
    if (d.toStringAsFixed(1) != _db.toStringAsFixed(1) && mounted) setState(() {});
    _db = d;
  }

  void _read() {
    final d = PeakMeter.db(widget.read());
    final now = PeakMeter.clock();
    final held = (now - _heldAt).inMicroseconds < PeakMeter.holdSeconds * 1e6;
    if (d >= _db || !held) {
      _show(d);
      _heldAt = now;
      _expire?.cancel();
      _expire = d > PeakMeter.floorDb
          ? Timer(Duration(microseconds: (PeakMeter.holdSeconds * 1e6).round()), () {
              _expire = null;
              _show(PeakMeter.db(widget.read()));
            })
          : null;
    }
  }

  @override
  Widget build(BuildContext context) => Text(PeakMeter.label(_db), style: widget.style ?? Neon.code(size: 11, color: Neon.dim));
}

/// A compact square toggle such as M (mute) or S (solo).
class ToggleChip extends StatelessWidget {
  const ToggleChip(
      {super.key, required this.label, required this.on, required this.color, required this.onTap, this.tooltip, this.size = 48});
  final String label;
  final bool on;
  final Color color;
  final VoidCallback onTap;
  final String? tooltip;

  /// Its width; compact track headers use a smaller chip (the height follows, a little flatter).
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip ?? label,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            Haptics.tap(); // M and S are felt, as every other press
            onTap();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: size,
            height: size >= 48 ? size : size * 0.84,
            alignment: Alignment.center,
            // Glass: on is a faint fill with a solid outline (not a solid block); off is outlined only.
            decoration: BoxDecoration(
              color: on ? (Glass.active ? color.withValues(alpha: 0.22) : color) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: on ? color : Neon.line, width: on && Glass.active ? 1.2 : 1),
              boxShadow: on && !Glass.active ? Neon.glow(color) : null,
            ),
            child: Text(label,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: on ? (Glass.active ? color : Neon.bg) : Neon.dim,
                    fontSize: size >= 48 ? 15 : 12)),
          ),
        ),
      );
}

/// Section heading in small caps.
class Heading extends StatelessWidget {
  const Heading(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Row(children: [
          Expanded(
            child: Text(text.toUpperCase(),
                style: const TextStyle(fontSize: 12, letterSpacing: 1.4, fontWeight: FontWeight.w700, color: Neon.dim)),
          ),
          ?trailing,
        ]),
      );
}

/// Asks for a typed value; [apply] gets it only if it parses and the text was changed (the [initial] text may be
/// rounded, so setting it unedited would round the value).
Future<void> typeValue(BuildContext context, {required String title, required String initial,
    required double? Function(String) parse, required void Function(double) apply,
    TextInputType keyboardType = TextInputType.text}) async {
  final v = await showDialog<double>(context: context, animationStyle: dialogAnimation(context),
    builder: (context) => ValueDialog(title: title, initial: initial, parse: parse, keyboardType: keyboardType));
  if (v != null) apply(v);
}

/// The dialog [typeValue] shows: refuses an entry that doesn't parse, and says so.
class ValueDialog extends StatefulWidget {
  const ValueDialog({super.key, required this.title, required this.initial, required this.parse,
      this.keyboardType = TextInputType.text});
  final String title, initial;
  final double? Function(String) parse;
  final TextInputType keyboardType;

  @override
  State<ValueDialog> createState() => _ValueDialogState();
}

class _ValueDialogState extends State<ValueDialog> {
  late final _text = TextEditingController(text: widget.initial);
  bool _bad = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done() {
    if (_text.text.trim() == widget.initial.trim()) return Navigator.pop(context);
    final v = widget.parse(_text.text);
    if (v == null) {
      setState(() => _bad = true);
    } else {
      Navigator.pop(context, v);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(controller: _text, autofocus: true, keyboardType: widget.keyboardType,
      onSubmitted: (_) => _done(),
      decoration: InputDecoration(errorText: _bad ? 'Not a value' : null)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(onPressed: _done, child: const Text('Set')),
    ],
  );
}

/// A whole number of bars from 1 to [max]: − and + step it, tapping the number types any value (no fixed list of
/// lengths; owner, 2026-11-09: a project's length has no cap).
class BarsField extends StatelessWidget {
  const BarsField({super.key, required this.value, required this.max, required this.onChanged, this.title = 'Bars'});
  final int value, max;
  final ValueChanged<int> onChanged;
  final String title;

  @override
  Widget build(BuildContext context) {
    void set(int v) {
      final c = v.clamp(1, max).toInt();
      if (c != value) onChanged(c);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(onPressed: value > 1 ? () => set(value - 1) : null, icon: const Icon(Icons.remove, size: 16),
        tooltip: 'One bar less', visualDensity: VisualDensity.compact),
      TextButton(
        onPressed: () => typeValue(context, title: title, initial: '$value', keyboardType: TextInputType.number,
          parse: (t) {
            final n = int.tryParse(t.trim());
            return n == null || n < 1 ? null : n.toDouble();
          },
          apply: (v) => set(v.toInt())),
        child: Text(value == 1 ? '1 bar' : '$value bars')),
      IconButton(onPressed: value < max ? () => set(value + 1) : null, icon: const Icon(Icons.add, size: 16),
        tooltip: 'One bar more', visualDensity: VisualDensity.compact),
    ]);
  }
}

/// A double-tap on [child] (a slider, usually) sets it back to its default (owner, 2026-11-10: every slider and knob
/// resets on a double-tap). The taps and drags belong to the slider and answer at once (a tap moves the thumb at
/// once): only a [Listener] counts them, and the second tap's reset lands after the slider has had that tap.
class ResetOnDoubleTap extends StatefulWidget {
  const ResetOnDoubleTap({super.key, required this.onReset, required this.child});
  final VoidCallback? onReset;
  final Widget child;

  @override
  State<ResetOnDoubleTap> createState() => _ResetOnDoubleTapState();
}

class _ResetOnDoubleTapState extends State<ResetOnDoubleTap> {
  final _taps = ClickCounter();

  void _up(PointerUpEvent e) {
    _taps.up(e);
    // A second tap that stayed in place (a drag is the slider's). The slider takes the tap in the same event, after
    // this listener: the reset waits for it, so the default is what stays.
    if (!_taps.twice || (e.position - _taps.position).distance > kDoubleTapTouchSlop) return;
    scheduleMicrotask(() {
      if (!mounted || widget.onReset == null) return;
      Motion.tick();
      widget.onReset!();
    });
  }

  @override
  Widget build(BuildContext context) => widget.onReset == null
      ? widget.child
      : Listener(onPointerDown: _taps.down, onPointerUp: _up, child: widget.child);
}

/// Settings › Editing › Ask before deleting a track: a dialog when it is on (true at once when off; undo takes a
/// delete back either way).
Future<bool> confirmTrackDelete(BuildContext context, AppState state, LayerDoc layer) async {
  if (!state.settings.confirmDelete) return true;
  final ok = await showDialog<bool>(
    context: context, animationStyle: dialogAnimation(context),
    builder: (context) => AlertDialog(
      title: Text('Delete "${layer.name}"?'),
      content: Text(layer.isFolder ? 'The folder and the tracks in it go.' : 'Its clips and effects go with it.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(
          key: const ValueKey('confirm-delete'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete', style: TextStyle(color: Neon.pink)),
        ),
      ],
    ),
  );
  return ok == true;
}

/// A number in an advanced menu (owner, 2026-11-11): its name, its value (a tap types one), a reset button and a big
/// slider under them, which a double-tap also resets. The value shows as [scale] × the value with [decimals] places
/// and [unit] (velocity 0..1 as `80%`); a typed number is read in the same units, clamped and, with [divisions],
/// snapped.
class ValueSlider extends StatelessWidget {
  const ValueSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.reset,
    required this.onChanged,
    this.onChangeEnd,
    this.scale = 1,
    this.decimals = 0,
    this.unit = '',
    this.divisions,
    this.sliderKey,
  });
  final String label, unit;
  final double value, min, max, reset, scale;
  final int decimals;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final Key? sliderKey;

  String show(double v) => '${(v * scale).toStringAsFixed(decimals)}$unit';

  double _snap(double v) {
    final c = v.clamp(min, max).toDouble();
    final d = divisions;
    if (d == null || d <= 0) return c;
    final step = (max - min) / d;
    return (min + ((c - min) / step).round() * step).clamp(min, max).toDouble();
  }

  void _set(double v) {
    onChanged(v);
    onChangeEnd?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(min, max).toDouble();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(child: Text(label, style: const TextStyle(color: Neon.text))),
        TextButton(
          key: ValueKey('value-type-$label'),
          onPressed: () => typeValue(context,
              title: label,
              initial: (v * scale).toStringAsFixed(decimals),
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              parse: (t) {
                final x = double.tryParse(t.trim().replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.\-]'), ''));
                return x == null || !x.isFinite ? null : _snap(x / scale);
              },
              apply: _set),
          child: Text(show(v), style: Neon.code(size: 13)),
        ),
        IconButton(
          tooltip: 'Reset to ${show(reset)}',
          visualDensity: VisualDensity.compact,
          onPressed: v == reset ? null : () => _set(reset),
          icon: const Icon(Icons.restart_alt, size: 18),
        ),
      ]),
      ResetOnDoubleTap(
        onReset: () => _set(reset),
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 8,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 11),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
          ),
          child: Slider(
            key: sliderKey,
            value: v,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
      ),
    ]);
  }
}
