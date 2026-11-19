// The flagship editor's own tools: its view state (panel, keys, "What's modulating?"), Init, Random patch, oscillator copy and paste, and the keys strip to play while editing.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/device_target.dart';
import '../../arrange/knob.dart' show Taper;
import '../../motion.dart';
import '../../panel_motion.dart';
import '../../theme.dart';
import '../device_scope.dart';
import '../kit/feel.dart';
import '../kit/presets.dart';

/// What the flagship's page shows besides the device's values: the phone's panel, the keys strip and the
/// "What's modulating?" highlight. One per open editor ([FlagshipUiScope]); the keys strip's choice outlives it.
class FlagshipUi extends ChangeNotifier {
  /// Whether the keys strip shows (kept while the app runs, so it stays out once put away).
  static bool keysShown = false;

  bool get keys => keysShown;
  set keys(bool on) {
    keysShown = on;
    notifyListeners();
  }

  bool _whoMods = false;

  /// Every knob says what modulates it (sources' colours and names), unmodulated knobs fade.
  bool get whoMods => _whoMods;
  set whoMods(bool on) {
    _whoMods = on;
    notifyListeners();
  }

  /// The knob whose sources the highlight names alone (a route tapped in the matrix list); null: every knob.
  String? _only;
  String? get only => _only;

  /// Turns the highlight on for [paramId] alone, or off when it already is.
  void showSources(String paramId) {
    if (_whoMods && _only == paramId) {
      _whoMods = false;
      _only = null;
    } else {
      _whoMods = true;
      _only = paramId;
    }
    notifyListeners();
  }

  void showAll(bool on) {
    _whoMods = on;
    _only = null;
    notifyListeners();
  }

  static FlagshipUi? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FlagshipUiScope>()?.notifier;
}

class FlagshipUiScope extends InheritedNotifier<FlagshipUi> {
  const FlagshipUiScope({super.key, required FlagshipUi ui, required super.child}) : super(notifier: ui);
}

/// Init: the defaults (the preset browser's Init, one undo step).
void initFlagship(DeviceTarget t) {
  final init = DevicePresets.factory(t).firstWhere((p) => p.name == 'Init', orElse: () => const DevicePreset('Init', {}));
  DevicePresets.apply(t, init);
}

/// Parameters a random patch leaves alone: the matrix, the voice's playing setup, every power switch (a random
/// patch keeps what is on), and the output volume.
final _keep = RegExp(r'^(mod\d+_|volume$|velocity$|bend_range$|voice_mode$|glide|.*_on$)');

/// Whether a random patch (this one, or the header's ⋯ › Randomize) leaves parameter [id] alone.
bool flagshipRandomKeeps(String id) => _keep.hasMatch(id);

/// The source of randomness (tests seed it).
math.Random flagshipRandom = math.Random();

/// A random patch [amount] of the way (0..1) from the current one: each knob moves that far towards a random
/// point of its travel, and each choice changes with that chance (never to the User table, which may be empty).
/// One undo step.
void randomizeFlagship(DeviceTarget t, double amount, {math.Random? random}) {
  final rng = random ?? flagshipRandom;
  final info = t.info;
  if (info == null || amount <= 0) return;
  final out = <String, double>{};
  for (final p in info.parameters) {
    if (flagshipRandomKeeps(p.id)) continue;
    final v = t.value(p.id);
    if (p.isChoice) {
      if (rng.nextDouble() >= amount) continue;
      var n = p.choices.length;
      if (p.id.endsWith('_table')) n -= 1; // not User
      if (n > 0) out[p.id] = p.min + rng.nextInt(n);
      continue;
    }
    final taper = Taper(p.min, p.max, exponential: p.exponential);
    final pos = taper.position(v);
    var next = taper.value(pos + (rng.nextDouble() - pos) * amount);
    if (p.step > 0) next = (next / p.step).round() * p.step;
    out[p.id] = next;
  }
  t.state.endUndoStep();  // an edit still settling stays a step of its own
  t.setAll(out);
  t.state.endUndoStep();
}

/// Copied oscillator settings (each `oscN_` value by its suffix), for Paste on another one.
Map<String, double>? flagshipOscClipboard;

/// Copies oscillator [n]'s settings.
void copyOscillator(DeviceTarget t, int n) {
  final p = 'osc${n}_';
  flagshipOscClipboard = {
    for (final x in t.info?.parameters ?? const []) if (x.id.startsWith(p)) x.id.substring(p.length): t.value(x.id),
  };
}

