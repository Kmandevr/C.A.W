// Flock's editor (org.caw.flock) in Kestrel's one-screen layout: the source tiles and the grain cloud drawn live as a flock over the sample or built-in tone (drag it for position and spray; drop or pick a sample), the grain knobs under it, the play, envelope and filter panels below, the mod-source strip at the bottom; a phone held upright swipes three panels (Grains, Play, Shape) under the picture.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../engine/audio_engine.dart' show AssetInfo;
import '../../../model/app_state.dart';
import '../../../model/audio_clips.dart' show FadeCurve;
import '../../../model/audio_edit.dart' show AudioEdit;
import '../../../model/flock.dart';
import '../../../model/project.dart';
import '../../arrange/audio_waveform.dart';
import '../../frame/sections.dart' show AssetDrag, AssetKind;
import '../../feedback.dart' show Pressable;
import '../../haptics.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_registry.dart';
import '../device_scope.dart';
import '../flagship/flagship_panels.dart';
import '../flagship/flagship_tools.dart' show FlagshipKeys, FlagshipUi, FlagshipUiScope, PanelDots;
import '../kit/controls.dart' show DeviceToggle, KnobRow;
import '../kit/device_style.dart';
import '../kit/feel.dart';
import '../kit/grab_gesture.dart';
import '../kit/hero.dart';
import '../kit/param_watch.dart';
import '../sampler/sampler_editor.dart' show SamplerFiles;
import 'flock_visual.dart';

export 'flock_visual.dart';

final Map<String, DeviceEditorEntry> flockEditors = {
  flockComponentId: DeviceEditorEntry(
    (_) => [
      DeviceSection('flock', 'FLOCK', Icons.grain, (_) => const FlockPage(), stripAtBottom: true),
    ],
    family: DeviceFamily.synth,
    inline: (_) => const FlockInline(),
  ),
};

/// Width from which the editor is one screen; narrower, the picture over three panels.
const double flockWide = 700;

/// The phone's three panels, by name.
const flockPanels = ['Grains', 'Play', 'Shape'];

/// The grain knobs (Murmur's) and their choices, in the engine's order.
const flockGrainKnobs = ['position', 'spray', 'size', 'density', 'jitter', 'pitch', 'spread', 'reverse', 'pan', 'width', 'seed'];
const flockGrainChoices = ['sync', 'scale', 'window'];

/// Movement through the source and how notes play it.
const flockPlayKnobs = ['scan', 'glide', 'keytrack', 'root', 'velocity', 'voices', 'level'];
const flockEnvelopeKnobs = ['attack', 'decay', 'sustain', 'release'];
const flockFilterKnobs = ['cutoff', 'resonance', 'filter_env', 'filter_decay', 'filter_key'];

/// Short knob names (the descriptor's are longer: "Pitch spread", "Filter key track").
const Map<String, String> flockLabels = {
  'spread': 'Spread', 'pan': 'Pan', 'filter_env': 'Env amt', 'filter_decay': 'Env decay', 'filter_key': 'Key track',
  'keytrack': 'Key track', 'root': 'Root', 'resonance': 'Reso',
};

/// The file's name without its folder.
String _baseName(String path) => path.split(RegExp(r'[/\\]')).last;

/// Flock's one page.
class FlockPage extends StatefulWidget {
  const FlockPage({super.key});

  @override
  State<FlockPage> createState() => _FlockPageState();
}

class _FlockPageState extends State<FlockPage> {
  final _ui = FlagshipUi();
  final _pages = PageController();
  bool _narrow = false;
  int _panel = 0;

  AppState get _state => DeviceScope.of(context).target.state;
  LayerDoc? get _layer => DeviceScope.of(context).target.layer;

  @override
  void dispose() {
    _pages.dispose();
    _ui.dispose();
    super.dispose();
  }

  void goTo(int i) {
    if (!_narrow || !_pages.hasClients) return;
    i = i.clamp(0, flockPanels.length - 1);
    final d = Motion.fade(Motion.standard * 2, Motion.of(context));
    d == Duration.zero ? _pages.jumpToPage(i) : _pages.animateToPage(i, duration: d, curve: Curves.easeOutCubic);
  }

