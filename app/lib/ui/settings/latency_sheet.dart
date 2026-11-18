// The latency sheet (#236): an output offset slider with ±1 ms nudges, saved for the routed output, opened from
// Record's long-press and the latency badge, with a visual beat to line up with the click (#241: the song's metronome,
// or stopped a click loop of its own); plus the cards it shares with Settings › Sound › Latency and Bluetooth: Bluetooth's own
// delay, how to lower it and its best quality, a correction learned from takes, a re-check.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';

import '../../model/app_state.dart';
import '../../model/latency_beat.dart';
import '../../model/latency_comp.dart';
import '../../model/sample_use.dart';
import '../../model/live_midi.dart';
import '../../model/settings.dart' show Metronome;
import '../../platform/audio_route.dart';
import '../glass.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';

String _ms(double v) => '${v.toStringAsFixed(v < 10 ? 1 : 0)} ms';

/// The routed output's total, part by part (#241), so each delay shows once: what the system reports and how it
/// knows (its timestamps already hold the buffer; "buffers" is the queued buffers alone, an estimate), the device's
/// buffer, and the offset on top with where it came from.
String latencyBreakdown(AppState s) {
  final l = s.latency;
  final st = s.audioStatus;
  final off = l.outputOffset;
  final how = switch (l.platformOutputSource) {
    'timestamp' => 'timestamps, buffer included',
    'buffers' => 'buffers only, an estimate',
    _ => 'not running',
  };
  final buffer = st == null || !st.running || st.periodFrames <= 0 ? null
      : 'buffer ${st.periodFrames}${st.periods > 1 ? ' × ${st.periods}' : ''} frames (${_ms(st.bufferMs)})';
  final source = switch (off.source) {
    OffsetSource.preset => 'preset',
    OffsetSource.typed => 'typed',
    OffsetSource.slider => 'slider',
    OffsetSource.tapped => 'tapped',
    OffsetSource.loopback => 'loopback',
    OffsetSource.learned => 'learned',
  };
  final sign = off.extraMs < 0 ? '−' : '+';
  return 'system ${_ms(l.platformOutputMs)} ($how) · ${buffer == null ? '' : '$buffer · '}'
      'offset $sign${_ms(off.extraMs.abs())} ($source)';
}

/// Opens the sheet over [context]; [settings] opens Settings › Sound › Latency and Bluetooth (the type-in, tap-along and
/// loopback live there).
Future<void> showLatencySheet(BuildContext context, AppState state, {VoidCallback? settings}) => showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: LatencySheet(state: state, settings: settings),
      ),
    );

/// The slider's top end for a total of [ms]: room to double it, at least 150 ms, in 50 ms steps (fixed while the
/// sheet is open, so the thumb doesn't jump under the finger).
double latencySliderMax(double ms) => math.min(maxOffsetMs, (math.max(150.0, ms * 2) / 50).ceil() * 50.0);

class LatencySheet extends StatefulWidget {
  const LatencySheet({super.key, required this.state, this.settings});
  final AppState state;
  final VoidCallback? settings;

  @override
  State<LatencySheet> createState() => _LatencySheetState();
}

class _LatencySheetState extends State<LatencySheet> {
  late double _max = latencySliderMax(l.outputTotalMs);
  bool _clicking = false;

  AppState get s => widget.state;
  LatencyComp get l => s.latency;

  @override
  void initState() {
    super.initState();
    s.addListener(_transportMoved);
  }

  @override
  void dispose() {
    s.removeListener(_transportMoved);
    // The click goes back to what Settings and recording want (LiveMidi sets it while a take runs).
    if (_clicking && !(LiveMidi.current?.recording ?? false)) {
      s.engine?.setMetronome(s.settings.metronome == Metronome.always);
    }
    _stopLoop();
    if (_dragging) unawaited(l.saveNow());
    super.dispose();
  }

  // Stopped, the click is a loop of its own on the preview voice (no song needed); playing, the song's metronome.
  bool _looping = false;
  final LoopBeat _loop = LoopBeat();
  static String? _loopPath;