/// Pastes the copied settings into oscillator [n] (one undo step); false with nothing copied.
bool pasteOscillator(DeviceTarget t, int n) {
  final c = flagshipOscClipboard;
  if (c == null) return false;
  t.state.endUndoStep();
  t.setAll({for (final e in c.entries) if (t.param('osc${n}_${e.key}') != null) 'osc${n}_${e.key}': e.value});
  t.state.endUndoStep();
  return true;
}

/// Asks how far to move for a random patch: the amount, or null when cancelled.
Future<double?> askRandomAmount(BuildContext context) => showDialog<double>(
  context: context, animationStyle: dialogAnimation(context), builder: (_) => const _RandomDialog());

class _RandomDialog extends StatefulWidget {
  const _RandomDialog();

  @override
  State<_RandomDialog> createState() => _RandomDialogState();
}

class _RandomDialogState extends State<_RandomDialog> {
  static double _last = 0.5;
  late double _amount = _last;

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('flagship-random-dialog'),
    title: const Text('Random patch'),
    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('How far from this sound: ${(_amount * 100).round()}%', style: const TextStyle(fontSize: 13)),
      Slider(key: const ValueKey('flagship-random-amount'), value: _amount, divisions: 20,
        onChanged: (v) => setState(() => _amount = v)),
      const Text('Power switches, the matrix and the volume stay. Undo takes it back.',
        style: TextStyle(fontSize: 11, color: Neon.dim)),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(key: const ValueKey('flagship-random-go'), onPressed: () {
        _last = _amount;
        Navigator.pop(context, _amount);
      }, child: const Text('Randomize')),
    ],
  );
}

/// The toolbar's buttons: Init, Random patch, What's modulating? and the keys strip.
class FlagshipActions extends StatelessWidget {
  const FlagshipActions({super.key, required this.ui});
  final FlagshipUi ui;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    Widget button(String key, String tip, IconData icon, VoidCallback onTap, {bool on = false}) => IconButton(
      key: ValueKey(key), tooltip: tip, iconSize: 19, visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
      color: on ? scope.accent : Neon.dim,
      style: on ? IconButton.styleFrom(backgroundColor: scope.accent.withValues(alpha: 0.16)) : null,
      onPressed: () {
        DeviceFeel.tap();
        onTap();
      },
      icon: Icon(icon));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      button('flagship-init', 'Init: every knob to its default', Icons.restart_alt, () => initFlagship(t)),
      button('flagship-random', 'Random patch…', Icons.casino_outlined, () async {
        final a = await askRandomAmount(context);
        if (a != null) randomizeFlagship(t, a);
      }),
      button('flagship-whomods', 'What\'s modulating? Every knob names its sources', Icons.hub_outlined,
        () => ui.showAll(!ui.whoMods), on: ui.whoMods),
      button('flagship-keys-toggle', ui.keys ? 'Hide the keys' : 'Show keys to play while editing', Icons.piano,
        () => ui.keys = !ui.keys, on: ui.keys),
    ]);
  }
}

/// A two-octave keyboard to play the synth while editing: each finger plays the key under it (sliding plays the
/// next), velocity from how far down the key it lands; ‹ › shift the octave.
class FlagshipKeys extends StatefulWidget {
  const FlagshipKeys({super.key, this.height = 64});
  final double height;

  @override
  State<FlagshipKeys> createState() => _FlagshipKeysState();
}

class _FlagshipKeysState extends State<FlagshipKeys> {
  static int _base = 48; // C3
  final Map<int, (int id, int note)> _held = {};
  DeviceTarget? _t;

  static bool _black(int n) => const {1, 3, 6, 8, 10}.contains(n % 12);

  @override
  void dispose() {
    for (final h in _held.values) {
      _t?.state.previewOff(h.$1);
    }
    super.dispose();
  }

  /// The note under [at] in a keyboard [size] wide: black keys over the top 60 %.
  int _noteAt(Offset at, Size size) {
    final wk = size.width / 15;
    final white = (at.dx / wk).floor().clamp(0, 14);
    final note = _base + _whiteToNote(white);
    if (at.dy < size.height * 0.6) {
      final frac = at.dx / wk - white;
      if (frac < 0.3 && white > 0 && _black(note - 1)) return note - 1;
      if (frac > 0.7 && _black(note + 1) && white < 14) return note + 1;
    }
    return note;
  }

  static int _whiteToNote(int w) => 12 * (w ~/ 7) + const [0, 2, 4, 5, 7, 9, 11][w % 7];

  void _on(int pointer, int note, double vel) {
    final t = _t!;
    final id = t.state.nextPreviewId();
    t.state.previewOn(t.layerId, id, note.toDouble(), vel);
    setState(() => _held[pointer] = (id, note));
  }

