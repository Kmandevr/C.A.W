// Bittern's page (org.caw.bittern, pipe organ): the pipe façade drawn live, its drawn ranks glowing (drag a rank up and down for its stop's level) beside the swell box's shutters, its 33 stops and the Chimes as drawknob pills by division under the registration, and the Stops, Wind and Room panels with the room's Hall, Loft and Dry.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/device_target.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/birds.dart';
import '../kit/feel.dart';
import '../kit/hero.dart';
import '../kit/touch_engage.dart';
import 'instrument_page.dart';

const bitternComponentId = 'org.caw.bittern';

/// The divisions, as the Tabernacle organ has them (engine/src/bittern_organ.h): the Great, the Swell and the Choir
/// (each in its swell box), the Antiphonal and the Pedal.
const bitternDivisions = ['GREAT', 'SWELL', 'CHOIR', 'ANTIPHONAL', 'PEDAL'];

/// The stops in the engine's order (engine/src/builtin_bittern.cpp), as the pills name them, with each one's division
/// and its rank's sounding length in feet (the façade's pipe heights; the mixtures' IV ranks drawn at 2', the two-rank
/// celestes at 8').
const bitternStops = <({String id, String name, String foot, double feet, int division})>[
  (id: 'subprincipal16', name: 'Subprincipal', foot: "16'", feet: 16, division: 0),
  (id: 'principal8', name: 'Principal', foot: "8'", feet: 8, division: 0),
  (id: 'flute_harm8', name: 'Flûte Harm.', foot: "8'", feet: 8, division: 0),
  (id: 'octave4', name: 'Octave', foot: "4'", feet: 4, division: 0),
  (id: 'fifteenth2', name: 'Super Octave', foot: "2'", feet: 2, division: 0),
  (id: 'mixture', name: 'Fourniture', foot: 'IV', feet: 2, division: 0),
  (id: 'trumpet8', name: 'Trumpet', foot: "8'", feet: 8, division: 0),
  (id: 'geigen8', name: 'Geigen', foot: "8'", feet: 8, division: 1),
  (id: 'rohrflute8', name: 'Gedeckt', foot: "8'", feet: 8, division: 1),
  (id: 'gamba8', name: 'Viole Céleste', foot: 'II', feet: 8, division: 1),
  (id: 'flute4', name: 'Fl. Traverso', foot: "4'", feet: 4, division: 1),
  (id: 'nazard', name: 'Nazard', foot: "2 2/3'", feet: 2.67, division: 1),
  (id: 'tierce', name: 'Tierce', foot: "1 3/5'", feet: 1.6, division: 1),
  (id: 'plein_jeu', name: 'Plein Jeu', foot: 'IV', feet: 2, division: 1),
  (id: 'trompette8', name: 'Trompette', foot: "8'", feet: 8, division: 1),
  (id: 'hautbois8', name: 'Hautbois', foot: "8'", feet: 8, division: 1),
  (id: 'concert_flute8', name: 'Concert Flute', foot: "8'", feet: 8, division: 2),
  (id: 'erzahler8', name: 'Kl. Erzähler', foot: 'II', feet: 8, division: 2),
  (id: 'krummhorn8', name: 'Krummhorn', foot: "8'", feet: 8, division: 2),
  (id: 'tuba8', name: 'Tuba Mirabilis', foot: "8'", feet: 8, division: 3),
  (id: 'subbass32', name: 'Contre Bourdon', foot: "32'", feet: 32, division: 4),
  (id: 'ped_principal16', name: 'Principal', foot: "16'", feet: 16, division: 4),
  (id: 'bourdon16', name: 'Bourdon', foot: "16'", feet: 16, division: 4),
  (id: 'ped_principal8', name: 'Principal', foot: "8'", feet: 8, division: 4),
  (id: 'trombone16', name: 'Trombone', foot: "16'", feet: 16, division: 4),
  (id: 'bombarde32', name: 'Bombarde', foot: "32'", feet: 32, division: 4),
  (id: 'gemshorn4', name: 'Gemshorn', foot: "4'", feet: 4, division: 0),
  (id: 'voix_humaine8', name: 'Voix Humaine', foot: "8'", feet: 8, division: 1),
  (id: 'violin8', name: 'Violin', foot: "8'", feet: 8, division: 2),
  (id: 'cello8', name: 'Violoncello', foot: "8'", feet: 8, division: 2),
  (id: 'chimes', name: 'Chimes', foot: 'G3-G5', feet: 4, division: 2),
  (id: 'contrabass16', name: 'Contrabass', foot: "16'", feet: 16, division: 4),
  (id: 'quint10', name: 'Quint', foot: "10 2/3'", feet: 10.67, division: 4),
  (id: 'choral_bass4', name: 'Choral Bass', foot: "4'", feet: 4, division: 4),
];

