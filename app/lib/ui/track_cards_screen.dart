// Track cards (Arrange's cards view): a project strip, a big card per track (its instrument, clips and notes, a meter,
// M and S) and a panel per track with its instrument, notes, effects and mix.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/arrange_fx.dart';
import '../model/audio_clips.dart';
import '../model/audio_edit.dart';
import '../model/cpp_starters.dart';
import '../model/cpp_workbench.dart';
import '../model/pattern_doc.dart';
import '../model/pattern_templates.dart' show PatternTemplate;
import '../model/project.dart';
import 'arrange/audio_waveform.dart';
import 'arrange/clip_preview.dart';
import 'arrange/fx_stack.dart' show FxStack, pickInstrument;
import 'cpp/build_start.dart' show ExamplesList, StarterExample;
import 'routing_view.dart' show SendKnobs;
import 'theme.dart';
import 'volume_fader.dart';
import 'arrange/track_color.dart';
import 'widgets.dart';
import 'glass.dart';

class TrackCardsScreen extends StatelessWidget {
  const TrackCardsScreen({super.key, required this.state, required this.onOpenModule, this.onBack});
  final AppState state;

  /// Opens a pattern in Build (a clip's notes).
  final ValueChanged<String> onOpenModule;

  /// Leaves the cards for the arrangement; Android's Back does the same while the cards are open.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final p = state.project;
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 96),
      children: [
        if (state.meters.overloaded > 0) _OverloadBanner(state: state),
        _ProjectStrip(state: state),
        const SizedBox(height: 14),
        for (var i = 0; i < p.layers.length; i++) ...[
          _TrackCard(state: state, layer: p.layers[i], index: i, onOpenModule: onOpenModule),
          const SizedBox(height: 10),
        ],
        if (p.layers.length < 64) _AddTrackCard(state: state, empty: p.layers.isEmpty),
      ],
    );
    final back = onBack;
    if (back == null) return list;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) back();
      },
      child: list,
    );
  }
}

/// The cards view's header row: ← Back to the arrangement, then the view's title.
class TrackCardsHeader extends StatelessWidget {
  const TrackCardsHeader({super.key, required this.onBack});
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 2),
        child: Row(children: [
          TextButton.icon(
            key: const ValueKey('track-cards-back'),
            onPressed: onBack,
            style: TextButton.styleFrom(foregroundColor: Neon.text),
            icon: const Icon(Icons.arrow_back, size: 20),
            label: const Text('Back'),
          ),
          const SizedBox(width: 6),
          const Text('TRACK CARDS', style: TextStyle(color: Neon.dim, fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800)),
        ]),
      );
}

class _OverloadBanner extends StatelessWidget {
  const _OverloadBanner({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: NeonPanel(
          color: Neon.pink,
          child: Row(children: [
            const Icon(Icons.speed, color: Neon.pink),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                  'Out of headroom: the newest track${state.meters.overloaded > 1 ? 's were' : ' was'} muted to keep audio clean.'
                  '${state.lightTurnedOnBySelf ? ' Light mode is now on (Settings).' : ''}'),
            ),
            TextButton(onPressed: state.clearOverload, child: const Text('Unmute')),
          ]),
        ),
      );
}

String _bpmText(ProjectDoc p) => p.bpm == p.bpm.roundToDouble() ? p.bpm.toStringAsFixed(0) : p.bpm.toStringAsFixed(1);

/// The project at a glance: tempo, meter, loop, key and the master level. A tap opens every project setting.
class _ProjectStrip extends StatelessWidget {
  const _ProjectStrip({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final p = state.project;
    Widget pill(String text) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(border: Border.all(color: Neon.line), borderRadius: BorderRadius.circular(20)),
          child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        );
    return NeonPanel(
      color: Neon.blue,
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => showProjectSheet(context, state),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
          child: Column(children: [
            Row(children: [
              Text(_bpmText(p), style: Neon.code(size: 30, color: Neon.blue).copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 6),
              const Text('BPM', style: TextStyle(color: Neon.dim, fontSize: 12)),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  pill('${p.beatsPerBar}/4'),
                  pill(p.loopBars == 1 ? '1 bar' : '${p.loopBars} bars'),
                  if (p.key != 'None') pill(p.key),
                ]),
              ),
              const Icon(Icons.tune, color: Neon.dim),
            ]),
            const SizedBox(height: 10),
            PeakMeter(
                state: state,
                read: () => state.meters.peakL,
                readRight: () => state.meters.peakR,
                color: Neon.blue),
          ]),
        ),
      ),
    );
  }
}

