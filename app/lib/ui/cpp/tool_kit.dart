// The Build tools' shared look (testing suite, sample-pack maker, plug-in export): a glass page with a neon header, result cards with pass/fail, segments, fields and graphs.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../feedback.dart';
import '../glass.dart';
import '../haptics.dart';
import '../theme.dart';

/// Opens a Build tool full screen (it slides in over the editor like a device editor).
Future<void> openToolPage(BuildContext context, Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => GlassPage(child: page),
    ));

/// A Build tool's page: the back arrow, a glowing badge, the title and what it works on, then [children] in a
/// centred column (560 dp wide at most, so desktop reads like the phone), and an optional [bottom] action bar.
class ToolPage extends StatelessWidget {
  const ToolPage({super.key, required this.title, required this.subtitle, required this.icon, required this.accent,
    required this.children, this.bottom});
  final String title, subtitle;
  final IconData icon;
  final Color accent;
  final List<Widget> children;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: SafeArea(child: Column(children: [
      Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: accent.withValues(alpha: 0.4)))),
        child: Row(children: [
          IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).maybePop()),
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(color: accent.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(9),
              boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.45), blurRadius: 12)]),
            child: Icon(icon, size: 20, color: Neon.bg)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Neon.text)),
            Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: accent)),
          ])),
        ]),
      ),
      Expanded(child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children))),
      )),
      if (bottom != null)
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: Neon.line))),
          child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: bottom)),
        ),
    ])),
  );
}

/// How a result card reads at a glance.
enum ToolStatus { pass, warn, fail, info }

extension ToolStatusLook on ToolStatus {
  Color get color => switch (this) {
        ToolStatus.pass => Neon.green,
        ToolStatus.warn => Neon.yellow,
        ToolStatus.fail => Neon.pink,
        ToolStatus.info => Neon.blue,
      };
  String get label => switch (this) {
        ToolStatus.pass => 'PASS',
        ToolStatus.warn => 'CHECK',
        ToolStatus.fail => 'FAIL',
        ToolStatus.info => 'INFO',
      };
  IconData get icon => switch (this) {
        ToolStatus.pass => Icons.check_circle,
        ToolStatus.warn => Icons.error_outline,
        ToolStatus.fail => Icons.cancel,
        ToolStatus.info => Icons.insights,
      };
}

/// A section heading: small spaced capitals in [color].
class ToolHeading extends StatelessWidget {
  const ToolHeading(this.text, {super.key, this.color = Neon.dim});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
    child: Text(text.toUpperCase(), style: TextStyle(fontSize: 10, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: color)),
  );
}

/// A frosted card with a neon edge: [title], an optional [status] badge, then [child].
class ToolCard extends StatelessWidget {
  const ToolCard({super.key, required this.title, required this.child, this.status, this.color, this.trailing});
  final String title;
  final ToolStatus? status;
  final Color? color;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = color ?? status?.color ?? Neon.blue;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
          Color.lerp(Neon.panel, c, 0.08)!.withValues(alpha: 0.85),
          Neon.panel.withValues(alpha: 0.7),
        ]),
        border: Border.all(color: c.withValues(alpha: 0.35)),
        boxShadow: [BoxShadow(color: c.withValues(alpha: 0.10), blurRadius: 16)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Neon.text))),
          ?trailing,
          if (status case final s?) StatusBadge(s),
        ]),
        const SizedBox(height: 8),
        child,
      ]),
    );
  }
}

/// PASS / CHECK / FAIL / INFO as a small glowing pill.
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key});
  final ToolStatus status;

  @override
  Widget build(BuildContext context) {
    final c = status.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c),
        boxShadow: [BoxShadow(color: c.withValues(alpha: 0.3), blurRadius: 8)]),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(status.icon, size: 12, color: c),
        const SizedBox(width: 4),
        Text(status.label, style: TextStyle(fontSize: 9, letterSpacing: 1, fontWeight: FontWeight.w800, color: c)),
      ]),
    );
  }
}

