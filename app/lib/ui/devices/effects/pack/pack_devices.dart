// The AutoStacc beta pack's device pages (1.1.0): Murmur (grains drifting over the recording), Peck (a slice grid lighting up), Bend (a bending grid) and Molt (a frozen spectrum you paint); their browser entries and the toy-like pieces they share.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_registry.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/device_style.dart';
import '../../kit/hero.dart';
import '../../kit/repaint.dart';
import '../creative/creative_catalog.dart' show FxCatalogEntry;
import '../creative/creative_common.dart' show HoldPad, LabelledChoice, valueOr;
import '../dyn_drive/common.dart' show chipWrap;
import '../modes_kit.dart' show valueText;
import '../space/space_devices.dart' show mergedPage;
import '../voice/voice_devices.dart' show DragHero, rawAt;
import 'pack_bend_iris.dart';

const murmurId = 'org.caw.pack.granular', peckId = 'org.caw.pack.glitch', bendId = 'org.caw.pack.warp',
    irisId = 'org.caw.pack.spectral';

/// The effect browser's "AutoStacc pack" tab.
const packCatalog = <FxCatalogEntry>[
  FxCatalogEntry(murmurId, 'Murmur', 'AutoStacc pack',
      'Granular texture: clouds of grains from the last seconds, sprayed, pitched, frozen and scanned.', Icons.grain),
  FxCatalogEntry(peckId, 'Peck', 'AutoStacc pack',
      'Glitch on the grid: seeded repeats, stutters, reverses, gates and pitch jumps per slice.', Icons.grid_view),
  FxCatalogEntry(bendId, 'Bend', 'AutoStacc pack',
      'Warp: a drawn curve bends time or speed through each cycle, from gentle wow to tape spins.', Icons.waves),
  FxCatalogEntry(irisId, 'Molt', 'AutoStacc pack',
      'Spectral: freeze a spectrum and paint it, blur, shift and gate the partials.', Icons.blur_circular),
];

DeviceEditorEntry _page(String id, String label, IconData icon, Widget Function() page) =>
    DeviceEditorEntry((_) => [DeviceSection(id, label, icon, (_) => page())], family: DeviceFamily.pack);

/// The pack's pages by id (effect_editors.dart merges them in).
final Map<String, DeviceEditorEntry> packEditors = {
  murmurId: _page('murmur', 'GRAINS', Icons.grain, () => const MurmurPage()),
  peckId: _page('peck', 'SLICES', Icons.grid_view, () => const PeckPage()),
  bendId: _page('bend', 'BEND', Icons.waves, () => const BendPage()),
  irisId: _page('iris', 'SPECTRUM', Icons.blur_circular, () => const IrisPage()),
};

/// The pack's toy-like canvas: a rounded, softly lit tray in the device's colours, with chunky dots for the corners
/// (behind a pack device's centrepiece).
void paintToyTray(Canvas canvas, Size size, Color color, Color second) {
  final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(18));
  canvas.drawRRect(r, Paint()
    ..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [color.withValues(alpha: 0.10), second.withValues(alpha: 0.06)]).createShader(Offset.zero & size));
  for (final c in [const Offset(10, 10), Offset(size.width - 10, 10), Offset(10, size.height - 10),
      Offset(size.width - 10, size.height - 10)]) {
    canvas.drawCircle(c, 3, Paint()..color = Neon.ink.withValues(alpha: 0.12));
  }
}

/// A chunky rounded cell (a slice, a band): [fill] 0..1 lit in [color].
void paintToyCell(Canvas canvas, Rect r, Color color, double fill, {bool now = false}) {
  final m = math.min(r.width, r.height);
  final rr = RRect.fromRectAndRadius(r, Radius.circular(m * 0.28));
  canvas.drawRRect(rr, Paint()..color = Color.lerp(Neon.panelHi, color, 0.12 + 0.7 * fill)!);
  if (fill > 0.05 && m > 8) {
    // A toy's shine along the top.
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(r.left + m * 0.18, r.top + m * 0.12, r.width - m * 0.36, m * 0.22),
        Radius.circular(m * 0.11)), Paint()..color = Colors.white.withValues(alpha: 0.14 * fill));
  }
  canvas.drawRRect(rr, Paint()
    ..color = now ? Neon.text : color.withValues(alpha: 0.5 + 0.5 * fill)
    ..style = PaintingStyle.stroke
    ..strokeWidth = now ? 2.6 : 1.4);
  if (now) canvas.drawRRect(rr.inflate(4), Paint()..color = color.withValues(alpha: 0.22));
}

