// The drums' plugin UIs: playable pads and each drum's sound drawn and draggable (the kick's pitch drop and decay, the snare's
// body and noise, the hats' two decays), and the kit's pad grid with a section per pad.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../../engine/component_info.dart';
import '../device_controls.dart';
import '../device_registry.dart';
import '../device_scope.dart';
import '../effects/effect_page.dart';
import '../kit/controls.dart';
import '../kit/device_style.dart';
import '../kit/feel.dart';
import '../kit/grab_gesture.dart';
import '../kit/hero.dart';

/// The drums' editors, by id.
final Map<String, DeviceEditorEntry> drumEditors = {
  'org.caw.drum.kick': singlePage('kick', 'KICK', Icons.circle_outlined, DeviceFamily.drums, () => const KickPage()),
  'org.caw.drum.snare': singlePage('snare', 'SNARE', Icons.album_outlined, DeviceFamily.drums, () => const SnarePage()),
  'org.caw.drum.hats': singlePage('hats', 'HATS', Icons.blur_circular, DeviceFamily.drums, () => const HatsPage()),
  'org.caw.drum.kit': singlePage('kit', 'KIT', Icons.grid_view_rounded, DeviceFamily.drums, () => const KitPage()),
};

/// The pads' colours: kick red, snare yellow, clap pink, hats blue and mint.
Color padColor(int key) => switch (key) {
      35 || 36 => Neon.layers[7],
      38 || 40 => Neon.yellow,
      39 => Neon.pink,
      42 || 44 => Neon.blue,
      _ => Neon.layers[6],
    };

// ---------------------------------------------------------------------------------------------------------------
// Sound shapes (drawn from the knobs, following caw/library/drums.hpp's voices)

/// A kick's sound at [s] seconds: a sine dropping from tune × (1 + 10·punch) to tune, its level falling to −60 dB
/// over the decay, a click of noise at the start, driven by a tanh.
class KickShape {
  const KickShape({required this.tune, required this.punch, required this.decay, this.click = 0.3, this.drive = 1.5});
  final double tune, punch, decay, click, drive;

  double dropTime() => 0.04 + punch * 0.08;
  double pitch(double s) {
    final d = math.exp(-6.9 * s / dropTime());
    return tune * (1 + 10 * punch * d * d);
  }

  double level(double s) => math.exp(-6.9 * s / math.max(0.01, decay));
}

/// The kick's waveform over [span] seconds in [r], with its pitch drop drawn above it.
void paintKick(Canvas canvas, Rect r, KickShape k, Color color, Color second, {double? span, bool labels = true}) {
  final secs = span ?? math.min(1.2, math.max(0.12, k.decay * 1.1));
  final mid = r.center.dy + r.height * 0.12, amp = r.height * 0.36;
  final wave = Path();
  var phase = 0.0;
  const n = 900;
  var seed = 3;
  for (var i = 0; i <= n; i++) {
    final s = secs * i / n;
    phase += 2 * math.pi * k.pitch(s) * secs / n;
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    final click = s < 0.008 ? k.click * (seed / 0x7FFFFFFF * 2 - 1) * (1 - s / 0.008) : 0.0;
    final d = math.max(1.0, k.drive);
    var y = (math.sin(phase) + click) * k.level(s);
    y = _tanh(y * d) / _tanh(d);
    final p = Offset(r.left + r.width * i / n, mid - y * amp);
    i == 0 ? wave.moveTo(p.dx, p.dy) : wave.lineTo(p.dx, p.dy);
  }
  canvas.drawPath(wave, Paint()
    ..color = color.withValues(alpha: 0.9)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.3);
  // The level envelope.
  final env = Path(), envLow = Path();
  for (var i = 0; i <= 80; i++) {
    final s = secs * i / 80;
    final x = r.left + r.width * i / 80;
    i == 0 ? env.moveTo(x, mid - k.level(s) * amp) : env.lineTo(x, mid - k.level(s) * amp);
    i == 0 ? envLow.moveTo(x, mid + k.level(s) * amp) : envLow.lineTo(x, mid + k.level(s) * amp);
  }
  final faint = Paint()
    ..color = color.withValues(alpha: 0.35)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  canvas.drawPath(env, faint);
  canvas.drawPath(envLow, faint);
  // The pitch drop, log-scaled from the tune to 11 × tune, in the top band.
  final top = r.top + 4, band = r.height * 0.22;
  final pitch = Path();
  for (var i = 0; i <= 80; i++) {
    final s = secs * i / 80;
    final v = math.log(k.pitch(s) / k.tune) / math.log(11);
    final p = Offset(r.left + r.width * i / 80, top + band * (1 - v));
    i == 0 ? pitch.moveTo(p.dx, p.dy) : pitch.lineTo(p.dx, p.dy);
  }
  strokeGlow(canvas, pitch, second, width: 2);
  if (labels) {
    paintLabel(canvas, '${k.pitch(0).round()} → ${k.tune.round()} Hz', Offset(r.left + 6, top + band + 8), second, size: 8,
        weight: FontWeight.w700);
  }
}

