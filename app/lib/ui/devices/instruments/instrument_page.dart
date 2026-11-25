// The 1.1.3 instruments' shared page in Kestrel's one-screen layout (Timber's, upgraded): the variant cards and the instrument drawn live on top with the variant's own knobs under it, the tone and space panels below, the mod-source strip at the bottom; a phone held upright swipes three named panels under the picture.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../model/device_display.dart';
import '../../../model/device_target.dart';
import '../../../model/sampler.dart' show noteName;
import '../../../model/settings.dart' show SoundQuality;
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_registry.dart';
import '../device_scope.dart';
import '../effects/eqfilter/variant_cards.dart' show VariantCards;
import '../flagship/flagship_panels.dart';
import '../flagship/flagship_tools.dart' show FlagshipKeys, FlagshipUi, FlagshipUiScope, PanelDots;
import '../kit/controls.dart' show ChoiceIcon, KnobRow;
import '../kit/device_style.dart';
import '../kit/feel.dart';
import '../kit/hero.dart';
import '../kit/touch_engage.dart';

/// Width from which the page is one screen; narrower, the picture over three panels.
const double instrumentWide = 700;

/// The knobs every 1.1.3 instrument shares (timber_core.h's frame), by panel: the tone panel's and the space panel's.
const instrumentToneKnobs = ['tone', 'body', 'velocity', 'release'];
const instrumentSpaceKnobs = ['space', 'level', 'voices'];
const _shared = {...instrumentToneKnobs, ...instrumentSpaceKnobs, 'variant'};

/// Short names for the shared knobs.
const instrumentLabels = <String, String>{
  'tone': 'Tone', 'body': 'Body', 'velocity': 'Velocity', 'release': 'Release', 'space': 'Room', 'level': 'Level',
  'voices': 'Voices', 'attack': 'Attack', 'vib_rate': 'Vib rate', 'vibrato': 'Vibrato', 'decay': 'Decay',
};

/// What an instrument's display frame says (docs/engine.md, Display data: timber_core.h's 16 floats): the shared
/// floats 0–8, the model's own from 9.
class InstrumentFrame {
  const InstrumentFrame(this.f);
  final DeviceDisplayFrame? f;
  double _at(int i, [double d = 0]) => f?.at(i, d) ?? d;
  bool get live => f != null && _at(0) >= 1;
  int get sounding => _at(2).round();
  int get cap => _at(3).round();
  double get peakDb => _at(4, -120);
  double get pedal => _at(5);
  int get lastKey => _at(6, -1).round();
  double get lastVelocity => _at(7);
  double own(int i) => _at(9 + i);
}

/// What a picture draws: the variant, the device's values ([value]), the newest frame, the motion clock and colours.
class InstrumentPicture {
  const InstrumentPicture({required this.variant, required this.name, required this.value, required this.frame,
    required this.seconds, required this.accent, required this.secondary});
  final int variant;

  /// The variant's name as the engine gives it ("Violin", "Tubular bells"); the device's name when it has none.
  final String name;
  final double Function(String id) value;
  final InstrumentFrame frame;
  final double seconds;
  final Color accent, secondary;

  /// How much the instrument is sounding, 0..1 (the output peak over 54 dB).
  double get energy => frame.live && frame.sounding > 0 ? dbUnit(frame.peakDb, floor: 54) : 0;

  /// The energy weighted by the last note's velocity: how far a string or bar swings.
  double get swing => energy * (0.4 + 0.6 * frame.lastVelocity.clamp(0, 1));

  /// The last key's place among [count] strings, bars or pipes over MIDI [low]..[high] (−1: none played yet).
  int struck(int count, {int low = 21, int high = 108}) {
    final k = frame.lastKey;
    if (k < 0 || !frame.live) return -1;
    return ((k - low).clamp(0, high - low) / (high - low + 1) * count).floor().clamp(0, count - 1);
  }
}

/// Where a drag on the picture goes: [x] moved sideways ([xSign] −1: right lowers it), [y] up and down (up raises
/// it). The whole range over [span] of the picture's size.
class PictureDrag {
  const PictureDrag({this.x, this.y, this.xSign = 1, this.span = 0.85});
  final String? x, y;
  final double xSign, span;
}