/// A measurement: a dim name and a value in the mono font.
class ToolStat extends StatelessWidget {
  const ToolStat(this.name, this.value, {super.key, this.color});
  final String name, value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [
      Expanded(child: Text(name, style: const TextStyle(fontSize: 12, color: Neon.dim))),
      Text(value, style: Neon.code(size: 12, color: color ?? Neon.text)),
    ]),
  );
}

/// A row of segments (one choice of a few), 36 dp tall, glowing in [color] where picked; a tap gives a haptic.
class ToolSegments<T> extends StatelessWidget {
  const ToolSegments({super.key, required this.values, required this.labels, required this.value, required this.onChanged,
    this.color = Neon.blue, this.keyPrefix});
  final List<T> values;
  final String Function(T) labels;
  final T value;
  final ValueChanged<T> onChanged;
  final Color color;
  final String? keyPrefix;

  @override
  Widget build(BuildContext context) => Container(
    height: 36,
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(9), border: Border.all(color: Neon.line)),
    child: Row(children: [
      for (final v in values)
        Expanded(child: GestureDetector(
          key: keyPrefix == null ? null : ValueKey('$keyPrefix-$v'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            Haptics.tap();
            onChanged(v);
          },
          child: Pressable(glow: color, radius: 8, child: Container(
            alignment: Alignment.center,
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: v == value ? color.withValues(alpha: 0.22) : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              boxShadow: v == value ? [BoxShadow(color: color.withValues(alpha: 0.25), blurRadius: 8)] : null),
            child: Text(labels(v), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11,
              fontWeight: v == value ? FontWeight.w800 : FontWeight.w500, color: v == value ? color : Neon.dim)),
          )),
        )),
    ]),
  );
}

/// A labelled on/off line with a switch.
class ToolSwitch extends StatelessWidget {
  const ToolSwitch({super.key, required this.label, required this.value, required this.onChanged, this.detail, this.color = Neon.blue});
  final String label;
  final String? detail;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color color;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: onChanged == null ? null : () {
      Haptics.tap();
      onChanged!(!value);
    },
    child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 13, color: onChanged == null ? Neon.dim : Neon.text)),
        if (detail != null) Text(detail!, style: const TextStyle(fontSize: 11, color: Neon.dim)),
      ])),
      Switch(value: value, onChanged: onChanged, activeThumbColor: color),
    ])),
  );
}

/// The big action at the bottom: [label] with [icon], or a progress bar with Cancel while [progress] is set.
class ToolAction extends StatelessWidget {
  const ToolAction({super.key, required this.label, required this.icon, required this.onPressed, this.color = Neon.green,
    this.progress, this.busyLabel = 'Working…', this.onCancel});
  final String label, busyLabel;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color color;

  /// Null while idle; 0..1 (or negative for an unknown amount) while working.
  final double? progress;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    if (p != null) {
      return Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(p < 0 ? busyLabel : '$busyLabel ${(p * 100).round()}%', style: TextStyle(fontSize: 12, color: color)),
          const SizedBox(height: 6),
          ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(
            key: const ValueKey('tool-progress'),
            value: p < 0 ? null : p, minHeight: 6, color: color, backgroundColor: color.withValues(alpha: 0.15))),
        ])),
        if (onCancel != null) ...[
          const SizedBox(width: 12),
          OutlinedButton(key: const ValueKey('tool-cancel'), onPressed: onCancel, child: const Text('Cancel')),
        ],
      ]);
    }
    return SizedBox(height: 46, child: FilledButton.icon(
      key: const ValueKey('tool-action'),
      style: FilledButton.styleFrom(backgroundColor: color, foregroundColor: Neon.bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      onPressed: onPressed == null ? null : () {
        Haptics.tap();
        onPressed!();
      },
      icon: Icon(icon),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
    ));
  }
}

/// A line of [hz, db] points on a log-frequency axis (20 Hz to 20 kHz) from [top] dB down [range] dB, with a
/// grid; a second series in [compare] draws dim behind it.
class BandGraph extends StatelessWidget {
  const BandGraph({super.key, required this.bands, this.compare, this.color = Neon.blue, this.height = 140, this.top = 0,
    this.range = 90, this.centred = false});
  final List<(double, double)> bands;
  final List<(double, double)>? compare;
  final Color color;
  final double height, top, range;