/// The reed stops (their pipes drawn flared).
const _reeds = {'trumpet8', 'trompette8', 'hautbois8', 'krummhorn8', 'tuba8', 'trombone16', 'bombarde32', 'voix_humaine8'};

/// The Room choices and the Room (`space`) each sets: the engine's own presets' (the Tabernacle's hall the default 0.45, the
/// Loft preset's 0.15, the Dry one's 0).
const bitternRooms = <(String, double)>[('Hall', 0.45), ('Loft', 0.15), ('Dry', 0)];

/// The façade's area (the swell box takes the right).
Rect _facade(Size s) => Rect.fromLTRB(s.width * 0.03, s.height * 0.14, s.width * 0.8, s.height * 0.96);

/// The stop whose rank is under [x] in a picture [width] wide.
int bitternRankAt(double x, double width) {
  final r = _facade(Size(width, 1));
  return ((x - r.left) / (r.width / bitternStops.length)).floor().clamp(0, bitternStops.length - 1);
}

final bitternSpec = InstrumentSpec(
  id: bitternComponentId,
  key: 'bittern',
  title: 'PIPE ORGAN',
  icon: Icons.church_outlined,
  hint: 'Draw stops, then play: the ranks you drew glow with what sounds. Drag a rank up and down for its level.',
  caption: (t, p) => 'PIPE ORGAN · ${bitternStops.where((s) => t.value(s.id) > 0).length} STOPS DRAWN',
  drag: (t, variant, at, size) =>
      at.dx > _facade(size).right ? null : PictureDrag(y: bitternStops[bitternRankAt(at.dx, size.width)].id, span: 0.8),
  painter: (p) => BitternPainter(p),
  inlineKnobs: const ['principal8', 'octave4', 'chiff', 'wind'],
  panels: [
    InstrumentPanel('Stops', (context, knob) => const BitternStops()),
    InstrumentPanel('Wind', (context, knob) => instrumentKnobPanel(const ['swell', 'tremulant', 'trem_rate', 'wind', 'chiff'], knob,
        labels: const {'swell': 'Swell', 'tremulant': 'Tremulant', 'trem_rate': 'Trem rate', 'wind': 'Wind', 'chiff': 'Chiff'})),
    InstrumentPanel('Room', (context, knob) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 4),
      const BitternRoom(),
      instrumentKnobPanel(['weight', 'spread', ...instrumentSpaceKnobs, ...instrumentToneKnobs], knob, labels: const {'weight': 'Weight', 'spread': 'Spread'}),
    ])),
  ],
);

/// The façade: each stop a rank of pipes (taller for a longer foot), glowing while drawn and brighter as it sounds,
/// the trumpet's flared, the swell box's shutters at the right, and the bittern standing on the case's top.
class BitternPainter extends CustomPainter {
  BitternPainter(this.p);
  final InstrumentPicture p;