double _tanh(double x) {
  final e = math.exp(2 * x.clamp(-20.0, 20.0));
  return (e - 1) / (e + 1);
}

/// Deterministic noise for drawing.
class _Noise {
  int _s;
  _Noise(this._s);
  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7FFFFFFF;
    return _s / 0x7FFFFFFF * 2 - 1;
  }
}

/// A snare: a body ringing at [tune] for [body] s under noise lasting [snappy] s at [mix], brighter with [tone] Hz.
void paintSnare(Canvas canvas, Rect r, {required double tune, required double body, required double snappy,
    required double mix, required double tone, required Color color, required Color second, bool labels = true}) {
  final secs = math.min(1.0, math.max(0.15, math.max(body, snappy) * 1.2));
  final mid = r.center.dy + 6, amp = r.height * 0.38;
  final noise = _Noise(11);
  // The noise as a filled spray (second colour), denser with a brighter tone.
  final dens = (0.35 + 0.65 * (math.log(tone / 200) / math.log(60))).clamp(0.2, 1.0);
  for (var i = 0; i < 360; i++) {
    final s = secs * i / 360;
    final lv = mix * math.exp(-6.9 * s / math.max(0.01, snappy));
    final y = noise.next() * lv * amp * dens;
    final x = r.left + r.width * i / 360;
    canvas.drawLine(Offset(x, mid), Offset(x, mid - y), Paint()
      ..color = second.withValues(alpha: 0.55)
      ..strokeWidth = 1);
  }
  final wave = Path();
  var phase = 0.0;
  for (var i = 0; i <= 600; i++) {
    final s = secs * i / 600;
    phase += 2 * math.pi * tune * (1 + 0.3 * math.exp(-s / 0.01)) * secs / 600;
    final y = math.sin(phase) * (1 - mix * 0.5) * math.exp(-6.9 * s / math.max(0.01, body));
    final p = Offset(r.left + r.width * i / 600, mid - y * amp);
    i == 0 ? wave.moveTo(p.dx, p.dy) : wave.lineTo(p.dx, p.dy);
  }
  strokeGlow(canvas, wave, color, width: 1.4, glow: false);
  // Where each part has died away.
  for (final (t, c, label) in [(body, color, 'BODY'), (snappy, second, 'SNAP')]) {
    if (t > secs || !labels) continue;
    final x = r.left + r.width * t / secs;
    canvas.drawLine(Offset(x, r.top + 18), Offset(x, r.bottom - 4), Paint()
      ..color = c.withValues(alpha: 0.4)
      ..strokeWidth = 1);
    paintLabel(canvas, label, Offset(x + 3, r.top + 24), c, size: 8, weight: FontWeight.w800);
  }
}

