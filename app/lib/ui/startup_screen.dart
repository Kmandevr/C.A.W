// The startup screen (owner's "waveform reveal", 2026-11-12): the crow draws itself from a moving waveform line, the
// real loading steps tick off under it, the version shows, and it fades away the moment loading is done.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/startup_progress.dart';
import '../version.dart';
import 'motion.dart';
import 'theme.dart';

/// The startup screen's background, the same in every theme: the native splash (Android's launch theme, the Windows
/// and Linux window) is this colour, so the first Flutter frame shows no flash. Neon's dark background.
const Color startupBackground = Color(0xFF07070B);

// The startup screen's own colours (fixed, like the background): Neon's dark text and the logo's sheen and eye.
const Color _text = Color(0xFFE9E9F2);
const Color _dim = Color(0xFF8C8CA3);
const Color _green = Color(0xFF39FF14);
const Color _cyan = Color(0xFF1FD8FF);
const Color _violet = Color(0xFFB46CFF);
const Color _pink = Color(0xFFFF2BD6);

/// How long the reveal takes when loading is slower than it: the wave runs in, the crow's outline traces, the
/// logo fades in. Loading that ends sooner cuts it short ([StartupGate]).
const Duration revealDuration = Duration(milliseconds: 1300);

/// The open-beta notice and the copyright under the version (owner, 2026-11-12).
const String openBetaNotice = 'Open beta: expect rough edges and unexpected issues.';
const String copyrightLine = '© 2026 AutoStacc';

/// Shows [child] (the app) with the startup screen in front until [state] is ready, then fades the screen out at
/// once over the app, which takes input from the first frame it shows (it never waits for the reveal to finish).
/// A launch still loading after [timeout] shows the app anyway ([AppState.startupTimedOut] says which step stuck).
class StartupGate extends StatefulWidget {
  const StartupGate({super.key, required this.state, required this.child, this.timeout = const Duration(seconds: 10)});
  final AppState state;
  final Widget child;
  final Duration timeout;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> with SingleTickerProviderStateMixin {
  late bool _ready = widget.state.ready;
  late bool _shown = !_ready;
  late final AnimationController _fade = AnimationController(vsync: this, value: 1)
    ..addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) setState(() => _shown = false);
    });

  Timer? _limit;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_changed);
    if (!_ready) _limit = Timer(widget.timeout, widget.state.startupTimedOut);
  }

  @override
  void dispose() {
    _limit?.cancel();
    widget.state.removeListener(_changed);
    _fade.dispose();
    super.dispose();
  }

  void _changed() {
    if (_ready == widget.state.ready || !mounted) return;
    setState(() => _ready = widget.state.ready);
    if (_ready) _limit?.cancel();
    if (!_ready || !_shown) return;
    final d = Motion.fade(Motion.standard, Motion.of(context));
    if (d == Duration.zero) {
      setState(() => _shown = false);
    } else {
      _fade
        ..duration = d
        ..reverse();
    }
  }

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.passthrough, children: [
        widget.child,
        if (_shown)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _ready,
              child: FadeTransition(
                  opacity: _fade, child: StartupScreen(progress: widget.state.startup, version: appVersion)),
            ),
          ),
      ]);
}

