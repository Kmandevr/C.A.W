// The drums' pads: the Kit/Single switch and A..D banks, a 4×4 grid lit by each pad's peak (tap plays and picks), and the pad's long-press menu.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../model/app_state.dart';
import '../../../model/device_display.dart';
import '../../../model/device_target.dart';
import '../../../model/drums.dart';
import '../../arrange/long_press_menu.dart';
import '../../feedback.dart';
import '../../haptics.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/device_style.dart';
import '../kit/feel.dart';
import 'drums_samples.dart';

/// Which pad and bank a Drums device shows, and the pad listening for a note to learn; shared by its inline view
/// and its full editor.
class DrumsSelection {
  final pad = ValueNotifier<int>(0);
  final bank = ValueNotifier<int>(0);
  final learning = ValueNotifier<int?>(null);

  static final Map<String, DrumsSelection> _all = {};

  static DrumsSelection of(DeviceTarget t) => _all.putIfAbsent('${t.layerId}/${t.slot}', DrumsSelection.new);

  /// Forgets every selection (tests).
  static void reset() => _all.clear();

  /// Picks pad [i] (its bank comes with it) and has the engine show it in the display data.
  void select(DeviceTarget t, int i) {
    pad.value = i;
    bank.value = i ~/ drumPadsPerBank;
    if (t.value('view_pad').round() != i + 1) t.setLive('view_pad', i + 1.0);
  }
}

/// The layout of the drums [t] shows.
DrumsLayout drumsLayout(DeviceTarget t) => DrumsLayout.of(t.info!);

/// A pad's colour by its drum type: kicks red, snares yellow, claps pink, hats blue and mint, toms orange,
/// cymbals violet, the rest green.
Color drumTypeColor(int type) {
  final c = spectrumColors(); // pink, orange, yellow, green, mint, blue, violet, red
  return switch (type) {
    0 || 14 => c[7],
    1 || 10 => c[2],
    2 => c[0],
    3 || 5 => c[5],
    4 => c[4],
    6 => c[1],
    7 || 8 || 9 => c[6],
    _ => c[3],
  };
}

/// Short or long-press a message near the bottom.
void drumsToast(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
}

/// The row over the grid: Kit / Single, then the four banks, each with a dot while it holds a sound.
class DrumBankBar extends StatelessWidget {
  const DrumBankBar({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final layout = drumsLayout(t);
    final sel = DrumsSelection.of(t);
    return SizedBox(height: 40, child: Row(children: [
      const DeviceChoice('mode', labels: ['KIT', 'SINGLE']),
      const SizedBox(width: 8),
      Expanded(child: ValueListenableBuilder<int>(valueListenable: sel.bank, builder: (context, bank, _) => Row(children: [
        for (var b = 0; b < drumBanks; b++)
          Expanded(child: Padding(padding: EdgeInsets.only(left: b == 0 ? 0 : 4), child: _BankButton(
            bank: b, selected: b == bank, used: [for (var i = 0; i < drumPadsPerBank; i++)
              DrumPadView(t, layout, b * drumPadsPerBank + i).used].any((u) => u),
            onTap: () {
              DeviceFeel.tap();
              sel.bank.value = b;
            }))),
      ]))),
    ]));
  }
}

class _BankButton extends StatelessWidget {
  const _BankButton({required this.bank, required this.selected, required this.used, required this.onTap});
  final int bank;
  final bool selected, used;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = DeviceScope.of(context).accent;
    return Semantics(button: true, selected: selected, label: 'Bank ${bankLabel(bank)}', child: GestureDetector(
      key: ValueKey('drum-bank-$bank'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Pressable(glow: c, child: AnimatedContainer(
        duration: Motion.fade(Motion.small, Motion.of(context)),
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          color: selected ? c.withValues(alpha: 0.22) : Colors.white.withValues(alpha: 0.03),
          border: Border.all(color: selected ? c : Neon.line),
          boxShadow: selected ? [BoxShadow(color: c.withValues(alpha: 0.3), blurRadius: 8)] : null),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(bankLabel(bank), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900,
            color: selected ? Neon.text : Neon.dim)),
          if (used) Container(width: 5, height: 5, margin: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(shape: BoxShape.circle, color: Neon.green)),
        ]),
      )),
    ));
  }
}

