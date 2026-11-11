// The theme editor's live preview: a mini Arrange, a device (knob and meters) and a piano roll drawn in the theme
// being edited, with its corners, clip look and glow.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'arrange/clip_look.dart';
import 'theme.dart';
import 'tokens.dart';

/// The three small screens side by side (stacked in two rows on a phone), drawn from [theme]'s palette.
class ThemePreview extends StatelessWidget {
  const ThemePreview({super.key, required this.theme});
  final CawTheme theme;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 560;
        Widget pane(String key, CustomPainter p, {double height = 112}) => Container(
              key: ValueKey('theme-preview-$key'),
              height: height,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: theme['bg'],
                borderRadius: BorderRadius.circular(Radii.m),
                border: Border.all(color: theme['line']),
              ),
              child: CustomPaint(painter: p, size: Size.infinite),
            );
        final arrange = pane('arrange', _ArrangePainter(theme, ClipLook.corner, ClipLook.fill, Radii.scale));
        final device = pane('device', _DevicePainter(theme, Radii.scale));
        final roll = pane('roll', _RollPainter(theme, Radii.scale));
        return wide
            ? Row(children: [
                Expanded(flex: 5, child: arrange),
                const SizedBox(width: 8),
                Expanded(flex: 3, child: device),
                const SizedBox(width: 8),
                Expanded(flex: 4, child: roll),
              ])
            : Column(children: [
                arrange,
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: device),
                  const SizedBox(width: 8),
                  Expanded(child: roll),
                ]),
              ]);
      });
}

TextPainter _label(String text, Color color, double size, {FontWeight weight = FontWeight.w700}) =>
    TextPainter(text: TextSpan(text: text, style: Neon.code(size: size, color: color).copyWith(fontWeight: weight, height: 1)),
        textDirection: TextDirection.ltr, maxLines: 1)
      ..layout();

/// A header column, three tracks with clips (the theme's clip corner and fill, notes inside) and a playhead.
class _ArrangePainter extends CustomPainter {
  _ArrangePainter(this.t, this.corner, this.fill, this.roundness);
  final CawTheme t;
  final ClipCorner corner;
  final ClipFill fill;
  final double roundness;

  @override
  void paint(Canvas canvas, Size size) {
    const head = 64.0, top = 14.0;
    final rowH = (size.height - top - 6) / 3;
    canvas.drawRect(Rect.fromLTWH(0, 0, head, size.height), Paint()..color = t['panel']);
    canvas.drawLine(Offset(head, 0), Offset(head, size.height), Paint()..color = t['line']);
    for (var b = 0; b < 8; b++) {
      final x = head + 6 + b * (size.width - head - 12) / 8;
      canvas.drawLine(Offset(x, top), Offset(x, size.height), Paint()..color = t['ink'].withValues(alpha: b % 4 == 0 ? 0.10 : 0.05));
      if (b % 4 == 0) _label('${b ~/ 4 + 1}', t['dim'], 8).paint(canvas, Offset(x + 2, 2));
    }
    const names = ['Drums', 'Bass', 'Keys'];
    final clips = [
      [(0.0, 0.48), (0.52, 0.96)],
      [(0.0, 0.96)],
      [(0.24, 0.72)],
    ];
    final span = size.width - head - 12;
    for (var i = 0; i < 3; i++) {
      final y = top + i * rowH;
      final c = t['layer${i + 1}'];
      canvas.drawRect(Rect.fromLTWH(0, y + 2, 3, rowH - 4), Paint()..color = c);
      _label(names[i], t['text'], 9).paint(canvas, Offset(8, y + rowH / 2 - 6));
      for (final (a, b) in clips[i]) {
        final r = Rect.fromLTRB(head + 6 + a * span, y + 3, head + 6 + b * span, y + rowH - 3);
        final radius = switch (corner) {
          ClipCorner.square => 0.0,
          ClipCorner.rounded => 5 * roundness,
          ClipCorner.round => r.height / 2,
        };
        final rr = RRect.fromRectAndRadius(r, Radius.circular(radius));
        final selected = i == 1;
        switch (fill) {
          case ClipFill.solid:
            canvas.drawRRect(rr, Paint()..color = c.withValues(alpha: selected ? .5 : .32));
          case ClipFill.gradient:
            canvas.drawRRect(rr, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: Neon.ramp([c.withValues(alpha: .40), c.withValues(alpha: .12)])).createShader(r));
          case ClipFill.standard:
            canvas.drawRRect(rr, Paint()..color = c.withValues(alpha: selected ? .42 : .23));
          case ClipFill.outline:
            break;
        }
        canvas.drawRRect(rr, Paint()
          ..color = selected ? c : c.withValues(alpha: .7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 1.6 : 1);
        // Notes in the clip.
        final note = Paint()..color = Color.lerp(c, t['ink'], 0.45)!.withValues(alpha: 0.9);
        for (var k = 0; k < 6; k++) {
          final nx = r.left + 6 + k * (r.width - 12) / 6;
          final ny = r.top + 4 + ((k * 37 + i * 11) % 7) / 7 * (r.height - 10);
          canvas.drawRect(Rect.fromLTWH(nx, ny, (r.width - 12) / 8, 2), note);
        }
      }
    }
    final px = head + 6 + span * 0.62;
    canvas.drawLine(Offset(px, 0), Offset(px, size.height), Paint()
      ..color = t['green']
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_ArrangePainter o) =>
      o.t != t || o.corner != corner || o.fill != fill || o.roundness != roundness;
}

/// A device: a knob (its cap squaring off with low roundness), a value and a stereo meter in the theme's colours.
class _DevicePainter extends CustomPainter {
  _DevicePainter(this.t, this.roundness);
  final CawTheme t;
  final double roundness;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width * 0.38, size.height * 0.48);
    final r = math.min(size.height * 0.32, size.width * 0.26);
    const start = math.pi * 0.75, sweep = math.pi * 1.5;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawArc(rect, start, sweep, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = t['line']);
    final accent = t['blue'];
    if (t.glow && !t.flat) {
      canvas.drawArc(rect, start, sweep * 0.62, false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..color = accent.withValues(alpha: t.light ? 0.12 : 0.2));
    }
    canvas.drawArc(rect, start, sweep * 0.62, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = accent);
    final cap = Rect.fromCircle(center: c, radius: r - 5);
    final capPaint = Paint()..color = t['panelHi'];
    if (roundness >= 1) {
      canvas.drawCircle(c, r - 5, capPaint);
    } else {
      canvas.drawRRect(RRect.fromRectAndRadius(cap, Radius.circular((r - 5) * (0.25 + 0.75 * roundness))), capPaint);
    }
    final a = start + sweep * 0.62;
    canvas.drawLine(c + Offset(math.cos(a), math.sin(a)) * (r * 0.3), c + Offset(math.cos(a), math.sin(a)) * (r - 6),
        Paint()
          ..color = t['text']
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round);
    final v = _label('-4.2 dB', accent, 9);
    v.paint(canvas, Offset(c.dx - v.width / 2, c.dy + r + 2));
    // A stereo meter: the track colour, the warning accent near the top, the danger accent at 0 dB.
    final mx = size.width * 0.78, mh = size.height - 20;
    for (var ch = 0; ch < 2; ch++) {
      final x = mx + ch * 9;
      final level = ch == 0 ? 0.78 : 0.95;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, 10, 6, mh), Radius.circular(2 * roundness)),
          Paint()..color = t['panelHi']);
      final top = 10 + mh * (1 - level);
      canvas.drawRect(Rect.fromLTRB(x, math.max(top, 10 + mh * 0.25), x + 6, 10 + mh), Paint()..color = t['green']);
      if (level > 0.75) canvas.drawRect(Rect.fromLTRB(x, top, x + 6, 10 + mh * 0.25), Paint()..color = t['yellow']);
      if (level > 0.9) canvas.drawRect(Rect.fromLTRB(x, 10, x + 6, 14), Paint()..color = t['pink']);
    }
  }

  @override
  bool shouldRepaint(_DevicePainter o) => o.t != t || o.roundness != roundness;
}

