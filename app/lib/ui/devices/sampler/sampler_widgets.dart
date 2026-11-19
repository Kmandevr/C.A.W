// The sampler editor's parts: the zone map (keys across, velocity up), the keyboard that plays and takes dropped audio, the zone's waveform with its markers, and the zone inspector (with time-stretch).
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../engine/audio_engine.dart';
import '../../../model/app_state.dart';
import '../../../model/audio_clips.dart';
import '../../../model/audio_edit.dart';
import '../../../model/sampler.dart';
import '../../arrange/audio_waveform.dart';
import '../../frame/sections.dart';
import '../../haptics.dart';
import '../../theme.dart';
import '../device_scope.dart';
import '../kit/repaint.dart';

// ---------- the zone map ----------

/// Zones over keys (across) and velocity (up): tap picks one (Ctrl or a second tap adds), drag a zone to move it,
/// drag its edges to change its range. The keys shown follow the zones, with room around them.
class ZoneMap extends StatefulWidget {
  const ZoneMap({super.key, required this.zones, required this.selected, required this.accent, required this.onSelect,
      required this.onDrag, required this.onDragEnd, this.height = 180});
  final SamplerState zones;
  final Set<int> selected;
  final Color accent;
  final double height;
  final void Function(int? index, {bool additive}) onSelect;
  final ValueChanged<SamplerState> onDrag;
  final VoidCallback onDragEnd;

  /// The keys drawn: the zones' span with an octave around it, at least four octaves and at most a piano's 88 keys
  /// (A0..C8: a zone over the whole keyboard shows those).
  static (int, int) keySpan(SamplerState z) {
    final (lo, hi) = zoneSpan(z);
    var a = math.max(21, lo - 12), b = math.min(108, hi + 12);
    if (b < a) (a, b) = (math.max(0, lo - 12), math.min(127, hi + 12));
    while (b - a < 48) {
      if (a > 0) a--;
      if (b - a < 48 && b < 127) b++;
      if (a == 0 && b == 127) break;
    }
    return (a, b);
  }

  @override
  State<ZoneMap> createState() => _ZoneMapState();
}

enum _Edge { body, left, right, top, bottom }

class _ZoneMapState extends State<ZoneMap> {
  int? _zone;
  _Edge _edge = _Edge.body;
  SamplerZone? _start;
  Offset _from = Offset.zero;

  (int, int) get _span => ZoneMap.keySpan(widget.zones);

  Rect _rect(SamplerZone z, Size size) {
    final (a, b) = _span;
    final kw = size.width / (b - a + 1);
    double y(int vel) => (1 - vel / 127) * size.height;
    return Rect.fromLTRB((z.loKey - a) * kw, y(z.hiVel), (z.hiKey - a + 1) * kw, y(z.loVel - 1));
  }

