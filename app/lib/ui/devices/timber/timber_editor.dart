// Timber's editor (org.caw.timber) in Raven's one-screen layout: the model cards and the instrument drawn live on top with the model's own knobs under it, the envelope, tone and space panels below, the mod-source strip at the bottom; a phone held upright swipes three panels (Model, Sound, Space) under the picture.
import 'package:flutter/material.dart';

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
import '../kit/controls.dart' show KnobRow;
import '../kit/device_style.dart';
import '../kit/feel.dart';
import '../kit/hero.dart';
import '../kit/touch_engage.dart';
import 'timber_visual.dart';

export 'timber_visual.dart';

const timberComponentId = 'org.caw.timber';

final Map<String, DeviceEditorEntry> timberEditors = {
  timberComponentId: DeviceEditorEntry(
    (_) => [
      DeviceSection('timber', 'TIMBER', Icons.piano_outlined, (_) => const TimberPage(), stripAtBottom: true),
    ],
    family: DeviceFamily.synth,
    ownsVariant: true,
    inline: (_) => const TimberInline(),
  ),
};

/// Width from which the editor is one screen; narrower, the picture over three panels.
const double timberWide = 700;

/// The phone's three panels, by name.
const timberPanels = ['Model', 'Sound', 'Space'];

/// The model's own choices (shown as switches) and knobs, in the order the engine declares them; the envelope's
/// `attack` and `decay` go to the Envelope panel, the organ's drawbars are drawn (and dragged) in the picture.
const Map<int, ({List<String> choices, List<String> knobs})> timberControls = {
  TimberModel.piano: (choices: ['character', 'sim', 'tier'], knobs: ['hammer', 'unison', 'stretch', 'sustain', 'soft', 'resonance', 'noise']),
  // 1.1.2: each model's `sim` (Classic or Simulated) is its last choice and `noises` its last knob (the organ's
  // `click` is its contacts' noise).
  TimberModel.epiano: (choices: ['kind', 'sim'], knobs: ['pickup', 'symmetry', 'bell', 'bark', 'tremolo', 'rate', 'noises']),
  TimberModel.organ: (choices: ['perc', 'perc_decay', 'vibrato', 'rotary', 'sim'], knobs: ['click', 'drive']),
  TimberModel.plucked: (choices: ['instrument', 'sim'], knobs: ['position', 'pick', 'damping', 'brightness', 'noises']),
  TimberModel.bowed: (choices: ['section', 'sim'], knobs: ['pressure', 'speed', 'position', 'vibrato', 'vib_rate', 'noises']),
  TimberModel.mallets: (choices: ['instrument', 'sim'], knobs: ['hardness', 'position', 'damping', 'dampen', 'motor', 'noises']),
  TimberModel.winds: (choices: ['instrument', 'sim'], knobs: ['breath', 'noise', 'reed', 'vibrato', 'vib_rate', 'growl', 'noises']),
};

/// Short knob names (the descriptor's are longer: "Bow pressure", "Unison detune").
const Map<String, String> timberLabels = {
  'unison': 'Detune', 'sustain': 'Sustain', 'soft': 'Soft', 'pressure': 'Pressure', 'speed': 'Speed',
  'position': 'Position', 'vib_rate': 'Vib rate', 'hardness': 'Hardness', 'damping': 'Damping', 'dampen': 'Key-up',
  'noise': 'Noise', 'rate': 'Rate', 'click': 'Click', 'attack': 'Attack', 'decay': 'Decay', 'release': 'Release',
  'velocity': 'Velocity', 'tone': 'Tone', 'body': 'Body', 'space': 'Room', 'level': 'Level', 'voices': 'Voices',
  'noises': 'Noises',
};

/// The model the device under [context] plays.
int timberModelOf(BuildContext context) => DeviceScope.of(context).target.info?.variantIndex ?? 0;

/// The knob labels for [model] (the winds' `reed` is a jet on a flute and lips on brass).
Map<String, String> _labelsFor(DeviceTarget t, int model) {
  if (model != TimberModel.winds) return timberLabels;
  final kind = t.value('instrument').round();
  return {...timberLabels, 'reed': kind == 1 ? 'Jet' : kind == 3 ? 'Lips' : 'Reed'};
}

/// Timber's one page.
class TimberPage extends StatefulWidget {
  const TimberPage({super.key});

  @override
  State<TimberPage> createState() => _TimberPageState();
}

class _TimberPageState extends State<TimberPage> {
  final _ui = FlagshipUi();
  final _pages = PageController();
  bool _narrow = false;
  int _panel = 0;

