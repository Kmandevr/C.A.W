// The testing suite (#163): render a built C++ effect offline against a test signal (an instrument: a note sequence) and show null tests, A/B, analysers, CPU, latency and the user's thresholds as pass/fail cards.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../engine/build_tools.dart';
import '../../engine/component_info.dart';
import '../../engine/engine.dart' show NativeComponentTrust;
import '../../model/arrange_fx.dart';
import '../../model/cpp_workbench.dart';
import '../haptics.dart';
import '../theme.dart';
import 'tool_kit.dart';

/// The test signals the screen offers (the engine has more: white noise, DC, silence, a WAV).
enum TestSignal { sine, sweep, impulse, pink }

extension on TestSignal {
  String get label => switch (this) {
        TestSignal.sine => 'Sine 1k',
        TestSignal.sweep => 'Sweep',
        TestSignal.impulse => 'Impulse',
        TestSignal.pink => 'Pink noise',
      };
}

/// The note sequences an instrument is played (the engine takes up to 4,096 notes).
enum TestNotes { single, chord, velocities, octaves }

extension TestNotesLook on TestNotes {
  String get label => switch (this) {
        TestNotes.single => 'C4',
        TestNotes.chord => 'Chord',
        TestNotes.velocities => 'Velocities',
        TestNotes.octaves => 'Octaves',
      };

  /// The request's `notes`: pitch, velocity, start and length (seconds).
  List<Map<String, num>> get notes => switch (this) {
        TestNotes.single => [{'pitch': 60, 'velocity': 100, 'start': 0, 'length': 1}],
        TestNotes.chord => [for (final p in const [60, 64, 67]) {'pitch': p, 'velocity': 100, 'start': 0, 'length': 1}],
        TestNotes.velocities => [
            for (final (i, v) in const [32, 64, 96, 127].indexed) {'pitch': 60, 'velocity': v, 'start': i * 0.5, 'length': 0.4},
          ],
        TestNotes.octaves => [
            for (final (i, p) in const [36, 48, 60, 72, 84].indexed) {'pitch': p, 'velocity': 100, 'start': i * 0.5, 'length': 0.4},
          ],
      };
}

/// The pass/fail thresholds the screen offers, as the engine's `checks` (docs/engine.md, "Component testing").
enum TestThreshold {
  headroom('Headroom', 'Peaks at most −0.3 dBFS on both sides'),
  audible('Not silent', 'RMS above −70 dBFS on both sides'),
  realtime('Real time', 'The median block takes under 50 % of its real time');

  const TestThreshold(this.label, this.detail);
  final String label, detail;

  List<Map<String, Object>> get checks => switch (this) {
        TestThreshold.headroom => [for (final c in const [0, 1]) {'path': 'output.channels.$c.peak_db', 'max': -0.3}],
        TestThreshold.audible => [for (final c in const [0, 1]) {'path': 'output.channels.$c.rms_db', 'min': -70}],
        TestThreshold.realtime => [{'path': 'cpu.median_percent', 'max': 50}],
      };
}

/// A readable name for a check's path (the screen's own; anything else shows its path).
String checkLabel(String path) => switch (path) {
      'output.channels.0.peak_db' => 'Peak L ≤ −0.3 dB',
      'output.channels.1.peak_db' => 'Peak R ≤ −0.3 dB',
      'output.channels.0.rms_db' => 'RMS L > −70 dB',
      'output.channels.1.rms_db' => 'RMS R > −70 dB',
      'cpu.median_percent' => 'Median block < 50 %',
      _ => path,
    };

/// One result card: its title, verdict and lines of measurements.
class TestCard {
  const TestCard(this.title, this.status, this.lines, {this.note});
  final String title;
  final ToolStatus status;
  final List<(String, String)> lines;
  final String? note;
}