// ---------------------------------------------------------------------------------------------------------------
// Murmur

/// Murmur: the recording ring as a strip (oldest left, newest right) with the grains drifting over it (each where
/// it reads, up and down by its pitch, sized by its window; the engine's while it plays, else a cloud ≈ from the
/// knobs). Drag sideways for Position, up and down for Size; Freeze holds the ring.
class MurmurPage extends StatelessWidget {
  const MurmurPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return mergedPage(context, 'murmur',
      hero: HeroCanvas(
        color: scope.accent,
        height: 220,
        caption: 'GRAINS',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final raw = f?.raw;
          if ((raw?.length ?? 0) < 43) return Text('≈ ${valueText(scope, 'size')} · ${valueText(scope, 'density')}');
          return Text('${rawAt(raw, 2).round()} grains${rawAt(raw, 5) > 0.5 ? ' · frozen' : ''}'
              '${rawAt(raw, 4) > 0 ? ' · ${rawAt(raw, 4).round()} dropped' : ''}');
        }),
        child: DragHero(heroKey: 'murmur-hero', x: 'position', xTravel: -1, y: 'size', painter: (context, raw, active) {
          final s = DeviceScope.of(context);
          return MurmurPainter(raw: (raw?.length ?? 0) >= 43 ? raw : null, position: t.value('position'),
              spray: valueOr(s, 'spray', 0), size: t.value('size'), pitch: t.value('pitch'), spread: valueOr(s, 'spread', 0),
              buffer: valueOr(s, 'buffer', 2), frozen: t.value('freeze') >= 0.5, color: s.accent, second: s.secondary,
              active: active);
        }),
      ),
      rows: [chipWrap([const DeviceToggle('freeze', label: 'Freeze', icon: Icons.ac_unit)]), const LabelledChoice('WINDOW', 'window')],
      knobs: KnobRow(const ['spray', 'density', 'pitch', 'spread', 'reverse', 'mix'], size: 48),
      more: const ParamGrid(only: ['buffer', 'sync', 'jitter', 'scale', 'pan', 'glide', 'width', 'feedback', 'scan',
        'seed', 'output']),
    );
  }
}

