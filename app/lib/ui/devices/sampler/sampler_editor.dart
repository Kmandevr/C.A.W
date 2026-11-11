// The sampler's editor (org.caw.sampler), in the device kit's style: ZONES (the zone map over keys and velocity,
// the keyboard that takes dropped samples and plays them, the zone's waveform with its loop points, the zone
// inspector, round robins, SFZ import and export) and SOUND (level, envelope and filter knobs).
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../engine/audio_engine.dart';
import '../../../model/app_state.dart';
import '../../../model/audio_clips.dart';
import '../../../model/audio_edit.dart';
import '../../../model/project.dart';
import '../../../model/sampler.dart';
import '../../arrange/audio_waveform.dart';
import '../../frame/sections.dart';
import '../../haptics.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_registry.dart';
import '../device_scope.dart';
import '../kit/controls.dart';
import '../kit/device_style.dart';

final Map<String, DeviceEditorEntry> samplerEditors = {
  samplerComponentId: DeviceEditorEntry(
    (_) => [
      DeviceSection('zones', 'ZONES', Icons.view_quilt_outlined, (_) => const SamplerZonesPage()),
      DeviceSection('sound', 'SOUND', Icons.tune, (_) => const SamplerSoundPage()),
    ],
    family: DeviceFamily.synth,
    inline: (_) => const SamplerSoundPage(),
  ),
};

/// Picking files for the sampler, for tests to replace: sample files (absolute paths in app storage) and an SFZ.
class SamplerFiles {
  SamplerFiles._();

  /// Audio files picked and copied into the project (paths of the copies).
  static Future<List<String>> Function(AppState state) pickSamples = _pickSamples;
  static Future<String?> Function() pickSfz = _pickSfz;
  static Future<String?> Function(String name) exportPath = _exportPath;

  static Future<List<String>> _pickSamples(AppState state) async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: audioExtensions);
    final out = <String>[];
    for (final f in files) {
      final a = await state.importAudio(f.name, () => f.readAsByteStream());
      out.add(a.path);
    }
    return out;
  }

  static Future<String?> _pickSfz() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['sfz']);
    return f?.path;
  }

  /// Where an export goes: a folder the user picks (the samples are copied beside the .sfz).
  static Future<String?> _exportPath(String name) async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Export SFZ to…');
    return dir == null ? null : '$dir/$name.sfz';
  }
}

/// What the ZONES page edits: the zones (a working copy while a drag runs) and the selection.
class _Zones {
  _Zones(this.state, this.layer);
  final AppState state;
  final LayerDoc layer;
  SamplerState get saved => state.samplerState(layer);
  void save(SamplerState z) => state.setSamplerState(layer, z);
}

class SamplerZonesPage extends StatefulWidget {
  const SamplerZonesPage({super.key});

  @override
  State<SamplerZonesPage> createState() => _SamplerZonesPageState();
}

class _SamplerZonesPageState extends State<SamplerZonesPage> {
  final Set<int> _selected = {};
  SamplerState? _working; // a drag's zones before they are saved
  bool _busy = false;