/// Hats: a closed and an open burst (each to −60 dB over its decay), stripes of their metal partials.
void paintHats(Canvas canvas, Rect r, {required double closed, required double open, required double tone,
    required double metal, required Color color, required Color second, String? active, bool labels = true}) {
  final secs = math.min(2.2, math.max(0.3, open * 1.15));
  final base = r.bottom - 6, top = r.top + 26;
  final noise = _Noise(5);
  final grain = (0.5 + 0.5 * (tone - 2000) / 12000).clamp(0.3, 1.0);
  for (final (decay, c, lane) in [(open, second, 0), (closed, color, 1)]) {
    for (var i = 0; i < 300; i++) {
      final s = secs * i / 300;
      final lv = math.exp(-6.9 * s / math.max(0.005, decay));
      if (lv < 0.01) break;
      final ring = metal * 0.5 * (math.sin(i * 1.7) * 0.5 + 0.5);
      final h = (base - top) * lv * (0.55 + 0.45 * (noise.next().abs() * grain + ring).clamp(0.0, 1.0)) * (lane == 0 ? 0.85 : 1);
      final x = r.left + r.width * i / 300;
      canvas.drawLine(Offset(x, base), Offset(x, base - h), Paint()
        ..color = c.withValues(alpha: lane == 0 ? 0.35 : 0.8)
        ..strokeWidth = 1.2);
    }
    if (!labels) continue;
    final ex = r.left + r.width * (decay / secs).clamp(0.0, 1.0);
    paintHandle(canvas, Offset(ex, base - 4), c, active: active == (lane == 0 ? 'open' : 'closed'), r: 6);
    paintLabel(canvas, lane == 0 ? 'OPEN' : 'CLOSED', Offset(ex, base - 18), c, size: 8, align: 0, weight: FontWeight.w800);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Pads

/// A pad that plays a note on the device's track while held: velocity by where it is struck (soft at the top,
/// full at the bottom, as the keys), a flash on the hit. [shape] draws the drum inside it.
class DrumPad extends StatefulWidget {
  const DrumPad({super.key, required this.note, required this.label, required this.color, this.shape, this.selected = false,
    this.onHit, this.height = 92});
  final int note;
  final String label;
  final Color color;
  final void Function(Canvas canvas, Rect r, Color c)? shape;
  final bool selected;
  final VoidCallback? onHit;
  final double height;

  @override
  State<DrumPad> createState() => _DrumPadState();
}

class _DrumPadState extends State<DrumPad> {
  int? _id;
  double _vel = 0;

  void _down(Offset local, Size size) {
    final s = DeviceScope.of(context).target;
    DeviceFeel.tap();
    _vel = (0.45 + 0.55 * (local.dy / size.height)).clamp(0.2, 1.0);
    _id = s.state.nextPreviewId();
    s.state.previewOn(s.layerId, _id!, widget.note.toDouble(), _vel);
    widget.onHit?.call();
    setState(() {});
  }

  void _up() {
    final id = _id;
    if (id == null) return;
    DeviceScope.of(context).target.state.previewOff(id);
    setState(() => _id = null);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    final hit = _id != null;
    return Semantics(
      button: true,
      label: 'Play ${widget.label}',
      child: LayoutBuilder(builder: (context, box) => Listener(
        key: ValueKey('pad-${widget.note}'),
        onPointerDown: (e) => _down(e.localPosition, Size(box.maxWidth, widget.height)),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: AnimatedContainer(
          duration: Duration(milliseconds: hit ? 0 : 220),
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [
              c.withValues(alpha: hit ? 0.55 : 0.2),
              c.withValues(alpha: hit ? 0.25 : 0.06),
            ]),
            border: Border.all(color: widget.selected || hit ? c : c.withValues(alpha: 0.45), width: widget.selected ? 2 : 1.2),
            boxShadow: [BoxShadow(color: c.withValues(alpha: hit ? 0.55 : (widget.selected ? 0.25 : 0.1)), blurRadius: hit ? 22 : 10)],
          ),
          child: Stack(children: [
            if (widget.shape != null) Positioned.fill(child: Padding(padding: const EdgeInsets.fromLTRB(8, 22, 8, 6),
              child: CustomPaint(painter: _PadShapePainter(widget.shape!, c)))),
            Positioned(left: 10, top: 7, child: Text(widget.label.toUpperCase(), style: TextStyle(fontSize: 10,
              letterSpacing: 1.2, fontWeight: FontWeight.w800, color: hit ? Neon.text : c))),
          ]),
        ),
      )),
    );
  }
}