/// The parts of a `caw_component_test` result the screen shows (docs/engine.md, "Component testing").
class TestSuiteResult {
  TestSuiteResult({required this.ok, this.error = '', this.cards = const [], this.spectrum = const [],
    this.response = const [], this.warnings = const []});
  final bool ok;
  final String error;
  final List<TestCard> cards;
  final List<(double, double)> spectrum, response;
  final List<String> warnings;

  ToolStatus get overall => cards.any((c) => c.status == ToolStatus.fail)
      ? ToolStatus.fail
      : cards.any((c) => c.status == ToolStatus.warn) ? ToolStatus.warn : ToolStatus.pass;

  /// The verdict the plug-in page shows (a run that couldn't start fails).
  PluginCheck get verdict => !ok
      ? PluginCheck.fail
      : switch (overall) {
          ToolStatus.fail => PluginCheck.fail,
          ToolStatus.warn => PluginCheck.warn,
          _ => PluginCheck.pass,
        };

  /// One line for the plug-in page: the verdict and how many thresholds pass.
  String get summary {
    if (!ok) return 'Could not run: ${error.split('\n').first}';
    final thresholds = cards.where((c) => c.title == 'Thresholds').firstOrNull;
    final passed = thresholds?.lines.where((l) => l.$1.startsWith('✓')).length;
    final head = switch (overall) {
      ToolStatus.pass => 'All checks pass',
      ToolStatus.warn => 'Passes, with things to check',
      _ => 'Something failed',
    };
    return thresholds == null ? head : '$head · $passed of ${thresholds.lines.length} thresholds pass';
  }

  static String db(Object? v) => v is num ? '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)} dB' : '−∞';
  static List<(double, double)> _bands(Object? o) => [
        for (final b in ((o as Map?)?['bands'] as List? ?? const []))
          if (b is List && b.length == 2 && b[0] is num && b[1] is num) ((b[0] as num).toDouble(), (b[1] as num).toDouble()),
      ];