Future<void> showProjectSheet(BuildContext context, AppState s) {
  final opened = s.project;
  return showGlassSheet<void>(
      context: context,
      backgroundColor: Neon.panel,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
          child: ListenableBuilder(
            listenable: s,
            builder: (context, _) {
              // Another project opened meanwhile: close rather than edit it unseen.
              if (!identical(s.project, opened)) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted) Navigator.maybePop(context);
                });
                return const SizedBox(height: 80);
              }
              return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
              const Heading('Project'),
              _ProjectSettings(state: s),
            ]);
            },
          ),
        ),
      ),
    );
}

class _ProjectSettings extends StatefulWidget {
  const _ProjectSettings({required this.state});
  final AppState state;

  @override
  State<_ProjectSettings> createState() => _ProjectSettingsState();
}

class _ProjectSettingsState extends State<_ProjectSettings> {
  late final TextEditingController _seed;
  late int _syncedSeed;

  static const keys = [
    'C major', 'C minor', 'C# minor', 'D major', 'D minor', 'Eb major', 'E minor', 'F major', 'F minor', //
    'F# minor', 'G major', 'G minor', 'A major', 'A minor', 'Bb major', 'B minor', 'None',
  ];

  @override
  void initState() {
    super.initState();
    _syncedSeed = widget.state.project.seed;
    _seed = TextEditingController(text: _syncedSeed.toRadixString(16));
  }

  @override
  void didUpdateWidget(covariant _ProjectSettings old) {
    super.didUpdateWidget(old);
    // Re-sync only when the project's seed changed (Enter, undo, another project). Comparing against the
    // typed text instead would put the old seed back on every rebuild while it is being edited (#20).
    final seed = widget.state.project.seed;
    if (seed == _syncedSeed) return;
    _syncedSeed = seed;
    _seed.text = seed.toRadixString(16);
  }

  @override
  void dispose() {
    _seed.dispose();
    super.dispose();
  }

  void _tap() => widget.state.tapTempo();

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final p = s.project;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        IconButton.outlined(
            onPressed: () => s.editProject((p) => p.bpm = (p.bpm - 1).clamp(20, 400).roundToDouble()),
            icon: const Icon(Icons.remove)),
        Expanded(
          child: Column(children: [
            Text(_bpmText(p), style: Neon.code(size: 34, color: Neon.blue).copyWith(fontWeight: FontWeight.w700)),
            const Text('BPM', style: TextStyle(color: Neon.dim, fontSize: 12)),
          ]),
        ),
        IconButton.outlined(
            onPressed: () => s.editProject((p) => p.bpm = (p.bpm + 1).clamp(20, 400).roundToDouble()),
            icon: const Icon(Icons.add)),
        const SizedBox(width: 8),
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: Neon.blue, minimumSize: const Size(88, 52)),
          onPressed: _tap,
          child: const Text('TAP TEMPO', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ]),
      const SizedBox(height: 10),
      Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _Labeled(
          'Time',
          DropdownButton<int>(
            value: p.beatsPerBar,
            items: [for (final b in {2, 3, 4, 5, 6, 7, p.beatsPerBar}.toList()..sort()) DropdownMenuItem(value: b, child: Text('$b/4'))],
            onChanged: (v) => s.editProject((p) => p.beatsPerBar = v!),
          ),
        ),
        _Labeled(
          'Length',
          BarsField(value: p.loopBars, max: p.maxLoopBars, title: 'Shortest song length',
            onChanged: (v) => s.editProject((p) => p.loopBars = v)),
        ),
        _Labeled(
          'Key',
          DropdownButton<String>(
            value: keys.contains(p.key) ? p.key : 'None',
            items: [for (final k in keys) DropdownMenuItem(value: k, child: Text(k))],
            onChanged: (v) => s.editProject((p) => p.key = v!),
          ),
        ),
        Text('${p.songSeconds.toStringAsFixed(2)} s song', style: const TextStyle(color: Neon.dim)),
      ]),
      Row(children: [
        const SizedBox(width: 56, child: Text('Master', style: TextStyle(color: Neon.dim))),
        Expanded(
          child: SizedBox(height: 40, child: VolumeFader(value: p.master, vertical: false, color: Neon.blue,
            label: 'Master level', defaultGain: 0.7, onChanged: s.setMaster)),
        ),
      ]),
      Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('More', style: TextStyle(color: Neon.dim)),
          children: [
            Row(children: [
              const Text('Seed ', style: TextStyle(color: Neon.dim)),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _seed,
                  style: Neon.code(size: 14),
                  decoration: const InputDecoration(prefixText: '0x'),
                  onSubmitted: (v) {
                    final n = int.tryParse(v, radix: 16);
                    if (n != null && n >= 0 && n <= 0xFFFFFFFF) s.editProject((p) => p.seed = n);
                  },
                ),
              ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              activeThumbColor: Neon.blue,
              title: const Text('Crossfade loop seams'),
              subtitle: const Text('3 ms blend where a track restarts', style: TextStyle(color: Neon.dim)),
              value: p.seamCrossfade,
              onChanged: (v) => s.editProject((p) => p.seamCrossfade = v),
            ),
          ],
        ),
      ),
    ]);
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label ', style: const TextStyle(color: Neon.dim)),
        child,
      ]);
}