  /// Writes the one-beat click file once (the app's cache, else the system's temporary folder).
  static Future<String> _clickFile() async {
    if (_loopPath case final p?) return p;
    Directory dir;
    try {
      dir = await getTemporaryDirectory();
    } catch (_) {
      dir = Directory.systemTemp;
    }
    final f = File('${dir.path}/caw-latency-click.wav');
    await f.writeAsBytes(clickLoopWav(), flush: true);
    return _loopPath = f.path;
  }

  Future<void> _startLoop() async {
    if (_looping) return;
    final error = s.openAudioForPreview();
    if (error != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    _looping = true;
    s.samplePreviewing = true;
    try {
      final path = await _clickFile();
      if (!_looping || !mounted) return;
      await s.samplePreview.play(path, loop: true, volume: s.settings.clickVolume.clamp(0.2, 1.0).toDouble());
    } catch (_) {
      _stopLoop();
    }
    if (!_looping) s.samplePreview.stop(); // closed or switched off meanwhile
  }

  void _stopLoop() {
    if (!_looping) return;
    _looping = false;
    s.samplePreviewing = false;
    s.samplePreview.stop();
  }

  // Play or Pause while the click is on: the song's metronome takes over from the loop, and back.
  void _transportMoved() {
    if (!_clicking) return;
    if (s.transportOn) {
      _stopLoop();
    } else if (!_looping) {
      unawaited(_startLoop());
    }
  }

  /// The beat's phase this frame, 0 on a heard click: the song's metronome while it plays, else the loop's; null
  /// with nothing clicking.
  double? _beatPhase() {
    if (!_clicking) return null;
    if (s.meters.playing && s.meters.loopLength > 0) {
      return songBeatPhase(s.smoothPlayheadStep, s.project.timeSignatures);
    }
    if (!_looping) return null;
    final now = s.nowUs;
    if (now - _loopReadUs >= 30000) {
      _loopReadUs = now;
      final st = s.samplePreview.state();
      _loop.read(seconds: st.seconds, length: st.length, atUs: now, playing: st.playing && !st.waiting);
    }
    if (!_loop.running) return null;
    return _loop.phase(nowUs: s.drawUs, leadUs: s.visualLeadUs, outputLatencyUs: s.outputLatencyUs);
  }

  int _loopReadUs = -1 << 40;

  bool _dragging = false;

  void _set(double v) {
    final ms = v.roundToDouble();
    if (ms == l.outputTotalMs.roundToDouble()) return;
    if ((ms / 10).floor() != (l.outputTotalMs / 10).floor()) Haptics.tick(); // a tick each 10 ms
    l.setOutputTotalMs(ms, source: OffsetSource.slider, save: false);
  }

  void _nudge(double by) {
    Haptics.tick();
    l.nudgeOutput(by);
    if (l.outputTotalMs > _max) setState(() => _max = latencySliderMax(l.outputTotalMs));
  }

  void _click(bool on) {
    Haptics.tap();
    s.engine?.setMetronome(on || s.settings.metronome == Metronome.always);
    setState(() => _clicking = on);
    if (on && !s.transportOn) unawaited(_startLoop());
    if (!on) _stopLoop();
  }

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([l, s]),
      builder: (context, _) {
        final total = l.outputTotalMs;
        final dev = l.routeInfo.output;
        final late = total > 50;
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), children: [
          Row(children: [
            Icon(dev.kind.isBluetooth ? Icons.bluetooth_audio : Icons.speaker_outlined,
                color: late ? Neon.yellow : Neon.blue, size: 20),
            const SizedBox(width: 8),
            const Expanded(child: Text('Output latency', style: TextStyle(fontWeight: FontWeight.w700))),
            AnimatedSwitcher(
              duration: Motion.fade(Motion.small, level),
              child: Text(_ms(total), key: ValueKey(total.round()),
                  style: Neon.code(size: 20, color: late ? Neon.yellow : Neon.text)),
            ),
          ]),
          Text('${dev.label} · ${latencyBreakdown(s)}', key: const ValueKey('latency-breakdown'),
              maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Neon.dim, fontSize: 11)),
          const SizedBox(height: 4),
          Row(children: [
            IconButton.outlined(key: const ValueKey('latency-nudge-down'), tooltip: '−1 ms',
                onPressed: total <= 0 ? null : () => _nudge(-1), icon: const Icon(Icons.remove)),
            Expanded(child: Slider(
              key: const ValueKey('latency-slider'),
              value: total.clamp(0, _max).toDouble(),
              max: _max,
              label: _ms(total),
              onChangeStart: (_) {
                _dragging = true;
                Haptics.grab();
              },
              onChanged: _set,
              onChangeEnd: (_) {
                _dragging = false;
                Haptics.drop();
                unawaited(l.saveNow());
              },
            )),
            IconButton.outlined(key: const ValueKey('latency-nudge-up'), tooltip: '+1 ms',
                onPressed: total >= maxOffsetMs ? null : () => _nudge(1), icon: const Icon(Icons.add)),
          ]),
          Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            FilledButton.tonalIcon(
              key: const ValueKey('latency-sheet-play'),
              onPressed: s.engine == null ? null : () {
                Haptics.tap();
                s.togglePlay();
              },
              icon: AnimatedSwitcher(duration: Motion.fade(Motion.small, level),
                  child: Icon(s.transportOn ? Icons.pause : Icons.play_arrow, key: ValueKey(s.transportOn))),
              label: Text(s.transportOn ? 'Pause' : 'Play'),
            ),
            FilterChip(
              key: const ValueKey('latency-sheet-click'),
              avatar: const Icon(Icons.av_timer, size: 16),
              label: const Text('Click'),
              selected: _clicking,
              onSelected: s.engine == null ? null : _click,
            ),
          ]),
          // The visual beat (#241): a dot runs to the line and flashes it at each click, drawn when the app
          // believes that click is heard, exactly as the playhead is.
          Padding(padding: const EdgeInsets.only(top: 6), child: LatencyBeatView(active: _clicking, phase: _beatPhase)),
          const SizedBox(height: 6),
          Text(
              l.enabled
                  ? 'Turn on the click (the song needn\'t play), then slide until the flash lands on each click as '
                      'you hear it. Higher moves the flash, the playhead and the meters later.'
                  : 'Compensation is off, so the playhead shows what was just rendered: turn it on to use this.',
              style: const TextStyle(color: Neon.dim, fontSize: 11)),
          if (!l.enabled)
            Align(alignment: Alignment.centerLeft, child: TextButton(
                key: const ValueKey('latency-sheet-enable'), onPressed: () => l.enabled = true,
                child: const Text('Turn compensation on'))),
          LatencyCards(state: s, onChanged: () {
            if (l.outputTotalMs > _max) setState(() => _max = latencySliderMax(l.outputTotalMs));
          }),
          if (widget.settings != null)
            Align(alignment: Alignment.centerRight, child: TextButton.icon(
              key: const ValueKey('latency-sheet-settings'),
              onPressed: () {
                Navigator.of(context).pop();
                widget.settings!();
              },
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('Type in, tap along or measure'),
            )),
        ]);
      },
    );
  }
}