  @override
  void dispose() {
    _pages.dispose();
    _ui.dispose();
    super.dispose();
  }

  void goTo(int i) {
    if (!_narrow || !_pages.hasClients) return;
    i = i.clamp(0, timberPanels.length - 1);
    final d = Motion.fade(Motion.standard * 2, Motion.of(context));
    d == Duration.zero ? _pages.jumpToPage(i) : _pages.animateToPage(i, duration: d, curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) => FlagshipUiScope(ui: _ui, child: ListenableBuilder(listenable: _ui,
    builder: (context, _) => LayoutBuilder(builder: (context, box) {
      _narrow = box.maxWidth < timberWide;
      final accent = DeviceScope.of(context).accent;
      return Column(key: const ValueKey('timber-page'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _toolbar(accent),
        Expanded(child: _narrow ? _phone() : _wide(box.maxWidth)),
        foldSize(context, _ui.keys ? const FlagshipKeys() : const SizedBox(width: double.infinity)),
      ]);
    })));

  Widget _toolbar(Color accent) => SizedBox(height: 40, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(children: [
      if (_narrow) ...[
        PanelDots(count: timberPanels.length, index: _panel, color: accent, onPick: goTo),
        const SizedBox(width: 6),
        Flexible(child: Text(timberPanels[_panel].toUpperCase(), key: const ValueKey('timber-panel-name'), maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: Neon.text))),
      ] else
        const Flexible(child: Text('Pick a model, then play: the picture moves with what sounds. Drag it to set the strike point.',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: Neon.dim))),
      const Spacer(),
      IconButton(
        key: const ValueKey('timber-keys-toggle'), tooltip: _ui.keys ? 'Hide the keys' : 'Show keys to play while editing',
        iconSize: 19, visualDensity: VisualDensity.compact, color: _ui.keys ? accent : Neon.dim,
        style: _ui.keys ? IconButton.styleFrom(backgroundColor: accent.withValues(alpha: 0.16)) : null,
        icon: const Icon(Icons.piano),
        onPressed: () {
          DeviceFeel.tap();
          _ui.keys = !_ui.keys;
        }),
    ])));

  /// The centrepiece: the model cards over the instrument drawn live; [withKnobs] puts the model's own controls
  /// under it (the wide screen; the phone has them on its Model panel).
  Widget _centrepiece({required double height, required double knob, required bool withKnobs}) => FPanel(
    key: const ValueKey('timber-centrepiece'),
    title: 'INSTRUMENT',
    trailing: const [_VoicesReadout()],
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      VariantCards(key: const ValueKey('timber-models'), icon: timberModelIcon, names: timberModels, height: 50),
      const SizedBox(height: 6),
      TimberVisual(height: height),
      if (withKnobs) TimberModelControls(knob: knob),
    ]),
  );

  List<Widget> _soundPanels(double k) => [
    FPanel(key: const ValueKey('timber-envelope'), title: 'ENVELOPE',
        child: FKnobRow(const ['attack', 'decay', 'release', 'velocity'], size: k, labels: timberLabels)),
    FPanel(key: const ValueKey('timber-tone'), title: 'TONE',
        child: FKnobRow(const ['tone', 'body'], size: k, labels: timberLabels)),
  ];

  Widget _spacePanel(double k) => FPanel(key: const ValueKey('timber-space'), title: 'SPACE',
      child: FKnobRow(const ['space', 'level', 'voices'], size: k, labels: timberLabels));

  /// The one screen: the instrument and its own knobs, then envelope, tone and space side by side.
  Widget _wide(double width) {
    final roomy = width >= 1200;
    final k = roomy ? 40.0 : 34.0;
    const gap = SizedBox(width: 8, height: 8);
    final sound = _soundPanels(k);
    return SingleChildScrollView(key: const ValueKey('timber-wide'), padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _centrepiece(height: roomy ? 220 : 180, knob: k, withKnobs: true),
        gap,
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 4, child: sound[0]),
          gap,
          Expanded(flex: 2, child: sound[1]),
          gap,
          Expanded(flex: 3, child: _spacePanel(k)),
        ]),
      ]));
  }

  /// The phone: the cards and the picture stay on top; under them the three panels swipe sideways.
  Widget _phone() {
    Widget panel(String key, List<Widget> children) => ListView(key: ValueKey(key),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      children: [for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 8), child: c)]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _centrepiece(height: 130, knob: 40, withKnobs: false)),
      Expanded(child: PageView(
        key: const ValueKey('timber-pages'),
        controller: _pages,
        onPageChanged: (i) {
          Motion.tick();
          setState(() => _panel = i);
        },
        children: [
          panel('timber-panel-model', [FPanel(key: const ValueKey('timber-model-panel'), title: 'MODEL',
              child: const TimberModelControls(knob: 40))]),
          panel('timber-panel-sound', _soundPanels(40)),
          panel('timber-panel-space', [_spacePanel(40)]),
        ],
      )),
    ]);
  }
}