/// What a track plays, in a few words: its instrument and preset ("Drums · Kit: 808"), an audio track, or a folder.
/// Null for a track with no instrument yet.
String? trackSoundText(AppState s, LayerDoc layer) {
  if (layer.isFolder) return layer.busEnabled ? 'Bus folder' : 'Folder';
  if (layer.isAudio) return layer.input != null && layer.audioClips.isEmpty ? 'Audio · input' : 'Audio';
  final use = layer.instrument;
  if (use == null) return null;
  final name = s.componentLabel(use.id), preset = use.preset;
  return preset == null || preset.isEmpty || preset == name ? name : '$name · $preset';
}

/// The tracks inside [folder], directly.
Iterable<LayerDoc> _childrenOf(ProjectDoc p, LayerDoc folder) => p.layers.where((l) => l.parentId == folder.id);

/// How many folders [layer] sits in (cards inside a folder are indented under it).
int _depthOf(ProjectDoc p, LayerDoc layer) {
  var depth = 0;
  var parent = layer.parentId;
  while (parent != null && depth < p.layers.length) {
    final folder = p.layers.where((l) => l.id == parent).firstOrNull;
    if (folder == null) break;
    depth++;
    parent = folder.parentId;
  }
  return depth;
}

/// The card's second line: what plays, the clips, and the effects.
String _detail(AppState s, LayerDoc layer) {
  final p = s.project;
  final sound = trackSoundText(s, layer);
  String count(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';
  final fx = layer.components.length + layer.noteComponents.length;
  return [
    // The instrument's name only when the track's own name doesn't already say it.
    if (sound == null) 'No instrument' else if (sound != layer.name) sound,
    if (layer.isFolder)
      count(_childrenOf(p, layer).length, 'track')
    else if (layer.isAudio)
      count(layer.audioClips.length, 'clip')
    else if (layer.clips.length == 1)
      p.module(layer.clips.first.patternId)?.name ?? 'Missing pattern'
    else if (layer.clips.isEmpty)
      'No clips'
    else
      count(layer.clips.length, 'clip'),
    if (fx > 0) '$fx fx',
  ].join('  ·  ');
}

Future<void> _rename(BuildContext context, AppState state, LayerDoc layer) async {
  final c = TextEditingController(text: layer.name);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename track'),
      content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Rename')),
      ],
    ),
  );
  if (name != null && name.trim().isNotEmpty) state.editLayer(layer, (l) => l.name = name.trim());
}

/// One track: its colour, name and sound, its clips across the song with their notes and the playhead, a level
/// meter, M and S.
class _TrackCard extends StatelessWidget {
  const _TrackCard({required this.state, required this.layer, required this.index, required this.onOpenModule});
  final AppState state;
  final LayerDoc layer;
  final int index;
  final ValueChanged<String> onOpenModule;