/// The latency sheet's visual beat: a dot that runs along a track to a line at its right end, reaching it as a
/// click is heard, and the line flashing then. [phase] gives where the beat is this frame (0 on a click; null: no
/// click, the track rests dim). Its own layer, drawn on every frame while a click runs.
class LatencyBeatView extends StatefulWidget {
  const LatencyBeatView({super.key, required this.active, required this.phase});

  /// A click runs: the ticker draws every frame (off, it asks for none).
  final bool active;
  final double? Function() phase;

  @override
  State<LatencyBeatView> createState() => _LatencyBeatViewState();
}

class _LatencyBeatViewState extends State<LatencyBeatView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _beat.value = widget.phase());
  final ValueNotifier<double?> _beat = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(LatencyBeatView old) {
    super.didUpdateWidget(old);
    _follow();
  }

  void _follow() {
    if (widget.active && !_ticker.isActive) unawaited(_ticker.start());
    if (!widget.active && _ticker.isActive) {
      _ticker.stop();
      _beat.value = null;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(child: SizedBox(
        key: const ValueKey('latency-beat'),
        height: 28,
        width: double.infinity,
        child: CustomPaint(painter: _BeatPainter(_beat, Neon.blue, Neon.yellow, Neon.line)),
      ));
}

class _BeatPainter extends CustomPainter {
  _BeatPainter(this.beat, this.color, this.flash, this.track) : super(repaint: beat);
  final ValueNotifier<double?> beat;
  final Color color, flash, track;

  @override
  void paint(Canvas canvas, Size size) {
    final p = beat.value;
    final cy = size.height / 2, end = size.width - 10;
    canvas.drawLine(Offset(8, cy), Offset(end, cy), Paint()..color = track..strokeWidth = 2);
    // The flash fades over a fifth of the beat after the click.
    final hit = p == null ? 0.0 : math.max(0.0, 1 - p * 5);
    canvas.drawLine(Offset(end, 2), Offset(end, size.height - 2), Paint()
      ..color = Color.lerp(track, flash, hit)!
      ..strokeWidth = 3 + 3 * hit);
    if (hit > 0) {
      canvas.drawCircle(Offset(end, cy), 6 + 8 * hit, Paint()..color = flash.withValues(alpha: 0.35 * hit));
    }
    if (p == null) return;
    canvas.drawCircle(Offset(8 + (end - 8) * p, cy), 6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _BeatPainter old) => old.color != color || old.flash != flash || old.track != track;
}

/// A compact card in the latency UI: an icon, a line or two and its buttons, in [color] on the glass.
class _Card extends StatelessWidget {
  const _Card({super.key, required this.icon, required this.color, required this.text, this.actions = const [],
      this.extra});
  final IconData icon;
  final Color color;
  final String text;
  final List<Widget> actions;

  /// More under the text (a section the card opens).
  final Widget? extra;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(Radii.m),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: color)),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
          ]),
          ?extra,
          if (actions.isNotEmpty) Wrap(alignment: WrapAlignment.end, spacing: 4, children: actions),
          if (actions.isEmpty) const SizedBox(height: 4),
        ]),
      );
}

