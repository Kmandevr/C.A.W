// The merged EQ's page (org.caw.eq, 1.0.8): mode cards for Bands, Graphic, DJ and Tilt over that mode's curve on one log grid.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart' show iconCurve;
import '../eq_editor.dart';
import '../filters/eq_pages.dart';
import '../filters/filters_shared.dart';
import 'variant_cards.dart';

/// The EQ: its mode cards (the variant) and the mode's own page under them, each drawing on the same grid. In the
/// FX stack the cards are left out (the hero's caption names the mode).
class EqDevicePage extends StatelessWidget {
  const EqDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final inline = DeviceScope.isInline(context);
    final lead = inline ? const <Widget>[] : const [Padding(padding: EdgeInsets.only(bottom: 8), child: VariantCards(
      key: ValueKey('eq-modes'), icon: eqModeIcon))];
    return switch (variantOf(context)) {
      1 => GraphicEqPage(lead: lead),
      2 => Eq3Page(lead: lead),
      3 => TiltPage(lead: lead),
      _ => EqEditorPage(lead: lead, caption: 'BANDS'),
    };
  }
}

/// Each EQ mode's card icon: Bands a bell and a shelf with their nodes, Graphic bars, DJ three regions, Tilt a slope.
void eqModeIcon(Canvas canvas, Rect r, int mode, Color c) {
  final fill = Paint()..color = c.withValues(alpha: 0.35);
  switch (mode) {
    case 1:
      const gains = [0.2, 0.45, 0.7, 0.5, 0.15, -0.2, -0.4, -0.15, 0.25, 0.55];
      final bw = r.width / gains.length;
      for (var i = 0; i < gains.length; i++) {
        final top = r.center.dy - gains[i] * r.height / 2;
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(r.left + i * bw + 1, math.min(top, r.center.dy),
            r.left + (i + 1) * bw - 1, math.max(top, r.center.dy) + 1), const Radius.circular(1)), Paint()..color = c);
      }
    case 2:
      for (final x in [r.left + r.width / 3, r.left + 2 * r.width / 3]) {
        canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), Paint()..color = c.withValues(alpha: 0.5));
      }
      canvas.drawRect(Rect.fromLTRB(r.left + r.width / 3, r.center.dy - r.height * 0.3, r.left + 2 * r.width / 3, r.bottom), fill);
      iconCurve(canvas, r, c, (x) => x < -1 / 3 ? 0.3 : (x < 1 / 3 ? -0.5 : 0.15));
    case 3:
      iconCurve(canvas, r, c, (x) => 0.55 * (2 / (1 + math.exp(-x * 4)) - 1));
      canvas.drawCircle(r.center, 3, Paint()..color = c);
    default:
      double db(double x) {
        final hz = 1000 * math.pow(2, x * 4.5).toDouble();
        return toDb(tiltResponse(hz, tilt: -6, freq: 250, q: 0.7).abs) / 12 +
            0.6 * math.exp(-math.pow((x - 0.35) * 4, 2).toDouble());
      }
      iconCurve(canvas, r, c, db);
      for (final x in [-0.62, 0.35]) {
        canvas.drawCircle(Offset(r.left + (x + 1) / 2 * r.width, r.center.dy - db(x).clamp(-1.0, 1.0) * r.height / 2), 2.6,
            Paint()..color = Neon.text);
      }
  }
}