/// One of the page's three panels: its [name] (the phone's dot row, the footer's) and its content at a knob size.
class InstrumentPanel {
  const InstrumentPanel(this.name, this.build);
  final String name;
  final Widget Function(BuildContext context, double knob) build;
}

/// One instrument's page: its picture, its drags and its three panels.
class InstrumentSpec {
  const InstrumentSpec({
    required this.id,
    required this.key,
    required this.title,
    required this.icon,
    required this.panels,
    required this.painter,
    required this.hint,
    this.cardIcon,
    this.cardNames,
    this.caption,
    this.drag,
    this.twoAxes = false,
    this.inlineKnobs = const [],
  });

  /// The component id and the prefix of the page's widget keys ("nightingale" → `nightingale-page`).
  final String id, key;

  /// The picture's caption when the variant adds nothing ("PIPE ORGAN").
  final String title;
  final IconData icon;

  /// Exactly three: the first is the instrument's own controls (under the picture on a wide screen).
  final List<InstrumentPanel> panels;
  final CustomPainter Function(InstrumentPicture p) painter;

  /// The wide screen's one-line hint over the picture.
  final String hint;
  final ChoiceIcon? cardIcon;
  final List<String>? cardNames;

  /// The picture's caption for a variant; null: its name in capitals.
  final String Function(DeviceTarget t, InstrumentPicture p)? caption;

  /// What a drag starting at a point of the picture moves; null: nothing.
  final PictureDrag? Function(DeviceTarget t, int variant, Offset at, Size size)? drag;

  /// The drag takes both axes (a pan, sideways at once) instead of up and down alone.
  final bool twoAxes;

  /// The track card's first knobs (then Tone, Room and Release).
  final List<String> inlineKnobs;

  /// The editor entry: one section, the variant picked by the cards, the mod-source strip at the bottom.
  DeviceEditorEntry entry() => DeviceEditorEntry(
    (_) => [DeviceSection(key, title, icon, (_) => InstrumentPage(spec: this), stripAtBottom: true)],
    family: DeviceFamily.synth,
    ownsVariant: true,
    inline: (_) => InstrumentInline(spec: this),
  );
}

/// The variant the device under [context] plays.
int instrumentVariantOf(BuildContext context) => DeviceScope.of(context).target.info?.variantIndex ?? 0;

/// [t]'s variant name as the engine gives it, or [fallback].
String instrumentVariantName(DeviceTarget t, String fallback) {
  final id = t.componentId;
  final choices = id == null ? const <String>[] : t.state.componentInfo(id)?.param('variant')?.choices ?? const <String>[];
  final k = t.info?.variantIndex ?? 0;
  return k < choices.length ? choices[k] : fallback;
}

/// The quality tier [t] plays at: its own Quality choice (`tier`: Setting, Eco, Normal, High), or the setting's.
SoundQuality instrumentQuality(DeviceTarget t) {
  final tier = t.value('tier').round();
  if (t.param('tier') != null && tier > 0) return SoundQuality.values[(tier - 1).clamp(0, 2)];
  return t.state.settings.soundQuality;
}

/// The variant's own controls: its choices (the descriptor's, not shared), then its knobs in [order] first and any
/// other own knob it declares after them (a new variant's knobs show without a change here); [hide] leaves some out.
class InstrumentOwnControls extends StatelessWidget {
  const InstrumentOwnControls({super.key, required this.prefix, this.order = const [], this.labels = const {},
    this.hide = const {}, this.knob = 40, this.exclude = const {}});
  final String prefix;
  final List<String> order;
  final Map<String, String> labels;
  final Set<String> hide, exclude;
  final double knob;

