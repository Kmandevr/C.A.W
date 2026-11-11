// Arrange's mixer card (owner 2026-11-09): a glass card over the tracks with the master strip and narrow track strips;
// tap one to widen it.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../model/app_state.dart';
import '../../model/project.dart';
import '../glass.dart';
import '../keyboard/key_area.dart';
import '../../model/routing.dart' show SendDoc;
import '../../model/routing_edit.dart';
import 'channel_strip.dart';
import '../routing_view.dart';
import '../theme.dart';
import '../volume_fader.dart';
import 'track_color.dart';
import '../widgets.dart';

class MixerCard extends StatefulWidget {
  const MixerCard({super.key, required this.state, required this.onClose});
  final AppState state;
  final VoidCallback onClose;

  @override
  State<MixerCard> createState() => _MixerCardState();
}

class _MixerCardState extends State<MixerCard> {
  String? _wide;
  final _keys = FocusNode(debugLabel: 'mixer');

  // The keyboard's place (owner, 2026-11-11): the strip (0 the master, then the tracks) and its control.
  int _strip = 0, _row = 0;

  @override
  void initState() {
    super.initState();
    _keys.addListener(_refresh);
  }

  @override
  void dispose() {
    _keys.removeListener(_refresh);
    _keys.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  List<LayerDoc> get _layers => widget.state.project.layers.where((l) => !l.isFolder || l.busEnabled).toList();

  /// The selected strip's controls: the master has its level; a track its level, pan and each send.
  List<String> _rows(LayerDoc? l) => l == null ? const ['Level'] : ['Level', 'Pan', for (var i = 0; i < l.sends.length; i++) 'Send ${i + 1}'];

  static double _db(double gain) => gain <= 0 ? -61.0 : VolumeTaper.db(gain);
  static double _gain(double db) => db < -60 ? 0 : math.min(VolumeTaper.maxGain, math.pow(10, db / 20).toDouble());

  /// The value under the keyboard, as the tag on its strip shows it.
  String _value(LayerDoc? l, int row) {
    final s = widget.state;
    if (row == 0) return VolumeTaper.label(l?.volume ?? s.project.master);
    if (row == 1) {
      final pan = l!.pan;
      return pan.abs() < 0.005 ? 'C' : '${pan < 0 ? 'L' : 'R'}${(pan.abs() * 100).round()}';
    }
    return VolumeTaper.label(l!.sends[row - 2].level);
  }

  /// The mixer's keys: left and right pick a strip, up and down its control, + and - change it, Home resets it,
  /// M and S mute and solo.
  bool _key(String id, int count, String? arg) {
    final s = widget.state;
    final layers = _layers;
    _strip = _strip.clamp(0, layers.length);
    LayerDoc? layer() => _strip == 0 ? null : layers[_strip - 1];
    void pick(int strip) {
      _strip = strip.clamp(0, layers.length);
      final l = layer();
      _row = _row.clamp(0, _rows(l).length - 1);
      // The picked track's strip widens, so its pan and sends are there to see.
      setState(() => _wide = l?.id ?? _wide);
    }

    void change(double d) {
      final l = layer();
      if (_row == 0) {
        final now = l?.volume ?? s.project.master;
        final v = _gain(_db(now) + d);
        l == null ? s.setMaster(v) : s.mixLayer(l, volume: v);
      } else if (_row == 1) {
        s.mixLayer(l!, pan: (l.pan + d * 0.05).clamp(-1.0, 1.0).toDouble());
      } else {
        final i = _row - 2;
        s.setSendLevelLive(l!, i, _gain(_db(l.sends[i].level) + d));
        s.commitSend(l);
      }
      setState(() {});
    }

    switch (id) {
      case 'mixer.left':
        pick(_strip - count);
      case 'mixer.right':
        pick(_strip + count);
      case 'mixer.up' || 'mixer.down':
        final n = _rows(layer()).length;
        setState(() => _row = (_row + (id == 'mixer.up' ? -count : count)).clamp(0, n - 1));
      case 'mixer.inc':
        change(count.toDouble());
      case 'mixer.dec':
        change(-count.toDouble());
      case 'mixer.reset':
        final l = layer();
        if (_row == 0) {
          l == null ? s.setMaster(1) : s.mixLayer(l, volume: 1);
        } else if (_row == 1) {
          s.mixLayer(l!, pan: 0);
        } else {
          s.setSendLevelLive(l!, _row - 2, SendDoc.defaultLevel);
          s.commitSend(l);
        }
        setState(() {});
      case 'mixer.mute' || 'mixer.solo':
        final l = layer();
        if (l == null) return false;
        id == 'mixer.mute' ? s.mixLayer(l, mute: !l.mute) : s.mixLayer(l, solo: !l.solo);
        setState(() {});
      default:
        return false;
    }
    return true;
  }

  /// [child] (strip [index]) with the focus ring and its control's tag while the mixer has the keyboard.
  Widget _ring(int index, LayerDoc? l, Widget child) {
    if (!_keys.hasFocus || index != _strip) return child;
    final rows = _rows(l);
    final row = _row.clamp(0, rows.length - 1);
    return KeyRingBox(label: '${rows[row]} ${_value(l, row)}', child: child);
  }

  /// The full strip needs this much height; a shorter card scrolls up and down.
  static const _stripHeight = 440.0;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final layers = _layers;
    return GlassOverlay(
      key: const ValueKey('mixer-card'),
      radius: 14,
      child: KeyArea(area: Area.mixer, label: 'Mixer', focusNode: _keys, onAction: _key, child: Column(children: [
        SizedBox(height: 36, child: Row(children: [
          const SizedBox(width: 12),
          const Text('MIXER', style: TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.4, fontWeight: FontWeight.w800)),
          const Spacer(),
          IconButton(key: const ValueKey('mixer-card-routing'), tooltip: 'Routing', iconSize: 18,
            onPressed: () => showRoutingView(context, s), icon: const Icon(Icons.account_tree_outlined)),
          IconButton(tooltip: 'Close mixer', iconSize: 18, onPressed: widget.onClose, icon: const Icon(Icons.close)),
        ])),
        Expanded(child: LayoutBuilder(builder: (context, box) {
          final h = math.max(_stripHeight, box.maxHeight);
          return SingleChildScrollView(child: SizedBox(height: h, child: ListView(
                key: const ValueKey('mixer-card-strips'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                children: [
                  Padding(padding: const EdgeInsets.only(right: 6), child: _ring(0, null, MasterStrip(state: s))),
                  if (layers.isEmpty)
                    const SizedBox(width: 180, child: Center(child: Text('Add a track to mix it.',
                        style: TextStyle(color: Neon.dim)))),
                  for (final (i, l) in layers.indexed)
                    Padding(padding: const EdgeInsets.only(right: 4), child: _ring(i + 1, l, AnimatedSize(
                      duration: const Duration(milliseconds: 160),
                      child: _wide == l.id
                          ? ChannelStrip(key: ValueKey('wide-${l.id}'), state: s, layer: l,
                              index: s.project.layers.indexOf(l))
                          : _NarrowStrip(state: s, layer: l, index: s.project.layers.indexOf(l),
                              onTap: () => setState(() => _wide = l.id)),
                    ))),
                ],
              )));
        })),
      ])),
    );
  }
}