class _PadShapePainter extends CustomPainter {
  _PadShapePainter(this.shape, this.color);
  final void Function(Canvas canvas, Rect r, Color c) shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => shape(canvas, Offset.zero & size, color);

  @override
  bool shouldRepaint(covariant _PadShapePainter o) => true;
}

// ---------------------------------------------------------------------------------------------------------------
// The drum pages

double taperPos(ComponentParameterInfo? p, double v) => p == null ? 0 : taperOf(p).position(v);
double taperVal(ComponentParameterInfo? p, double pos) => p == null ? 0 : taperOf(p).value(pos);

/// A drum's hero with region drags: [regions] maps a touch to the parameter pair it moves (x then y, either null).
class _ShapeHero extends StatefulWidget {
  const _ShapeHero({super.key, required this.keyName, required this.region, required this.paint, this.caption, this.height = 200});
  final String keyName;
  final (String?, String?) Function(Offset local, Size size) region;
  final void Function(Canvas canvas, Rect r, (String?, String?)? active) paint;
  final String? caption;
  final double height;

  @override
  State<_ShapeHero> createState() => _ShapeHeroState();
}

class _ShapeHeroState extends State<_ShapeHero> {
  (String?, String?)? _active;
  double _x = 0, _y = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return HeroCanvas(color: scope.accent, height: widget.height, caption: widget.caption, child: LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      return GrabGesture(
        key: ValueKey(widget.keyName),
        onStart: (p, _) {
          final r = widget.region(p, size);
          _x = r.$1 == null ? 0 : taperPos(t.param(r.$1!), t.value(r.$1!));
          _y = r.$2 == null ? 0 : taperPos(t.param(r.$2!), t.value(r.$2!));
          setState(() => _active = r);
        },
        onUpdate: (u) {
          final a = _active;
          if (a == null) return;
          final fine = DeviceFingers.fine;
          if (a.$1 case final id?) {
            _x = (_x + u.delta.dx / size.width * fine).clamp(0.0, 1.0);
            t.setLive(id, taperVal(t.param(id), _x));
          }
          if (a.$2 case final id?) {
            _y = (_y - u.delta.dy / size.height * fine).clamp(0.0, 1.0);
            t.setLive(id, taperVal(t.param(id), _y));
          }
        },
        onEnd: () {
          t.commit();
          setState(() => _active = null);
        },
        child: CustomPaint(size: size, painter: _FnPainter((canvas, s) => widget.paint(canvas, Offset.zero & s, _active))),
      );
    }));
  }
}

class _FnPainter extends CustomPainter {
  _FnPainter(this.fn);
  final void Function(Canvas canvas, Size size) fn;

  @override
  void paint(Canvas canvas, Size size) => fn(canvas, size);

  @override
  bool shouldRepaint(covariant _FnPainter o) => true;
}

/// A drum page: the hero, the pads, the knobs.
Widget _drumPage(String id, Widget hero, List<Widget> pads, List<String> knobs, {Map<String, String> labels = const {}}) =>
    effectPage(id, [
      hero,
      Row(children: [
        for (var i = 0; i < pads.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: pads[i]),
        ],
      ]),
      const SizedBox(height: 6),
      KnobRow(knobs, size: 50, labels: labels),
    ]);

/// The kick: its waveform with the pitch drop above. Drag the left of it up and down for punch; elsewhere sideways
/// for the decay, up and down for the tune.
class KickPage extends StatelessWidget {
  const KickPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final k = KickShape(tune: t.value('tune'), punch: t.value('punch'), decay: t.value('decay'), click: t.value('click'),
      drive: t.value('drive'));
    return _drumPage('kick', _ShapeHero(
      keyName: 'kick-hero',
      caption: 'KICK',
      region: (p, size) => p.dx < size.width * 0.22 ? (null, 'punch') : ('decay', 'tune'),
      paint: (canvas, r, a) => paintKick(canvas, r.deflate(8).translate(0, 8), k, scope.accent, scope.secondary),
    ), [DrumPad(note: 36, label: 'Kick', color: padColor(36),
      shape: (canvas, r, c) => paintKick(canvas, r, k, c, Colors.white70, labels: false))],
      ['tune', 'punch', 'decay', 'click', 'tone', 'drive', 'volume']);
  }
}