  int? _hit(Offset at, Size size) {
    // The selected zones first, then the last drawn (on top).
    final order = [...widget.selected, for (var i = widget.zones.zones.length - 1; i >= 0; i--) i];
    for (final i in order) {
      if (i < widget.zones.zones.length && _rect(widget.zones.zones[i], size).inflate(4).contains(at)) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => SizedBox(height: widget.height, child: LayoutBuilder(builder: (context, box) {
    final size = Size(box.maxWidth, widget.height);
    final (a, b) = _span;
    final kw = size.width / (b - a + 1);
    // A zone moves from the first few pixels (a key is narrow on a phone), before the page's scroll takes the drag.
    final mq = MediaQuery.of(context);
    void addUnder(Offset at) {
      final under = [
        for (var i = widget.zones.zones.length - 1; i >= 0; i--)
          if (_rect(widget.zones.zones[i], size).inflate(4).contains(at)) i,
      ];
      final i = under.where((i) => !widget.selected.contains(i)).firstOrNull ?? under.firstOrNull;
      if (i != null) widget.onSelect(i, additive: true);
    }

    return MediaQuery(data: mq.copyWith(gestureSettings: const DeviceGestureSettings(touchSlop: kTouchSlop / 3)),
        child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Where the finger went down picks the zone and its edge, not where the drag was recognised.
      dragStartBehavior: DragStartBehavior.down,
      onTapUp: (d) => widget.onSelect(_hit(d.localPosition, size), additive: widget.selected.length > 1 ||
          HardwareKeyboard.instance.isControlPressed),
      // A long-press adds a zone to the selection: of stacked zones, the first not chosen yet (layers, round robins).
      onLongPressStart: (d) => addUnder(d.localPosition),
      onSecondaryTapUp: (d) => addUnder(d.localPosition), // a right-click does the same
      onPanStart: (d) {
        final i = _hit(d.localPosition, size);
        if (i == null) return;
        final r = _rect(widget.zones.zones[i], size);
        final p = d.localPosition;
        // The edges are 10 px wide (8 px high), less on a narrow zone so its middle still moves it.
        final ex = math.min(10.0, r.width / 4), ey = math.min(8.0, r.height / 4);
        _edge = (p.dx - r.left).abs() < ex ? _Edge.left : (p.dx - r.right).abs() < ex ? _Edge.right
            : (p.dy - r.top).abs() < ey ? _Edge.top : (p.dy - r.bottom).abs() < ey ? _Edge.bottom : _Edge.body;
        _zone = i;
        _start = widget.zones.zones[i].copy();
        _from = p;
        if (!widget.selected.contains(i)) widget.onSelect(i);
        Haptics.grab();
      },
      onPanUpdate: (d) {
        final i = _zone, s0 = _start;
        if (i == null || s0 == null) return;
        final dk = ((d.localPosition.dx - _from.dx) / kw).round();
        final dv = (-(d.localPosition.dy - _from.dy) / size.height * 127).round();
        final next = widget.zones.copy();
        final z = s0.copy();
        switch (_edge) {
          case _Edge.body:
            next.zones[i] = z;
            next.moveZone(i, dk, dv);
          case _Edge.left:
            z.loKey = (s0.loKey + dk).clamp(0, s0.hiKey);
            next.zones[i] = z;
          case _Edge.right:
            z.hiKey = (s0.hiKey + dk).clamp(s0.loKey, 127);
            next.zones[i] = z;
          case _Edge.top:
            z.hiVel = (s0.hiVel + dv).clamp(s0.loVel, 127);
            next.zones[i] = z;
          case _Edge.bottom:
            z.loVel = (s0.loVel + dv).clamp(1, s0.hiVel);
            next.zones[i] = z;
        }
        final was = widget.zones.zones[i];
        if (was.loKey != next.zones[i].loKey || was.hiKey != next.zones[i].hiKey ||
            was.loVel != next.zones[i].loVel || was.hiVel != next.zones[i].hiVel) {
          Haptics.tick();
        }
        widget.onDrag(next);
      },
      onPanEnd: (_) {
        if (_zone == null) return;
        _zone = null;
        _start = null;
        widget.onDragEnd();
      },
      child: CustomPaint(size: size, painter: _ZoneMapPainter(widget.zones, widget.selected, widget.accent, a, b, _rect)),
    ));
  }));
}

class _ZoneMapPainter extends CustomPainter {
  _ZoneMapPainter(this.zones, this.selected, this.accent, this.lo, this.hi, this.rectOf);
  final SamplerState zones;
  final Set<int> selected;
  final Color accent;
  final int lo, hi;
  final Rect Function(SamplerZone, Size) rectOf;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8));
    canvas.drawRRect(bg, Paint()..color = Color.lerp(Neon.bg, accent, 0.06)!);
    final kw = size.width / (hi - lo + 1);
    final grid = Paint()..color = Neon.line.withValues(alpha: 0.5);
    for (var k = lo; k <= hi; k++) {
      if (k % 12 == 0) canvas.drawLine(Offset((k - lo) * kw, 0), Offset((k - lo) * kw, size.height), grid);
    }
    for (final v in [32, 64, 96]) {
      final y = (1 - v / 127) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid..color = Neon.line.withValues(alpha: 0.25));
    }
    for (var i = 0; i < zones.zones.length; i++) {
      final z = zones.zones[i];
      final r = rectOf(z, size).deflate(0.5);
      final on = selected.contains(i);
      final hue = z.seqLength > 1 ? Color.lerp(accent, Neon.pink, 0.5)! : accent;
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)),
          Paint()..color = hue.withValues(alpha: on ? 0.45 : 0.20));
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)), Paint()
        ..color = on ? Neon.ink : hue.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = on ? 1.6 : 1);
      // The root key: a tick at the zone's foot.
      final rx = (z.root - lo + 0.5) * kw;
      if (rx >= r.left && rx <= r.right) {
        canvas.drawLine(Offset(rx, r.bottom - 6), Offset(rx, r.bottom), Paint()..color = Neon.ink..strokeWidth = 2);
      }
      if (r.width > 34 && r.height > 14) {
        final tp = TextPainter(text: TextSpan(text: z.seqLength > 1 ? '${z.name} · ${z.seqPosition}/${z.seqLength}' : z.name,
            style: Neon.code(size: 9, color: Neon.ink)), textDirection: TextDirection.ltr, maxLines: 1,
            ellipsis: '…')
          ..layout(maxWidth: r.width - 6);
        tp.paint(canvas, Offset(r.left + 3, r.top + 2));
      }
    }
    final tp = TextPainter(text: TextSpan(text: '${noteName(lo)} · velocity ↑',
        style: Neon.code(size: 9, color: Neon.dim)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset(4, size.height - tp.height - 2));
  }

  @override
  bool shouldRepaint(covariant _ZoneMapPainter old) =>
      paintInputsChanged([old.zones, old.selected, old.accent, old.lo, old.hi, old.rectOf], [zones, selected, accent, lo, hi, rectOf]);
}