  void _off(int pointer) {
    final h = _held.remove(pointer);
    if (h == null) return;
    _t?.state.previewOff(h.$1);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    _t = scope.target;
    final accent = scope.accent;
    Widget shift(String key, IconData icon, int by) => SizedBox(width: 34, child: IconButton(
      key: ValueKey(key), padding: EdgeInsets.zero, iconSize: 20, color: Neon.dim,
      tooltip: by < 0 ? 'Octave down' : 'Octave up',
      onPressed: () => setState(() => _base = (_base + by).clamp(12, 96)),
      icon: Icon(icon)));
    return Container(
      key: const ValueKey('flagship-keys'),
      height: widget.height,
      decoration: BoxDecoration(border: Border(top: BorderSide(color: accent.withValues(alpha: 0.35)))),
      child: Row(children: [
        shift('flagship-keys-down', Icons.chevron_left, -12),
        Expanded(child: LayoutBuilder(builder: (context, box) {
          final size = Size(box.maxWidth, widget.height - 6);
          double vel(Offset at) => (0.35 + 0.65 * (at.dy / size.height)).clamp(0.1, 1.0);
          return Padding(padding: const EdgeInsets.only(top: 3, bottom: 3), child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              DeviceFeel.tap();
              _on(e.pointer, _noteAt(e.localPosition, size), vel(e.localPosition));
            },
            onPointerMove: (e) {
              final h = _held[e.pointer];
              final n = _noteAt(e.localPosition, size);
              if (h != null && h.$2 != n) {
                _off(e.pointer);
                _on(e.pointer, n, vel(e.localPosition));
              }
            },
            onPointerUp: (e) => _off(e.pointer),
            onPointerCancel: (e) => _off(e.pointer),
            child: CustomPaint(size: size, painter: _KeysPainter(_base, {for (final h in _held.values) h.$2}, accent)),
          ));
        })),
        shift('flagship-keys-up', Icons.chevron_right, 12),
      ]),
    );
  }
}

class _KeysPainter extends CustomPainter {
  _KeysPainter(this.base, this.held, this.accent);
  final int base;
  final Set<int> held;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final wk = size.width / 15;
    final r = Radius.circular(math.min(4, wk / 5));
    for (var w = 0; w < 15; w++) {
      final note = base + _FlagshipKeysState._whiteToNote(w);
      final rect = Rect.fromLTWH(w * wk + 0.75, 0, wk - 1.5, size.height);
      canvas.drawRRect(RRect.fromRectAndCorners(rect, bottomLeft: r, bottomRight: r),
        Paint()..color = held.contains(note) ? Color.lerp(const Color(0xFFDADAE2), accent, 0.65)! : const Color(0xFFDADAE2));
      if (note % 12 == 0) {
        final tp = TextPainter(text: TextSpan(text: 'C${note ~/ 12 - 1}',
          style: const TextStyle(fontSize: 8, color: Color(0xFF55555F))), textDirection: TextDirection.ltr)..layout();
        tp.paint(canvas, Offset(rect.center.dx - tp.width / 2, size.height - tp.height - 2));
      }
    }
    for (var w = 0; w < 15; w++) {
      final note = base + _FlagshipKeysState._whiteToNote(w);
      if (w < 14 && _FlagshipKeysState._black(note + 1)) {
        final rect = Rect.fromLTWH((w + 0.68) * wk, 0, wk * 0.64, size.height * 0.6);
        canvas.drawRRect(RRect.fromRectAndCorners(rect, bottomLeft: r, bottomRight: r),
          Paint()..color = held.contains(note + 1) ? accent : const Color(0xFF1A1A22));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _KeysPainter o) => o.base != base || o.accent != accent || !_same(o.held, held);

  static bool _same(Set<int> a, Set<int> b) => a.length == b.length && a.containsAll(b);
}

/// A row of page dots: the phone's panels, the one shown lit; a tap goes to one.
class PanelDots extends StatelessWidget {
  const PanelDots({super.key, required this.count, required this.index, required this.onPick, required this.color});
  final int count, index;
  final ValueChanged<int> onPick;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    for (var i = 0; i < count; i++)
      GestureDetector(
        key: ValueKey('flagship-dot-$i'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onPick(i),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 10), child: AnimatedContainer(
          duration: Motion.fade(Motion.small, Motion.of(context)),
          width: i == index ? 16 : 7, height: 7,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(4),
            color: i == index ? color : Neon.ink.withValues(alpha: 0.22)))),
      ),
  ]);
}
