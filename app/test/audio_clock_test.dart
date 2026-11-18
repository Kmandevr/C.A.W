// Engine diagnostics' Audio clock block (#241): the streams' real rates, callbacks, xruns, shedding and the input's fill, live and copyable.
import 'package:caw/engine/engine.dart';
import 'package:caw/ui/settings/audio_diagnostics.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> status({double seconds = 10, int frames = 480000, bool input = true}) => {
      'running': true,
      'backend': 'AAudio',
      'device': 'Default Playback Device',
      'sample_rate': 48000,
      'engine_sample_rate': 48000,
      'clock': {
        'seconds': seconds,
        'callbacks': 2500,
        'frames': frames,
        'rendered_frames': frames + 32,
        'min_frames': 96,
        'max_frames': 1920,
        'late_callbacks': 3,
        'xruns': 2,
        'shed': 1,
        'restored': 1,
        'muted_now': 0,
      },
      'input': input
          ? {
              'running': true,
              'state': 'open',
              'sample_rate': 48000,
              'duplex_buffer_frames': 2463,
              'drift_ppm': 120,
              'pushed_frames': 240600,
              'seconds': 5.0,
              'fill_frames': 2470,
              'skipped_frames': 0,
              'underruns': 1,
              'xruns': -1,
            }
          : {'running': false, 'state': 'off'},
    };

void main() {
  test('the report gives each stream its real rate and the counters', () {
    final text = audioClockReport(AudioClockSample(status(), 2000000),
        previous: AudioClockSample(status(seconds: 9, frames: 432000), 1000000),
        devices: const AudioDeviceList(backend: 'AAudio', devices: [
          AudioDeviceInfo(name: 'Default Playback Device', isDefault: true, rates: [44100]),
          AudioDeviceInfo(name: 'Other', rates: [0]),
        ]));
    for (final line in [
      'Engine sample rate: 48000 Hz',
      'Output stream: 48000 Hz (AAudio, Default Playback Device)',
      'Output rate: 48000.0 frames/s over 10.0 s (last 1.0 s: 48000.0)',
      'Callbacks: 2500 · frames 96..1920 · rendered 480032 of 480000',
      'Late callbacks: 3 · xruns: 2',
      'Layers shed: 1 · restored: 1 · muted now: 0',
      'Input stream: 48000 Hz',
      'Input rate: 48120.0 frames/s over 5.0 s · drift 120 ppm',
      'Input fill: 2470 frames (starts at 2463) · skipped 0 · underruns 1 · xruns: not reported',
      'Native rates (AAudio):',
      '  Default Playback Device [default]: 44100 Hz',
      '  Other: not known',
    ]) {
      expect(text, contains(line));
    }
  });

  test('without a device, or from an engine without the clock, it says so', () {
    expect(audioClockReport(const AudioClockSample({}, 0)), 'Engine sample rate: not reported\nOutput: not running\nInput: off');
    final old = status(input: false)..remove('clock');
    expect(audioClockReport(AudioClockSample(old, 0)), contains('Output clock: not reported by this engine'));
  });

  testWidgets('the block reads the status every second and copies what it shows', (tester) async {
    var reads = 0;
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
        theme: Neon.theme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: AudioClockPanel(
          read: () {
            reads++;
            return status(seconds: 10.0 + reads, frames: 480000 + 48000 * reads);
          },
          clockUs: () => reads * 1000000,
          devices: () async => const AudioDeviceList(
              backend: 'AAudio', devices: [AudioDeviceInfo(name: 'Speaker', isDefault: true, rates: [48000])]),
        )))));
    await tester.pump();
    String text() => tester.widget<SelectableText>(find.byKey(const ValueKey('audio-clock-text'))).data!;
    expect(reads, 1);
    expect(text(), contains('Speaker [default]: 48000 Hz'));
    await tester.pump(const Duration(seconds: 1));
    expect(reads, 2);
    expect(text(), contains('Output rate: 48000.0 frames/s over 12.0 s (last 1.0 s: 48000.0)'));
    await tester.tap(find.byKey(const ValueKey('audio-clock-copy')));
    await tester.pump();
    expect(copied, text());
    await tester.pump(const Duration(seconds: 5));  // the snack bar's own timer
    await tester.pumpWidget(const SizedBox());  // disposed: the timer stops
    await tester.pump(const Duration(seconds: 2));
    expect(reads, lessThanOrEqualTo(8));
  });
}