  void _say(String t) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(t),
      action: SnackBarAction(label: 'Undo', onPressed: () => _state.undo())));

  void _use(String path) {
    final layer = _layer;
    if (layer == null) return;
    if (!_state.setFlockSample(layer, path)) {
      Haptics.error();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('That sample\'s path is too long for Flock')));
      return;
    }
    Haptics.drop();
    _say('The grains read ${_baseName(path)}');
  }

  Future<void> _pick() async {
    final state = _state;
    try {
      final paths = await SamplerFiles.pickSamples(state);
      if (paths.isNotEmpty && mounted) _use(paths.first);
    } catch (e) {
      Haptics.error();
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Adding the sample: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => FlagshipUiScope(ui: _ui, child: ListenableBuilder(listenable: _ui,
    builder: (context, _) => LayoutBuilder(builder: (context, box) {
      _narrow = box.maxWidth < flockWide;
      final accent = DeviceScope.of(context).accent;
      return Column(key: const ValueKey('flock-page'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _toolbar(accent),
        Expanded(child: _narrow ? _phone() : _wide(box.maxWidth)),
        foldSize(context, _ui.keys ? const FlagshipKeys() : const SizedBox(width: double.infinity)),
      ]);
    })));

  Widget _toolbar(Color accent) {
    final layer = _layer;
    final sample = layer == null ? null : _state.flockSample(layer);
    return SizedBox(height: 40, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        if (_narrow) ...[
          PanelDots(count: flockPanels.length, index: _panel, color: accent, onPick: goTo),
          const SizedBox(width: 6),
          Flexible(child: Text(flockPanels[_panel].toUpperCase(), key: const ValueKey('flock-panel-name'), maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: Neon.text))),
        ] else
          const Flexible(child: Text('Drop a sample on the picture, or play a built-in tone. Drag the flock: sideways for position, up for spray.',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: Neon.dim))),
        const Spacer(),
        IconButton(key: const ValueKey('flock-add'), tooltip: 'Pick a sample', iconSize: 18,
            visualDensity: VisualDensity.compact, icon: const Icon(Icons.library_add_outlined), onPressed: _pick),
        if (sample != null)
          IconButton(key: const ValueKey('flock-clear'), tooltip: 'Remove the sample (play the built-in tone)', iconSize: 18,
              visualDensity: VisualDensity.compact, icon: const Icon(Icons.link_off), onPressed: () {
                DeviceFeel.tap();
                _state.setFlockSample(layer!, null);
              }),
        IconButton(
          key: const ValueKey('flock-keys-toggle'), tooltip: _ui.keys ? 'Hide the keys' : 'Show keys to play while editing',
          iconSize: 19, visualDensity: VisualDensity.compact, color: _ui.keys ? accent : Neon.dim,
          style: _ui.keys ? IconButton.styleFrom(backgroundColor: accent.withValues(alpha: 0.16)) : null,
          icon: const Icon(Icons.piano),
          onPressed: () {
            DeviceFeel.tap();
            _ui.keys = !_ui.keys;
          }),
      ])));
  }

  /// The centrepiece: the source tiles over the picture (one drop target); [withKnobs] puts the grain knobs under it
  /// (the wide screen; the phone has them on its Grains panel).
  Widget _centrepiece({required double height, required double knob, required bool withKnobs}) {
    final accent = DeviceScope.of(context).accent;
    final state = _state;
    return FPanel(
      key: const ValueKey('flock-centrepiece'),
      title: 'SOURCE',
      trailing: const [_GrainsReadout()],
      child: DragTarget<AssetDrag>(
        key: const ValueKey('flock-drop'),
        onWillAcceptWithDetails: (d) => d.data.kind == AssetKind.audioFile,
        onAcceptWithDetails: (d) => _use(state.project.asset(d.data.id)?.path ?? d.data.id),
        builder: (context, hovering, _) => AnimatedContainer(
          duration: Motion.fade(Motion.small, Motion.of(context)),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
              border: Border.all(color: hovering.isNotEmpty ? accent : Colors.transparent, width: 2)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _SourceTiles(onPick: _pick),
            const SizedBox(height: 6),
            FlockVisual(height: height),
            if (withKnobs) FlockGrainControls(knob: knob),
          ]),
        ),
      ),
    );
  }

  Widget _playPanel(double k) => FPanel(key: const ValueKey('flock-play'), title: 'PLAY',
      trailing: const [DeviceToggle('freeze', icon: Icons.ac_unit)],
      child: FKnobRow(flockPlayKnobs, size: k, labels: flockLabels));

  Widget _envelopePanel(double k) => FPanel(key: const ValueKey('flock-envelope'), title: 'ENVELOPE',
      child: FKnobRow(flockEnvelopeKnobs, size: k, labels: flockLabels));

  Widget _filterPanel(double k) => FPanel(key: const ValueKey('flock-filter'), title: 'FILTER',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const DeviceChoice('filter', maxSegments: 4),
        watchDevice(context, (context) {
          final off = DeviceScope.of(context).target.value('filter').round() == 0;
          return AnimatedOpacity(duration: Motion.fade(Motion.small, Motion.of(context)), opacity: off ? 0.45 : 1,
              child: FKnobRow(flockFilterKnobs, size: k, labels: flockLabels));
        }),
      ]));

  /// The one screen: the source and its grain knobs, then play, envelope and filter side by side.
  Widget _wide(double width) {
    final roomy = width >= 1200;
    final k = roomy ? 40.0 : 34.0;
    const gap = SizedBox(width: 8, height: 8);
    return SingleChildScrollView(key: const ValueKey('flock-wide'), padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _centrepiece(height: roomy ? 220 : 180, knob: k, withKnobs: true),
        gap,
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 5, child: _playPanel(k)),
          gap,
          Expanded(flex: 3, child: _envelopePanel(k)),
          gap,
          Expanded(flex: 4, child: _filterPanel(k)),
        ]),
      ]));
  }

  /// The phone: the tiles and the picture stay on top; under them the three panels swipe sideways.
  Widget _phone() {
    Widget panel(String key, List<Widget> children) => ListView(key: ValueKey(key),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      children: [for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 8), child: c)]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _centrepiece(height: 140, knob: 40, withKnobs: false)),
      Expanded(child: PageView(
        key: const ValueKey('flock-pages'),
        controller: _pages,
        onPageChanged: (i) {
          Motion.tick();
          setState(() => _panel = i);
        },
        children: [
          panel('flock-panel-grains', [FPanel(key: const ValueKey('flock-grains'), title: 'GRAINS',
              child: const FlockGrainControls(knob: 40))]),
          panel('flock-panel-play', [_playPanel(40)]),
          panel('flock-panel-shape', [_envelopePanel(40), _filterPanel(40)]),
        ],
      )),
    ]);
  }
}