// ---------- the keyboard ----------

/// The keys under the map: a press plays the sampler, an audio file dropped on a key makes zones from there up.
class SamplerKeyboard extends StatelessWidget {
  const SamplerKeyboard({super.key, required this.zones, required this.accent, required this.onNote,
      required this.onDropFiles, this.height = 56});
  final SamplerState zones;
  final Color accent;
  final double height;
  final void Function(int key, bool on) onNote;
  final void Function(int key, List<String> paths) onDropFiles;

  static bool _black(int k) => const {1, 3, 6, 8, 10}.contains(k % 12);

  @override
  Widget build(BuildContext context) {
    final (lo, hi) = ZoneMap.keySpan(zones);
    final state = DeviceScope.maybeOf(context)?.target.state;
    return SizedBox(height: height, child: LayoutBuilder(builder: (context, box) {
      final kw = box.maxWidth / (hi - lo + 1);
      int keyAt(double x) => (lo + (x / kw).floor()).clamp(lo, hi);
      return DragTarget<AssetDrag>(
        onWillAcceptWithDetails: (d) => d.data.kind == AssetKind.audioFile,
        onAcceptWithDetails: (d) {
          final box = context.findRenderObject() as RenderBox?;
          final x = box == null ? 0.0 : box.globalToLocal(d.offset).dx;
          final path = state?.project.asset(d.data.id)?.path ?? d.data.id;
          onDropFiles(keyAt(x), [path]);
        },
        builder: (context, hovering, _) => Listener(
          onPointerDown: (e) => onNote(keyAt(e.localPosition.dx), true),
          onPointerUp: (e) => onNote(keyAt(e.localPosition.dx), false),
          onPointerCancel: (e) => onNote(keyAt(e.localPosition.dx), false),
          child: CustomPaint(size: Size(box.maxWidth, height), painter: _KeysPainter(lo, hi, accent, zones,
              hovering.isNotEmpty)),
        ),
      );
    }));
  }
}

class _KeysPainter extends CustomPainter {
  _KeysPainter(this.lo, this.hi, this.accent, this.zones, this.hover);
  final int lo, hi;
  final Color accent;
  final SamplerState zones;
  final bool hover;

