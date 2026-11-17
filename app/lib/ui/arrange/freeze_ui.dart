// Freeze and bounce on screen (1.0.5, #209): the render's progress with Cancel, "Unfreeze to edit?", the
// snowflake on a frozen track's header and its dimmed devices.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/freeze.dart';
import '../../model/project.dart';
import '../motion.dart';
import '../theme.dart';

/// Runs a freeze or bounce ([start]) under a dialog showing its progress, with Cancel; a failure says why in a
/// snack bar. Returns whether it was applied.
Future<bool> runTrackRender(BuildContext context, String title, TrackRenderJob Function() start) async {
  final job = start();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final progress = ValueNotifier<double>(0);
  final poll = Timer.periodic(const Duration(milliseconds: 100), (_) => progress.value = job.progress);
  final navigator = Navigator.of(context);
  var open = true;
  unawaited(job.done.whenComplete(() {
    if (open) navigator.pop();
  }));
  await showDialog<void>(context: context, barrierDismissible: false, builder: (context) => AlertDialog(
    key: const ValueKey('track-render-dialog'),
    title: Text(title),
    content: ValueListenableBuilder<double>(valueListenable: progress, builder: (context, v, _) => Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        LinearProgressIndicator(value: v > 0 ? v : null),
        const SizedBox(height: 8),
        Text('${(v * 100).round()} %', style: const TextStyle(fontSize: 12, color: Neon.dim)),
      ])),
    actions: [TextButton(key: const ValueKey('track-render-cancel'), onPressed: job.cancel, child: const Text('Cancel'))],
  ));
  open = false;
  poll.cancel();
  progress.dispose();
  final error = await job.done;
  if (error != null && error != 'cancelled') {
    messenger?.showSnackBar(SnackBar(content: Text('$title failed: $error')));
  }
  return error == null;
}

/// "Unfreeze to edit?" for frozen track [layer]: Unfreeze unfreezes it (one undo step) and returns true.
Future<bool> askUnfreeze(BuildContext context, AppState state, LayerDoc layer) async {
  final yes = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
    key: const ValueKey('unfreeze-prompt'),
    title: const Text('Unfreeze to edit?'),
    content: Text('${layer.name} is frozen: its instrument and effects play as audio. Unfreeze it to change its '
        'notes, devices or their automation.'),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
      TextButton(key: const ValueKey('unfreeze-prompt-yes'), onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Unfreeze')),
    ],
  ));
  if (yes != true) return false;
  state.unfreezeTrack(layer);
  return true;
}

/// Whether [layer] may be edited now: true when it isn't frozen, or the user chose to unfreeze it.
Future<bool> editableOrUnfreeze(BuildContext context, AppState state, LayerDoc layer) async =>
    !state.project.playsFrozen(layer) || await askUnfreeze(context, state, layer);

/// A frozen track's devices: dimmed (in and out through the motion tokens), and a tap on them asks to unfreeze
/// instead of reaching a knob.
class FrozenDevices extends StatelessWidget {
  const FrozenDevices({super.key, required this.state, required this.layer, required this.child});
  final AppState state;
  final LayerDoc layer;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final frozen = state.project.playsFrozen(layer);
    final d = EditMotion.of(context, EditMotionKind.lengths) ?? Duration.zero;
    return Stack(children: [
      AnimatedOpacity(key: ValueKey('frozen-dim-${layer.id}'), opacity: frozen ? 0.38 : 1, duration: d,
          curve: EditMotion.curve, child: IgnorePointer(ignoring: frozen, child: child)),
      if (frozen) Positioned.fill(child: GestureDetector(key: ValueKey('frozen-devices-${layer.id}'),
          behavior: HitTestBehavior.opaque, onTap: () => askUnfreeze(context, state, layer))),
    ]);
  }
}

/// The snowflake a frozen track's header shows (dimmer while its freeze no longer plays: the tempo changed).
class FrozenBadge extends StatelessWidget {
  const FrozenBadge({super.key, required this.state, required this.layer, this.size = 14});
  final AppState state;
  final LayerDoc layer;
  final double size;

  @override
  Widget build(BuildContext context) {
    final plays = state.project.playsFrozen(layer);
    return Tooltip(
      message: plays ? 'Frozen: its instrument and effects play as audio' : 'Frozen, but the tempo changed: it plays '
          'live until it is frozen again',
      child: Padding(padding: const EdgeInsets.only(right: 3),
        child: Icon(Icons.ac_unit, key: ValueKey('frozen-badge-${layer.id}'), size: size,
            color: plays ? Neon.blue : Neon.dim)));
  }
}