class MurmurPainter extends CustomPainter {
  MurmurPainter({required this.raw, required this.position, required this.spray, required this.size, required this.pitch,
    required this.spread, required this.buffer, required this.frozen, required this.color, required this.second,
    required this.active});
  final List<double>? raw;
  final double position, spray, size, pitch, spread, buffer;
  final bool frozen, active;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size sz) {
    paintToyTray(canvas, sz, color, second);
    final r = Rect.fromLTRB(16, 26, sz.width - 16, sz.height - 22);
    final mid = r.center.dy;
    // The ring: 32 rounded peaks (the engine's overview, oldest first), else a soft hum.
    final w = r.width / 32;
    for (var i = 0; i < 32; i++) {
      final peak = raw != null ? rawAt(raw, 11 + i).clamp(0.0, 1.0) : 0.25 + 0.15 * math.sin(i * 0.9);
      final h = math.max(3.0, peak * r.height * 0.42);
      final cell = Rect.fromCenter(center: Offset(r.left + w * (i + 0.5), mid), width: w * 0.62, height: h * 2);
      canvas.drawRRect(RRect.fromRectAndRadius(cell, Radius.circular(w * 0.31)),
          Paint()..color = (frozen ? second : Neon.ink).withValues(alpha: frozen ? 0.35 : 0.13));
    }
    double xOf(double where) => r.left + r.width * (1 - where.clamp(0.0, 1.0));
    double yOf(double st) => mid - (st / 24).clamp(-1.0, 1.0) * r.height * 0.46;
    // Where grains start: Position, Spray's reach around it.
    final at = xOf(position);
    final reach = (spray / 1000 / math.max(0.5, buffer)) * r.width;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(at - reach - 2, r.top, at + 2, r.bottom), const Radius.circular(10)),
        Paint()..color = color.withValues(alpha: active ? 0.16 : 0.08));
    final grains = <(double, double, double, double)>[];
    if (raw != null) {
      final n = rawAt(raw, 10).round().clamp(0, 128);
      for (var g = 0; g < n && 43 + 4 * g + 3 < raw!.length; g++) {
        grains.add((rawAt(raw, 43 + 4 * g), rawAt(raw, 44 + 4 * g), rawAt(raw, 45 + 4 * g), rawAt(raw, 46 + 4 * g)));
      }
    } else {
      // A seeded cloud ≈: spread around Position by Spray, pitched by Pitch ± Spread.
      final rnd = math.Random(7);
      for (var g = 0; g < 14; g++) {
        final where = position + rnd.nextDouble() * spray / 1000 / math.max(0.5, buffer) + g * 0.004;
        grains.add((where, (g * 0.37) % 1, rnd.nextDouble() * 2 - 1, pitch + (rnd.nextDouble() * 2 - 1) * spread));
      }
    }
    final radius = (4 + 10 * math.sqrt((size / 500).clamp(0.0, 1.0))).toDouble();
    for (final (where, phase, pan, st) in grains) {
      final env = math.sin(math.pi * phase.clamp(0.0, 1.0));
      final c = Color.lerp(color, second, (pan + 1) / 2)!;
      final o = Offset(xOf(where), yOf(st));
      canvas.drawCircle(o, radius * (0.5 + 0.5 * env) + 5, Paint()..color = c.withValues(alpha: 0.12 * env + 0.04));
      canvas.drawCircle(o, radius * (0.5 + 0.5 * env), Paint()..color = c.withValues(alpha: 0.35 + 0.55 * env));
      canvas.drawCircle(o.translate(-radius * 0.2, -radius * 0.25), radius * 0.22 * (0.5 + 0.5 * env),
          Paint()..color = Colors.white.withValues(alpha: 0.35 * env));
      if (st < 0) paintLabel(canvas, '◂', o.translate(0, radius + 6), c, size: 7, align: 0);
    }
    paintHandle(canvas, Offset(at, r.bottom + 9), color, active: active, r: 5);
    paintLabel(canvas, 'OLD', Offset(r.left, sz.height - 8), Neon.dim, size: 7, weight: FontWeight.w800);
    paintLabel(canvas, 'NOW', Offset(r.right, sz.height - 8), Neon.dim, size: 7, align: 1, weight: FontWeight.w800);
    if (raw == null) paintLabel(canvas, '≈', Offset(r.left, r.top - 10), Neon.dim, size: 9);
  }

  @override
  bool shouldRepaint(covariant MurmurPainter o) => paintInputsChanged(
      [...?o.raw, o.position, o.spray, o.size, o.pitch, o.spread, o.buffer, o.frozen, o.color, o.second, o.active],
      [...?raw, position, spray, size, pitch, spread, buffer, frozen, color, second, active]);
}

// ---------------------------------------------------------------------------------------------------------------
// Peck

/// Each action's name and colour (display: 0 through, 1 repeat, 2 stutter, 3 reverse, 4 gate, 5 pitch).
const peckActions = ['·', 'REP', 'STUT', 'REV', 'GATE', 'PITCH'];
Color peckColor(int action, Color accent) => switch (action) {
      1 => Neon.blue,
      2 => Neon.yellow,
      3 => Neon.violet,
      4 => Neon.layers[6],
      5 => accent,
      _ => Neon.dim,
    };