  @override
  void paint(Canvas canvas, Size s) {
    if (s.isEmpty) return;
    final f = _facade(s);
    final w = f.width / bitternStops.length;
    final base = f.bottom - 10;
    // The case's floor (the impost) and the key the last note played lighting its pipe in every drawn rank.
    canvas.drawLine(Offset(f.left, base + 3), Offset(f.right, base + 3), instrumentLine(Neon.ink.withValues(alpha: 0.35), 2));
    final hit = p.struck(5, low: 36, high: 96);
    var tallest = 0.0, tallestX = f.center.dx;
    for (var i = 0; i < bitternStops.length; i++) {
      final st = bitternStops[i];
      final level = p.value(st.id).clamp(0.0, 1.0);
      final drawn = level > 0;
      // Height: log of the foot (32' the case's full height, 1 3/5' about a fifth of it).
      final h = (f.height - 26) * (0.22 + 0.78 * (math.log(st.feet) / math.log(32)).clamp(0.0, 1.0));
      final cx = f.left + w * (i + 0.5);
      final glow = drawn ? 0.25 + 0.45 * level + 0.3 * p.energy : 0.0;
      final c = drawn ? p.accent : Neon.dim;
      final pipes = st.foot == 'IV' ? 3 : 2;
      for (var j = 0; j < pipes; j++) {
        final pw = w * 0.7 / pipes;
        final x = cx - w * 0.35 + pw * (j + 0.5);
        final ph = h * (1 - j * 0.12);
        final top = base - ph;
        final body = Rect.fromLTRB(x - pw * 0.36, top, x + pw * 0.36, base - ph * 0.12);
        final lit = drawn && hit == j + 1;
        canvas.drawRect(body, Paint()..color = c.withValues(alpha: drawn ? 0.12 + glow * (lit ? 0.9 : 0.55) : 0.06));
        canvas.drawRect(body, instrumentLine(c.withValues(alpha: drawn ? 0.5 + 0.5 * glow : 0.25), 0.9));
        // The mouth (a flue's) or the reed's flared resonator, then the foot into the windchest.
        if (_reeds.contains(st.id)) {
          canvas.drawPath(Path()
            ..moveTo(body.left - pw * 0.15, top)
            ..lineTo(body.right + pw * 0.15, top)
            ..lineTo(body.right, top + ph * 0.12)
            ..lineTo(body.left, top + ph * 0.12)
            ..close(), Paint()..color = c.withValues(alpha: drawn ? 0.3 + glow * 0.5 : 0.1));
        } else {
          canvas.drawLine(Offset(body.left + 1, body.bottom - pw * 0.6), Offset(body.right - 1, body.bottom - pw * 0.6),
              instrumentLine(Neon.bg.withValues(alpha: 0.8), 1));
        }
        canvas.drawPath(Path()
          ..moveTo(body.left, body.bottom)
          ..lineTo(x, base)
          ..lineTo(body.right, body.bottom), instrumentLine(c.withValues(alpha: 0.4), 0.8));
      }
      if (h > tallest) {
        tallest = h;
        tallestX = cx;
      }
      // A drawn stop's level as a short bar under its rank.
      canvas.drawLine(Offset(cx - w * 0.35, base + 7), Offset(cx - w * 0.35 + w * 0.7 * level, base + 7),
          instrumentLine(p.accent.withValues(alpha: drawn ? 0.9 : 0), 2));
    }
    // The one motif: a bittern standing on the tallest tower, its throat filling as the organ sounds.
    paintBittern(canvas, Offset(tallestX, base - tallest - 3), s.height * 0.13, p.accent, boom: p.energy);
    _swell(canvas, Rect.fromLTRB(s.width * 0.83, s.height * 0.3, s.width * 0.97, s.height * 0.9));
  }

  /// The swell box: a frame of shutters (the mod wheel opens and closes them in the engine; drawn half open, as the
  /// display does not say how far).
  void _swell(Canvas canvas, Rect r) {
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)), Paint()..color = Neon.ink.withValues(alpha: 0.05));
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)), instrumentLine(p.accent.withValues(alpha: 0.4), 1.1));
    const n = 7;
    for (var i = 0; i < n; i++) {
      final y = r.top + r.height * (i + 0.5) / n;
      final open = 0.5 + 0.2 * p.energy;
      final dy = r.height / n * 0.45 * (1 - open);
      canvas.drawLine(Offset(r.left + 4, y - dy), Offset(r.right - 4, y + dy), instrumentLine(Neon.ink.withValues(alpha: 0.45), 2));
    }
    paintLabel(canvas, 'SWELL', Offset(r.center.dx, r.top - 8), Neon.dim, size: 7.5, align: 0);
  }

  @override
  bool shouldRepaint(covariant BitternPainter o) => true;
}

/// The registration (the usual combinations, one tap) over the stops as drawknob pills by division: a tap draws or
/// pushes in a stop (back to its default level, or full when that is none), an up-and-down drag sets its level, shown
/// as the pill's fill; the Pedal's division says which key its stops play.
class BitternStops extends StatelessWidget {
  const BitternStops({super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final cols = box.maxWidth >= 600 ? 7 : box.maxWidth >= 380 ? 4 : 3;
    final w = (box.maxWidth - 6 * (cols - 1)) / cols;
    Widget label(String text) => Padding(padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Text(text, style: const TextStyle(fontSize: 9.5, letterSpacing: 1.1, fontWeight: FontWeight.w800, color: Neon.dim)));
    return Padding(padding: const EdgeInsets.only(top: 4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [label('REGISTRATION'), const Spacer(), const DeviceChoice('registration')]),
      for (var d = 0; d < bitternDivisions.length; d++) ...[
        Row(children: [
          label(bitternDivisions[d]),
          if (d == bitternDivisions.length - 1) ...[const Spacer(), const DeviceChoice('pedal')],
        ]),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final st in bitternStops)
            if (st.division == d) SizedBox(width: w, child: _Drawknob(st.id, st.name, st.foot)),
        ]),
      ],
    ]));
  });
}