/// A narrow strip: the track's colour and name, a fader with its meter, M and S. Tap the name to widen it.
class _NarrowStrip extends StatelessWidget {
  const _NarrowStrip({required this.state, required this.layer, required this.index, required this.onTap});
  final AppState state;
  final LayerDoc layer;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tint = trackColor(state, layer);
    return SizedBox(width: 52, child: GlassPanel(tint: tint, radius: 8, child: ValueListenableBuilder<int>(
      valueListenable: state.layerValueTick(layer.id),
      builder: (context, _, _) => Column(children: [
        Semantics(button: true, label: 'Widen ${layer.name}', child: InkWell(
          key: ValueKey('narrow-${layer.id}'),
          onTap: onTap,
          child: Container(
            height: 40,
            decoration: BoxDecoration(border: Border(top: BorderSide(color: tint, width: 3))),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(layer.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700)),
          ),
        )),
        Expanded(child: Row(children: [
          Expanded(child: VolumeFader(value: layer.volume, color: tint, label: '${layer.name} level',
            onChanged: (v) => state.mixLayer(layer, volume: v))),
          SizedBox(width: layer.isStereo ? 9 : 6, child: TrackMeter(state: state, index: index, stereo: layer.isStereo,
            color: tint, vertical: true)),
          const SizedBox(width: 4),
        ])),
        Text(VolumeTaper.label(layer.volume), style: Neon.code(size: 9, color: Neon.dim)),
        const SizedBox(height: 2),
        ToggleChip(label: 'M', size: 34, on: layer.mute, color: Neon.yellow,
          tooltip: layer.mute ? 'Unmute ${layer.name}' : 'Mute ${layer.name}',
          onTap: () => state.mixLayer(layer, mute: !layer.mute)),
        const SizedBox(height: 3),
        ToggleChip(label: 'S', size: 34, on: layer.solo, color: Neon.blue,
          tooltip: layer.solo ? 'Unsolo ${layer.name}' : 'Solo ${layer.name}',
          onTap: () => state.mixLayer(layer, solo: !layer.solo)),
        const SizedBox(height: 6),
      ]),
    )));
  }
}
