// The fx-space effects' plugin UIs by id (Space, Modulation, Utility) and the pieces their pages share: a meter bar and a hero builder.
import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_registry.dart';
import '../../device_scope.dart';
import '../../kit/device_style.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';
import 'space_fx_mod.dart';
import 'space_fx_reverb.dart';
import 'space_fx_stereo.dart';

/// Each fx-space effect's family (its colours and badge).
const fxSpaceFamilies = <String, DeviceFamily>{
  'org.caw.convolver': DeviceFamily.space,
  'org.caw.shimmer': DeviceFamily.space,
  'org.caw.haas': DeviceFamily.space,
  'org.caw.ensemble': DeviceFamily.modulation,
  'org.caw.doubler': DeviceFamily.modulation,
  'org.caw.vibrato': DeviceFamily.modulation,
  'org.caw.tremolo': DeviceFamily.modulation,
  'org.caw.autopan': DeviceFamily.modulation,
  'org.caw.rotary': DeviceFamily.modulation,
  'org.caw.imager': DeviceFamily.utility,
  'org.caw.channelmixer': DeviceFamily.utility,
};

/// The icon each shows in the FX stack and the browser.
const fxSpaceIcons = <String, IconData>{
  'org.caw.convolver': Icons.account_balance_outlined,
  'org.caw.shimmer': Icons.auto_awesome,
  'org.caw.haas': Icons.call_split,
  'org.caw.ensemble': Icons.groups_2_outlined,
  'org.caw.doubler': Icons.content_copy_outlined,
  'org.caw.vibrato': Icons.graphic_eq,
  'org.caw.tremolo': Icons.show_chart,
  'org.caw.autopan': Icons.swap_horiz,
  'org.caw.rotary': Icons.cyclone,
  'org.caw.imager': Icons.surround_sound_outlined,
  'org.caw.channelmixer': Icons.grid_4x4,
};

DeviceEditorEntry _page(String id, String key, String label, Widget Function() page) =>
    singlePage(key, label, fxSpaceIcons[id]!, fxSpaceFamilies[id]!, page);

/// The plugin UI of each fx-space effect, by id.
final Map<String, DeviceEditorEntry> fxSpaceEditors = {
  'org.caw.convolver': _page('org.caw.convolver', 'convolver', 'CONVOLVE', () => const ConvolverPage()),
  'org.caw.shimmer': _page('org.caw.shimmer', 'shimmer', 'SHIMMER', () => const ShimmerPage()),
  'org.caw.haas': _page('org.caw.haas', 'haas', 'HAAS', () => const HaasPage()),
  'org.caw.ensemble': _page('org.caw.ensemble', 'ensemble', 'ENSEMBLE', () => const EnsemblePage()),
  'org.caw.doubler': _page('org.caw.doubler', 'doubler', 'DOUBLER', () => const DoublerPage()),
  'org.caw.vibrato': _page('org.caw.vibrato', 'vibrato', 'VIBRATO', () => const VibratoPage()),
  'org.caw.tremolo': _page('org.caw.tremolo', 'tremolo', 'TREMOLO', () => const TremoloPage(pan: false)),
  'org.caw.autopan': _page('org.caw.autopan', 'autopan', 'PAN', () => const TremoloPage(pan: true)),
  'org.caw.rotary': _page('org.caw.rotary', 'rotary', 'ROTARY', () => const RotaryPage()),
  'org.caw.imager': _page('org.caw.imager', 'imager', 'IMAGER', () => const ImagerPage()),
  'org.caw.channelmixer': _page('org.caw.channelmixer', 'mixer', 'MATRIX', () => const ChannelMixerPage()),
};

/// A small caption over a row of controls.
Widget spaceLabel(String text) => Padding(padding: const EdgeInsets.only(right: 8), child: Text(text,
    style: const TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)));

/// A labelled row: [label], then [child] taking the rest.
Widget spaceRow(String label, Widget child) => Padding(padding: const EdgeInsets.only(top: 6),
    child: Row(children: [spaceLabel(label), Flexible(child: child)]));

/// A horizontal meter of [value] between [lo] and [hi] (null: no signal), the centre marked when [centred]:
/// a correlation (−1..1), a balance, a mono loss in dB.
class SpaceBar extends StatelessWidget {
  const SpaceBar({super.key, required this.label, required this.value, this.lo = -1, this.hi = 1, this.centred = true,
    this.text});
  final String label;
  final double? value;
  final double lo, hi;
  final bool centred;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final c = DeviceScope.of(context).accent;
    return Semantics(label: label, value: value?.toStringAsFixed(2) ?? 'no signal', child: SizedBox(height: 24, child: Row(children: [
      SizedBox(width: 74, child: Text(label, style: const TextStyle(fontSize: 9, letterSpacing: 1, fontWeight: FontWeight.w800, color: Neon.dim))),
      Expanded(child: CustomPaint(size: const Size.fromHeight(10), painter: _BarPainter(value, lo, hi, centred, c))),
      SizedBox(width: 52, child: Text(text ?? (value == null ? '—' : value!.toStringAsFixed(2)), textAlign: TextAlign.right,
          style: Neon.code(size: 10, color: Neon.text))),
    ])));
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.v, this.lo, this.hi, this.centred, this.color);
  final double? v;
  final double lo, hi;
  final bool centred;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(0, size.height / 2 - 3, size.width, 6), const Radius.circular(3));
    canvas.drawRRect(r, Paint()..color = Neon.ink.withValues(alpha: 0.07));
    final x0 = centred ? size.width / 2 : 0.0;
    if (centred) canvas.drawLine(Offset(x0, 0), Offset(x0, size.height), Paint()..color = Neon.ink.withAlpha(0x3D));
    if (v case final x?) {
      final px = ((x - lo) / (hi - lo)).clamp(0.0, 1.0) * size.width;
      final bad = centred ? x < 0 : false;
      final c = bad ? Neon.pink : color;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(px < x0 ? px : x0, size.height / 2 - 3, px < x0 ? x0 : px,
          size.height / 2 + 3), const Radius.circular(3)), Paint()..color = c.withValues(alpha: 0.6));
      canvas.drawCircle(Offset(px, size.height / 2), 4, Paint()..color = c);
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter o) => o.v != v || o.color != color;
}

/// A hero canvas whose painting moves: the newest display frame and a running clock, for [painter].
Widget liveHero({required BuildContext context, required String caption, required Widget readout, required double height,
  required Widget Function(BuildContext context, double secs, Map<String, double>? values) builder}) {
  final scope = DeviceScope.of(context);
  return HeroCanvas(color: scope.accent, height: height, caption: caption, grid: false, readout: readout,
      child: DeviceDisplay(builder: (context, f) => DevicePhase(builder: (context, secs) => builder(context, secs, f?.values))));
}