/// "14 / 128 grains": what flies now against the pool (the quality setting's), from the display; dropped grains
/// (the pool full) named.
class _GrainsReadout extends StatelessWidget {
  const _GrainsReadout();

  @override
  Widget build(BuildContext context) => DeviceDisplay(builder: (context, f) {
    final fr = FlockFrame(f);
    final text = !fr.live
        ? 'Not playing'
        : '${fr.grains} / ${fr.cap} grains${fr.dropped > 0 ? ' · full' : ''}';
    return Text(text, key: const ValueKey('flock-grains-readout'),
        style: TextStyle(fontSize: 10, color: fr.live && fr.dropped > 0 ? Neon.yellow : Neon.dim));
  });
}

/// The source: the sample (its name, or what a drop does) and the four built-in tones; a tone picked with a sample
/// loaded lets the sample go (one undo step), so the tile picked is what plays.
class _SourceTiles extends StatelessWidget {
  const _SourceTiles({required this.onPick});
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) => watchDevice(context, (context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final layer = t.layer;
    if (layer == null) return const SizedBox.shrink();
    final sample = t.state.flockSample(layer);
    final tone = t.value('builtin').round().clamp(0, flockTones.length - 1);
    final c = scope.accent;
    Widget tile(int k, String label, VoidCallback onTap, {bool wide = false}) {
      final on = k == 0 ? sample != null : sample == null && tone == k - 1;
      return Expanded(flex: wide ? 2 : 1, child: Padding(padding: EdgeInsets.only(right: k < 4 ? 4 : 0), child: Semantics(
        button: true, selected: on, label: k == 0 ? 'Sample: $label' : 'Built-in tone: $label',
        child: GestureDetector(
          key: ValueKey('flock-source-$k'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Pressable(glow: c, child: AnimatedContainer(
            duration: Motion.fade(Motion.small, Motion.of(context)),
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: on ? c.withValues(alpha: 0.2) : Neon.ink.withValues(alpha: 0.03),
              border: Border.all(color: on ? c : Neon.line, width: on ? 1.5 : 1),
              boxShadow: on ? [BoxShadow(color: c.withValues(alpha: 0.25), blurRadius: 10)] : null),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(6, 6, 6, 2), child: CustomPaint(
                size: Size.infinite, painter: _SourceIconPainter(k, on ? c : Neon.dim)))),
              Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 4), child: Text(label, maxLines: 1,
                overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 9.5, letterSpacing: 0.3,
                  fontWeight: FontWeight.w800, color: on ? Neon.text : Neon.dim))),
            ])))))));
    }
    return Row(key: const ValueKey('flock-sources'), children: [
      tile(0, sample == null ? 'Drop a sample' : _baseName(sample), () {
        DeviceFeel.tap();
        onPick();
      }, wide: true),
      for (var k = 0; k < flockTones.length; k++)
        tile(k + 1, flockTones[k], () {
          DeviceFeel.tap();
          if (sample != null) {
            t.state.setFlockSample(layer, null, tone: k);
          } else {
            t.set('builtin', k.toDouble());
          }
        }),
    ]);
  });
}

