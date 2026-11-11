// The testing suite (#163): render a built C++ effect offline against a test signal and show null tests, A/B, analysers, CPU and latency as pass/fail cards.
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
      if (channels.isNotEmpty) ('Gain', db(channels.first['gain_db'])),
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

    final lat = (out['latency'] as Map?) ?? const {};
    cards.add(TestCard('Latency', lat['matches'] == false ? ToolStatus.fail : (lat['matches'] == true ? ToolStatus.pass : ToolStatus.info), [
      ('Declared', '${lat['declared'] ?? 0} frames'),
      ('Measured', lat['measured'] == null ? 'n/a for this signal' : '${lat['measured']} frames'),
    ], note: lat['matches'] == false ? 'The measured delay differs from latencyFrames: hosts will misalign it.'
        : (lat['measured'] == null ? 'Use an impulse, a sweep or noise to measure it.' : null)));

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
/// from the C++ editor's ⋯ menu ("Test suite…").
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
  bool _bypass = true;
  bool _cpu = true;
  String _compare = _none;
  bool _running = false;
  TestSuiteResult? _result;
  (List<(double, double)>, List<(double, double)>)? _wave;

  CppWorkbench get w => widget.workbench;
  BuildToolsBackend get backend => widget.backend ?? BuildToolsBackend.current;

  /// Built-in stereo effects to compare against.
  List<NativeComponentInfo> get _builtins => [
        for (final i in w.state.componentCatalog.value.values)
          if ((i.builtin || isBuiltinComponent(i.id)) && !i.isInstrument &&
              i.ports.where((p) => p.isAudio && p.channels == 2).length == 2)
            i,
      ]..sort((a, b) => a.label.compareTo(b.label));

  /// The knobs as the first track using it has them, else the defaults.
  Map<String, double> get _params => {...?w.uses.firstOrNull?.use.params};

  Map<String, dynamic> request(String library) => {
        'component': {'id': w.componentId, 'library': library, 'params': _params},
        'signal': switch (_signal) {
          TestSignal.sine => {'type': 'sine', 'frequency': 1000},
          TestSignal.sweep => {'type': 'sweep'},
          TestSignal.impulse => {'type': 'impulse'},
          TestSignal.pink => {'type': 'pink'},
        },
        'bypass': _bypass,
        'cpu': _cpu,
        'align': _signal == TestSignal.sine ? 'declared' : 'measured',
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
      setState(() {
        _result = result;
        _wave = wave;
      });
    } catch (e) {
      if (mounted) setState(() => _result = TestSuiteResult(ok: false, error: '$e'));
    } finally {
      if (mounted) setState(() => _running = false);
      unawaited(dir?.delete(recursive: true).then((_) {}, onError: (_) {}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final built = w.artifactPath != null;
    final instrument = w.isInstrument;
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
        onPressed: built && !instrument ? _run : null,
      ),
      children: [
        if (instrument)
          const ToolCard(title: 'Effects only for now', status: ToolStatus.info, child: Text(
            'The testing suite runs a stereo effect against a test signal. Instruments need note input, which the engine\'s '
            'suite doesn\'t send yet. Try the sample-pack maker to render this instrument.',
            style: TextStyle(fontSize: 12, color: Neon.dim)))
        else if (!built)
          const ToolCard(title: 'Build it first', status: ToolStatus.info, child: Text(
            'The suite loads the library the last build made. Press ▶ Build in the editor, then come back.',
            style: TextStyle(fontSize: 12, color: Neon.dim))),
        const ToolHeading('Signal'),
        ToolSegments<TestSignal>(values: TestSignal.values, labels: (s) => s.label, value: _signal, color: accent,
          keyPrefix: 'signal', onChanged: (s) => setState(() => _signal = s)),
        const ToolHeading('Compare'),
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
              child: Text('${_signal.label} through ${w.name}${_params.isEmpty ? ', default knobs' : ', knobs as on its first track'}.',
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