/// The snare: its body and its noise. The top half drags the noise (sideways snappy, up level), the bottom the body
/// (sideways its ring, up the tune).
class SnarePage extends StatelessWidget {
  const SnarePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    void paint(Canvas canvas, Rect r, Color a, Color b) => paintSnare(canvas, r, tune: t.value('tune'), body: t.value('body'),
        snappy: t.value('snappy'), mix: t.value('mix'), tone: t.value('tone'), color: a, second: b);
    return _drumPage('snare', _ShapeHero(
      keyName: 'snare-hero',
      caption: 'SNARE',
      region: (p, size) => p.dy < size.height / 2 ? ('snappy', 'mix') : ('body', 'tune'),
      paint: (canvas, r, a) => paint(canvas, r.deflate(8), scope.accent, scope.secondary),
    ), [DrumPad(note: 38, label: 'Snare', color: padColor(38), shape: (canvas, r, c) => paintSnare(canvas, r, tune: t.value('tune'), body: t.value('body'),
        snappy: t.value('snappy'), mix: t.value('mix'), tone: t.value('tone'), color: c, second: Colors.white54, labels: false))],
      ['tune', 'body', 'snappy', 'tone', 'mix', 'volume']);
  }
}

/// The hats: the closed and open bursts. Drag sideways near either end for that decay, up and down for the tone.
class HatsPage extends StatelessWidget {
  const HatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    void paint(Canvas canvas, Rect r, Color a, Color b, String? active) => paintHats(canvas, r, closed: t.value('closed'),
        open: t.value('open'), tone: t.value('tone'), metal: t.value('metal'), color: a, second: b, active: active);
    return effectPage('hats', [
      _ShapeHero(
        keyName: 'hats-hero',
        caption: 'HATS',
        region: (p, size) {
          final secs = math.min(2.2, math.max(0.3, t.value('open') * 1.15));
          final cx = size.width * t.value('closed') / secs;
          return ((p.dx - cx).abs() < size.width * 0.12 ? 'closed' : 'open', 'tone');
        },
        paint: (canvas, r, a) => paint(canvas, r.deflate(8), scope.accent, scope.secondary, a?.$1),
      ),
      Row(children: [
        Expanded(child: DrumPad(note: 42, label: 'Closed', color: padColor(42),
          shape: (canvas, r, c) => paintHats(canvas, r, closed: t.value('closed'), open: t.value('closed'), tone: t.value('tone'),
            metal: t.value('metal'), color: c, second: c, labels: false))),
        const SizedBox(width: 8),
        Expanded(child: DrumPad(note: 46, label: 'Open', color: padColor(46),
          shape: (canvas, r, c) => paintHats(canvas, r, closed: t.value('open'), open: t.value('open'), tone: t.value('tone'),
            metal: t.value('metal'), color: c, second: c, labels: false))),
      ]),
      const SizedBox(height: 6),
      const Row(children: [
        Text('PLAYS', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)),
        SizedBox(width: 8),
        Flexible(child: DeviceChoice('mode')),
      ]),
      const KnobRow(['closed', 'open', 'tone', 'metal', 'volume'], size: 50),
    ]);
  }
}

/// The kit: a grid of pads (tap plays and picks), the picked drum's sound and knobs, and the mix.
class KitPage extends StatefulWidget {
  const KitPage({super.key});

  @override
  State<KitPage> createState() => _KitPageState();
}

class _KitPageState extends State<KitPage> {
  int _pad = 36;