  /// A response around 0 dB (top is +range/2) rather than a spectrum below [top].
  final bool centred;

  @override
  Widget build(BuildContext context) => SizedBox(height: height, child: CustomPaint(
    painter: _BandPainter(bands, compare, color, centred ? range / 2 : top, range),
    child: const SizedBox.expand()));
}

class _BandPainter extends CustomPainter {
  _BandPainter(this.bands, this.compare, this.color, this.top, this.range);
  final List<(double, double)> bands;
  final List<(double, double)>? compare;
  final Color color;
  final double top, range;

  static double xOf(double hz, double w) => (math.log(hz.clamp(20, 20000) / 20) / math.log(1000)) * w;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = Colors.white.withValues(alpha: 0.06);
    for (final hz in const [100.0, 1000.0, 10000.0]) {
      final x = xOf(hz, size.width);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var d = 1; d < 3; d++) {
      canvas.drawLine(Offset(0, size.height * d / 3), Offset(size.width, size.height * d / 3), grid);
    }
    double yOf(double db) => ((top - db) / range).clamp(0.0, 1.0) * size.height;
    Path line(List<(double, double)> pts) {
      final p = Path();
      for (var i = 0; i < pts.length; i++) {
        final o = Offset(xOf(pts[i].$1, size.width), yOf(pts[i].$2));
        i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
      }
      return p;
    }

    if (compare case final c? when c.length > 1) {
      canvas.drawPath(line(c), Paint()
        ..color = Neon.dim.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2);
    }
    if (bands.length < 2) return;
    final path = line(bands);
    final fill = Path.from(path)
      ..lineTo(xOf(bands.last.$1, size.width), size.height)
      ..lineTo(xOf(bands.first.$1, size.width), size.height)
      ..close();
    canvas.drawPath(fill, Paint()
      ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.02)]).createShader(Offset.zero & size));
    canvas.drawPath(path, Paint()
      ..color = color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6);
    final text = TextPainter(textDirection: TextDirection.ltr);
    for (final (hz, label) in const [(100.0, '100'), (1000.0, '1k'), (10000.0, '10k')]) {
      text.text = TextSpan(text: label, style: Neon.code(size: 9, color: Neon.dim).copyWith(height: 1));
      text.layout();
      text.paint(canvas, Offset(xOf(hz, size.width) + 3, size.height - 12));
    }
  }

  @override
  bool shouldRepaint(covariant _BandPainter o) => o.bands != bands || o.compare != compare || o.color != color;
}

/// A waveform overview: per column the lowest and highest sample of the left (above) and right (below) channels.
class WaveGraph extends StatelessWidget {
  const WaveGraph({super.key, required this.left, required this.right, this.color = Neon.green, this.height = 120});

  /// Pairs of (min, max) per column, in −1..1.
  final List<(double, double)> left, right;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(height: height, child: CustomPaint(
    painter: _WavePainter(left, right, color), child: const SizedBox.expand()));
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.left, this.right, this.color);
  final List<(double, double)> left, right;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final half = size.height / 2;
    final mid = Paint()..color = Colors.white.withValues(alpha: 0.07);
    canvas.drawLine(Offset(0, half / 2), Offset(size.width, half / 2), mid);
    canvas.drawLine(Offset(0, half * 1.5), Offset(size.width, half * 1.5), mid);
    void lane(List<(double, double)> cols, double y0, Color c) {
      if (cols.isEmpty) return;
      final paint = Paint()
        ..color = c
        ..strokeWidth = math.max(1, size.width / cols.length);
      for (var i = 0; i < cols.length; i++) {
        final x = (i + 0.5) / cols.length * size.width;
        final (lo, hi) = cols[i];
        canvas.drawLine(Offset(x, y0 + half / 2 - hi.clamp(-1.0, 1.0) * half / 2 * 0.95),
          Offset(x, y0 + half / 2 - lo.clamp(-1.0, 1.0) * half / 2 * 0.95 + 0.5), paint);
      }
    }

    lane(left, 0, color);
    lane(right, half, Color.lerp(color, Neon.blue, 0.5)!);
  }

  @override
  bool shouldRepaint(covariant _WavePainter o) => o.left != left || o.right != right || o.color != color;
}