  factory TestSuiteResult.fromJson(Map<String, dynamic> j) {
    if (j['ok'] != true) return TestSuiteResult(ok: false, error: (j['error'] as String?) ?? 'The test failed.');
    final out = (j['output'] as Map?) ?? const {};
    final warnings = [for (final w in (j['warnings'] as List? ?? const [])) '$w'];
    final channels = [for (final c in (out['channels'] as List? ?? const [])) c as Map];
    final cards = <TestCard>[];

    final levelStatus = warnings.contains('non_finite')
        ? ToolStatus.fail
        : warnings.any((w) => const {'clipping', 'denormals', 'failed_blocks'}.contains(w)) ? ToolStatus.warn : ToolStatus.pass;
    final stereo = (out['stereo'] as Map?) ?? const {};
    cards.add(TestCard('Levels', levelStatus, [
      for (final (i, side) in const [(0, 'L'), (1, 'R')])
        if (i < channels.length) ...[
          ('Peak $side', db(channels[i]['peak_db'])),
          ('RMS $side', db(channels[i]['rms_db'])),
        ],
      if (channels.isNotEmpty && channels.first['gain_db'] is num) ('Gain', db(channels.first['gain_db'])),
      if (stereo['correlation'] is num) ('Correlation', (stereo['correlation'] as num).toStringAsFixed(2)),
      if (stereo['width'] is num) ('Width', '${((stereo['width'] as num) * 100).round()}%'),
    ], note: switch (levelStatus) {
      ToolStatus.fail => 'NaN or infinity in the output: the host treats those samples as silence.',
      ToolStatus.warn => 'Watch out: ${warnings.where((w) => const {'clipping', 'denormals', 'failed_blocks'}.contains(w)).join(', ')}.',
      _ => null,
    }));

    if (j['bypass'] case final Map b) {
      final exact = b['exact'] == true;
      cards.add(TestCard('Null test · against bypass', ToolStatus.info, [
        ('Difference', exact ? 'none' : db(b['depth_db'])),
        ('Difference peak', db(b['difference_peak_db'])),
      ], note: exact ? 'Identical to the dry signal: at these settings the effect changes nothing.'
          : 'How far the output is from the dry signal (0 dB: as loud as the output itself).'));
    }
    if (j['compare'] case final Map c) {
      final exact = c['exact'] == true;
      final depth = c['depth_db'];
      final status = exact || (depth is num && depth < -90) ? ToolStatus.pass : ToolStatus.warn;
      cards.add(TestCard('Null test · against ${c['id'] ?? 'the other'}', status, [
        ('Difference', exact ? 'none (bit-identical)' : db(depth)),
        ('Difference peak', db(c['difference_peak_db'])),
        ('Offset', '${c['offset_frames'] ?? 0} frames'),
      ], note: status == ToolStatus.pass ? 'They null: the two sound the same.' : 'They sound different.'));
    }

    if (out['latency'] case final Map lat) {
      cards.add(TestCard('Latency', lat['matches'] == false ? ToolStatus.fail : (lat['matches'] == true ? ToolStatus.pass : ToolStatus.info), [
        ('Declared', '${lat['declared'] ?? 0} frames'),
        ('Measured', lat['measured'] == null ? 'n/a for this signal' : '${lat['measured']} frames'),
      ], note: lat['matches'] == false ? 'The measured delay differs from latencyFrames: hosts will misalign it.'
          : (lat['measured'] == null ? 'Use an impulse, a sweep or noise to measure it.' : null)));
    }

    final tail = (out['tail'] as Map?) ?? const {};
    final tailStatus = tail['within_declared'] == false
        ? ToolStatus.fail
        : (tail['truncated'] == true ? ToolStatus.warn : ToolStatus.pass);
    cards.add(TestCard('Tail', tailStatus, [
      ('Declared', tail['declared'] is num ? '${tail['declared']} frames' : '${tail['declared'] ?? 0}'),
      ('Measured', tail['measured_ms'] is num ? '${(tail['measured_ms'] as num).toStringAsFixed(1)} ms' : 'n/a'),
    ], note: switch (tailStatus) {
      ToolStatus.fail => 'It rings longer than tailFrames says: a host may cut it off.',
      ToolStatus.warn => 'The render ended while the tail still sounded.',
      _ => null,
    }));

    if (j['cpu'] case final Map cpu) {
      final median = (cpu['median_percent'] as num?)?.toDouble() ?? 0;
      final worst = (cpu['worst_percent'] as num?)?.toDouble() ?? 0;
      cards.add(TestCard('CPU', median > 100 ? ToolStatus.fail : (median > 50 ? ToolStatus.warn : ToolStatus.pass), [
        ('Median block', '${median.toStringAsFixed(median < 1 ? 2 : 1)}% · ${cpu['median_us']} µs'),
        ('Worst block', '${worst.toStringAsFixed(1)}% · ${cpu['worst_us']} µs'),
        ('Blocks', '${cpu['blocks']}'),
      ], note: 'Of one block\'s real time on this device. The worst block often includes a first-call warm-up.'));
    }

    if (out['thd'] case final Map thd) {
      final l = (thd['left'] as Map?) ?? const {};
      cards.add(TestCard('Distortion', ToolStatus.info, [
        ('THD', l['thd_percent'] is num ? '${(l['thd_percent'] as num).toStringAsFixed(2)}%' : 'n/a'),
        ('THD+N', l['thd_n_percent'] is num ? '${(l['thd_n_percent'] as num).toStringAsFixed(2)}%' : 'n/a'),
      ]));
    }

    if (j['checks'] case final List checks when checks.isNotEmpty) {
      final rows = [for (final c in checks) if (c is Map) c];
      cards.add(TestCard('Thresholds', j['passed'] == true ? ToolStatus.pass : ToolStatus.fail, [
        for (final c in rows)
          ('${c['pass'] == true ? '✓' : '✗'} ${checkLabel('${c['path']}')}', c['value'] is num
              ? (c['value'] as num).toStringAsFixed(1)
              : (c['value'] == null ? 'missing' : '${c['value']}')),
      ], note: j['passed'] == true ? null : 'A value outside its threshold fails the test (a missing value too).'));
    }

    return TestSuiteResult(ok: true, cards: cards, spectrum: _bands(out['spectrum']), response: _bands(out['frequency_response']),
      warnings: warnings);
  }
}