/// The selected bank as 4 × 4 pads, pad 1 at the bottom left as on an MPC (13..16 on top). [height] is a pad's.
class DrumPadGrid extends StatelessWidget {
  const DrumPadGrid({super.key, this.padHeight = 64, this.gap = 6});
  final double padHeight, gap;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final sel = DrumsSelection.of(t);
    return ListenableBuilder(listenable: Listenable.merge([sel.bank, sel.pad, sel.learning]), builder: (context, _) {
      final bank = sel.bank.value;
      return Column(key: const ValueKey('drum-grid'), mainAxisSize: MainAxisSize.min, children: [
        for (var r = 0; r < 4; r++)
          Padding(padding: EdgeInsets.only(top: r == 0 ? 0 : gap), child: Row(children: [
            for (var c = 0; c < 4; c++) ...[
              if (c > 0) SizedBox(width: gap),
              Expanded(child: DrumPadTile(
                pad: bank * drumPadsPerBank + (3 - r) * 4 + c,
                height: padHeight,
                selected: sel.pad.value == bank * drumPadsPerBank + (3 - r) * 4 + c,
                learning: sel.learning.value == bank * drumPadsPerBank + (3 - r) * 4 + c)),
            ],
          ])),
      ]);
    });
  }
}

/// One pad: its name, sound and note, lit by its peak from the display data; a touch plays it (softer toward the
/// top, as the keys) and picks it, a long-press opens its menu.
class DrumPadTile extends StatefulWidget {
  const DrumPadTile({super.key, required this.pad, this.height = 64, this.selected = false, this.learning = false});
  final int pad;
  final double height;
  final bool selected, learning;

  @override
  State<DrumPadTile> createState() => _DrumPadTileState();
}

class _DrumPadTileState extends State<DrumPadTile> {
  int? _voice;
  AppState? _state;

  void _down(Offset local) {
    final t = DeviceScope.of(context).target;
    final layout = drumsLayout(t);
    DeviceFeel.tap();
    DrumsSelection.of(t).select(t, widget.pad);
    final note = auditionNote(t, layout, widget.pad);
    if (note == null) return;
    final vel = (0.45 + 0.55 * (local.dy / widget.height)).clamp(0.2, 1.0).toDouble();
    _state = t.state;
    _voice = t.state.nextPreviewId();
    t.state.previewOn(t.layerId, _voice!, note.toDouble(), vel);
    setState(() {});
  }

  void _up() {
    final id = _voice;
    if (id == null) return;
    _state?.previewOff(id);
    setState(() => _voice = null);
  }

  @override
  void dispose() {
    // The tile can go with a finger still down (a bank switched under it): its note ends with it.
    if (_voice case final id?) _state?.previewOff(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final layout = drumsLayout(t);
    final p = DrumPadView(t, layout, widget.pad);
    final used = p.used;
    final c = used ? drumTypeColor(p.v('type').round()) : Neon.dim;
    final hit = _voice != null;
    final single = t.value('mode').round() == 1;
    final silent = single && widget.pad != 0;
    final note = single ? (widget.pad == 0 ? 'ALL' : null) : switch (t.value(p.id('note')).round()) {
      1 => 'OFF',
      2 => 'ANY',
      _ => noteName(padNote(t, layout, widget.pad) ?? 0),
    };
    final sample = padSample(t, widget.pad);
    final live = TickerMode.valuesOf(context).enabled;
    final frames = live ? DeviceDisplaySource.current.frames(t) : null;
    final label = '${padLabel(widget.pad)} ${used ? p.typeName : 'empty'}';
    return Semantics(
      button: true,
      selected: widget.selected,
      label: 'Pad $label',
      child: GestureDetector(
        onLongPressStart: (d) => showDrumPadMenu(context, t, widget.pad, d.globalPosition),
        onSecondaryTapUp: (d) => showDrumPadMenu(context, t, widget.pad, d.globalPosition),
        child: Listener(
          key: ValueKey('drum-pad-${widget.pad}'),
          onPointerDown: (e) => _down(e.localPosition),
          onPointerUp: (_) => _up(),
          onPointerCancel: (_) => _up(),
          child: Pressable(glow: c, radius: 12, child: AnimatedOpacity(
            duration: Motion.fade(Motion.small, Motion.of(context)),
            opacity: silent ? 0.45 : 1,
            child: Container(
              height: widget.height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [
                  c.withValues(alpha: hit ? 0.5 : (used ? 0.18 : 0.05)),
                  c.withValues(alpha: hit ? 0.22 : (used ? 0.05 : 0.02)),
                ]),
                border: Border.all(
                  color: widget.learning ? Neon.yellow : (widget.selected ? c : c.withValues(alpha: used ? 0.45 : 0.2)),
                  width: widget.selected || widget.learning ? 2 : 1),
                boxShadow: widget.selected ? [BoxShadow(color: c.withValues(alpha: 0.3), blurRadius: 10)] : null,
              ),
              child: Stack(fit: StackFit.expand, children: [
                if (frames != null) RepaintBoundary(child: CustomPaint(
                  painter: _PeakGlow(frames, widget.pad, c))),
                Padding(padding: const EdgeInsets.fromLTRB(7, 5, 6, 4), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(padLabel(widget.pad), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900,
                        letterSpacing: 0.6, color: widget.selected ? Neon.text : c)),
                      const Spacer(),
                      if (p.choke > 0) _Badge('C${p.choke}', Neon.violet),
                      if (sample != null) const Icon(Icons.graphic_eq, size: 11, color: Neon.blue),
                    ]),
                    const Spacer(),
                    if (widget.height >= 52) Text(used ? p.typeName : '—', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: used ? Neon.text : Neon.dim)),
                    if (note != null) Text(widget.learning ? 'LEARN…' : note, maxLines: 1,
                      style: Neon.code(size: 9, color: widget.learning ? Neon.yellow : Neon.dim)),
                  ])),
              ]),
            ),
          )),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(right: 3),
    padding: const EdgeInsets.symmetric(horizontal: 3),
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.7))),
    child: Text(text, style: TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: color)),
  );
}