/// The startup screen itself: the logo (revealed from a waveform at Full motion, still otherwise), the loading
/// steps as [progress] reports them, and [version].
class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key, required this.progress, required this.version});
  final StartupProgress progress;
  final String version;

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> with SingleTickerProviderStateMixin {
  // A Ticker, so the reveal runs at the display's real rate; it stops when the reveal ends.
  late final AnimationController _reveal = AnimationController(vsync: this, duration: revealDuration);
  late final Animation<double> _logo = CurvedAnimation(parent: _reveal, curve: const Interval(0.7, 1, curve: Curves.easeOut));
  bool? _moving;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Full motion reveals; Reduced, Off and the Minimal profile show the still logo (owner's D3).
    final moving = Motion.of(context) == MotionLevel.full;
    if (moving == _moving) return;
    _moving = moving;
    if (moving) {
      _reveal.forward(from: 0);
    } else {
      _reveal.value = 1;
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
        color: startupBackground,
        child: SafeArea(
          child: LayoutBuilder(builder: (context, box) {
            final logo = math.min(box.maxWidth * 0.36, box.maxHeight * 0.24).clamp(64.0, 148.0);
            final listWidth = math.min(280.0, box.maxWidth - 32);
            final image = Image.asset('assets/logo/caw_mark.png',
                width: logo, height: logo, filterQuality: FilterQuality.medium, semanticLabel: 'C.A.W.');
            return Column(children: [
              const Spacer(flex: 5),
              SizedBox(
                width: box.maxWidth,
                height: logo,
                child: _moving == true
                    ? CustomPaint(
                        painter: WaveformRevealPainter(_reveal, logoSize: logo),
                        child: Center(child: FadeTransition(opacity: _logo, child: image)),
                      )
                    : Center(child: image),
              ),
              const SizedBox(height: 28),
              SizedBox(width: listWidth, child: _StepList(progress: widget.progress)),
              const Spacer(flex: 6),
              // The version, the open-beta notice and the copyright: small and quiet, fading in with the steps.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _Appear(
                  child: Column(children: [
                    for (final line in ['v${widget.version}', openBetaNotice, copyrightLine])
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(line,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontFamily: Neon.mono, fontSize: 11, height: 1.3, color: _dim, letterSpacing: 0.5)),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
            ]);
          }),
        ),
      );
}

/// The steps begun so far, each appearing as it starts and ticking off as it ends.
class _StepList extends StatelessWidget {
  const _StepList({required this.progress});
  final StartupProgress progress;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: progress,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          // Room for every step from the start, so the logo never moves as steps appear.
          children: [
            for (final step in StartupStep.values)
              SizedBox(
                height: 24,
                child: progress.begun(step)
                    ? _Appear(key: ValueKey(step), child: _StepRow(step: step, progress: progress))
                    : null,
              ),
          ],
        ),
      );
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.progress});
  final StartupStep step;
  final StartupProgress progress;

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    final done = progress.done(step), failed = progress.failed(step);
    final name = progress.projectName;
    final label = step == StartupStep.project && name != null ? 'Opening $name' : step.label;
    final Widget mark = failed
        ? const Icon(Icons.close_rounded, key: ValueKey('failed'), size: 14, color: _pink)
        : done
            ? const Icon(Icons.check_rounded, key: ValueKey('done'), size: 14, color: _green)
            : const _Pending(key: ValueKey('pending'));
    return Row(children: [
      SizedBox(
        width: 22,
        child: AnimatedSwitcher(
          duration: Motion.fade(Motion.small, level),
          transitionBuilder: (child, a) => level == MotionLevel.full
              ? FadeTransition(opacity: a, child: ScaleTransition(scale: a, child: child))
              : FadeTransition(opacity: a, child: child),
          child: mark,
        ),
      ),
      Expanded(
        child: AnimatedDefaultTextStyle(
          duration: Motion.fade(Motion.small, level),
          style: Theme.of(context).textTheme.bodyMedium!.copyWith(fontSize: 13, color: done ? _dim : _text, height: 1.2),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    ]);
  }
}

/// The mark of a step still running: a small hollow ring.
class _Pending extends StatelessWidget {
  const _Pending({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: _cyan, width: 1.4)),
        ),
      );
}

/// A row appearing: a fade (Reduced too) and a short rise (Full only); Off shows it at once.
class _Appear extends StatefulWidget {
  const _Appear({super.key, required this.child});
  final Widget child;

  @override
  State<_Appear> createState() => _AppearState();
}

class _AppearState extends State<_Appear> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this);
  late final Animation<double> _curve = CurvedAnimation(parent: _in, curve: Curves.easeOutCubic);
  MotionLevel _level = MotionLevel.full;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _level = Motion.of(context);
    if (_started) return;
    _started = true;
    final d = Motion.fade(Motion.standard, _level);
    if (d == Duration.zero) {
      _in.value = 1;
    } else {
      _in
        ..duration = d
        ..forward();
    }
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _curve,
        child: _level == MotionLevel.full
            ? AnimatedBuilder(
                animation: _curve,
                builder: (context, child) => Transform.translate(offset: Offset(0, 6 * (1 - _curve.value)), child: child),
                child: widget.child,
              )
            : widget.child,
      );
}

/// Paints the reveal at [reveal]'s value (0 to 1) across its whole width, with the crow's [logoSize] square at the
/// centre: a waveform runs in from the left edge to the crow's back, its energy flows into the crow's outline
/// (traced edge by edge, a bright point at the pen), then the outline fades as the logo itself fades in (drawn by
/// [StartupScreen] over this). The outline is the logo's own drawing (`assets/logo/caw_mark.svg`), unchanged.
class WaveformRevealPainter extends CustomPainter {
  WaveformRevealPainter(this.reveal, {required this.logoSize}) : super(repaint: reveal);
  final Animation<double> reveal;
  final double logoSize;

  // The outline's edges in the SVG's own coordinates (its 512 viewBox, before its transforms), in drawing order:
  // the head from the back of the skull round, the beak, the two facet lines, the beak's line. The eye follows.
  static const List<List<(double, double)>> _edges = [
    [(108, 262), (172, 151), (300, 151), (336, 184), (319, 334), (338, 370), (300, 373), (160, 414), (108, 262)],
    [(336, 184), (413, 254), (319, 334), (276, 262), (336, 184)],
    [(172, 151), (226, 282), (300, 151)],
    [(108, 262), (226, 282), (160, 414)],
    [(276, 262), (407, 254)],
  ];
  static const _eye = (251.36, 210.8), _eyeRadius = 13.0;