/// Columns of (min, max) per channel from a 32-bit float or 16/24-bit PCM stereo WAV (the suite's `write_wav`).
(List<(double, double)>, List<(double, double)>) waveOverview(Uint8List bytes, int columns) {
  final d = ByteData.sublistView(bytes);
  var pos = 12, format = 3, channels = 2, bits = 32;
  int? dataAt, dataLen;
  while (pos + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(pos, pos + 4));
    final len = d.getUint32(pos + 4, Endian.little);
    if (id == 'fmt ') {
      format = d.getUint16(pos + 8, Endian.little);
      channels = d.getUint16(pos + 10, Endian.little);
      bits = d.getUint16(pos + 22, Endian.little);
    } else if (id == 'data') {
      dataAt = pos + 8;
      dataLen = math.min(len, bytes.length - dataAt);
      break;
    }
    pos += 8 + len + (len & 1);
  }
  if (dataAt == null || channels < 1) return (const [], const []);
  final bytesPer = bits ~/ 8;
  final frames = dataLen! ~/ (bytesPer * channels);
  double sample(int frame, int ch) {
    final o = dataAt! + (frame * channels + ch) * bytesPer;
    if (format == 3 && bits == 32) return d.getFloat32(o, Endian.little);
    if (bits == 16) return d.getInt16(o, Endian.little) / 32768;
    if (bits == 24) return ((d.getUint8(o) | d.getUint8(o + 1) << 8 | d.getInt8(o + 2) << 16)) / 8388608;
    return 0;
  }

  List<(double, double)> lane(int ch) {
    if (frames == 0) return const [];
    final cols = <(double, double)>[];
    for (var c = 0; c < columns; c++) {
      final a = c * frames ~/ columns, b = math.max(a + 1, (c + 1) * frames ~/ columns);
      var lo = 0.0, hi = 0.0;
      for (var f = a; f < b && f < frames; f++) {
        final v = sample(f, ch);
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
      cols.add((lo, hi));
    }
    return cols;
  }

  return (lane(0), lane(math.min(1, channels - 1)));
}

/// The testing suite for the open C++ component: pick a signal and the comparisons, Run, and read the cards. Reach it
/// from the component's plug-in page (its Test step).
class TestSuiteScreen extends StatefulWidget {
  const TestSuiteScreen({super.key, required this.workbench, this.backend});
  final CppWorkbench workbench;

  /// Where requests go (the engine unless a test passes a fake).
  final BuildToolsBackend? backend;

  @override
  State<TestSuiteScreen> createState() => _TestSuiteScreenState();
}

/// What the tested output is compared with, besides bypass.
const _none = '', _previous = '@previous';

class _TestSuiteScreenState extends State<TestSuiteScreen> {
  TestSignal _signal = TestSignal.sine;
  TestNotes _notes = TestNotes.single;
  final Set<TestThreshold> _thresholds = {TestThreshold.headroom, TestThreshold.audible};
  bool _bypass = true;
  bool _cpu = true;
  String _compare = _none;
  bool _running = false;
  TestSuiteResult? _result;
  (List<(double, double)>, List<(double, double)>)? _wave;

  CppWorkbench get w => widget.workbench;
  BuildToolsBackend get backend => widget.backend ?? BuildToolsBackend.current;

  bool get _instrument => w.isInstrument;

  /// Built-ins of the same kind to compare against: stereo effects, or instruments for an instrument.
  List<NativeComponentInfo> get _builtins => [
        for (final i in w.state.componentCatalog.value.values)
          if ((i.builtin || isBuiltinComponent(i.id)) && i.isInstrument == _instrument &&
              i.ports.where((p) => p.isAudio && p.channels == 2).length == (_instrument ? 1 : 2))
            i,
      ]..sort((a, b) => a.label.compareTo(b.label));