  @override
  void paint(Canvas canvas, Size size) {
    final kw = size.width / (hi - lo + 1);
    for (var k = lo; k <= hi; k++) {
      final r = Rect.fromLTWH((k - lo) * kw, 0, kw, size.height).deflate(0.4);
      final mapped = zones.zones.any((z) => k >= z.loKey && k <= z.hiKey);
      final black = SamplerKeyboard._black(k);
      canvas.drawRect(r, Paint()..color = black ? const Color(0xFF1A1A22) : const Color(0xFFDADAE2));
      if (mapped) canvas.drawRect(Rect.fromLTWH(r.left, r.bottom - 4, r.width, 4), Paint()..color = accent);
    }
    if (hover) {
      canvas.drawRect(Offset.zero & size, Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(covariant _KeysPainter old) =>
      paintInputsChanged([old.lo, old.hi, old.accent, old.zones, old.hover], [lo, hi, accent, zones, hover]);
}

// ---------- the zone's waveform ----------

/// The zone's sample with its start and end and its loop (drag a marker to move it; positions are the file's
/// frames).
class ZoneWaveform extends StatefulWidget {
  const ZoneWaveform({super.key, required this.state, required this.zone, required this.accent, required this.onChanged});
  final AppState state;
  final SamplerZone zone;
  final Color accent;
  final ValueChanged<SamplerZone> onChanged;

  @override
  State<ZoneWaveform> createState() => _ZoneWaveformState();
}

class _ZoneWaveformState extends State<ZoneWaveform> {
  AssetInfo? _info;
  String? _marker;
  SamplerZone? _drag;

  static final Map<String, AssetInfo> _known = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ZoneWaveform old) {
    super.didUpdateWidget(old);
    if (old.zone.path != widget.zone.path) _load();
  }

  void _load() {
    final path = widget.zone.path;
    _info = _known[path];
    if (_info != null) return;
    widget.state.audioIo.loadAsset(path).then((i) {
      if (!i.ok) return;
      _known[path] = i;
      if (mounted && widget.zone.path == path) setState(() => _info = i);
    });
  }

  int get _frames => _info == null ? 0 : (_info!.seconds * (_info!.sourceRate > 0 ? _info!.sourceRate : _info!.sampleRate)).round();

  @override
  Widget build(BuildContext context) {
    final z = _drag ?? widget.zone;
    final info = _info;
    return SizedBox(height: 96, child: LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final frames = _frames;
      double x(int frame) => frames <= 0 ? 0 : frame / frames * w;
      int frameAt(double px) => frames <= 0 ? 0 : (px / w * frames).round().clamp(0, frames);
      final end = z.end > 0 ? z.end : frames;
      final markers = <(String, int, Color)>[
        ('start', z.offset, Neon.green),
        ('end', end, Neon.pink),
        if (z.loopEnd > z.loopStart || z.playedLoopMode.startsWith('loop')) ...[
          ('loop_start', z.loopStart, Neon.yellow),
          ('loop_end', z.loopEnd > 0 ? z.loopEnd : end, Neon.yellow),
        ],
      ];
      return Stack(children: [
        Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(color: Color.lerp(Neon.bg, widget.accent, 0.07),
            borderRadius: BorderRadius.circular(8)))),
        if (info != null)
          Positioned.fill(child: CustomPaint(key: const ValueKey('sampler-wave'), painter: AudioClipPainter(
            peaks: () => WaveformCache.instance.peaks(widget.state.audioIo, z.path, info.seconds, info.seconds / w),
            window: ClipWindow(offset: 0, perPixel: info.seconds / w, fileSeconds: info.seconds),
            color: widget.accent.withValues(alpha: 0.85), gain: 1, fadeIn: 0, fadeOut: 0,
            inCurve: FadeCurve.linear, outCurve: FadeCurve.linear, path: z.path))),
        if (z.loopEnd > z.loopStart)
          Positioned(left: x(z.loopStart), width: math.max(1, x(z.loopEnd) - x(z.loopStart)), top: 0, bottom: 0,
              child: IgnorePointer(child: ColoredBox(color: Neon.yellow.withValues(alpha: 0.10)))),
        for (final (name, frame, color) in markers)
          // Kept inside the waveform, so a marker at either end can still be grabbed; its line stays on its frame.
          Positioned(left: (x(frame) - 12).clamp(0.0, math.max(0.0, w - 24)), top: 0, bottom: 0, width: 24, child: GestureDetector(
            key: ValueKey('sampler-marker-$name'),
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (_) {
              _marker = name;
              _drag = widget.zone.copy();
              Haptics.grab();
            },
            onHorizontalDragUpdate: (d) {
              final dz = _drag;
              if (dz == null || frames <= 0) return;
              final f = frameAt(x(switch (_marker) {
                    'start' => dz.offset,
                    'end' => dz.end > 0 ? dz.end : frames,
                    'loop_start' => dz.loopStart,
                    _ => dz.loopEnd > 0 ? dz.loopEnd : frames,
                  }) + d.delta.dx);
              setState(() {
                switch (_marker) {
                  case 'start':
                    dz.offset = f.clamp(0, (dz.end > 0 ? dz.end : frames) - 1);
                  case 'end':
                    dz.end = f.clamp(dz.offset + 1, frames);
                  case 'loop_start':
                    dz.loopStart = f.clamp(0, (dz.loopEnd > 0 ? dz.loopEnd : frames) - 1);
                    if (dz.loopEnd <= dz.loopStart) dz.loopEnd = frames;
                  default:
                    dz.loopEnd = f.clamp(dz.loopStart + 1, frames);
                }
              });
            },
            onHorizontalDragEnd: (_) {
              final dz = _drag;
              _drag = null;
              _marker = null;
              if (dz != null) widget.onChanged(dz);
              Haptics.drop();
            },
            child: Align(alignment: Alignment((x(frame) - (x(frame) - 12).clamp(0.0, math.max(0.0, w - 24)) - 12) / 12, 0),
                child: Container(width: 2, color: color)))),
        Positioned(left: 6, top: 4, child: Text(info == null ? '${z.name} · loading…'
            : '${z.name} · ${info.seconds.toStringAsFixed(2)} s', style: const TextStyle(fontSize: 10, color: Neon.dim))),
      ]);
    }));
  }
}