  @override
  Widget build(BuildContext context) {
    final p = state.project;
    final color = trackColor(state, layer);
    final sound = trackSoundText(state, layer);
    final dim = layer.mute || (p.layers.any((l) => l.solo) && !layer.solo);
    final icon = layer.isFolder
        ? Icons.folder_outlined
        : layer.isAudio
            ? Icons.graphic_eq
            : sound == null
                ? Icons.add_circle_outline
                : Icons.piano_outlined;
    return Padding(
      padding: EdgeInsets.only(left: 14.0 * math.min(_depthOf(p, layer), 4)),
      child: Opacity(
        opacity: dim ? 0.5 : 1,
        child: NeonPanel(
          key: ValueKey('track-card-${layer.id}'),
          color: color,
          padding: EdgeInsets.zero,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => showTrackSheet(context, state, layer, onOpenModule),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(icon, color: color, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(layer.name,
                          overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                      Text(_detail(state, layer),
                          key: ValueKey('track-card-detail-${layer.id}'),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: sound == null ? Neon.pink : Neon.dim, fontSize: 12.5)),
                    ]),
                  ),
                  ValueListenableBuilder<int>(
                    valueListenable: state.tick,
                    builder: (context, _, _) {
                      final m = index < state.layerMeters.length ? state.layerMeters[index] : null;
                      if (m?.overloaded != true) return const SizedBox();
                      return const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Icon(Icons.speed, color: Neon.pink, size: 20),
                      );
                    },
                  ),
                  ToggleChip(
                      label: 'M', tooltip: 'Mute', on: layer.mute, color: Neon.yellow, onTap: () => state.mixLayer(layer, mute: !layer.mute)),
                  const SizedBox(width: 6),
                  ToggleChip(
                      label: 'S', tooltip: 'Solo', on: layer.solo, color: Neon.blue, onTap: () => state.mixLayer(layer, solo: !layer.solo)),
                ]),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _Lane(state: state, layer: layer, index: index, color: color),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: TrackMeter(state: state, index: index, stereo: layer.isStereo, color: color),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// The whole song in one strip: the track's clips where they sit, each drawing its notes as Arrange's clips do (the
/// same mini piano roll, loops included) or its waveform, and the playhead. A folder shows its tracks' clips.
class _Lane extends StatelessWidget {
  const _Lane({required this.state, required this.layer, required this.index, required this.color});
  final AppState state;
  final LayerDoc layer;
  final int index;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 40,
        child: LayoutBuilder(builder: (context, box) {
          final p = state.project;
          final song = math.max(1, p.engineLoopSteps);
          final stepW = box.maxWidth / song;
          final tracks = layer.isFolder ? _childrenOf(p, layer).toList() : [layer];
          final notes = Color.lerp(color, Colors.white, 0.35)!;
          Widget clipBox(Key key, double start, double length, bool muted, Widget? body) {
            final left = start * stepW;
            final width = math.max(2.0, math.min(length * stepW, box.maxWidth - left));
            if (left >= box.maxWidth) return const SizedBox.shrink();
            return Positioned(
              key: key,
              left: left,
              width: width,
              top: 4,
              bottom: 4,
              child: Container(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: muted ? 0.08 : 0.2),
                  border: Border.all(color: color.withValues(alpha: muted ? 0.3 : 0.7)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: body == null || width < 6 ? null : ClipRRect(borderRadius: BorderRadius.circular(4), child: body),
              ),
            );
          }

          return Stack(fit: StackFit.expand, children: [
            RepaintBoundary(child: CustomPaint(painter: _GridPainter(song, p.stepsPerBar))),
            for (final t in tracks) ...[
              for (final c in t.clips)
                clipBox(ValueKey('card-clip-${c.id}'), c.startSteps.toDouble(), c.lengthSteps.toDouble(), c.mute || t.mute,
                    layer.isFolder ? null : _midiNotes(p, c, stepW, notes)),
              for (final c in t.audioClips)
                clipBox(ValueKey('card-audio-${c.id}'), c.startSteps, c.lengthAt(p.bpm), c.mute || t.mute,
                    layer.isFolder ? null : _waveform(c, stepW, notes)),
            ],
            ValueListenableBuilder<int>(
              valueListenable: state.tick,
              builder: (context, _, _) {
                final m = index < state.layerMeters.length ? state.layerMeters[index] : null;
                final at = state.meters.playing ? (m?.progress ?? 0) : -1.0;
                return CustomPaint(painter: _PlayheadPainter(at, color));
              },
            ),
          ]);
        }),
      );

  Widget? _midiNotes(ProjectDoc p, ClipDoc c, double stepW, Color notes) {
    final preview = MidiClipPreview.of(p, c, stepW: stepW, top: 1, color: notes);
    return preview == null ? null : RepaintBoundary(child: CustomPaint(
      key: ValueKey('card-notes-${c.id}'),
      painter: ClipPreviewPainter(preview),
      size: Size.infinite));
  }

  Widget _waveform(AudioClipDoc c, double stepW, Color wave) {
    final asset = state.project.asset(c.assetId);
    final fileSeconds = asset?.seconds ?? 0;
    final per = c.sourcePerStep(state.project.bpm, asset?.bpm) / stepW;
    return CustomPaint(
      key: ValueKey('card-wave-${c.id}'),
      size: Size.infinite,
      painter: AudioClipPainter(
        peaks: () => asset == null || state.engine == null
            ? null
            : WaveformCache.instance.peaks(state.audioIo, asset.path, fileSeconds, per.abs()),
        window: ClipWindow(offset: c.offsetSeconds, perPixel: per, fileSeconds: fileSeconds, reverse: c.reverse,
            loop: c.loop, loopStart: c.loopStart, loopEnd: c.loopEnd),
        color: wave, gain: c.gain, fadeIn: 0, fadeOut: 0, inCurve: c.fadeInCurve, outCurve: c.fadeOutCurve),
    );
  }
}