/// "3 / 32 voices": what sounds now against the cap (the quality setting's for the model), from the display.
class _VoicesReadout extends StatelessWidget {
  const _VoicesReadout();

  @override
  Widget build(BuildContext context) => DeviceDisplay(builder: (context, f) {
    final fr = TimberFrame(f);
    final t = DeviceScope.of(context).target;
    final text = fr.live ? '${fr.sounding} / ${fr.cap} voices' : '${t.value('voices').round()} voices';
    return Text(text, key: const ValueKey('timber-voices'), style: const TextStyle(fontSize: 10, color: Neon.dim));
  });
}

/// The model's own controls: its choices, then its knobs; the piano adds a line on the quality setting's caps.
class TimberModelControls extends StatelessWidget {
  const TimberModelControls({super.key, this.knob = 40});
  final double knob;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final model = timberModelOf(context);
    final all = timberControls[model]!;
    // The piano's Quality and Noise act only in Simulated: Classic (the 1.1.0 piano) leaves them out.
    final simulated = model != TimberModel.piano || t.value('sim').round() == 1;
    final c = (
      choices: [for (final id in all.choices) if (simulated || id != 'tier') id],
      knobs: [for (final id in all.knobs) if (simulated || id != 'noise') id],
    );
    return AnimatedSwitcher(
      duration: Motion.fade(Motion.small, Motion.of(context)),
      child: Column(key: ValueKey('timber-controls-$model'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 4),
        // The choices side by side: all in one row when wide, two to a row on a phone.
        LayoutBuilder(builder: (context, box) {
          final cols = box.maxWidth >= 600 ? c.choices.length : c.choices.length.clamp(1, 2);
          final w = (box.maxWidth - 8 * (cols - 1)) / cols;
          // A last choice alone on its row takes the row (the piano's four-way Quality on a phone).
          final alone = c.choices.length % cols == 1 && c.choices.length > 1;
          return Wrap(spacing: 8, runSpacing: 6, children: [
            for (final (i, id) in c.choices.indexed)
              SizedBox(width: alone && i == c.choices.length - 1 ? box.maxWidth : w,
                  child: DeviceChoice(id, maxSegments: 4, label: t.param(id)?.label)),
          ]);
        }),
        FKnobRow(c.knobs, size: knob, labels: _labelsFor(t, model)),
        if (model == TimberModel.piano) const _PianoQualityNote(),
      ]),
    );
  }
}

/// The piano's voice caps follow Settings › Sound › Quality; its Quality choice (Simulated, 1.1.2) can hold the
/// sound itself at one tier: says which.
class _PianoQualityNote extends StatelessWidget {
  const _PianoQualityNote();

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final q = t.state.settings.soundQuality;
    final (name, cap) = switch (q) { SoundQuality.eco => ('Eco', 16), SoundQuality.normal => ('Normal', 32), _ => ('High', 48) };
    final tier = t.value('tier').round();
    final own = t.value('sim').round() == 1 && tier > 0 ? ' This piano plays at ${const ['', 'Eco', 'Normal', 'High'][tier.clamp(0, 3)]}.' : '';
    return Padding(padding: const EdgeInsets.only(top: 6), child: Text(
      'Quality $name: up to $cap piano voices${q == SoundQuality.eco ? '' : '. Eco (Settings › Sound) plays 16 for less CPU'}.$own',
      key: const ValueKey('timber-quality'), textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 10, color: Neon.dim)));
  }
}

/// The instrument drawn live ([TimberPainter]) in a hero canvas: a drag sets the strike point (or pulls a drawbar).
class TimberVisual extends StatefulWidget {
  const TimberVisual({super.key, this.height = 160});
  final double height;

  @override
  State<TimberVisual> createState() => _TimberVisualState();
}

class _TimberVisualState extends State<TimberVisual> {
  int? _bar; // the organ's drawbar under the finger
  double _start = 0, _from = 0;