  /// A point of the SVG's drawing in the 512 viewBox: the inner `translate(-10 -14) rotate(-12 256 256)`, then the
  /// outer `translate(256 256) scale(1.18) translate(-262 -250)`.
  static Offset _svg((double, double) p) {
    const a = -12 * math.pi / 180;
    final dx = p.$1 - 256, dy = p.$2 - 256;
    final x = 256 + dx * math.cos(a) - dy * math.sin(a) - 10;
    final y = 256 + dx * math.sin(a) + dy * math.cos(a) - 14;
    return Offset(256 + 1.18 * (x - 262), 256 + 1.18 * (y - 250));
  }

  // The outline at one size, measured once (the size only changes with the window).
  static (double, List<PathMetric>, double)? _cache;

  static (List<PathMetric>, double) _outline(double size) {
    final c = _cache;
    if (c != null && c.$1 == size) return (c.$2, c.$3);
    final k = size / 512;
    final path = Path();
    for (final edge in _edges) {
      final first = _svg(edge.first) * k;
      path.moveTo(first.dx, first.dy);
      for (final p in edge.skip(1)) {
        final o = _svg(p) * k;
        path.lineTo(o.dx, o.dy);
      }
    }
    final metrics = path.computeMetrics().toList();
    final total = metrics.fold(0.0, (sum, m) => sum + m.length);
    _cache = (size, metrics, total);
    return (metrics, total);
  }

  static double _span(double t, double from, double to) => ((t - from) / (to - from)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final t = reveal.value;
    if (t >= 1) return; // the logo alone
    final box = Offset((size.width - logoSize) / 2, (size.height - logoSize) / 2);
    final k = logoSize / 512;
    final start = box + _svg(_edges.first.first) * k; // the back of the skull, where the wave flows in
    final stroke = math.max(1.4, logoSize / 80);

    // The waveform: its tip runs in from the left edge to the crow (0 to 0.35), then it calms and fades (to 0.75).
    final run = Curves.easeOutCubic.transform(_span(t, 0, 0.35));
    final calm = 1 - _span(t, 0.3, 0.75);
    if (run > 0 && calm > 0) {
      final tip = start.dx * run;
      final amp = logoSize * 0.17 * (0.25 + 0.75 * calm);
      final phase = t * math.pi * 7;
      final wave = Path()..moveTo(0, start.dy);
      final steps = math.max(96, tip ~/ 2); // about one point every 2 px
      for (var i = 1; i <= steps; i++) {
        final u = i / steps;
        final x = tip * u;
        // An audio-like line: two partials and a beat, swelling in the middle and meeting the crow at zero.
        final env = math.sin(math.pi * u) * (0.6 + 0.4 * math.sin(u * 9 + phase * 0.5));
        final y = math.sin(x / logoSize * 22 - phase) * 0.65 + math.sin(x / logoSize * 57 + phase * 1.6) * 0.35;
        wave.lineTo(x, start.dy + y * amp * env);
      }
      final shader = const LinearGradient(colors: [_violet, _cyan, _green])
          .createShader(Rect.fromLTWH(0, start.dy - logoSize / 2, math.max(tip, 1), logoSize));
      canvas.drawPath(
          wave,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeJoin = StrokeJoin.round
            ..shader = shader
            ..color = Color.fromRGBO(255, 255, 255, calm));
    }

    // The outline traces (0.3 to 0.8), then fades as the logo fades in (0.8 to 1).
    final trace = Curves.easeInOutCubic.transform(_span(t, 0.3, 0.8));
    final fadeOut = 1 - _span(t, 0.8, 1);
    if (trace <= 0 || fadeOut <= 0) return;
    final (metrics, total) = _outline(logoSize);
    var left = trace * total;
    final drawn = Path();
    Offset? pen;
    for (final m in metrics) {
      if (left <= 0) break;
      final part = math.min(left, m.length);
      drawn.addPath(m.extractPath(0, part), box);
      if (part < m.length) pen = box + m.getTangentForOffset(part)!.position;
      left -= part;
    }
    final rect = box & Size.square(logoSize);
    final sheen = const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_green, _cyan, _violet])
        .createShader(rect);
    canvas.drawPath(
        drawn,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 3
          ..strokeJoin = StrokeJoin.round
          ..shader = sheen
          ..color = Color.fromRGBO(255, 255, 255, 0.18 * fadeOut)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 2));
    canvas.drawPath(
        drawn,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..shader = sheen
          ..color = Color.fromRGBO(255, 255, 255, fadeOut));
    if (pen != null) {
      canvas.drawCircle(pen, stroke * 1.6, Paint()..color = Color.fromRGBO(255, 255, 255, 0.9 * fadeOut));
    }
    // The pink eye lights once the outline is whole.
    final eye = _span(t, 0.78, 0.86) * fadeOut;
    if (eye > 0) {
      canvas.drawCircle(box + _svg(_eye) * k, _eyeRadius * 1.18 * k, Paint()..color = _pink.withValues(alpha: eye));
    }
  }

  @override
  bool shouldRepaint(WaveformRevealPainter old) => old.reveal != reveal || old.logoSize != logoSize;
}
