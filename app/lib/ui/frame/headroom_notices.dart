// The headroom notices under the shell's banner (1.1.0): smart freeze's one-time suggestion (freeze the heaviest track, only on a tap) and a warn-only heat line on serious thermal status; neither changes a setting.
import 'package:flutter/material.dart';

import '../../engine/execution.dart';
import '../../model/app_state.dart';
import '../../model/freeze.dart';
import '../../model/freeze_hint.dart';
import '../../model/routing_edit.dart';
import '../arrange/freeze_ui.dart';
import '../motion.dart';
import '../theme.dart';

/// Whether [p] is serious thermal status (Android's THERMAL_STATUS_SEVERE or worse).
bool seriousHeat(EnginePressure p) => p == EnginePressure.thermalHot || p == EnginePressure.thermalCritical;

/// The freeze suggestion and the heat warning, each one line that slides in and out; nothing while neither applies.
class HeadroomNotices extends StatefulWidget {
  const HeadroomNotices({super.key, required this.state});
  final AppState state;

  /// The heat line's text.
  static const heatText = 'The phone is getting hot, so audio may stutter. Freezing tracks or a larger buffer helps.';

  @override
  State<HeadroomNotices> createState() => _HeadroomNoticesState();
}

class _HeadroomNoticesState extends State<HeadroomNotices> {
  // The heat line, once closed, stays closed until the phone cools and heats up again.
  bool _heatClosed = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final motion = Motion.of(context);
    return AnimatedSize(
      duration: Motion.move(Motion.standard, motion),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: ValueListenableBuilder<EnginePressure>(valueListenable: s.pressure, builder: (context, p, _) {
        if (!seriousHeat(p)) _heatClosed = false;
        return ValueListenableBuilder<FreezeSuggestion?>(valueListenable: s.freezeHint.suggestion,
          builder: (context, f, _) => AnimatedSwitcher(
            duration: Motion.fade(Motion.standard, motion),
            child: Column(key: ValueKey((f?.layerId, seriousHeat(p) && !_heatClosed)), mainAxisSize: MainAxisSize.min, children: [
              if (f != null) _freezeLine(context, f),
              if (seriousHeat(p) && !_heatClosed) _line(
                key: const ValueKey('heat-banner'),
                color: Neon.yellow,
                icon: Icons.device_thermostat,
                text: HeadroomNotices.heatText,
                actions: [_close(const ValueKey('heat-close'), () => setState(() => _heatClosed = true))],
              ),
            ]),
          ));
      }),
    );
  }

  Widget _freezeLine(BuildContext context, FreezeSuggestion f) {
    final s = widget.state;
    final share = f.share;
    final cost = share == null ? '' : ' (${(share * 100).toStringAsFixed(share < 0.1 ? 1 : 0)}% of a core)';
    return _line(
      key: const ValueKey('freeze-suggestion'),
      color: Neon.blue,
      icon: Icons.ac_unit,
      text: 'Near the phone\'s limit. ${f.name} is the heaviest track$cost: freeze it to free the CPU?',
      actions: [
        TextButton(key: const ValueKey('freeze-suggestion-freeze'), onPressed: () async {
          s.freezeHint.dismiss();
          final layer = s.layerById(f.layerId);
          if (layer == null || layer.frozen || !s.canRenderTrack(layer)) return;
          await runTrackRender(context, 'Freeze ${layer.name}', () => s.freezeTrack(layer));
        }, child: const Text('Freeze')),
        _close(const ValueKey('freeze-suggestion-close'), s.freezeHint.dismiss),
      ],
    );
  }

  Widget _close(Key key, VoidCallback onTap) => IconButton(key: key, tooltip: 'Dismiss', iconSize: 18,
      visualDensity: VisualDensity.compact, color: Neon.dim, onPressed: onTap, icon: const Icon(Icons.close));

  Widget _line({required Key key, required Color color, required IconData icon, required String text,
          required List<Widget> actions}) =>
      Container(
        key: key,
        width: double.infinity,
        color: color.withValues(alpha: 0.15),
        padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
        child: Row(children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: color))),
          ...actions,
        ]),
      );
}