/// The pad's light: its peak in the newest display frame, repainted from the frames without rebuilding the pad.
class _PeakGlow extends CustomPainter {
  _PeakGlow(this.frames, this.pad, this.color) : super(repaint: frames);
  final ValueListenable<DeviceDisplayFrame?> frames;
  final int pad;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final f = frames.value;
    if (f is! DrumsDisplayFrame) return;
    final peak = f.peaks[pad];
    if (peak <= 0) return;
    final a = math.sqrt(peak.clamp(0.0, 1.0)).toDouble();
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12));
    canvas.drawRRect(r, Paint()..color = color.withValues(alpha: 0.45 * a));
    canvas.drawRRect(r.deflate(1), Paint()
      ..color = color.withValues(alpha: 0.9 * a)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
  }

  @override
  bool shouldRepaint(covariant _PeakGlow o) => o.frames != frames || o.pad != pad || o.color != color;
}

// ---------------------------------------------------------------------------------------------------------------
// The pad menu

enum _PadAction { type, sound, copy, paste, clear, choke, learn, randomize, mutate, sample }

/// The pad's long-press menu: type, a library sound, copy / paste / clear, choke group, learn its note, randomize,
/// mutate and load a sample.
Future<void> showDrumPadMenu(BuildContext context, DeviceTarget t, int pad, Offset at) async {
  final layout = drumsLayout(t);
  final sel = DrumsSelection.of(t);
  sel.select(t, pad);
  Haptics.grab();
  final p = DrumPadView(t, layout, pad);
  final a = await showLongPressMenu<_PadAction>(context, at: at, title: '${padLabel(pad)} · ${p.used ? p.typeName : 'Empty'}',
    actions: [
      MenuAction(_PadAction.type, 'Type: ${p.typeName}', Icons.category_outlined),
      if (DrumsApi.current.sounds() != null) const MenuAction(_PadAction.sound, 'Load sound…', Icons.library_music_outlined),
      const MenuAction(_PadAction.sample, 'Load sample…', Icons.graphic_eq),
      const MenuAction(_PadAction.randomize, 'Randomize', Icons.casino_outlined),
      const MenuAction(_PadAction.mutate, 'Mutate', Icons.auto_fix_high),
      MenuAction(_PadAction.choke, 'Choke: ${p.choke == 0 ? 'Off' : 'group ${p.choke}'}', Icons.content_cut),
      MenuAction(_PadAction.learn, sel.learning.value == pad ? 'Stop learning' : 'Learn note', Icons.hearing_outlined),
      const MenuAction(_PadAction.copy, 'Copy', Icons.copy),
      MenuAction(_PadAction.paste, 'Paste', Icons.paste, enabled: DrumsClipboard.pad != null, hint: 'Copy a pad first'),
      const MenuAction(_PadAction.clear, 'Clear', Icons.delete_outline, danger: true),
    ]);
  if (a == null || !context.mounted) return;
  switch (a) {
    case _PadAction.type:
      final param = t.param(p.id('type'));
      if (param == null) return;
      final k = await showLongPressMenu<int>(context, at: at, title: 'Drum type', actions: [
        for (var i = 0; i < param.choices.length; i++)
          MenuAction(i, param.choices[i], Icons.circle, checked: p.v('type').round() == i),
      ]);
      if (k != null) t.set(p.id('type'), k.toDouble());
    case _PadAction.sound:
      final sounds = DrumsApi.current.sounds() ?? const [];
      final k = await showLongPressMenu<int>(context, at: at, title: 'Load a sound', actions: [
        for (var i = 0; i < sounds.length; i++) MenuAction(i, sounds[i].name, Icons.music_note),
      ]);
      if (k != null) {
        loadSound(t, layout, pad, sounds[k].params);
        if (context.mounted) drumsToast(context, '${padLabel(pad)}: ${sounds[k].name}');
      }
    case _PadAction.copy:
      copyPad(t, layout, pad);
      drumsToast(context, 'Copied ${padLabel(pad)}');
    case _PadAction.paste:
      pastePad(t, layout, pad);
    case _PadAction.clear:
      clearPad(t, layout, pad);
    case _PadAction.choke:
      final k = await showLongPressMenu<int>(context, at: at, title: 'Choke group', actions: [
        for (var g = 0; g <= 8; g++) MenuAction(g, g == 0 ? 'Off' : 'Group $g', Icons.content_cut, checked: p.choke == g),
      ]);
      if (k != null) t.set(p.id('choke'), k.toDouble());
    case _PadAction.learn:
      toggleLearn(context, t, pad);
    case _PadAction.randomize:
      if (!randomizePad(t, layout, pad)) drumsToast(context, 'Randomize needs the engine');
    case _PadAction.mutate:
      if (!mutatePad(t, layout, pad)) drumsToast(context, 'Mutate needs the engine');
    case _PadAction.sample:
      await showDrumSamplePicker(context, t, pad);
  }
}