/// The cards the sheet and the Latency page share, each fading in and out with what it reports: a learned
/// correction to accept or dismiss, a saved offset to re-check after the platform's figure moved, and on Bluetooth
/// what it adds and how to lower it.
class LatencyCards extends StatelessWidget {
  const LatencyCards({super.key, required this.state, this.onChanged});
  final AppState state;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state.latency,
        builder: (context, _) {
          final l = state.latency;
          final sug = l.outputSuggestion;
          final duration = Motion.move(Motion.panel, Motion.of(context));
          return AnimatedSize(
            duration: duration,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: Motion.fade(Motion.standard, Motion.of(context)),
              child: Column(
                key: ValueKey((sug?.totalMs, l.outputNeedsCheck, l.outputIsBluetooth)),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (sug != null)
                    _Card(
                      key: const ValueKey('latency-suggestion'),
                      icon: Icons.auto_graph,
                      color: Neon.green,
                      text: 'Your last ${sug.takes} takes (${sug.onsets} notes) landed about '
                          '${sug.shiftMs.abs().round()} ms ${sug.shiftMs > 0 ? 'late' : 'early'} on the beat. Set the '
                          'output latency to ${_ms(sug.totalMs)} (now ${_ms(sug.fromMs)})?',
                      actions: [
                        TextButton(key: const ValueKey('latency-suggestion-dismiss'),
                            onPressed: () {
                              Haptics.tap();
                              l.dismissSuggestion();
                            },
                            child: const Text('Not now')),
                        FilledButton.tonal(key: const ValueKey('latency-suggestion-apply'),
                            onPressed: () {
                              Haptics.drop();
                              l.acceptSuggestion();
                              onChanged?.call();
                            },
                            child: const Text('Apply')),
                      ],
                    ),
                  if (l.outputNeedsCheck)
                    _Card(
                      key: const ValueKey('latency-recheck'),
                      icon: Icons.update,
                      color: Neon.yellow,
                      text: 'The system now reports ${_ms(l.platformOutputMs)} for ${l.routeInfo.output.label}, '
                          '${_ms((l.platformOutputMs - (l.store.outputs[l.routeInfo.output.key]?.platformMs ?? 0)).abs())} '
                          'from when its offset was set: check it with the slider while playing.',
                    ),
                  if (l.outputIsBluetooth) BluetoothLatencyCard(state: state),
                ],
              ),
            ),
          );
        },
      );
}

