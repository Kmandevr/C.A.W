// Shows the app's hidden surprises over everything without ever blocking a touch: a hatching crow, a short line of text, Parrot's rainbow, and the one sound.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/easter_eggs.dart';
import '../model/sample_use.dart';
import '../model/settings.dart';
import 'crow.dart';
import 'motion.dart';
import 'parrot.dart';
import 'theme.dart';

/// How long the brief surprises stay.
const eggToastTime = Duration(milliseconds: 2600);
const parrotFlashTime = Duration(milliseconds: 2000);

/// Plays the caw (the engine's sample preview, the audition path) and stops it; tests swap it.
abstract class CawPlayer {
  Future<void> play();
  void stop();
}

/// The caw through [AppState.samplePreview]: made once ([synthCawWav]) into a temporary file.
class EngineCawPlayer implements CawPlayer {
  EngineCawPlayer(this.state);
  final AppState state;
  static File? _file;

  @override
  Future<void> play() async {
    try {
      final f = _file ??= File('${Directory.systemTemp.path}${Platform.pathSeparator}caw-$pid.wav');
      if (!await f.exists()) await f.writeAsBytes(synthCawWav());
      await state.samplePreview.play(f.path);
    } catch (_) {
      // No engine or no audio: the surprise is silent.
    }
  }

  @override
  void stop() {
    try {
      state.samplePreview.stop();
    } catch (_) {}
  }
}

/// Over [child]: Parrot's glow while the theme is Parrot (or flashing), and the surprises [eggs] sends.
class EggLayer extends StatefulWidget {
  const EggLayer({super.key, required this.settings, required this.child, this.state, this.eggs, this.player});
  final Settings settings;

  /// The app, whose engine plays the caw (null: silent).
  final AppState? state;
  final Widget child;
  final EasterEggs? eggs;
  final CawPlayer? player;

  @override
  State<EggLayer> createState() => _EggLayerState();
}

class _EggLayerState extends State<EggLayer> {
  EasterEggs get _eggs => widget.eggs ?? EasterEggs.instance;
  String? _toast;
  bool _flash = false;
  int _hatch = 0;
  bool _cawing = false;
  final _timers = <Timer>[];

  @override
  void initState() {
    super.initState();
    _eggs.events.addListener(_event);
  }

  @override
  void didUpdateWidget(EggLayer old) {
    super.didUpdateWidget(old);
    if (old.eggs != widget.eggs) {
      (old.eggs ?? EasterEggs.instance).events.removeListener(_event);
      _eggs.events.addListener(_event);
    }
  }

  @override
  void dispose() {
    _eggs.events.removeListener(_event);
    for (final t in _timers) {
      t.cancel();
    }
    super.dispose();
  }

  void _after(Duration d, VoidCallback f) => _timers.add(Timer(d, () {
        if (mounted) setState(f);
      }));

  void _say(String text) {
    setState(() => _toast = text);
    _after(eggToastTime, () => _toast = _toast == text ? null : _toast);
  }

  void _event() {
    final e = _eggs.events.value;
    if (e == null || !mounted) return;
    switch (e.kind) {
      case EggKind.hatch:
        setState(() => _hatch = e.seq);
        _after(const Duration(milliseconds: 2200), () => _hatch = _hatch == e.seq ? 0 : _hatch);
      case EggKind.timeFlies:
        _say('Time flies.');
      case EggKind.parrotFlash:
        setState(() => _flash = true);
        _after(parrotFlashTime, () => _flash = false);
      case EggKind.parrotUnlocked:
        unawaited(widget.settings.unlockParrot());
        _say('Parrot found: it is in Settings › Appearance and feel › Theme.');
      case EggKind.caw:
        _caw();
    }
  }

  CawPlayer? get _player {
    if (widget.player != null) return widget.player;
    final state = widget.state;
    return state == null ? null : EngineCawPlayer(state);
  }