class _SourceIconPainter extends CustomPainter {
  _SourceIconPainter(this.k, this.color);
  final int k;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => flockSourceIcon(canvas, Offset.zero & size, k, color);

  @override
  bool shouldRepaint(covariant _SourceIconPainter o) => o.k != k || o.color != color;
}

/// The grain knobs: sync, scale and window, then position to seed.
class FlockGrainControls extends StatelessWidget {
  const FlockGrainControls({super.key, this.knob = 40});
  final double knob;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    return Column(key: const ValueKey('flock-grain-controls'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 4),
      LayoutBuilder(builder: (context, box) {
        final cols = box.maxWidth >= 600 ? flockGrainChoices.length : 1;
        final w = (box.maxWidth - 8 * (cols - 1)) / cols;
        return Wrap(spacing: 8, runSpacing: 6, children: [
          for (final id in flockGrainChoices)
            SizedBox(width: w, child: DeviceChoice(id, maxSegments: 7, label: t.param(id)?.label)),
        ]);
      }),
      FKnobRow(flockGrainKnobs, size: knob, labels: flockLabels),
    ]);
  }
}

/// The source drawn with the grain cloud over it ([FlockPainter]) in a hero canvas: a drag moves the position
/// (sideways) and the spray (up is more); a double tap puts both back.
class FlockVisual extends StatefulWidget {
  const FlockVisual({super.key, this.height = 160});
  final double height;

  @override
  State<FlockVisual> createState() => _FlockVisualState();
}

class _FlockVisualState extends State<FlockVisual> {
  double _pos = 0, _spray = 0;
  bool _active = false;
  String? _path;
  AssetInfo? _info;

  static final Map<String, AssetInfo> _known = {};

  void _load(AppState state, String? path) {
    if (path == _path) return;
    _path = path;
    _info = path == null ? null : _known[path];
    if (path == null || _info != null) return;
    unawaited(state.audioIo.loadAsset(path).then((i) {
      if (!i.ok) return;
      _known[path] = i;
      if (mounted && _path == path) setState(() => _info = i);
    }, onError: (_) {}));
  }