  /// [t]'s own choices and knobs as [order] sorts them.
  static ({List<String> choices, List<String> knobs}) of(DeviceTarget t, List<String> order, Set<String> skip) {
    final params = t.info?.parameters ?? const [];
    final own = [for (final p in params) if (!_shared.contains(p.id) && !skip.contains(p.id)) p];
    final choices = [for (final p in own) if (p.isChoice) p.id];
    final knobs = [
      for (final id in order) if (own.any((p) => p.id == id && !p.isChoice)) id,
      for (final p in own) if (!p.isChoice && !order.contains(p.id)) p.id,
    ];
    return (choices: choices, knobs: knobs);
  }

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final variant = instrumentVariantOf(context);
    final c = of(t, order, {...hide, ...exclude});
    return AnimatedSwitcher(
      duration: Motion.fade(Motion.small, Motion.of(context)),
      child: Column(key: ValueKey('$prefix-controls-$variant'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (c.choices.isNotEmpty) ...[
          const SizedBox(height: 4),
          LayoutBuilder(builder: (context, box) {
            final cols = box.maxWidth >= 600 ? c.choices.length : c.choices.length.clamp(1, 2);
            final w = (box.maxWidth - 8 * (cols - 1)) / cols;
            final alone = c.choices.length % cols == 1 && c.choices.length > 1;
            return Wrap(spacing: 8, runSpacing: 6, children: [
              for (final (i, id) in c.choices.indexed)
                SizedBox(width: alone && i == c.choices.length - 1 ? box.maxWidth : w,
                    child: DeviceChoice(id, maxSegments: 4, label: labels[id] ?? t.param(id)?.label)),
            ]);
          }),
        ],
        FKnobRow(c.knobs, size: knob, labels: {...instrumentLabels, ...labels}),
      ]),
    );
  }
}

/// A panel of knobs (the shared Tone and Space panels).
Widget instrumentKnobPanel(List<String> ids, double knob, {Map<String, String> labels = const {}}) =>
    FKnobRow(ids, size: knob, labels: {...instrumentLabels, ...labels});

/// An instrument's one page.
class InstrumentPage extends StatefulWidget {
  const InstrumentPage({super.key, required this.spec});
  final InstrumentSpec spec;

  @override
  State<InstrumentPage> createState() => _InstrumentPageState();
}

class _InstrumentPageState extends State<InstrumentPage> {
  final _ui = FlagshipUi();
  final _pages = PageController();
  bool _narrow = false;
  int _panel = 0;

  InstrumentSpec get spec => widget.spec;
  String get k => spec.key;

  @override
  void dispose() {
    _pages.dispose();
    _ui.dispose();
    super.dispose();
  }