// ---------- the zone inspector ----------

class ZoneInspector extends StatelessWidget {
  const ZoneInspector({super.key, required this.zone, required this.accent, required this.onChanged});
  final SamplerZone zone;
  final Color accent;
  final ValueChanged<SamplerZone> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget stepper(String key, String label, String value, VoidCallback down, VoidCallback up) => SizedBox(
          width: 172,
          child: Row(children: [
            SizedBox(width: 54, child: Text(label, style: const TextStyle(fontSize: 11, color: Neon.dim))),
            IconButton(key: ValueKey('zone-$key-down'), visualDensity: VisualDensity.compact, iconSize: 16,
                icon: const Icon(Icons.remove), onPressed: () { Haptics.tick(); down(); }),
            Expanded(child: FittedBox(fit: BoxFit.scaleDown, child: Text(value, maxLines: 1, softWrap: false,
                style: Neon.code(size: 11, color: Neon.text)))),
            IconButton(key: ValueKey('zone-$key-up'), visualDensity: VisualDensity.compact, iconSize: 16,
                icon: const Icon(Icons.add), onPressed: () { Haptics.tick(); up(); }),
          ]));
    SamplerZone c() => zone.copy();
    return Padding(padding: const EdgeInsets.only(top: 8), child: Wrap(spacing: 8, runSpacing: 2, children: [
      stepper('root', 'Root', noteName(zone.root), () => onChanged(c()..root = (zone.root - 1).clamp(0, 127)),
          () => onChanged(c()..root = (zone.root + 1).clamp(0, 127))),
      stepper('lokey', 'Low key', noteName(zone.loKey), () => onChanged(c()..loKey = (zone.loKey - 1).clamp(0, 127)),
          () => onChanged(c()..loKey = (zone.loKey + 1).clamp(0, zone.hiKey))),
      stepper('hikey', 'High key', noteName(zone.hiKey), () => onChanged(c()..hiKey = (zone.hiKey - 1).clamp(zone.loKey, 127)),
          () => onChanged(c()..hiKey = (zone.hiKey + 1).clamp(0, 127))),
      stepper('lovel', 'Low vel', '${zone.loVel}', () => onChanged(c()..loVel = (zone.loVel - 8).clamp(1, zone.hiVel)),
          () => onChanged(c()..loVel = (zone.loVel + 8).clamp(1, zone.hiVel))),
      stepper('hivel', 'High vel', '${zone.hiVel}', () => onChanged(c()..hiVel = (zone.hiVel - 8).clamp(zone.loVel, 127)),
          () => onChanged(c()..hiVel = (zone.hiVel + 8).clamp(zone.loVel, 127))),
      stepper('tune', 'Tune', '${zone.tune.round()} ct', () => onChanged(c()..tune = zone.tune - 5),
          () => onChanged(c()..tune = zone.tune + 5)),
      stepper('volume', 'Volume', '${zone.volume.toStringAsFixed(1)} dB', () => onChanged(c()..volume = zone.volume - 1),
          () => onChanged(c()..volume = math.min(24, zone.volume + 1))),
      stepper('pan', 'Pan', zone.pan == 0 ? 'C' : '${zone.pan.abs().round()}${zone.pan < 0 ? 'L' : 'R'}',
          () => onChanged(c()..pan = (zone.pan - 10).clamp(-100, 100)), () => onChanged(c()..pan = (zone.pan + 10).clamp(-100, 100))),
      stepper('group', 'Choke', zone.group == 0 ? 'none' : '${zone.group}',
          () => onChanged(c()..group = math.max(0, zone.group - 1)..offBy = math.max(0, zone.group - 1)),
          () => onChanged(c()..group = zone.group + 1..offBy = zone.group + 1)),
      SizedBox(width: 300, child: Row(children: [
        const SizedBox(width: 54, child: Text('Loop', style: TextStyle(fontSize: 11, color: Neon.dim))),
        DropdownButton<String>(key: const ValueKey('zone-loop-mode'), isDense: true, value: zone.playedLoopMode,
            underline: const SizedBox.shrink(),
            items: [for (final m in samplerLoopModes) DropdownMenuItem(value: m, child: Text(loopModeLabel(m),
                style: const TextStyle(fontSize: 12)))],
            onChanged: (m) {
              if (m == null) return;
              Haptics.tick();
              onChanged(c()..loopMode = m);
            }),
        if (zone.seqLength > 1) Padding(padding: const EdgeInsets.only(left: 8), child: Text(
            'Round robin ${zone.seqPosition}/${zone.seqLength}', style: TextStyle(fontSize: 11, color: accent))),
      ])),
      // Time-stretch: the zone keeps its length on every key; a sample tempo makes it follow the song's.
      SizedBox(width: 172, child: Row(children: [
        const SizedBox(width: 54, child: Text('Stretch', style: TextStyle(fontSize: 11, color: Neon.dim))),
        Switch(key: const ValueKey('zone-stretch'), value: zone.stretch, onChanged: (v) {
          Haptics.tick();
          onChanged(c()..stretch = v);
        }),
        Flexible(child: Text(zone.stretch ? 'same length' : 'off', maxLines: 1, overflow: TextOverflow.fade, softWrap: false,
            style: TextStyle(fontSize: 10, color: zone.stretch ? accent : Neon.dim))),
      ])),
      AnimatedOpacity(duration: const Duration(milliseconds: 150), opacity: zone.stretch ? 1 : 0.4,
        child: stepper('bpm', 'Tempo', zone.stretchBpm < 20 ? 'own' : '${zone.stretchBpm.round()} BPM',
          () => onChanged(c()..stretch = true..stretchBpm = zone.stretchBpm <= 20 ? 0 : zone.stretchBpm - 1),
          () => onChanged(c()..stretch = true..stretchBpm = zone.stretchBpm < 20 ? 120 : math.min(999, zone.stretchBpm + 1)))),
    ]));
  }
}