/// A piano roll: keys, a grid and a few notes (one selected), with velocity bars below.
class _RollPainter extends CustomPainter {
  _RollPainter(this.t, this.roundness);
  final CawTheme t;
  final double roundness;

  @override
  void paint(Canvas canvas, Size size) {
    const keys = 14.0, rows = 10;
    final gridH = size.height - 22;
    final rowH = gridH / rows;
    for (var i = 0; i < rows; i++) {
      final black = {1, 3, 6, 8}.contains(i % 12);
      canvas.drawRect(Rect.fromLTWH(0, i * rowH, keys, rowH - 0.5),
          Paint()..color = black ? t['panel'] : Color.lerp(t['panelHi'], t['ink'], t.light ? 0.0 : 0.35)!);
      if (black) canvas.drawRect(Rect.fromLTWH(keys, i * rowH, size.width - keys, rowH), Paint()..color = t['panel']);
    }
    for (var b = 0; b <= 8; b++) {
      final x = keys + b * (size.width - keys) / 8;
      canvas.drawLine(Offset(x, 0), Offset(x, gridH), Paint()..color = t['ink'].withValues(alpha: b % 4 == 0 ? 0.12 : 0.05));
    }
    final notes = [(0, 7, 2), (2, 5, 1), (3, 4, 2), (5, 2, 1), (6, 4, 2)];
    final step = (size.width - keys) / 8;
    for (final (k, (at, row, len)) in notes.indexed) {
      final r = Rect.fromLTWH(keys + at * step + 1, row * rowH + 1, len * step - 2, rowH - 2);
      final selected = k == 2;
      final c = selected ? t['yellow'] : t['green'];
      canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(2 * roundness)), Paint()..color = c.withValues(alpha: 0.85));
      if (selected) {
        canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(2 * roundness)), Paint()
          ..color = t['ink']
          ..style = PaintingStyle.stroke);
      }
      final vh = 14 * (0.5 + 0.1 * ((k * 3) % 5));
      canvas.drawRect(Rect.fromLTWH(r.left, size.height - 2 - vh, 3, vh), Paint()..color = c);
    }
  }

  @override
  bool shouldRepaint(_RollPainter o) => o.t != t || o.roundness != roundness;
}