  @override
  Widget build(BuildContext context) => watchDevice(context, (context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final layer = t.layer;
    final sample = layer == null ? null : t.state.flockSample(layer);
    _load(t.state, sample);
    final info = _info;
    final style = deviceStyle(DeviceFamily.synth);
    final tone = flockTones[t.value('builtin').round().clamp(0, flockTones.length - 1)];
    return HeroCanvas(
      key: const ValueKey('flock-visual'),
      color: scope.accent,
      height: widget.height,
      caption: sample == null ? '≈ ${tone.toUpperCase()}' : _baseName(sample).toUpperCase(),
      readout: DeviceDisplay(builder: (context, f) {
        final fr = FlockFrame(f);
        final text = fr.live && fr.missing ? 'NOT FOUND · ${tone.toUpperCase()}' : fr.live ? '${fr.voices} voices' : '';
        return Text(text, key: const ValueKey('flock-status'),
            style: TextStyle(color: fr.live && fr.missing ? Neon.pink : null));
      }),
      child: LayoutBuilder(builder: (context, box) {
        final size = box.biggest;
        return GrabGesture(
          key: const ValueKey('flock-grab'),
          onStart: (_, _) {
            _pos = t.value('position');
            _spray = t.value('spray');
            DeviceFeel.grab();
            setState(() => _active = true);
          },
          onUpdate: (u) {
            final fine = DeviceFingers.fine;
            final sp = t.param('spray');
            _pos = (_pos + u.delta.dx / size.width * fine).clamp(0.0, 1.0);
            final range = sp == null ? 500.0 : sp.max - sp.min;
            _spray = (_spray - u.delta.dy / size.height * range * fine).clamp(sp?.min ?? 0.0, sp?.max ?? 500.0);
            t.setLive('position', _pos);
            t.setLive('spray', _spray);
          },
          onEnd: () {
            t.commit();
            DeviceFeel.release();
            setState(() => _active = false);
          },
          onDoubleTap: (_) => t.setAll({
            for (final id in ['position', 'spray']) if (t.param(id) case final p?) id: p.defaultValue,
          }),
          child: Stack(children: [
            if (sample != null && info != null)
              Positioned.fill(child: Padding(padding: EdgeInsets.symmetric(vertical: size.height * 0.12),
                child: CustomPaint(key: const ValueKey('flock-wave'), painter: AudioClipPainter(
                  peaks: () => WaveformCache.instance.peaks(t.state.audioIo, sample, info.seconds, info.seconds / size.width),
                  window: ClipWindow(offset: 0, perPixel: info.seconds / size.width, fileSeconds: info.seconds),
                  color: scope.accent.withValues(alpha: 0.3), gain: 1, fadeIn: 0, fadeOut: 0,
                  inCurve: FadeCurve.linear, outCurve: FadeCurve.linear, path: sample)))),
            // Filling the picture (tight constraints): a motion frame's relayout stays inside it, so the page around
            // it is not laid out and repainted with every frame (1.1.1: the whole page repainted 60 times a second).
            Positioned.fill(child: DeviceDisplay(builder: (context, f) => DevicePhase(
              builder: (context, seconds) {
                final fr = FlockFrame(f);
                final secs = fr.live && fr.seconds > 0 ? fr.seconds : info?.seconds ?? 2.0;
                return CustomPaint(size: size, painter: FlockPainter(FlockPicture(
                  value: t.value, frame: fr, seconds: secs, sample: sample != null && info != null && !(fr.live && fr.missing),
                  time: seconds, accent: scope.accent, secondary: style.secondary, active: _active)));
              }))),
          ]),
        );
      }),
    );
  });
}

// ---------- the track card's inline controls ----------

class FlockInline extends StatelessWidget {
  const FlockInline({super.key});

  @override
  Widget build(BuildContext context) => const Column(key: ValueKey('flock-inline'), crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      KnobRow(['position', 'spray', 'size', 'density', 'pitch', 'scan', 'release'], size: 40, labels: flockLabels),
    ]);
}