  void _say(String t) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(t)));

  _Zones? _zones(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final l = t.layer;
    return l == null ? null : _Zones(t.state, l);
  }

  Future<void> _run(String label, Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      Haptics.error();
      _say('$label: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addSamples(_Zones z, {int? key}) => _run('Adding samples', () async {
        final paths = await SamplerFiles.pickSamples(z.state);
        if (paths.isEmpty) return;
        final s = z.saved;
        final made = s.addFiles(paths, key ?? (s.zones.isEmpty ? 60 : zoneSpan(s).$2 + 1));
        z.save(s);
        setState(() => _selected..clear()..addAll(made));
        Haptics.drop();
      });

  Future<void> _importSfz(_Zones z) => _run('SFZ import', () async {
        final path = await SamplerFiles.pickSfz();
        if (path == null) return;
        final r = await z.state.audioIo.sfzImport(path);
        if (!r.ok || r.state == null) throw r.error.isEmpty ? 'the file could not be read' : r.error;
        z.save(SamplerState.fromJson(r.state!));
        setState(_selected.clear);
        Haptics.drop();
        _say('Imported ${r.zones} zone${r.zones == 1 ? '' : 's'}'
            '${r.warnings.isEmpty ? '' : ' · left out: ${r.warnings.take(3).join('; ')}${r.warnings.length > 3 ? '…' : ''}'}');
      });

  Future<void> _exportSfz(_Zones z) => _run('SFZ export', () async {
        final path = await SamplerFiles.exportPath(z.layer.name.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '_'));
        if (path == null) return;
        final r = await z.state.audioIo.sfzExport(jsonEncode(z.saved.toJson()), path,
            copySamples: true);
        if (!r.ok) throw r.error;
        Haptics.drop();
        _say('Exported ${r.files.length} file${r.files.length == 1 ? '' : 's'} (samples copied beside it)');
      });

  @override
  Widget build(BuildContext context) {
    final z = _zones(context);
    if (z == null) return const SizedBox.shrink();
    final scope = DeviceScope.of(context);
    final s = _working ?? z.saved;
    _selected.removeWhere((i) => i >= s.zones.length);
    final sel = _selected.isEmpty ? null : _selected.first;
    final accent = scope.accent;
    return ListView(key: const ValueKey('sampler-zones'), padding: const EdgeInsets.fromLTRB(8, 8, 8, 32), children: [
      Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        ActionChip(key: const ValueKey('sampler-add'), avatar: const Icon(Icons.library_add_outlined, size: 16),
            label: const Text('Add samples'), onPressed: _busy ? null : () => _addSamples(z)),
        ActionChip(key: const ValueKey('sampler-import-sfz'), avatar: const Icon(Icons.file_open_outlined, size: 16),
            label: const Text('Import SFZ'), onPressed: _busy ? null : () => _importSfz(z)),
        ActionChip(key: const ValueKey('sampler-export-sfz'), avatar: const Icon(Icons.file_upload_outlined, size: 16),
            label: const Text('Export SFZ'), onPressed: _busy || s.zones.isEmpty ? null : () => _exportSfz(z)),
        if (_selected.length > 1)
          ActionChip(key: const ValueKey('sampler-round-robin'), avatar: const Icon(Icons.repeat, size: 16),
              label: Text('Round robin (${_selected.length})'), onPressed: () {
                final next = z.saved..roundRobin(_selected.toList()..sort());
                z.save(next);
                Haptics.drop();
                _say('${_selected.length} zones take turns on each hit');
              }),
        if (_selected.isNotEmpty)
          ActionChip(key: const ValueKey('sampler-delete'), avatar: const Icon(Icons.delete_outline, size: 16, color: Neon.pink),
              label: Text(_selected.length == 1 ? 'Delete zone' : 'Delete ${_selected.length}'), onPressed: () {
                final next = z.saved;
                for (final i in _selected.toList()..sort((a, b) => b.compareTo(a))) {
                  next.zones.removeAt(i);
                }
                z.save(next);
                setState(_selected.clear);
                Haptics.tap();
              }),
        if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      ]),
      const SizedBox(height: 8),
      ZoneMap(
        key: const ValueKey('sampler-zone-map'),
        zones: s,
        selected: _selected,
        accent: accent,
        onSelect: (i, {additive = false}) => setState(() {
          if (i == null) return _selected.clear();
          if (!additive) _selected.clear();
          _selected.contains(i) && additive ? _selected.remove(i) : _selected.add(i);
          Haptics.tap();
        }),
        onDrag: (next) => setState(() => _working = next),
        onDragEnd: () {
          final w = _working;
          _working = null;
          if (w != null) z.save(w);
          Haptics.drop();
        },
      ),
      SamplerKeyboard(
        key: const ValueKey('sampler-keyboard'),
        zones: s,
        accent: accent,
        onNote: (key, on) {
          final id = key + 1000;
          on ? z.state.previewOn(z.layer.id, id, key.toDouble(), 0.8) : z.state.previewOff(id);
        },
        onDropFiles: (key, paths) {
          final next = z.saved;
          final made = next.addFiles(paths, key);
          z.save(next);
          setState(() => _selected..clear()..addAll(made));
          Haptics.drop();
        },
      ),
      if (s.zones.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text(
            'No zones yet: add samples, import an SFZ, or drag audio from Files onto a key.',
            textAlign: TextAlign.center, style: TextStyle(color: Neon.dim))),
      if (sel != null) ...[
        const SizedBox(height: 8),
        ZoneWaveform(key: ValueKey('sampler-wave-$sel'), state: z.state, zone: s.zones[sel], accent: accent,
            onChanged: (zone) {
              final next = z.saved;
              next.zones[sel] = zone;
              z.save(next);
            }),
        ZoneInspector(key: ValueKey('sampler-zone-$sel'), zone: s.zones[sel], accent: accent, onChanged: (zone) {
          final next = z.saved;
          next.zones[sel] = zone..normalize();
          z.save(next);
        }),
      ],
    ]);
  }
}

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

  /// The keys drawn: the zones' span with an octave around it, at least four octaves.
  static (int, int) keySpan(SamplerState z) {
    final (lo, hi) = zoneSpan(z);
    var a = math.max(0, lo - 12), b = math.min(127, hi + 12);
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => widget.onSelect(_hit(d.localPosition, size), additive: widget.selected.length > 1 ||
          HardwareKeyboard.instance.isControlPressed),
      onLongPressStart: (d) {
        final i = _hit(d.localPosition, size);
        if (i != null) widget.onSelect(i, additive: true);
      },
      onPanStart: (d) {
        final i = _hit(d.localPosition, size);
        if (i == null) return;
        final r = _rect(widget.zones.zones[i], size);
        final p = d.localPosition;
        _edge = (p.dx - r.left).abs() < 10 ? _Edge.left : (p.dx - r.right).abs() < 10 ? _Edge.right
            : (p.dy - r.top).abs() < 8 ? _Edge.top : (p.dy - r.bottom).abs() < 8 ? _Edge.bottom : _Edge.body;
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
    );
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
        ..color = on ? Colors.white : hue.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = on ? 1.6 : 1);
      // The root key: a tick at the zone's foot.
      final rx = (z.root - lo + 0.5) * kw;
      if (rx >= r.left && rx <= r.right) {
        canvas.drawLine(Offset(rx, r.bottom - 6), Offset(rx, r.bottom), Paint()..color = Colors.white..strokeWidth = 2);
      }
      if (r.width > 34 && r.height > 14) {
        final tp = TextPainter(text: TextSpan(text: z.seqLength > 1 ? '${z.name} · ${z.seqPosition}/${z.seqLength}' : z.name,
            style: const TextStyle(fontSize: 9, color: Colors.white)), textDirection: TextDirection.ltr, maxLines: 1,
            ellipsis: '…')
          ..layout(maxWidth: r.width - 6);
        tp.paint(canvas, Offset(r.left + 3, r.top + 2));
      }
    }
    final tp = TextPainter(text: TextSpan(text: '${noteName(lo)} · velocity ↑',
        style: const TextStyle(fontSize: 9, color: Neon.dim)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset(4, size.height - tp.height - 2));
  }

  @override
  bool shouldRepaint(covariant _ZoneMapPainter old) => true;
}