class _Drawknob extends StatefulWidget {
  const _Drawknob(this.id, this.name, this.foot);
  final String id, name, foot;

  @override
  State<_Drawknob> createState() => _DrawknobState();
}

class _DrawknobState extends State<_Drawknob> {
  double _from = 0, _start = 0;

  void _tap(DeviceTarget t) {
    final p = t.param(widget.id);
    if (p == null) return;
    final on = t.value(widget.id) > 0;
    t.set(widget.id, on ? 0 : (p.defaultValue > 0 ? p.defaultValue : 1));
    DeviceFeel.tap();
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final level = t.value(widget.id).clamp(0.0, 1.0);
    final on = level > 0;
    final c = scope.accent;
    final d = Motion.fade(Motion.small, Motion.of(context));
    return Semantics(
      button: true,
      toggled: on,
      label: '${widget.name} ${widget.foot}',
      value: '${(level * 100).round()} %',
      child: EngageVerticalDrag(
        onStart: (e) {
          _from = level;
          _start = e.localPosition.dy;
          DeviceFeel.tap();
        },
        onUpdate: (e) => t.setLive(widget.id, (_from - (e.localPosition.dy - _start) / 120).clamp(0.0, 1.0)),
        onEnd: (_) => t.commit(),
        onCancel: () => t.commit(),
        child: GestureDetector(
          key: ValueKey('bittern-stop-${widget.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _tap(t),
          child: AnimatedContainer(
            duration: d,
            height: 44,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              color: on ? c.withValues(alpha: 0.12) : Neon.ink.withValues(alpha: 0.03),
              border: Border.all(color: on ? c : Neon.line, width: on ? 1.5 : 1),
              boxShadow: on ? [BoxShadow(color: c.withValues(alpha: 0.22), blurRadius: 10)] : null,
            ),
            child: Stack(fit: StackFit.expand, children: [
              // The level: the pill filled from the bottom.
              Align(alignment: Alignment.bottomCenter, child: AnimatedFractionallySizedBox(duration: d, widthFactor: 1,
                  heightFactor: level, child: ColoredBox(color: c.withValues(alpha: 0.22)))),
              Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5,
                    fontWeight: FontWeight.w800, color: on ? Neon.text : Neon.dim)),
                Text(widget.foot, maxLines: 1, style: TextStyle(fontSize: 9, color: on ? c : Neon.dim)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The room: Hall, Loft or Dry, each setting the Room knob to its preset's value; the one nearest the knob is lit.
class BitternRoom extends StatelessWidget {
  const BitternRoom({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final v = t.value('space');
    var near = 0;
    for (var i = 1; i < bitternRooms.length; i++) {
      if ((bitternRooms[i].$2 - v).abs() < (bitternRooms[near].$2 - v).abs()) near = i;
    }
    final d = Motion.fade(Motion.small, Motion.of(context));
    return Row(children: [
      for (final (i, room) in bitternRooms.indexed)
        Expanded(child: Padding(padding: EdgeInsets.only(right: i < bitternRooms.length - 1 ? 6 : 0), child: GestureDetector(
          key: ValueKey('bittern-room-$i'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            t.set('space', room.$2);
            DeviceFeel.tap();
          },
          child: AnimatedContainer(
            duration: d,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: i == near ? scope.accent.withValues(alpha: 0.18) : Neon.ink.withValues(alpha: 0.03),
              border: Border.all(color: i == near ? scope.accent : Neon.line, width: i == near ? 1.5 : 1),
            ),
            child: Text(room.$1.toUpperCase(), style: TextStyle(fontSize: 10, letterSpacing: 0.8, fontWeight: FontWeight.w800,
                color: i == near ? Neon.text : Neon.dim)),
          ),
        ))),
    ]);
  }
}
