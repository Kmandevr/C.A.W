// The instruments' bird motifs, each drawn into its device's own picture (never laid over it as decoration): the woodpecker at a strike point (Timber, Woodpecker) and the bittern standing on Bittern's organ case.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';

/// A small woodpecker (Timber's and Woodpecker's one motif) perched with its feet at [feet], [size] tall, facing left
/// (its beak at the strike point). [beak] 0..1 tilts it from upright to pecking (the hammer's or mallet's hardness).
void paintWoodpecker(Canvas canvas, Offset feet, double size, Color color, {double beak = 0.4}) {
  final h = size.clamp(10.0, 30.0);
  canvas.save();
  canvas.translate(feet.dx, feet.dy);
  final body = Paint()..color = Color.lerp(Neon.ink, Neon.bg, 0.15)!;
  final edge = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  // Tail prop and body, leaning against the post.
  final tail = Path()
    ..moveTo(h * 0.18, -h * 0.05)
    ..lineTo(h * 0.42, h * 0.12)
    ..lineTo(h * 0.26, -h * 0.2)
    ..close();
  canvas.drawPath(tail, body);
  canvas.rotate(-0.15 - beak * 0.25);
  final torso = Rect.fromCenter(center: Offset(h * 0.12, -h * 0.42), width: h * 0.42, height: h * 0.7);
  canvas.drawOval(torso, body);
  canvas.drawOval(torso, edge);
  // The head, its red crest and the beak (pointing left, down as it pecks).
  final head = Offset(h * 0.02, -h * 0.82);
  canvas.drawCircle(head, h * 0.17, body);
  canvas.drawCircle(head, h * 0.17, edge);
  canvas.drawPath(Path()..addArc(Rect.fromCircle(center: head, radius: h * 0.17), -math.pi * 0.95, math.pi * 0.7),
      Paint()..color = Neon.pink..style = PaintingStyle.stroke..strokeWidth = h * 0.09);
  final beakPath = Path()
    ..moveTo(head.dx - h * 0.12, head.dy - h * 0.05)
    ..lineTo(head.dx - h * 0.46, head.dy + h * 0.02 + beak * h * 0.06)
    ..lineTo(head.dx - h * 0.12, head.dy + h * 0.06)
    ..close();
  canvas.drawPath(beakPath, Paint()..color = color);
  canvas.drawCircle(head + Offset(-h * 0.05, -h * 0.03), h * 0.035, Paint()..color = color);
  canvas.restore();
}

/// Bittern's one motif: a bittern standing with its feet at [feet], [size] tall, its bill pointing up (as a bittern
/// hides in the reeds), drawn as the finial on the organ case's top. [boom] 0..1 puffs its throat (the organ
/// sounding).
void paintBittern(Canvas canvas, Offset feet, double size, Color color, {double boom = 0}) {
  final h = size.clamp(12.0, 34.0);
  canvas.save();
  canvas.translate(feet.dx, feet.dy);
  final body = Paint()..color = Color.lerp(Neon.ink, Neon.bg, 0.2)!;
  final edge = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  // Legs, then the long body held upright and the neck straight up into the bill.
  canvas.drawLine(const Offset(-1.5, 0), Offset(-1.5, -h * 0.2), edge);
  canvas.drawLine(const Offset(1.5, 0), Offset(1.5, -h * 0.2), edge);
  final torso = Path()
    ..moveTo(-h * 0.16, -h * 0.2)
    ..quadraticBezierTo(-h * 0.24, -h * 0.5, -h * 0.08, -h * 0.78)
    ..lineTo(h * 0.06, -h * 0.78)
    ..quadraticBezierTo(h * (0.2 + 0.06 * boom), -h * 0.5, h * 0.14, -h * 0.2)
    ..close();
  canvas.drawPath(torso, body);
  canvas.drawPath(torso, edge);
  // The streaks down its breast.
  for (var i = 0; i < 3; i++) {
    final x = -h * 0.06 + i * h * 0.06;
    canvas.drawLine(Offset(x, -h * 0.66), Offset(x, -h * 0.32), Paint()
      ..color = color.withValues(alpha: 0.45)
      ..strokeWidth = 0.8);
  }
  canvas.drawCircle(Offset(-h * 0.01, -h * 0.8), h * 0.025 + 0.6, Paint()..color = color);
  final bill = Path()
    ..moveTo(-h * 0.05, -h * 0.82)
    ..lineTo(h * 0.0, -h * 1.0)
    ..lineTo(h * 0.04, -h * 0.82)
    ..close();
  canvas.drawPath(bill, Paint()..color = color);
  canvas.restore();
}
