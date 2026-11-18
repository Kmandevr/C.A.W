// The startup screen (owner's "waveform reveal", 2026-11-12): the crow draws itself from a moving waveform line, the
// real loading steps tick off under it, the version shows, and it fades away the moment loading is done.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/startup_progress.dart';
import '../model/updates/update_service.dart';
import '../version.dart';
import 'app_prompts.dart';
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

/// How long the reveal takes: the wave runs in, the crow's outline traces, the logo fades in. It plays to its end
/// unless Settings › Feel › Full startup animation is off, when loading that ends sooner cuts it short ([StartupGate]).
const Duration revealDuration = Duration(milliseconds: 1300);

/// The crow logo, precached as the reveal starts.
const AssetImage _logoImage = AssetImage('assets/logo/caw_mark.png');

/// The open-alpha notice and the copyright under the version (owner, 2026-11-12).
const String openAlphaNotice = 'Open alpha: expect rough edges and unexpected issues.';
const String copyrightLine = '© 2026 AutoStacc';

/// Shows [child] (the app) with the startup screen in front until [state] is ready and, with
/// [Settings.fullStartupAnimation] on (the default), the reveal has played to its end; then fades the screen out over
/// the app, which takes input from the moment the fade starts. The app is built only then, under the screen, so its
/// first build and every rebuild while loading never take a frame from the reveal; the fade starts on the frame after.
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
  late bool _buildChild = _ready; // the app is built once the screen starts to leave
  bool _revealDone = false;
  bool _leaving = false;
  late final AnimationController _fade = AnimationController(vsync: this, value: 1)
    ..addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) _hide();
    });

  Timer? _limit;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_changed);
    if (!_ready) _limit = Timer(widget.timeout, widget.state.startupTimedOut);
    AppPrompts.startupInFront.value = _shown; // the first-run page and update prompts wait until it has gone
  }

  void _hide() {
    setState(() => _shown = false);
    AppPrompts.startupInFront.value = false;
  }

  @override
  void dispose() {
    _limit?.cancel();
    widget.state.removeListener(_changed);
    _fade.dispose();
    AppPrompts.startupInFront.value = false;
    super.dispose();
  }

  void _changed() {
    if (_ready == widget.state.ready || !mounted) return;
    setState(() => _ready = widget.state.ready);
    if (_ready) _limit?.cancel();
    _maybeLeave();
  }

  void _revealEnded() {
    _revealDone = true;
    if (mounted) _maybeLeave();
  }

  // Leaves once loading is done and, when the full animation is asked for, the reveal has ended too.
  void _maybeLeave() {
    if (!_ready || !_shown || _leaving) return;
    if (widget.state.settings.fullStartupAnimation && !_revealDone) return;
    setState(() {
      _leaving = true;
      _buildChild = true;
    });
    final d = Motion.fade(Motion.standard, Motion.of(context));
    if (d == Duration.zero) {
      _hide();
    } else {
      // The app's first frame (its heaviest) is drawn under the still screen; the fade starts on the next one, so
      // it runs smoothly from its first step.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _fade
          ..duration = d
          ..reverse();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.passthrough, children: [
        _buildChild ? widget.child : const ColoredBox(color: startupBackground, child: SizedBox.expand()),
        if (_shown)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _leaving,
              child: FadeTransition(
                  opacity: _fade,
                  child: StartupScreen(
                      progress: widget.state.startup,
                      version: appVersion,
                      onRevealDone: _revealEnded,
                      updateLine: UpdateService.running?.startupLine)),
            ),
          ),
      ]);
}