  void _caw() {
    final p = _player;
    if (p == null) return;
    _cawing = true;
    unawaited(p.play());
    _timers.add(Timer(const Duration(milliseconds: 600), () => _cawing = false));
  }

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    final parrot = widget.settings.themeName == parrotTheme.name || _flash;
    return Listener(
      behavior: HitTestBehavior.translucent,
      // A tap stops the caw (the April count-in's); it still reaches the app.
      onPointerDown: (_) {
        if (!_cawing) return;
        _cawing = false;
        _player?.stop();
      },
      child: Stack(fit: StackFit.passthrough, children: [
        ParrotGlow(on: parrot, child: widget.child),
        if (_hatch != 0)
          Positioned(
            right: 16,
            bottom: 96,
            child: IgnorePointer(child: _HatchingCrow(key: ValueKey('hatch-$_hatch'), level: level)),
          ),
        Positioned(
          left: 16,
          right: 16,
          top: 48,
          child: IgnorePointer(
            child: Center(
              child: AnimatedSwitcher(
                duration: Motion.fade(Motion.standard, level),
                child: _toast == null
                    ? const SizedBox.shrink()
                    : Material(
                        key: ValueKey(_toast),
                        color: Neon.panelHi.withValues(alpha: 0.94),
                        borderRadius: BorderRadius.circular(20),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          child: Text(_toast!, key: const ValueKey('egg-toast'),
                              style: const TextStyle(color: Neon.text, fontSize: 13)),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// A tiny crow in the corner that hatches from an egg and flies off; with Reduced it fades in and out where it
/// is, with Off it just shows and goes.
class _HatchingCrow extends StatefulWidget {
  const _HatchingCrow({super.key, required this.level});
  final MotionLevel level;

  @override
  State<_HatchingCrow> createState() => _HatchingCrowState();
}

class _HatchingCrowState extends State<_HatchingCrow> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        key: const ValueKey('hatching-crow'),
        width: 64,
        height: 64,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value;
            final full = widget.level == MotionLevel.full;
            // 0 to 0.35: the egg wobbles and cracks; then the crow flies up and away.
            final hatched = t > 0.35 || !full;
            final fly = full ? ((t - 0.45) / 0.55).clamp(0.0, 1.0) : 0.0;
            final alpha = switch (widget.level) {
              MotionLevel.full => 1.0,
              MotionLevel.reduced => t < 0.2 ? t / 0.2 : (t > 0.8 ? (1 - t) / 0.2 : 1.0),
              MotionLevel.off => 1.0,
            };
            return Opacity(
              opacity: alpha.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(-80 * fly, -160 * fly),
                child: CustomPaint(
                  painter: hatched
                      ? CrowPainter(
                          color: Neon.text,
                          pose: fly > 0 ? CrowPose.flying : CrowPose.perched,
                          wing: fly > 0 ? (t * 20 % 2 - 1) : 0)
                      : _EggPainter(full ? t / 0.35 : 1),
                ),
              ),
            );
          },
        ),
      );
}

class _EggPainter extends CustomPainter {
  _EggPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(0.15 * (t * 12).remainder(2) * (t < 0.9 ? 1 : 0) - 0.075);
    final egg = Rect.fromCenter(center: Offset.zero, width: size.width * 0.5, height: size.height * 0.66);
    canvas.drawOval(egg, Paint()..color = Neon.text);
    if (t > 0.5) {
      canvas.drawPath(
          Path()
            ..moveTo(egg.left, 0)
            ..lineTo(egg.left + egg.width * 0.25, -6)
            ..lineTo(egg.left + egg.width * 0.5, 2)
            ..lineTo(egg.left + egg.width * 0.75, -6)
            ..lineTo(egg.right, 0),
          Paint()
            ..color = Neon.bg
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EggPainter old) => old.t != t;
}

/// How long the tempo reads "leet".
const leetTime = Duration(milliseconds: 1500);

/// The tempo's [child], which reads "leet" for a moment when the tempo becomes 133.7 BPM.
class TempoLeet extends StatefulWidget {
  const TempoLeet({super.key, required this.bpm, required this.child, this.style});
  final double bpm;
  final Widget child;
  final TextStyle? style;

  @override
  State<TempoLeet> createState() => _TempoLeetState();
}

class _TempoLeetState extends State<TempoLeet> {
  bool _leet = false;
  Timer? _timer;

  @override
  void didUpdateWidget(TempoLeet old) {
    super.didUpdateWidget(old);
    if (!isLeetTempo(old.bpm) && isLeetTempo(widget.bpm)) {
      _leet = true;
      _timer?.cancel();
      _timer = Timer(leetTime, () {
        if (mounted) setState(() => _leet = false);
      });
    } else if (!isLeetTempo(widget.bpm)) {
      _leet = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: Motion.fade(Motion.standard, Motion.of(context)),
        child: _leet ? Text('leet', key: const ValueKey('tempo-leet'), style: widget.style) : widget.child,
      );
}