/// The strip's background and its bar lines (not drawn one by one when bars are under 2 px: a long song).
class _GridPainter extends CustomPainter {
  _GridPainter(this.steps, this.bar);
  final int steps, bar;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
        Paint()..color = Neon.bg.withValues(alpha: 0.6));
    final stepW = size.width / steps;
    if (bar * stepW < 2) return;
    final grid = Paint()..color = Neon.line;
    for (var s = bar; s < steps; s += bar) {
      canvas.drawLine(Offset(s * stepW, 2), Offset(s * stepW, size.height - 2), grid);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.steps != steps || old.bar != bar;
}

class _PlayheadPainter extends CustomPainter {
  _PlayheadPainter(this.at, this.color);
  final double at; // 0..1 through the cycle, or negative when stopped
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (at < 0) return;
    final x = at.clamp(0.0, 1.0) * size.width;
    canvas.drawRect(Rect.fromLTWH(0, 0, x, size.height), Paint()..color = color.withValues(alpha: 0.08));
    canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = Neon.text
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant _PlayheadPainter old) => old.at != at || old.color != color;
}

/// The last card: adds a track, starting from a sound in the project or a sound template.
class _AddTrackCard extends StatelessWidget {
  const _AddTrackCard({required this.state, required this.empty});
  final AppState state;
  final bool empty;

  /// An empty track, or one playing a copy of a C++ starter (they replace the .caw templates, #160).
  Future<void> _add(BuildContext context) async {
    final pick = await showGlassSheet<Object>(
      context: context,
      backgroundColor: Neon.panel,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
          child: ListView(shrinkWrap: true, children: [
            ListTile(
              autofocus: true,
              leading: const Icon(Icons.crop_square, color: Neon.dim),
              title: const Text('Empty track'),
              subtitle: const Text('Pick its instrument later', style: TextStyle(color: Neon.dim)),
              onTap: () => Navigator.pop(context, false),
            ),
            const Heading('New track from a starter'),
            ExamplesList(
                examples: [for (final s in cppStarters) if (s.instrument) StarterExample.cpp(s)],
                onPick: (e) => Navigator.pop(context, e)),
          ]),
        ),
      ),
    );
    if (pick == false) state.addEmptyTrack();
    if (pick is StarterExample && pick.starter != null) {
      final doc = state.addCppStarter(pick.starter!);
      state.cppWorkbench(doc.id).tryOn(null);
    }
  }

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _add(context),
        child: Container(
          height: empty ? 120 : 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Neon.yellow.withValues(alpha: 0.6)),
          ),
          alignment: Alignment.center,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.add, color: Neon.yellow),
              SizedBox(width: 8),
              Text('Add track', style: TextStyle(color: Neon.yellow, fontWeight: FontWeight.w700, fontSize: 16)),
            ]),
            if (empty)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Start with a drum, a bass or a lead', style: TextStyle(color: Neon.dim)),
              ),
          ]),
        ),
      );
}