/// The startup screen itself: the logo (revealed from a waveform at Full motion, still otherwise), the loading
/// steps as [progress] reports them, and [version].
class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key, required this.progress, required this.version, this.updateLine, this.onRevealDone});
  final StartupProgress progress;
  final String version;

  /// Called once the reveal has ended (at once when motion shows the still logo).
  final VoidCallback? onRevealDone;

  /// "Update available: vX" when an earlier launch's check found one (startup never waits on the network).
  final String? updateLine;

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> with SingleTickerProviderStateMixin {
  // A Ticker, so the reveal runs at the display's real rate; it stops when the reveal ends.
  late final AnimationController _reveal = AnimationController(vsync: this, duration: revealDuration)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _done();
    });
  bool _told = false;

  void _done() {
    if (_told) return;
    _told = true;
    // After this frame: the gate's setState must not run inside this widget's build or layout.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onRevealDone?.call());
  }
  late final Animation<double> _logo = CurvedAnimation(parent: _reveal, curve: const Interval(0.7, 1, curve: Curves.easeOut));
  bool? _moving;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Full motion reveals; Reduced, Off and the Minimal profile show the still logo (owner's D3).
    final moving = Motion.of(context) == MotionLevel.full;
    if (moving == _moving) return;
    // The logo decodes while the wave runs (off the UI isolate), so it is ready when it fades in at 70%.
    if (_moving == null) unawaited(precacheImage(_logoImage, context).catchError((Object _) {}));
    _moving = moving;
    if (moving) {
      _reveal.forward(from: 0);
    } else {
      _reveal.value = 1;
      _done();
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
            final image = Image(
                image: _logoImage, width: logo, height: logo, filterQuality: FilterQuality.medium, semanticLabel: 'C.A.W.');
            return Column(children: [
              const Spacer(flex: 5),
              // Layers of their own: the reveal repaints every frame without the steps and lines, and a step that
              // changes repaints none of the reveal.
              RepaintBoundary(
                child: SizedBox(
                  width: box.maxWidth,
                  height: logo,
                  child: _moving == true
                      ? CustomPaint(
                          painter: WaveformRevealPainter(_reveal, logoSize: logo),
                          child: Center(child: FadeTransition(opacity: _logo, child: image)),
                        )
                      : Center(child: image),
                ),
              ),
              const SizedBox(height: 28),
              RepaintBoundary(child: SizedBox(width: listWidth, child: _StepList(progress: widget.progress))),
              const Spacer(flex: 6),
              // The version (and an update an earlier check found), the open-alpha notice and the copyright: small
              // and quiet, fading in with the steps.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _Appear(
                  child: Column(children: [
                    for (final line in [
                      'v${widget.version}',
                      ?widget.updateLine,
                      openAlphaNotice,
                      copyrightLine,
                    ])
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
    final label = progress.label(step); // with its count, as the work goes ("Loading C++ components 3/7")
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
          // Tabular figures: a count going up doesn't shift the row.
          style: Theme.of(context).textTheme.bodyMedium!.copyWith(
              fontSize: 13, color: done ? _dim : _text, height: 1.2, fontFeatures: const [FontFeature.tabularFigures()]),
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

  // The outline at one size, measured once (the size only changes with the window): each edge's points scaled to
  // the logo and the length along it at every point, so a frame walks the polyline without measuring or extracting.
  static _Outline? _outlineCache;

  static _Outline _outline(double size) {
    final c = _outlineCache;
    if (c != null && c.size == size) return c;
    final k = size / 512;
    final edges = <List<Offset>>[];
    final lengths = <List<double>>[];
    var total = 0.0;
    for (final edge in _edges) {
      final points = [for (final p in edge) _svg(p) * k];
      final at = <double>[0];
      for (var i = 1; i < points.length; i++) {
        at.add(at.last + (points[i] - points[i - 1]).distance);
      }
      total += at.last;
      edges.add(points);
      lengths.add(at);
    }
    return _outlineCache = _Outline(size, edges, lengths, total);
  }

  static double _span(double t, double from, double to) => ((t - from) / (to - from)).clamp(0.0, 1.0);

  /// Paths the painter has made since the app started (a test checks a frame makes none once warmed up).
  @visibleForTesting
  static int debugPathsMade = 0;

  // What every frame reuses: the two paths (reset and refilled; a canvas copies a path when it records it), the
  // paints, the outline's sheen (per logo size), its glow's blur and the wave's gradient (per tip and height).
  static final Path _wave = _newPath(), _drawn = _newPath();
  static Path _newPath() {
    debugPathsMade++;
    return Path();
  }

  static final Paint _wavePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round;
  static final Paint _glowPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round;
  static final Paint _linePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;
  static final Paint _dotPaint = Paint();
  static (Rect, Shader)? _sheen, _waveShader;
  static (double, MaskFilter)? _blur;

  static Shader _sheenFor(Rect rect) {
    final c = _sheen;
    if (c != null && c.$1 == rect) return c.$2;
    final shader = const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_green, _cyan, _violet])
        .createShader(rect);
    _sheen = (rect, shader);
    return shader;
  }

  static Shader _waveShaderFor(Rect rect) {
    final c = _waveShader;
    if (c != null && c.$1 == rect) return c.$2;
    final shader = const LinearGradient(colors: [_violet, _cyan, _green]).createShader(rect);
    _waveShader = (rect, shader);
    return shader;
  }

  static MaskFilter _blurFor(double sigma) {
    final c = _blur;
    if (c != null && c.$1 == sigma) return c.$2;
    final blur = MaskFilter.blur(BlurStyle.normal, sigma);
    _blur = (sigma, blur);
    return blur;
  }

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
      final wave = _wave
        ..reset()
        ..moveTo(0, start.dy);
      final steps = math.max(96, tip ~/ 2); // about one point every 2 px
      for (var i = 1; i <= steps; i++) {
        final u = i / steps;
        final x = tip * u;
        // An audio-like line: two partials and a beat, swelling in the middle and meeting the crow at zero.
        final env = math.sin(math.pi * u) * (0.6 + 0.4 * math.sin(u * 9 + phase * 0.5));
        final y = math.sin(x / logoSize * 22 - phase) * 0.65 + math.sin(x / logoSize * 57 + phase * 1.6) * 0.35;
        wave.lineTo(x, start.dy + y * amp * env);
      }
      canvas.drawPath(
          wave,
          _wavePaint
            ..strokeWidth = stroke
            ..shader = _waveShaderFor(Rect.fromLTWH(0, start.dy - logoSize / 2, math.max(tip, 1), logoSize))
            ..color = Color.fromRGBO(255, 255, 255, calm));
    }

    // The outline traces (0.3 to 0.8), then fades as the logo fades in (0.8 to 1).
    final trace = Curves.easeInOutCubic.transform(_span(t, 0.3, 0.8));
    final fadeOut = 1 - _span(t, 0.8, 1);
    if (trace <= 0 || fadeOut <= 0) return;
    final outline = _outline(logoSize);
    // The pen goes by length along the whole outline (the same speed on every edge), the edges in drawing order.
    var left = trace * outline.total;
    final drawn = _drawn..reset();
    Offset? pen;
    for (var e = 0; e < outline.edges.length && left > 0; e++) {
      final points = outline.edges[e], at = outline.lengths[e];
      drawn.moveTo(box.dx + points[0].dx, box.dy + points[0].dy);
      for (var i = 1; i < points.length; i++) {
        if (left >= at[i] - 1e-6) { // whole (the edges' lengths may sum a hair under the total)
          drawn.lineTo(box.dx + points[i].dx, box.dy + points[i].dy);
          continue;
        }
        final p = box + Offset.lerp(points[i - 1], points[i], (left - at[i - 1]) / (at[i] - at[i - 1]))!;
        drawn.lineTo(p.dx, p.dy);
        pen = p;
        break;
      }
      left -= at.last;
    }
    final sheen = _sheenFor(box & Size.square(logoSize));
    canvas.drawPath(
        drawn,
        _glowPaint
          ..strokeWidth = stroke * 3
          ..shader = sheen
          ..color = Color.fromRGBO(255, 255, 255, 0.18 * fadeOut)
          ..maskFilter = _blurFor(stroke * 2));
    canvas.drawPath(
        drawn,
        _linePaint
          ..strokeWidth = stroke
          ..shader = sheen
          ..color = Color.fromRGBO(255, 255, 255, fadeOut));
    if (pen != null) {
      canvas.drawCircle(pen, stroke * 1.6, _dotPaint..color = Color.fromRGBO(255, 255, 255, 0.9 * fadeOut));
    }
    // The pink eye lights once the outline is whole.
    final eye = _span(t, 0.78, 0.86) * fadeOut;
    if (eye > 0) {
      canvas.drawCircle(box + _svg(_eye) * k, _eyeRadius * 1.18 * k, _dotPaint..color = _pink.withValues(alpha: eye));
    }
  }

  @override
  bool shouldRepaint(WaveformRevealPainter old) => old.reveal != reveal || old.logoSize != logoSize;
}

/// The crow's outline at one logo size: each edge's points, the length along it at each point, and the total.
class _Outline {
  _Outline(this.size, this.edges, this.lengths, this.total);
  final double size;
  final List<List<Offset>> edges;
  final List<List<double>> lengths;
  final double total;
}