  void _down(DeviceTarget t, int model, Offset at, Size size) {
    if (model == TimberModel.organ) {
      final k = organBarAt(at.dx, size.width);
      _bar = k;
      _from = t.value(organDrawbars[k]);
      _start = at.dy;
      return;
    }
    final g = timberGrab(model);
    if (g == null) return;
    _from = t.value(g.id);
    _start = g.horizontal ? at.dx : at.dy;
  }

  void _move(DeviceTarget t, int model, Offset at, Size size) {
    if (model == TimberModel.organ) {
      final k = _bar;
      if (k == null) return;
      // Down pulls the bar out (as on the organ): its whole travel over 70 % of the height.
      t.setLive(organDrawbars[k], (_from + (at.dy - _start) / (size.height * 0.7) * 8).clamp(0, 8).roundToDouble());
      return;
    }
    final g = timberGrab(model);
    final p = g == null ? null : t.param(g.id);
    if (g == null || p == null) return;
    // Sideways: the point moves with the finger toward the bridge (right); up and down: up is more.
    final span = p.max - p.min;
    final d = g.horizontal ? -(at.dx - _start) / (size.width * 0.9) : -(at.dy - _start) / size.height;
    t.setLive(g.id, (_from + d * span).clamp(p.min, p.max).toDouble());
  }

  void _up(DeviceTarget t) {
    _bar = null;
    t.commit();
    DeviceFeel.tap();
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final model = timberModelOf(context);
    final style = deviceStyle(DeviceFamily.synth);
    final kind = timberControls[model]!.choices.first;
    final choice = t.param(kind);
    final sub = choice != null && choice.isChoice && choice.choices.isNotEmpty && model != TimberModel.organ
        ? ' · ${choice.choices[(t.value(kind) - choice.min).round().clamp(0, choice.choices.length - 1)].toUpperCase()}'
        : '';
    return HeroCanvas(
      key: const ValueKey('timber-visual'),
      color: scope.accent,
      height: widget.height,
      caption: '${const ['PIANO', 'ELECTRIC PIANO', 'ORGAN', 'PLUCKED', 'BOWED', 'MALLETS', 'WINDS'][model]}$sub',
      readout: DeviceDisplay(builder: (context, f) {
        final fr = TimberFrame(f);
        return Text(fr.live && fr.lastKey >= 0 ? noteName(fr.lastKey) : '', key: const ValueKey('timber-last-key'));
      }),
      child: LayoutBuilder(builder: (context, box) {
        final size = box.biggest;
        // One axis: a sideways grab wins over the page's scroll at once; an up-and-down one engages after a short rest or
        // a slow start, so a quick swipe still scrolls (kit/touch_engage.dart).
        final sideways = timberGrab(model)?.horizontal ?? false;
        return EngageVerticalDrag(
          onStart: sideways ? null : (d) => _down(t, model, d.localPosition, size),
          onUpdate: sideways ? null : (d) => _move(t, model, d.localPosition, size),
          onEnd: sideways ? null : (_) => _up(t),
          onCancel: sideways ? null : () => _up(t),
          child: GestureDetector(
          key: const ValueKey('timber-grab'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: sideways ? (d) => _down(t, model, d.localPosition, size) : null,
          onHorizontalDragUpdate: sideways ? (d) => _move(t, model, d.localPosition, size) : null,
          onHorizontalDragEnd: sideways ? (_) => _up(t) : null,
          onHorizontalDragCancel: sideways ? () => _up(t) : null,
          child: AnimatedSwitcher(
            duration: Motion.fade(Motion.standard, Motion.of(context)),
            // At the picture's size (tight constraints): a motion frame's relayout stays inside it, not the page.
            child: SizedBox.fromSize(key: ValueKey('timber-picture-$model'), size: size, child: DeviceDisplay(
              builder: (context, f) => DevicePhase(
              builder: (context, seconds) => CustomPaint(size: size, painter: TimberPainter(TimberPicture(
                model: model, value: t.value, frame: TimberFrame(f), seconds: seconds,
                accent: scope.accent, secondary: style.secondary))))))),
        ));
      }),
    );
  }
}

// ---------- the track card's inline controls ----------

class TimberInline extends StatelessWidget {
  const TimberInline({super.key});

  @override
  Widget build(BuildContext context) {
    final model = timberModelOf(context);
    return Column(key: const ValueKey('timber-inline'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const VariantCards(icon: timberModelIcon, names: timberModels, height: 42),
      KnobRow([...timberControls[model]!.knobs.take(4), 'tone', 'space', 'release'], size: 40, labels: timberLabels),
    ]);
  }
}