  /// The thresholds asked for, as the engine's checks (real time only while CPU is timed).
  List<Map<String, Object>> get _checks => [
        for (final t in TestThreshold.values)
          if (_thresholds.contains(t) && (t != TestThreshold.realtime || _cpu)) ...t.checks,
      ];

  /// The knobs as the first track using it has them, else the defaults.
  Map<String, double> get _params => {...?w.uses.firstOrNull?.use.params};

  Map<String, dynamic> request(String library) => {
        'component': {'id': w.componentId, 'library': library, 'params': _params},
        if (_instrument)
          'notes': _notes.notes
        else ...{
          'signal': switch (_signal) {
            TestSignal.sine => {'type': 'sine', 'frequency': 1000},
            TestSignal.sweep => {'type': 'sweep'},
            TestSignal.impulse => {'type': 'impulse'},
            TestSignal.pink => {'type': 'pink'},
          },
          'bypass': _bypass,
        },
        'cpu': _cpu,
        // An instrument has no input to measure a delay against, so its null test aligns by the declared latency.
        'align': _instrument || _signal == TestSignal.sine ? 'declared' : 'measured',
        if (_checks.isNotEmpty) 'checks': _checks,
        if (_compare == _previous && w.previousArtifactPath != null)
          'compare': {'id': w.componentId, 'library': w.previousArtifactPath, 'params': _params}
        else if (_compare.isNotEmpty && _compare != _previous)
          'compare': {'id': _compare},
        'write_wav': 'output.wav',
      };