  void _goTo(int i) {
    if (!_narrow || !_pages.hasClients) return;
    i = i.clamp(0, spec.panels.length - 1);
    final d = Motion.fade(Motion.standard * 2, Motion.of(context));
    d == Duration.zero ? _pages.jumpToPage(i) : _pages.animateToPage(i, duration: d, curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) => FlagshipUiScope(ui: _ui, child: ListenableBuilder(listenable: _ui,
    builder: (context, _) => LayoutBuilder(builder: (context, box) {
      _narrow = box.maxWidth < instrumentWide;
      final accent = DeviceScope.of(context).accent;
      return Column(key: ValueKey('$k-page'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _toolbar(accent),
        Expanded(child: _narrow ? _phone() : _wide(box.maxWidth)),
        foldSize(context, _ui.keys ? const FlagshipKeys() : const SizedBox(width: double.infinity)),
      ]);
    })));

  Widget _toolbar(Color accent) => SizedBox(height: 40, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(children: [
      if (_narrow) ...[
        PanelDots(count: spec.panels.length, index: _panel, color: accent, onPick: _goTo),
        const SizedBox(width: 6),
        Flexible(child: AnimatedSwitcher(duration: Motion.fade(Motion.small, Motion.of(context)),
          child: Text(spec.panels[_panel].name.toUpperCase(), key: ValueKey('$k-panel-name'), maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: Neon.text)))),
      ] else
        Flexible(child: Text(spec.hint, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Neon.dim))),
      const Spacer(),
      IconButton(
        key: ValueKey('$k-keys-toggle'), tooltip: _ui.keys ? 'Hide the keys' : 'Show keys to play while editing',
        iconSize: 19, visualDensity: VisualDensity.compact, color: _ui.keys ? accent : Neon.dim,
        style: _ui.keys ? IconButton.styleFrom(backgroundColor: accent.withValues(alpha: 0.16)) : null,
        icon: const Icon(Icons.piano),
        onPressed: () {
          DeviceFeel.tap();
          _ui.keys = !_ui.keys;
        }),
    ])));

  /// The centrepiece: the variant cards over the instrument drawn live; [withOwn] puts the first panel's controls
  /// under it (the wide screen; the phone has them on its first panel).
  Widget _centrepiece({required double height, required double knob, required bool withOwn}) => FPanel(
    key: ValueKey('$k-centrepiece'),
    title: 'INSTRUMENT',
    trailing: [InstrumentVoices(prefix: k)],
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (spec.cardIcon != null) ...[
        VariantCards(key: ValueKey('$k-variants'), icon: spec.cardIcon!, names: spec.cardNames, height: 50),
        const SizedBox(height: 6),
      ],
      InstrumentVisual(spec: spec, height: height),
      if (withOwn) spec.panels.first.build(context, knob),
    ]),
  );

  Widget _panelBox(int i, double knob) => FPanel(key: ValueKey('$k-${spec.panels[i].name.toLowerCase()}'),
      title: spec.panels[i].name.toUpperCase(), child: spec.panels[i].build(context, knob));

  /// The one screen: the instrument and its own controls, then the other two panels side by side.
  Widget _wide(double width) {
    final roomy = width >= 1200;
    final knob = roomy ? 40.0 : 34.0;
    const gap = SizedBox(width: 8, height: 8);
    return SingleChildScrollView(key: ValueKey('$k-wide'), padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _centrepiece(height: roomy ? 220 : 180, knob: knob, withOwn: true),
        gap,
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 4, child: _panelBox(1, knob)),
          gap,
          Expanded(flex: 3, child: _panelBox(2, knob)),
        ]),
      ]));
  }

  /// The phone: the cards and the picture stay on top; under them the three panels swipe sideways, each scrolling.
  Widget _phone() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: _centrepiece(height: 130, knob: 40, withOwn: false)),
    Expanded(child: PageView(
      key: ValueKey('$k-pages'),
      controller: _pages,
      onPageChanged: (i) {
        Motion.tick();
        setState(() => _panel = i);
      },
      children: [
        for (var i = 0; i < spec.panels.length; i++)
          ListView(key: ValueKey('$k-panel-$i'), padding: const EdgeInsets.fromLTRB(8, 8, 8, 24), children: [_panelBox(i, 40)]),
      ],
    )),
  ]);
}

/// "3 / 16 voices": what sounds now against the cap, from the display; the Voices knob while it is silent.
class InstrumentVoices extends StatelessWidget {
  const InstrumentVoices({super.key, required this.prefix});
  final String prefix;

  @override
  Widget build(BuildContext context) => DeviceDisplay(builder: (context, f) {
    final fr = InstrumentFrame(f);
    final t = DeviceScope.of(context).target;
    final text = fr.live ? '${fr.sounding} / ${fr.cap} voices' : '${t.value('voices').round()} voices';
    return Text(text, key: ValueKey('$prefix-voices'), style: const TextStyle(fontSize: 10, color: Neon.dim));
  });
}

/// The instrument drawn live in a hero canvas from the display data; a drag on it sets what [InstrumentSpec.drag]
/// names, following the finger.
class InstrumentVisual extends StatefulWidget {
  const InstrumentVisual({super.key, required this.spec, this.height = 160});
  final InstrumentSpec spec;
  final double height;

  @override
  State<InstrumentVisual> createState() => _InstrumentVisualState();
}

class _InstrumentVisualState extends State<InstrumentVisual> {
  PictureDrag? _drag;
  Offset _start = Offset.zero;
  double _fromX = 0, _fromY = 0;

  void _down(DeviceTarget t, int variant, Offset at, Size size) {
    final g = widget.spec.drag?.call(t, variant, at, size);
    _drag = g;
    _start = at;
    if (g == null) return;
    if (g.x != null) _fromX = t.value(g.x!);
    if (g.y != null) _fromY = t.value(g.y!);
  }