/// Everything about one track in one panel: instrument, notes, effects and mix. It follows the track by its id, so
/// an undo or redo (which rebuilds the project) keeps it open on the same track.
Future<void> showTrackSheet(BuildContext context, AppState s, LayerDoc layer, ValueChanged<String> onOpenModule) {
  final id = layer.id;
  return showGlassSheet<void>(
    context: context,
    backgroundColor: Neon.panel,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 760),
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: ListenableBuilder(
          listenable: s,
          builder: (context, _) {
            final now = s.project.layers.where((l) => l.id == id).firstOrNull;
            // Deleted from elsewhere (a key, another project opened): close instead of showing a stale track.
            if (now == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) Navigator.maybePop(context);
              });
              return const SizedBox(height: 80);
            }
            return _TrackSheet(
              key: ValueKey('track-sheet-$id'),
              state: s,
              layer: now,
              onOpenModule: (id) {
                Navigator.pop(context);
                onOpenModule(id);
              },
            );
          },
        ),
      ),
    ),
  );
}

class _TrackSheet extends StatelessWidget {
  const _TrackSheet({super.key, required this.state, required this.layer, required this.onOpenModule});
  final AppState state;
  final LayerDoc layer;
  final ValueChanged<String> onOpenModule;

  Widget _section(String title, Color color, {Widget? action}) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Row(children: [
          Text(title.toUpperCase(),
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
          const Spacer(),
          ?action,
        ]),
      );

  Widget _note(String text) => Text(text, style: const TextStyle(color: Neon.dim));

  /// Opens [clip]'s notes: the clip becomes the selection and its pattern opens in Build.
  void _openClip(ClipDoc clip) {
    state.selectClip(layer, clip);
    onOpenModule(clip.patternId);
  }