// ---------- the keyboard ----------

/// The keys under the map: a press plays the sampler, an audio file dropped on a key makes zones from there up.
class SamplerKeyboard extends StatelessWidget {
  const SamplerKeyboard({super.key, required this.zones, required this.accent, required this.onNote,
      required this.onDropFiles, this.height = 44});
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
  bool shouldRepaint(covariant _KeysPainter old) => true;
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
            inCurve: FadeCurve.linear, outCurve: FadeCurve.linear))),
        if (z.loopEnd > z.loopStart)
          Positioned(left: x(z.loopStart), width: math.max(1, x(z.loopEnd) - x(z.loopStart)), top: 0, bottom: 0,
              child: IgnorePointer(child: ColoredBox(color: Neon.yellow.withValues(alpha: 0.10)))),
        for (final (name, frame, color) in markers)
          Positioned(left: x(frame) - 12, top: 0, bottom: 0, width: 24, child: GestureDetector(
            key: ValueKey('sampler-marker-$name'),
            behavior: HitTestBehavior.opaque,
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
            child: Center(child: Container(width: 2, color: color)))),
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
          width: 150,
          child: Row(children: [
            SizedBox(width: 54, child: Text(label, style: const TextStyle(fontSize: 11, color: Neon.dim))),
            IconButton(key: ValueKey('zone-$key-down'), visualDensity: VisualDensity.compact, iconSize: 16,
                icon: const Icon(Icons.remove), onPressed: () { Haptics.tick(); down(); }),
            Expanded(child: Text(value, textAlign: TextAlign.center, style: Neon.code(size: 11, color: Neon.text))),
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
    ]));
  }
}

// ---------- SOUND ----------

class SamplerSoundPage extends StatelessWidget {
  const SamplerSoundPage({super.key});

  @override
  Widget build(BuildContext context) {
    final inline = DeviceScope.isInline(context);
    final size = inline ? 40.0 : 50.0;
    Widget head(String t) => Padding(padding: const EdgeInsets.fromLTRB(4, 10, 4, 2),
        child: Text(t, style: const TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800)));
    final body = Column(key: const ValueKey('sampler-sound'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      head('LEVEL'),
      KnobRow(const ['gain', 'velocity', 'tune', 'transpose', 'polyphony'], size: size),
      head('ENVELOPE'),
      KnobRow(const ['attack', 'decay', 'sustain', 'release'], size: size),
      head('FILTER'),
      const DeviceChoice('filter'),
      KnobRow(const ['cutoff', 'resonance', 'filter_env', 'filter_key'], size: size),
      if (!inline) KnobRow(const ['filter_attack', 'filter_decay', 'filter_sustain', 'filter_release'], size: size,
          labels: const {'filter_attack': 'Attack', 'filter_decay': 'Decay', 'filter_sustain': 'Sustain',
            'filter_release': 'Release'}),
    ]);
    return inline ? body : ListView(padding: const EdgeInsets.fromLTRB(8, 4, 8, 32), children: [body]);
  }
}