  void _move(DeviceTarget t, Offset at, Size size) {
    final g = _drag;
    if (g == null) return;
    final d = at - _start;
    void put(String id, double from, double unit) {
      final p = t.param(id);
      if (p == null) return;
      final span = p.max - p.min;
      t.setLive(id, (from + unit * span).clamp(p.min, p.max).toDouble());
    }
    if (g.x != null) put(g.x!, _fromX, g.xSign * d.dx / (size.width * g.span));
    if (g.y != null) put(g.y!, _fromY, -d.dy / (size.height * g.span));
  }

  void _up(DeviceTarget t) {
    if (_drag == null) return;
    _drag = null;
    t.commit();
    DeviceFeel.tap();
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final variant = instrumentVariantOf(context);
    final style = deviceStyle(DeviceFamily.synth);
    final spec = widget.spec;
    final name = instrumentVariantName(t, spec.title);
    InstrumentPicture picture(InstrumentFrame f, double seconds) => InstrumentPicture(variant: variant, name: name,
        value: t.value, frame: f, seconds: seconds, accent: scope.accent, secondary: style.secondary);
    final cap = spec.caption?.call(t, picture(const InstrumentFrame(null), 0)) ?? name.toUpperCase();
    return HeroCanvas(
      key: ValueKey('${spec.key}-visual'),
      color: scope.accent,
      height: widget.height,
      caption: cap,
      readout: DeviceDisplay(builder: (context, f) {
        final fr = InstrumentFrame(f);
        return Text(fr.live && fr.lastKey >= 0 ? noteName(fr.lastKey) : '', key: ValueKey('${spec.key}-last-key'));
      }),
      child: LayoutBuilder(builder: (context, box) {
        final size = box.biggest;
        final art = AnimatedSwitcher(
          duration: Motion.fade(Motion.standard, Motion.of(context)),
          // At the picture's size (tight constraints): a motion frame's relayout stays inside it, not the page.
          child: SizedBox.fromSize(key: ValueKey('${spec.key}-picture-$variant'), size: size, child: DeviceDisplay(
            builder: (context, f) => DevicePhase(builder: (context, seconds) =>
                CustomPaint(size: size, painter: spec.painter(picture(InstrumentFrame(f), seconds)))))));
        if (spec.drag == null) return art;
        if (spec.twoAxes) {
          // Sideways at once, any direction after a short rest (the knobs' pan), so a quick up-and-down swipe scrolls.
          return RawGestureDetector(
            key: ValueKey('${spec.key}-grab'),
            behavior: HitTestBehavior.opaque,
            gestures: {
              EngageKnobPanRecognizer: GestureRecognizerFactoryWithHandlers<EngageKnobPanRecognizer>(
                () => EngageKnobPanRecognizer(debugOwner: this),
                (r) => r
                  ..onStart = ((d) => _down(t, variant, d.localPosition, size))
                  ..onUpdate = ((d) => _move(t, d.localPosition, size))
                  ..onEnd = ((_) => _up(t))
                  ..onCancel = (() => _up(t)),
              ),
            },
            child: art,
          );
        }
        // Up and down: after a short rest or a slow start, so a quick swipe still scrolls (kit/touch_engage.dart).
        return EngageVerticalDrag(
          key: ValueKey('${spec.key}-grab'),
          onStart: (d) => _down(t, variant, d.localPosition, size),
          onUpdate: (d) => _move(t, d.localPosition, size),
          onEnd: (_) => _up(t),
          onCancel: () => _up(t),
          child: art,
        );
      }),
    );
  }
}

/// The track card's inline controls: the cards, then the spec's first knobs, Tone, Room and Release.
class InstrumentInline extends StatelessWidget {
  const InstrumentInline({super.key, required this.spec});
  final InstrumentSpec spec;

  @override
  Widget build(BuildContext context) => Column(key: ValueKey('${spec.key}-inline'), crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (spec.cardIcon != null) VariantCards(icon: spec.cardIcon!, names: spec.cardNames, height: 42),
      KnobRow([...spec.inlineKnobs, 'tone', 'space', 'release'], size: 40, labels: instrumentLabels),
    ]);
}

/// A stroke paint for the pictures.
Paint instrumentLine(Color c, double w) => Paint()
  ..color = c
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeCap = StrokeCap.round;
