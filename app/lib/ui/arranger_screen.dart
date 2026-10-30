// Tracks (the Arranger area): a project strip, big visual track cards, and a panel per track with its sound, notes, effects and mix.
import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../model/app_state.dart';
import '../model/pattern_doc.dart';
import '../model/project.dart';
import 'builder_screen.dart' show kindColor, kindIcon;
import 'param_control.dart';
import 'theme.dart';
import 'widgets.dart';

class ArrangerScreen extends StatelessWidget {
  const ArrangerScreen({super.key, required this.state, required this.onOpenModule});
  final AppState state;

  /// Opens a module in the Sounds area (its controls, code or notes).
  final ValueChanged<String> onOpenModule;

  @override
  Widget build(BuildContext context) {
    final p = state.project;
    return ListView(
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
  }
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
                read: () => state.meters.peakL > state.meters.peakR ? state.meters.peakL : state.meters.peakR,
                color: Neon.blue),
          ]),
        ),
      ),
    );
  }
}

Future<void> showProjectSheet(BuildContext context, AppState s) {
  final opened = s.project;
  return showModalBottomSheet<void>(
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
              if (s.globalDefs.isNotEmpty) ...[
                const Heading('Project controls'),
                ValueListenableBuilder<int>(
                  valueListenable: s.values,
                  builder: (context, _, _) => ParamGroups(
                    params: s.globalDefs,
                    color: Neon.blue,
                    valueOf: s.globalValue,
                    onChanged: (p, v) => s.setGlobal(p.name, v),
                  ),
                ),
              ],
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

  static const keys = [
    'C major', 'C minor', 'C# minor', 'D major', 'D minor', 'Eb major', 'E minor', 'F major', 'F minor', //
    'F# minor', 'G major', 'G minor', 'A major', 'A minor', 'Bb major', 'B minor', 'None',
  ];

  @override
  void initState() {
    super.initState();
    _seed = TextEditingController(text: widget.state.project.seed.toRadixString(16));
  }

  @override
  void didUpdateWidget(covariant _ProjectSettings old) {
    super.didUpdateWidget(old);
    final hex = widget.state.project.seed.toRadixString(16);
    if (int.tryParse(_seed.text, radix: 16) != widget.state.project.seed) _seed.text = hex;
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
            items: [for (var b = 2; b <= 7; b++) DropdownMenuItem(value: b, child: Text('$b/4'))],
            onChanged: (v) => s.editProject((p) => p.beatsPerBar = v!),
          ),
        ),
        _Labeled(
          'Loop',
          DropdownButton<int>(
            value: p.loopBars,
            items: [
              for (final b in {1, 2, 4, 8, 16, p.loopBars}.toList()..sort())
                DropdownMenuItem(value: b, child: Text(b == 1 ? '1 bar' : '$b bars')),
            ],
            onChanged: (v) => s.editProject((p) => p.loopBars = v!),
          ),
        ),
        _Labeled(
          'Key',
          DropdownButton<String>(
            value: keys.contains(p.key) ? p.key : 'None',
            items: [for (final k in keys) DropdownMenuItem(value: k, child: Text(k))],
            onChanged: (v) => s.editProject((p) => p.key = v!),
          ),
        ),
        Text('${p.loopSeconds.toStringAsFixed(2)} s loop', style: const TextStyle(color: Neon.dim)),
      ]),
      Row(children: [
        const SizedBox(width: 56, child: Text('Master', style: TextStyle(color: Neon.dim))),
        Expanded(
          child: Slider(
            value: p.master,
            activeColor: Neon.blue,
            onChanged: (v) => s.editProject((p) => p.master = v),
          ),
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

/// The steps one cycle of a track lasts: its pattern's length, its own, or the project loop's.
int _cycleSteps(AppState s, LayerDoc l) {
  final p = s.project;
  final pattern = p.module(l.patternId);
  if (pattern != null) return _notesOf(pattern.source)?.lengthSteps(p.beatsPerBar) ?? p.loopSteps;
  return l.lengthSteps > 0 ? l.lengthSteps : p.loopSteps;
}

String _stepsLabel(int steps, int stepsPerBar) {
  if (steps % stepsPerBar == 0) return steps == stepsPerBar ? '1 bar' : '${steps ~/ stepsPerBar} bars';
  if (steps % 4 == 0) return steps == 4 ? '1 beat' : '${steps ~/ 4} beats';
  return '$steps 16ths';
}

/// Parsed pattern sources, so cards don't re-parse text that hasn't changed.
final Map<String, PatternDoc?> _parsed = {};
PatternDoc? _notesOf(String source) {
  if (_parsed.length > 64) _parsed.clear();
  return _parsed.putIfAbsent(source, () => PatternDoc.parse(source).doc);
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

/// One track: its colour, name, sound and notes, a picture of one cycle with the playhead, a level meter, M and S.
class _TrackCard extends StatelessWidget {
  const _TrackCard({required this.state, required this.layer, required this.index, required this.onOpenModule});
  final AppState state;
  final LayerDoc layer;
  final int index;
  final ValueChanged<String> onOpenModule;

  @override
  Widget build(BuildContext context) {
    final p = state.project;
    final color = Neon.layer(layer.color);
    final sound = p.module(layer.generatorId);
    final pattern = p.module(layer.patternId);
    final cycle = _cycleSteps(state, layer);
    final dim = layer.mute || (p.layers.any((l) => l.solo) && !layer.solo);
    final detail = [
      // The sound's name only when the track's own name doesn't already say it.
      if (sound == null) 'No sound' else if (sound.name != layer.name) sound.name,
      if (pattern != null) pattern.name,
      _stepsLabel(cycle, p.stepsPerBar),
      if (layer.effectIds.isNotEmpty) '${layer.effectIds.length} fx',
    ].join('  ·  ');
    return Opacity(
      opacity: dim ? 0.5 : 1,
      child: NeonPanel(
        color: color,
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => showTrackSheet(context, state, layer, onOpenModule),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(sound == null ? Icons.add_circle_outline : kindIcon('generator'), color: color, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(layer.name,
                        overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    Text(detail,
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
                child: _Lane(state: state, index: index, color: color, pattern: pattern, cycle: cycle, stepsPerBar: p.stepsPerBar),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: PeakMeter(
                    state: state,
                    read: () => index < state.layerMeters.length ? state.layerMeters[index].peak : 0,
                    color: color),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One cycle of a track: its pattern's notes, or a block per bar for a sound with no pattern, and the playhead.
class _Lane extends StatelessWidget {
  const _Lane(
      {required this.state,
      required this.index,
      required this.color,
      required this.pattern,
      required this.cycle,
      required this.stepsPerBar});
  final AppState state;
  final int index;
  final Color color;
  final ModuleDoc? pattern;
  final int cycle, stepsPerBar;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 40,
        child: Stack(fit: StackFit.expand, children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: _LanePainter(
                  notes: pattern == null ? null : _notesOf(pattern!.source)?.notes, cycle: cycle, bar: stepsPerBar, color: color),
            ),
          ),
          ValueListenableBuilder<int>(
            valueListenable: state.tick,
            builder: (context, _, _) {
              final m = index < state.layerMeters.length ? state.layerMeters[index] : null;
              final at = state.meters.playing ? (m?.progress ?? 0) : -1.0;
              return CustomPaint(painter: _PlayheadPainter(at, color));
            },
          ),
        ]),
      );
}

class _LanePainter extends CustomPainter {
  _LanePainter({required this.notes, required this.cycle, required this.bar, required this.color});
  final List<PatternNote>? notes;
  final int cycle, bar;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6));
    canvas.drawRRect(r, Paint()..color = Neon.bg.withValues(alpha: 0.6));
    final stepW = size.width / cycle;
    // Bar lines.
    final grid = Paint()..color = Neon.line;
    for (var s = bar; s < cycle; s += bar) {
      canvas.drawLine(Offset(s * stepW, 2), Offset(s * stepW, size.height - 2), grid);
    }
    final ns = notes;
    if (ns == null) {
      // No pattern: the sound plays the whole cycle, shown as one block per bar.
      final fill = Paint()..color = color.withValues(alpha: 0.22);
      final edge = Paint()
        ..color = color.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke;
      for (var s = 0; s < cycle; s += bar) {
        final w = ((s + bar > cycle ? cycle - s : bar) * stepW) - 3;
        final rect = RRect.fromRectAndRadius(Rect.fromLTWH(s * stepW + 1.5, 6, w, size.height - 12), const Radius.circular(4));
        canvas.drawRRect(rect, fill);
        canvas.drawRRect(rect, edge);
      }
      return;
    }
    if (ns.isEmpty) return;
    var lo = ns.first.pitch, hi = lo;
    for (final n in ns) {
      if (n.pitch < lo) lo = n.pitch;
      if (n.pitch > hi) hi = n.pitch;
    }
    final span = hi - lo < 6 ? 6.0 : hi - lo;
    final rowH = (size.height - 8) / (span + 1);
    final noteH = rowH.clamp(2.0, 7.0);
    final paint = Paint();
    for (final n in ns) {
      final x = n.at.toDouble() * stepW;
      if (x > size.width - 2) continue;
      final w = (n.len.toDouble() * stepW).clamp(2.0, size.width - x);
      final y = 4 + (hi - n.pitch + (span - (hi - lo)) / 2) * rowH + (rowH - noteH) / 2;
      paint.color = color.withValues(alpha: 0.45 + 0.55 * n.vel.clamp(0.0, 1.0));
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, noteH), const Radius.circular(2)), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LanePainter old) =>
      old.notes != notes || old.cycle != cycle || old.bar != bar || old.color != color;
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

  Future<void> _add(BuildContext context) async {
    final p = state.project;
    final sounds = p.modules.where((m) => state.isGenerator(m.id)).toList();
    final templates = [
      for (final t in state.templates)
        if (const {'generator', 'synth'}.contains(headerValue(t.source, 'kind') ?? 'generator')) t,
    ];
    final pick = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Neon.panel,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
          child: ListView(shrinkWrap: true, children: [
            if (sounds.isNotEmpty) ...[
              const Heading('Sounds in this project'),
              for (final (i, m) in sounds.indexed)
                ListTile(
                  autofocus: i == 0,
                  leading: Icon(kindIcon('generator'), color: kindColor('generator')),
                  title: Text(m.name),
                  onTap: () => Navigator.pop(context, m),
                ),
            ],
            const Heading('New sound from a template'),
            for (final t in templates)
              ListTile(
                leading: const Icon(Icons.auto_awesome, color: Neon.green),
                title: Text(headerValue(t.source, 'name') ?? t.file),
                subtitle: Text(headerValue(t.source, 'summary') ?? '', style: const TextStyle(color: Neon.dim)),
                onTap: () => Navigator.pop(context, t),
              ),
            ListTile(
              leading: const Icon(Icons.crop_square, color: Neon.dim),
              title: const Text('Empty track'),
              subtitle: const Text('Pick its sound later', style: TextStyle(color: Neon.dim)),
              onTap: () => Navigator.pop(context, false),
            ),
          ]),
        ),
      ),
    );
    if (pick == null) return;
    if (pick is ModuleDoc) state.addLayer(soundId: pick.id);
    if (pick is Template) state.addLayer(soundId: state.addModule(pick));
    if (pick == false) state.addLayer(empty: true);
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

/// Everything about one track in one panel: sound (with its sliders), notes, effects and mix.
Future<void> showTrackSheet(BuildContext context, AppState s, LayerDoc layer, ValueChanged<String> onOpenModule) =>
    showModalBottomSheet<void>(
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
              // Deleted from elsewhere (a key, another project opened): close instead of showing a stale track.
              if (!s.project.layers.contains(layer)) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted) Navigator.maybePop(context);
                });
                return const SizedBox(height: 80);
              }
              return _TrackSheet(
                state: s,
                layer: layer,
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

class _TrackSheet extends StatelessWidget {
  const _TrackSheet({required this.state, required this.layer, required this.onOpenModule});
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

  Widget _choice(String label, IconData icon, Color color, bool selected, VoidCallback onTap) => ChoiceChip(
        avatar: Icon(icon, size: 16, color: color),
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        selectedColor: color.withValues(alpha: 0.22),
        side: BorderSide(color: selected ? color : Neon.line),
        labelStyle: const TextStyle(color: Neon.text, fontWeight: FontWeight.w600),
        showCheckmark: false,
      );

  @override
  Widget build(BuildContext context) {
    final s = state;
    final p = s.project;
    final color = Neon.layer(layer.color);
    final index = p.layers.indexOf(layer);
    final sounds = p.modules.where((m) => s.isGenerator(m.id)).toList();
    final effects = p.modules.where((m) => s.isEffect(m.id)).toList();
    final patterns = p.modules.where((m) => s.isPattern(m.id)).toList();
    final sound = p.module(layer.generatorId);
    final soundParams = [for (final q in s.info[sound?.id]?.params ?? const <ParamInfo>[]) if (!q.global) q];
    final lengths = lengthChoices(p.stepsPerBar);
    if (!lengths.any((c) => c.$1 == layer.lengthSteps)) lengths.add((layer.lengthSteps, '${layer.lengthSteps} 16ths'));
    Widget? edit(String? id) => id == null
        ? null
        : TextButton.icon(onPressed: () => onOpenModule(id), icon: const Icon(Icons.edit, size: 16), label: const Text('Edit'));

    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 4, 8, 20), children: [
      Row(children: [
        Tooltip(
          message: 'Change colour',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => s.editLayer(layer, (l) => l.color = (l.color + 1) % Neon.layers.length),
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
          onSelected: (v) {
            switch (v) {
              case 'rename':
                _rename(context, s, layer);
              case 'up':
                s.moveLayer(index, index - 1);
              case 'down':
                s.moveLayer(index, index + 2);
              case 'delete':
                Navigator.pop(context);
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

      _section('Sound', Neon.green, action: edit(sound?.id)),
      if (sounds.isEmpty)
        const Text('No sounds yet: make one in Sounds, or add a track from a template.', style: TextStyle(color: Neon.dim))
      else
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final m in sounds)
            _choice(m.name, kindIcon('generator'), Neon.green, m.id == layer.generatorId,
                () => s.editLayer(layer, (l) => l.generatorId = m.id)),
        ]),
      if (sound != null && soundParams.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8, right: 8),
          child: ValueListenableBuilder<int>(
            valueListenable: s.values,
            builder: (context, _, _) => ParamGroups(
              params: soundParams,
              color: color,
              valueOf: (q) => sound.params[q.name] ?? q.defaultValue,
              onChanged: (q, v) => s.setParam(sound.id, q.name, v),
            ),
          ),
        ),

      _section('Notes', Neon.yellow, action: edit(layer.patternId)),
      Wrap(spacing: 6, runSpacing: 6, children: [
        _choice('None', Icons.block, Neon.dim, layer.patternId == null, () => s.editLayer(layer, (l) => l.patternId = null)),
        for (final m in patterns)
          _choice(m.name, kindIcon('pattern'), Neon.yellow, m.id == layer.patternId,
              () => s.editLayer(layer, (l) => l.patternId = m.id)),
      ]),
      if (layer.patternId == null) ...[
        const Padding(
          padding: EdgeInsets.only(top: 10, bottom: 6),
          child: Text('Loops every', style: TextStyle(color: Neon.dim, fontSize: 13)),
        ),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final c in lengths)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(c.$2),
                  selected: c.$1 == layer.lengthSteps,
                  onSelected: (_) => s.editLayer(layer, (l) => l.lengthSteps = c.$1),
                  selectedColor: color.withValues(alpha: 0.22),
                  side: BorderSide(color: c.$1 == layer.lengthSteps ? color : Neon.line),
                  labelStyle: const TextStyle(color: Neon.text, fontWeight: FontWeight.w600),
                  showCheckmark: false,
                ),
              ),
          ]),
        ),
      ] else
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('Loops with its notes', style: TextStyle(color: Neon.dim, fontSize: 13)),
        ),

      _section('Effects', Neon.pink),
      Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final id in layer.effectIds)
          InputChip(
            label: Text(p.module(id)?.name ?? '?'),
            avatar: Icon(kindIcon('effect'), size: 16, color: Neon.pink),
            onPressed: () => onOpenModule(id),
            onDeleted: () => s.editLayer(layer, (l) => l.effectIds.remove(id)),
          ),
        if (layer.effectIds.length < 8)
          PopupMenuButton<String>(
            tooltip: 'Add an effect',
            enabled: effects.isNotEmpty,
            onSelected: (id) => s.editLayer(layer, (l) => l.effectIds.add(id)),
            itemBuilder: (_) => [for (final e in effects) PopupMenuItem(value: e.id, child: Text(e.name))],
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Text(effects.isEmpty ? 'No effects yet (make one in Sounds)' : '+ Add effect',
                  style: const TextStyle(color: Neon.pink, fontWeight: FontWeight.w600)),
            ),
          ),
      ]),

      _section('Mix', Neon.blue),
      ValueListenableBuilder<int>(
        valueListenable: s.values,
        builder: (context, _, _) => Column(children: [
          Row(children: [
            const SizedBox(width: 56, child: Text('Volume', style: TextStyle(color: Neon.dim))),
            Expanded(child: Slider(value: layer.volume, activeColor: color, onChanged: (v) => s.mixLayer(layer, volume: v))),
          ]),
          Row(children: [
            const SizedBox(width: 56, child: Text('Pan', style: TextStyle(color: Neon.dim))),
            const Text('L', style: TextStyle(color: Neon.dim, fontSize: 12)),
            Expanded(
              child: Slider(
                value: layer.pan,
                min: -1,
                max: 1,
                activeColor: color,
                onChanged: (v) => s.mixLayer(layer, pan: v.abs() < 0.04 ? 0 : v),
              ),
            ),
            const Text('R', style: TextStyle(color: Neon.dim, fontSize: 12)),
          ]),
        ]),
      ),
    ]);
  }
}
