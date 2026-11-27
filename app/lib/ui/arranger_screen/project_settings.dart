// Arrange's project settings sheet: tempo and tap tempo, time signature, key, seed, master level and loop crossfades.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../theme.dart';
import '../widgets.dart';
import '../volume_fader.dart';

class ProjectSettingsSheet extends StatefulWidget {
  const ProjectSettingsSheet({super.key, required this.state});
  final AppState state;

  @override
  State<ProjectSettingsSheet> createState() => _ProjectSettingsState();
}

class _ProjectSettingsState extends State<ProjectSettingsSheet> {
  final List<DateTime> _taps = [];
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
  void didUpdateWidget(covariant ProjectSettingsSheet old) {
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

  void _tap() {
    final now = DateTime.now();
    if (_taps.isNotEmpty && now.difference(_taps.last).inMilliseconds > 2000) _taps.clear();
    _taps.add(now);
    if (_taps.length > 5) _taps.removeAt(0);
    if (_taps.length >= 2) {
      final ms = _taps.last.difference(_taps.first).inMicroseconds / 1000.0 / (_taps.length - 1);
      final bpm = (60000 / ms).clamp(20.0, 400.0);
      widget.state.editProject((p) => p.bpm = double.parse(bpm.toStringAsFixed(1)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final p = s.project;
    final bpmText = p.bpm == p.bpm.roundToDouble() ? p.bpm.toStringAsFixed(0) : p.bpm.toStringAsFixed(1);
    return NeonPanel(
      color: Neon.blue,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton.outlined(
              tooltip: 'Slower: 1 BPM',
              onPressed: () => s.editProject((p) => p.bpm = (p.bpm - 1).clamp(20, 400).roundToDouble()),
              icon: const Icon(Icons.remove)),
          Expanded(
            child: Column(children: [
              Text(bpmText, style: Neon.code(size: 34, color: Neon.blue).copyWith(fontWeight: FontWeight.w700)),
              const Text('BPM', style: TextStyle(color: Neon.dim, fontSize: 12)),
            ]),
          ),
          IconButton.outlined(
              tooltip: 'Faster: 1 BPM',
              onPressed: () => s.editProject((p) => p.bpm = (p.bpm + 1).clamp(20, 400).roundToDouble()),
              icon: const Icon(Icons.add)),
          const SizedBox(width: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Neon.blue, minimumSize: const Size(72, 48)),
            onPressed: _tap,
            child: const Text('TAP', style: TextStyle(fontWeight: FontWeight.w800)),
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
          _Labeled(
            'Seed',
            SizedBox(
              width: 92,
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
          ),
          Text('${p.songSeconds.toStringAsFixed(2)} s song', style: const TextStyle(color: Neon.dim)),
        ]),
        Row(children: [
          const SizedBox(width: 56, child: Text('Master', style: TextStyle(color: Neon.dim))),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: s.masterValueTick,
              builder: (context, _, _) => Row(children: [
                Expanded(child: SizedBox(height: 36, child: VolumeFader(value: s.project.master, vertical: false,
                  color: Neon.blue, label: 'Master level', onChanged: s.setMaster))),
                SizedBox(width: 56, child: Text(VolumeTaper.label(s.project.master), textAlign: TextAlign.right,
                  style: Neon.code(size: 10, color: Neon.dim))),
              ]),
            ),
          ),
          SizedBox(width: 120, child: PeakMeter(state: s, read: () => s.audibleMeters.peakL, readRight: () => s.audibleMeters.peakR, color: Neon.blue)),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          activeThumbColor: Neon.blue,
          title: const Text('Crossfade loop seams'),
          subtitle: const Text('3 ms blend where a layer restarts', style: TextStyle(color: Neon.dim)),
          value: p.seamCrossfade,
          onChanged: (v) => s.editProject((p) => p.seamCrossfade = v),
        ),
      ]),
    );
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