  static const pads = [(36, 'Kick'), (38, 'Snare'), (39, 'Clap'), (42, 'Closed hat'), (44, 'Pedal hat'), (46, 'Open hat')];

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final kick = KickShape(tune: t.value('kick_tune'), punch: t.value('kick_punch'), decay: t.value('kick_decay'));
    void hats(Canvas canvas, Rect r, Color a, Color b, double decay, bool big, {String? active}) => paintHats(canvas, r,
        closed: math.min(decay, t.value('hat_closed')), open: decay, tone: t.value('hat_tone'), metal: 0.5, color: a, second: b,
        active: active, labels: big);
    void clap(Canvas canvas, Rect r, Color a, Color b, bool big) => paintSnare(canvas, r, tune: 1200, body: 0.005,
        snappy: t.value('clap_decay'), mix: 1, tone: 3000, color: a, second: b, labels: big);
    void snare(Canvas canvas, Rect r, Color a, Color b, bool big) => paintSnare(canvas, r, tune: t.value('snare_tune'), body: 0.07,
        snappy: t.value('snare_snappy'), mix: 0.5, tone: 2500, color: a, second: b, labels: big);
    void shape(int note, Canvas canvas, Rect r, Color a, Color b, String? active) {
      final big = r.height > 80;
      switch (note) {
        case 36:
          paintKick(canvas, r, kick, a, b, labels: big);
        case 38:
          snare(canvas, r, a, b, big);
        case 39:
          clap(canvas, r, a, b, big);
        case 46:
          hats(canvas, r, a, b, t.value('hat_open'), big, active: active);
        default:
          hats(canvas, r, a, b, t.value('hat_closed'), big, active: active);
      }
    }
    final c = padColor(_pad);
    final (String?, String?) Function(Offset, Size) region = switch (_pad) {
      36 => (p, size) => p.dx < size.width * 0.22 ? (null, 'kick_punch') : ('kick_decay', 'kick_tune'),
      38 => (p, size) => ('snare_snappy', 'snare_tune'),
      39 => (p, size) => ('clap_decay', 'clap'),
      46 => (p, size) => ('hat_open', 'hat_tone'),
      _ => (p, size) => ('hat_closed', 'hat_tone'),
    };
    final knobs = switch (_pad) {
      36 => ['kick_tune', 'kick_punch', 'kick_decay', 'kick'],
      38 => ['snare_tune', 'snare_snappy', 'snare'],
      39 => ['clap_decay', 'clap'],
      _ => ['hat_closed', 'hat_open', 'hat_tone', 'hats'],
    };
    return effectPage('kit', [
      LayoutBuilder(builder: (context, box) {
        final cols = box.maxWidth > 600 ? 6 : 3;
        final rows = <Widget>[];
        for (var i = 0; i < pads.length; i += cols) {
          rows.add(Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
            for (var k = i; k < i + cols && k < pads.length; k++) ...[
              if (k > i) const SizedBox(width: 8),
              Expanded(child: DrumPad(
                note: pads[k].$1, label: pads[k].$2, color: padColor(pads[k].$1), height: 84, selected: pads[k].$1 == _pad,
                shape: (canvas, r, col) => shape(pads[k].$1, canvas, r, col, Colors.white60, null),
                onHit: () => setState(() => _pad = pads[k].$1))),
            ],
          ])));
        }
        return Column(children: rows);
      }),
      ControlGroup(title: pads.firstWhere((p) => p.$1 == _pad).$2.toUpperCase(), color: c, child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _ShapeHero(
            key: ValueKey('kit-hero-$_pad'),
            keyName: 'kit-hero',
            height: 150,
            region: region,
            paint: (canvas, r, a) => shape(_pad, canvas, r.deflate(8), c, scope.secondary, a?.$1 == 'hat_open' ? 'open' : (a == null ? null : 'closed')),
          ),
          KnobRow(knobs, size: 50, labels: const {
            'kick_tune': 'Tune', 'kick_punch': 'Punch', 'kick_decay': 'Decay', 'kick': 'Level', 'snare_tune': 'Tune',
            'snare_snappy': 'Snappy', 'snare': 'Level', 'clap_decay': 'Decay', 'clap': 'Level', 'hat_closed': 'Closed',
            'hat_open': 'Open', 'hat_tone': 'Tone', 'hats': 'Level',
          }),
        ])),
      ControlGroup(title: 'MIX', color: scope.accent, child: const KnobRow(['kick', 'snare', 'clap', 'hats', 'volume'], size: 42,
        labels: {'kick': 'Kick', 'snare': 'Snare', 'clap': 'Clap', 'hats': 'Hats'})),
    ]);
  }
}