/// Starts (or stops) pad [pad] listening for the next MIDI note ([DrumLearn] writes it).
void toggleLearn(BuildContext context, DeviceTarget t, int pad) {
  final sel = DrumsSelection.of(t);
  sel.learning.value = sel.learning.value == pad ? null : pad;
  DeviceFeel.tap();
  if (sel.learning.value != null) drumsToast(context, 'Play a note for ${padLabel(pad)}');
}

/// Note learn: while a pad listens, the next note the drums receive (the display's last-note count changing) is
/// written into its note map (`3 + key`), with a tick and a message.
class DrumLearn extends StatefulWidget {
  const DrumLearn({super.key, required this.child});
  final Widget child;

  @override
  State<DrumLearn> createState() => _DrumLearnState();
}

class _DrumLearnState extends State<DrumLearn> {
  DrumsSelection? _sel;
  DeviceTarget? _t;
  ValueListenable<DeviceDisplayFrame?>? _frames;
  int? _baseline;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final t = DeviceScope.of(context).target;
    if (_t?.layerId != t.layerId || _t?.slot != t.slot) {
      _sel?.learning.removeListener(_learning);
      _t = t;
      _sel = DrumsSelection.of(t)..learning.addListener(_learning);
      _learning();
    }
  }

  void _learning() {
    final on = _sel!.learning.value != null;
    if (on && _frames == null) {
      _baseline = null;
      _frames = DeviceDisplaySource.current.frames(_t!)..addListener(_frame);
      _frame();
    } else if (!on && _frames != null) {
      _frames!.removeListener(_frame);
      _frames = null;
    }
  }

  void _frame() {
    final f = _frames?.value;
    final pad = _sel?.learning.value;
    if (f is! DrumsDisplayFrame || pad == null) return;
    if (_baseline == null) {
      _baseline = f.noteCount;
      return;
    }
    if (f.noteCount == _baseline || f.lastNote < 0) return;
    final t = _t!;
    t.set(drumsLayout(t).id(pad, 'note'), noteValueFor(f.lastNote));
    Haptics.tick();
    _sel!.learning.value = null;
    if (mounted) drumsToast(context, '${padLabel(pad)} plays ${noteName(f.lastNote)} (${f.lastNote})');
  }

  @override
  void dispose() {
    _sel?.learning.removeListener(_learning);
    _frames?.removeListener(_frame);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