  Future<void> _run() async {
    final library = w.artifactPath;
    if (library == null || _running) return;
    setState(() {
      _running = true;
      _result = null;
      _wave = null;
    });
    Directory? dir;
    try {
      dir = await Directory.systemTemp.createTemp('caw-test-');
      final json = await backend.test(request(library), trust: NativeComponentTrust.trusted, outputDir: dir.path);
      final result = TestSuiteResult.fromJson(json);
      final wav = File('${dir.path}/output.wav');
      final wave = await wav.exists()
          ? await Isolate.run(() => waveOverview(wav.readAsBytesSync(), 240))
          : null;
      if (!mounted) return;
      result.ok ? Haptics.threshold() : Haptics.error();
      w.recordTest(result.verdict, result.summary);
      setState(() {
        _result = result;
        _wave = wave;
      });
    } catch (e) {
      if (mounted) {
        final failed = TestSuiteResult(ok: false, error: '$e');
        w.recordTest(failed.verdict, failed.summary);
        setState(() => _result = failed);
      }
    } finally {
      if (mounted) setState(() => _running = false);
      unawaited(dir?.delete(recursive: true).then((_) {}, onError: (_) {}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final built = w.artifactPath != null;
    final instrument = _instrument;
    const accent = Neon.blue;
    final result = _result;
    return ToolPage(
      title: 'Test suite',
      subtitle: w.name,
      icon: Icons.science_outlined,
      accent: accent,
      bottom: ToolAction(
        label: 'Run test',
        icon: Icons.play_arrow,
        color: accent,
        busyLabel: 'Rendering offline…',
        progress: _running ? -1 : null,
        onPressed: built ? _run : null,
      ),
      children: [
        if (!built)
          const ToolCard(title: 'Build it first', status: ToolStatus.info, child: Text(
            'The suite loads the library the last build made. Press ▶ Build in the editor, then come back.',
            style: TextStyle(fontSize: 12, color: Neon.dim))),
        if (instrument) ...[
          const ToolHeading('Notes'),
          ToolSegments<TestNotes>(values: TestNotes.values, labels: (n) => n.label, value: _notes, color: accent,
            keyPrefix: 'notes', onChanged: (n) => setState(() => _notes = n)),
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(switch (_notes) {
            TestNotes.single => 'One C4 at velocity 100, held 1 s, then its release.',
            TestNotes.chord => 'C4, E4 and G4 together at velocity 100, held 1 s.',
            TestNotes.velocities => 'C4 four times, at velocity 32, 64, 96 and 127.',
            TestNotes.octaves => 'C2 to C6, one note per octave.',
          }, style: const TextStyle(fontSize: 11, color: Neon.dim))),
        ] else ...[
          const ToolHeading('Signal'),
          ToolSegments<TestSignal>(values: TestSignal.values, labels: (s) => s.label, value: _signal, color: accent,
            keyPrefix: 'signal', onChanged: (s) => setState(() => _signal = s)),
        ],
        const ToolHeading('Compare'),
        if (!instrument)
          ToolSwitch(label: 'A/B against bypass', detail: 'A null test of the output against the dry signal',
            value: _bypass, color: accent, onChanged: (v) => setState(() => _bypass = v)),
        ToolSwitch(label: 'CPU per block', detail: 'Times every process call on this device',
          value: _cpu, color: accent, onChanged: (v) => setState(() => _cpu = v)),
        Padding(padding: const EdgeInsets.only(top: 4), child: Row(children: [
          const Expanded(child: Text('Null test against', style: TextStyle(fontSize: 13, color: Neon.text))),
          DropdownButton<String>(
            key: const ValueKey('test-compare'),
            value: _compare,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 12, color: accent),
            underline: const SizedBox.shrink(),
            items: [
              const DropdownMenuItem(value: _none, child: Text('Nothing else')),
              if (w.previousArtifactPath != null) const DropdownMenuItem(value: _previous, child: Text('The previous build')),
              for (final b in _builtins) DropdownMenuItem(value: b.id, child: Text(b.label)),
            ],
            onChanged: (v) => setState(() => _compare = v ?? _none),
          ),
        ])),
        const ToolHeading('Pass / fail'),
        for (final t in TestThreshold.values)
          ToolSwitch(
            key: ValueKey('test-threshold-${t.name}'),
            label: t.label,
            detail: t == TestThreshold.realtime && !_cpu ? '${t.detail} (needs CPU per block)' : t.detail,
            value: _thresholds.contains(t),
            color: accent,
            onChanged: (v) => setState(() => v ? _thresholds.add(t) : _thresholds.remove(t))),
        if (result != null) ...[
          const ToolHeading('Results'),
          if (!result.ok)
            ToolCard(title: 'The test could not run', status: ToolStatus.fail,
              child: Text(result.error, style: const TextStyle(fontSize: 12, color: Neon.text)))
          else ...[
            ToolCard(
              key: const ValueKey('test-summary'),
              title: switch (result.overall) {
                ToolStatus.pass => 'All checks pass',
                ToolStatus.warn => 'Passes, with things to check',
                _ => 'Something failed',
              },
              status: result.overall,
              child: Text('${instrument ? '${_notes.label} played on' : '${_signal.label} through'} ${w.name}'
                '${_params.isEmpty ? ', default knobs' : ', knobs as on its first track'}.',
                style: const TextStyle(fontSize: 12, color: Neon.dim))),
            if (_wave case (final l, final r))
              ToolCard(title: 'Scope · output', color: Neon.green, child: WaveGraph(left: l, right: r)),
            if (result.spectrum.isNotEmpty)
              ToolCard(title: 'Spectrum · output', color: accent, child: BandGraph(bands: result.spectrum, color: accent)),
            if (result.response.isNotEmpty)
              ToolCard(title: 'Frequency response', color: Neon.violet,
                child: BandGraph(bands: result.response, color: Neon.violet, range: 48, centred: true)),
            for (final c in result.cards)
              ToolCard(key: ValueKey('test-card-${c.title}'), title: c.title, status: c.status, child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (k, v) in c.lines) ToolStat(k, v),
                  if (c.note != null) Padding(padding: const EdgeInsets.only(top: 6),
                    child: Text(c.note!, style: const TextStyle(fontSize: 11, color: Neon.dim))),
                ])),
          ],
        ],
      ],
    );
  }
}