/// Peck: the bar's 16 slices as a grid of chunky cells, each in its action's colour (the engine's plans, played
/// and to come), the slice playing lit; drag up and down for Chaos, sideways to roll another Seed. Hold repeats.
class PeckPage extends StatelessWidget {
  const PeckPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return mergedPage(context, 'peck',
      hero: HeroCanvas(
        color: scope.accent,
        height: 210,
        caption: 'SLICES',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final raw = f?.raw;
          if ((raw?.length ?? 0) < 40) return Text('≈ ${(t.value('chaos') * 100).round()} % chaos');
          final a = rawAt(raw, 3).round().clamp(0, 5);
          return Text('slice ${rawAt(raw, 2).round() + 1} · ${a == 0 ? 'through' : peckActions[a]}'
              '${rawAt(raw, 6) > 0.5 ? ' · held' : ''}');
        }),
        child: DragHero(heroKey: 'peck-hero', x: 'seed', xTravel: 0.05, y: 'chaos', painter: (context, raw, active) {
          final s = DeviceScope.of(context);
          return PeckPainter(raw: (raw?.length ?? 0) >= 40 ? raw : null, chaos: s.target.value('chaos'),
              seed: s.target.value('seed'), color: s.accent, second: s.secondary, active: active);
        }),
      ),
      rows: [
        const Padding(padding: EdgeInsets.only(bottom: 4),
            child: HoldPad('hold', label: 'HOLD TO REPEAT', held: 'HOLDING', icon: Icons.pan_tool_alt_outlined, height: 48)),
        const LabelledChoice('GRID', 'grid'),
      ],
      knobs: KnobRow(const ['chaos', 'repeat', 'stutter', 'reverse', 'gate', 'pitch'], size: 46),
      more: const ParamGrid(only: ['stutters', 'range', 'seed', 'smooth', 'mix', 'output']),
    );
  }
}

class PeckPainter extends CustomPainter {
  PeckPainter({required this.raw, required this.chaos, required this.seed, required this.color, required this.second,
    required this.active});
  final List<double>? raw;
  final double chaos, seed;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    paintToyTray(canvas, size, color, second);
    final r = Rect.fromLTRB(14, 24, size.width - 14, size.height - 22);
    final cols = r.width / r.height > 3 ? 16 : (r.width / r.height > 1.6 ? 8 : 4);
    final rows = 16 ~/ cols;
    final cw = r.width / cols, ch = r.height / rows;
    final now = raw == null ? -1 : rawAt(raw, 2).round();
    final progress = rawAt(raw, 4).clamp(0.0, 1.0);
    // Without the engine's plans: a pattern ≈ as dense as Chaos, seeded by Seed (not the engine's rolls).
    final rnd = math.Random(seed.round());
    for (var i = 0; i < 16; i++) {
      final a = raw != null
          ? rawAt(raw, 8 + i).round().clamp(0, 5)
          : (rnd.nextDouble() < chaos ? 1 + rnd.nextInt(5) : 0);
      final cell = Rect.fromLTWH(r.left + cw * (i % cols), r.top + ch * (i ~/ cols), cw, ch).deflate(math.min(cw, ch) * 0.08);
      final c = peckColor(a, color);
      paintToyCell(canvas, cell, c, a == 0 ? 0.05 : (i == now ? 1.0 : 0.55), now: i == now);
      if (i == now) {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(cell.left, cell.bottom - 4, cell.width * progress, 4),
            const Radius.circular(2)), Paint()..color = Neon.text.withValues(alpha: 0.8));
      }
      if (cell.width > 26) {
        paintLabel(canvas, a == 0 ? '${i + 1}' : peckActions[a], cell.center, a == 0 ? Neon.dim : Neon.text,
            size: cell.width > 44 ? 9 : 7, align: 0, weight: FontWeight.w800);
      }
    }
    // Chaos as a fill line on the left edge.
    final y = r.bottom - r.height * chaos.clamp(0.0, 1.0);
    canvas.drawLine(Offset(6, r.bottom), Offset(6, y), Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round);
    paintLabel(canvas, 'seed ${seed.round()}', Offset(r.right, size.height - 9), Neon.dim, size: 7.5, align: 1);
    if (raw == null) paintLabel(canvas, '≈', Offset(r.left, r.top - 10), Neon.dim, size: 9);
    if (active) {
      canvas.drawRRect(RRect.fromRectAndRadius(r.inflate(4), const Radius.circular(14)),
          Paint()..color = color.withValues(alpha: 0.4)..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(covariant PeckPainter o) => paintInputsChanged(
      [...?o.raw, o.chaos, o.seed, o.color, o.second, o.active], [...?raw, chaos, seed, color, second, active]);
}