  List<Widget> _notes(BuildContext context) {
    final s = state;
    final p = s.project;
    if (layer.isFolder) return [_note('A folder holds tracks; their clips play into it.')];
    if (layer.isAudio) {
      return [
        if (layer.audioClips.isEmpty) _note('Records from its input; no clips yet.'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final c in layer.audioClips)
            Chip(
              avatar: const Icon(Icons.graphic_eq, size: 16, color: Neon.yellow),
              label: Text('${s.audioClipName(c)} · bar ${c.startSteps ~/ p.stepsPerBar + 1}'),
              side: const BorderSide(color: Neon.line),
            ),
        ]),
      ];
    }
    if (layer.clips.isEmpty) {
      return [
        _note('No clips on this track yet.'),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('track-sheet-new-pattern'),
            onPressed: () {
              final id = s.addModule(
                  PatternTemplate('${layer.name} notes', PatternDoc.blank(name: '${layer.name} notes').serialize()));
              s.addClip(layer, id);
            },
            icon: const Icon(Icons.queue_music, size: 16, color: Neon.yellow),
            label: const Text('New pattern on this track'),
          ),
        ),
      ];
    }
    return [
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final c in layer.clips)
          ActionChip(
            key: ValueKey('track-sheet-clip-${c.id}'),
            avatar: const Icon(Icons.piano, size: 16, color: Neon.yellow),
            label: Text('${p.module(c.patternId)?.name ?? 'Missing pattern'} · bar ${c.startSteps ~/ p.stepsPerBar + 1}'),
            side: BorderSide(color: c.id == s.selectedClipId ? Neon.yellow : Neon.line),
            labelStyle: const TextStyle(color: Neon.text, fontWeight: FontWeight.w600),
            onPressed: p.module(c.patternId) == null ? null : () => _openClip(c),
          ),
      ]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = state;
    final p = s.project;
    final color = trackColor(state, layer);
    final index = p.layers.indexOf(layer);
    final sound = trackSoundText(s, layer);
    final instrumentTrack = !layer.isFolder && !layer.isAudio;
    final first = layer.clips.where((c) => c.id == s.selectedClipId).firstOrNull ?? layer.clips.firstOrNull;

    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 4, 8, 20), children: [
      Row(children: [
        Tooltip(
          message: 'Change colour',
          child: InkWell(
            customBorder: const CircleBorder(),
            // The track's own colour from now on (a track in a folder otherwise shows a shade of the folder's).
            onTap: () => s.editLayer(layer, (l) {
              l.color = (l.color + 1) % LayerDoc.trackColors;
              l.ownColor = true;
            }),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: Neon.glow(color)),
              ),
            ),
          ),
        ),
        Expanded(
          child: InkWell(
            onTap: () => _rename(context, s, layer),
            child: Text(layer.name,
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          ),
        ),
        ToggleChip(label: 'M', tooltip: 'Mute', on: layer.mute, color: Neon.yellow, onTap: () => s.mixLayer(layer, mute: !layer.mute)),
        const SizedBox(width: 6),
        ToggleChip(label: 'S', tooltip: 'Solo', on: layer.solo, color: Neon.blue, onTap: () => s.mixLayer(layer, solo: !layer.solo)),
        PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'rename':
                _rename(context, s, layer);
              case 'up':
                s.moveLayer(index, index - 1);
              case 'down':
                s.moveLayer(index, index + 2);
              case 'delete':
                final nav = Navigator.of(context);
                if (!await confirmTrackDelete(context, s, layer)) return;
                nav.pop();
                s.removeLayer(layer);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
            if (index > 0) const PopupMenuItem(value: 'up', child: Text('Move up')),
            if (index < p.layers.length - 1) const PopupMenuItem(value: 'down', child: Text('Move down')),
            const PopupMenuItem(value: 'delete', child: Text('Delete track', style: TextStyle(color: Neon.pink))),
          ],
        ),
      ]),

      _section('Instrument', Neon.green,
          action: instrumentTrack
              ? TextButton.icon(onPressed: () => pickInstrument(context, s, layer),
                  icon: const Icon(Icons.piano, size: 16), label: Text(sound == null ? 'Pick' : 'Change'))
              : null),
      Text(
        layer.isFolder
            ? (layer.busEnabled ? 'A bus folder: its tracks play through its effects.' : 'A folder: it groups its tracks.')
            : layer.isAudio
                ? 'An audio track: it plays its audio clips${layer.input != null ? ' and its input' : ''}.'
                : sound ?? 'Nothing plays this track\'s notes yet',
        key: const ValueKey('track-sheet-instrument'),
        style: TextStyle(color: instrumentTrack && sound == null ? Neon.dim : Neon.text),
      ),

      _section('Notes', Neon.yellow,
          action: first == null || p.module(first.patternId) == null || layer.isAudio
              ? null
              : TextButton.icon(
                  key: const ValueKey('track-sheet-edit-notes'),
                  onPressed: () => _openClip(first),
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('Edit'))),
      ..._notes(context),

      _section('Effects', Neon.pink),
      // The focus view's FX stack: the instrument first, per-note FX, the track's effects (reorder, bypass, knobs,
      // remove) and its modulators. A folder without a bus explains why it has none.
      SizedBox(height: 420, child: FxStack(key: ValueKey('track-sheet-fx-${layer.id}'), state: s, layer: layer)),

      _section('Mix', Neon.blue),
      ValueListenableBuilder<int>(
        valueListenable: s.layerValueTick(layer.id),
        builder: (context, _, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const SizedBox(width: 56, child: Text('Volume', style: TextStyle(color: Neon.dim))),
            Expanded(child: SizedBox(height: 40, child: VolumeFader(value: layer.volume, vertical: false, color: color,
              label: '${layer.name} level', onChanged: (v) => s.mixLayer(layer, volume: v)))),
            SizedBox(width: 56, child: Text(VolumeTaper.label(layer.volume), textAlign: TextAlign.right,
              style: Neon.code(size: 10, color: Neon.dim))),
          ]),
          Row(children: [
            const SizedBox(width: 56, child: Text('Pan', style: TextStyle(color: Neon.dim))),
            const Text('L', style: TextStyle(color: Neon.dim, fontSize: 12)),
            Expanded(
              child: ResetOnDoubleTap(onReset: () => s.mixLayer(layer, pan: 0), child: Slider(
                key: const ValueKey('track-sheet-pan'),
                value: layer.pan.clamp(-1.0, 1.0),
                min: -1,
                max: 1,
                activeColor: color,
                onChanged: (v) => s.mixLayer(layer, pan: v.abs() < 0.04 ? 0 : v),
              )),
            ),
            const Text('R', style: TextStyle(color: Neon.dim, fontSize: 12)),
          ]),
          // Sends to bus folders, as the focus view's Mixer tab has them.
          if (!layer.isFolder || layer.busEnabled) ...[
            const SizedBox(height: 4),
            const Text('Sends', style: TextStyle(color: Neon.dim)),
            const SizedBox(height: 4),
            SendKnobs(state: s, layer: layer, size: 36),
          ],
        ]),
      ),
    ]);
  }
}
