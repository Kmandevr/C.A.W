// The latency sheet (#236): an output offset slider with ±1 ms nudges to use while the song plays, saved for the
// routed output, opened from Record's long-press and the latency badge; plus the cards it shares with Settings ›
// Audio › Latency: Bluetooth's own delay and how to lower it, a correction learned from takes, a re-check.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/latency_comp.dart';
import '../../model/live_midi.dart';
import '../../model/settings.dart' show Metronome;
import '../../platform/audio_route.dart';
import '../glass.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';

String _ms(double v) => '${v.toStringAsFixed(v < 10 ? 1 : 0)} ms';

/// Opens the sheet over [context]; [settings] opens Settings › Audio › Latency (the type-in, tap-along and
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
  void dispose() {
    // The click goes back to what Settings and recording want (LiveMidi sets it while a take runs).
    if (_clicking && !(LiveMidi.current?.recording ?? false)) {
      s.engine?.setMetronome(s.settings.metronome == Metronome.always);
    }
    if (_dragging) unawaited(l.saveNow());
    super.dispose();
  }

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
          Text('${dev.label} · system ${_ms(l.platformOutputMs)} · saved for this output',
              maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Neon.dim, fontSize: 11)),
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
          const SizedBox(height: 6),
          Text(
              l.enabled
                  ? 'Play with the click, then slide until the playhead lands on each click as you hear it. '
                      'Higher moves the playhead and meters later.'
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

/// A compact card in the latency UI: an icon, a line or two and its buttons, in [color] on the glass.
class _Card extends StatelessWidget {
  const _Card({super.key, required this.icon, required this.color, required this.text, this.actions = const []});
  final IconData icon;
  final Color color;
  final String text;
  final List<Widget> actions;

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

/// Bluetooth adds a delay of its own: said plainly, with how to get the lowest and a way to the system's page.
class BluetoothLatencyCard extends StatelessWidget {
  const BluetoothLatencyCard({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final bt = BluetoothSettings.current;
    return _Card(
      key: const ValueKey('latency-bluetooth'),
      icon: Icons.bluetooth,
      color: Neon.blue,
      text: 'Bluetooth adds its own delay (about ${_ms(state.latency.outputTotalMs)} here), and no app can remove '
          'it: compensation only lines the screen up with it. For the lowest, turn on LE Audio, or your earbuds\' '
          'game or low-latency mode, where the phone or earbuds offer it. For playing live, wired or USB '
          'headphones are best.',
      actions: [
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