/// Bluetooth adds a delay of its own: said plainly, with how to get the lowest and a way to the system's page; and,
/// opened from it, how to get the best quality (owner, 2026-11-18): the phone and the headphones choose a codec
/// together and the codec sets the rate; no app can choose either (**[Fact]** `BluetoothA2dp.setCodecConfigPreference`
/// is a privileged system API; Android's preferred mixer attributes are USB only, source.android.com, read
/// 2026-11-18), so the card names the user's own switches and opens Developer options for them.
class BluetoothLatencyCard extends StatefulWidget {
  const BluetoothLatencyCard({super.key, required this.state});
  final AppState state;

  @override
  State<BluetoothLatencyCard> createState() => _BluetoothLatencyCardState();
}

class _BluetoothLatencyCardState extends State<BluetoothLatencyCard> {
  bool _quality = false;

  Future<void> _developer() async {
    Haptics.tap();
    final bt = BluetoothSettings.current;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final r = await bt.openDeveloperOptions();
    if (r == DeveloperOptions.opened) return;
    if (r == DeveloperOptions.off) {
      messenger?.showSnackBar(const SnackBar(duration: Duration(seconds: 8), content: Text(
          'Developer options are off. To turn them on: Settings › About phone › Software information, then tap '
          'Build number seven times. The Bluetooth settings are open meanwhile.')));
    } else {
      messenger?.showSnackBar(const SnackBar(content: Text('Couldn\'t open Developer options')));
    }
    await bt.open();
  }

  @override
  Widget build(BuildContext context) {
    final bt = BluetoothSettings.current;
    final level = Motion.of(context);
    return _Card(
      key: const ValueKey('latency-bluetooth'),
      icon: Icons.bluetooth,
      color: Neon.blue,
      text: 'Bluetooth adds its own delay (about ${_ms(widget.state.latency.outputTotalMs)} here), and no app can remove '
          'it: compensation only lines the screen up with it. For the lowest, turn on LE Audio, or your earbuds\' '
          'game or low-latency mode, where the phone or earbuds offer it. For playing live, wired or USB '
          'headphones are best.',
      extra: AnimatedSize(
        duration: Motion.move(Motion.panel, level),
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: Motion.fade(Motion.standard, level),
          child: !_quality ? const SizedBox(width: double.infinity) : Padding(
            key: const ValueKey('latency-bluetooth-quality'),
            padding: const EdgeInsets.only(left: 24, top: 6),
            child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Get the best Bluetooth quality', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              SizedBox(height: 2),
              Text('The phone and the headphones pick a codec together, and the codec sets the sample rate '
                  '(often 44.1 kHz). No app can change it; you can:\n'
                  '1. In Developer options › Bluetooth audio codec, pick the best one both support (LDAC or '
                  'Samsung Scalable, where listed), then Bluetooth audio sample rate, if it is not locked.\n'
                  '2. In your headphones\' own app, turn on a quality mode if it has one.\n'
                  'Which rates you can reach depends on the codec the two share. C.A.W plays at whatever rate the '
                  'link ends up at.',
                  style: TextStyle(fontSize: 11, color: Neon.dim)),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('latency-bluetooth-quality-toggle'),
          onPressed: () {
            Haptics.tap();
            setState(() => _quality = !_quality);
          },
          child: Text(_quality ? 'Less' : 'Best quality'),
        ),
        if (bt.canOpen && _quality)
          TextButton.icon(
            key: const ValueKey('latency-bluetooth-developer'),
            onPressed: _developer,
            icon: const Icon(Icons.developer_mode, size: 16),
            label: const Text('Open Developer options'),
          ),
        if (bt.canOpen)
          TextButton.icon(
            key: const ValueKey('latency-bluetooth-settings'),
            onPressed: () async {
              Haptics.tap();
              final messenger = ScaffoldMessenger.maybeOf(context);
              if (!await bt.open()) {
                messenger?.showSnackBar(const SnackBar(content: Text('Couldn\'t open the Bluetooth settings')));
              }
            },
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Bluetooth settings'),
          ),
      ],
    );
  }
}
