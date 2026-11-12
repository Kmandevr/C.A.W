// Files' select mode (owner, 2026-11-12): the checkbox that grows in beside each item, the bottom bar with "N selected",
// select all / none and the actions, and the Undo snackbar a delete leaves.
import 'package:flutter/material.dart';

import '../motion.dart';
import '../panel_motion.dart';
import '../presence.dart';
import '../theme.dart';
import '../tokens.dart';

/// The checkbox of an item in select mode: [checked] null (not selecting) folds it away, in and out through the
/// motion tokens (a fade alone with Reduced, at once with Off).
class SelectCheck extends StatelessWidget {
  const SelectCheck({super.key, required this.checked, this.size = 20});
  final bool? checked;
  final double size;

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    final on = checked;
    return AnimatedSize(
      duration: Motion.move(Motion.standard, level),
      curve: Curves.easeOutCubic,
      alignment: Alignment.centerLeft,
      child: AnimatedSwitcher(
        duration: Motion.fade(Motion.standard, level),
        child: on == null
            ? const SizedBox(key: ValueKey('no check'), height: 0)
            : Padding(
                key: const ValueKey('check'),
                padding: const EdgeInsets.only(right: Space.s),
                child: AnimatedContainer(
                  duration: Motion.fade(Motion.small, level),
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    color: on ? Neon.blue : Colors.transparent,
                    borderRadius: BorderRadius.circular(Radii.s),
                    border: Border.all(color: on ? Neon.blue : Neon.dim, width: 1.5),
                  ),
                  child: on ? Icon(Icons.check, size: size * 0.8, color: Neon.bg) : null,
                ),
              ),
      ),
    );
  }
}

/// One button of the bar.
class SelectionAction {
  const SelectionAction(this.key, this.icon, this.label, this.onPressed, {this.danger = false});
  final String key;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool danger;
}

/// The bar at the bottom while select mode is on: it slides up from below as select mode starts and back down as
/// it ends ([visible]).
class SelectionBar extends StatelessWidget {
  const SelectionBar({super.key, required this.visible, required this.count, required this.total, required this.onAll,
      required this.onNone, required this.actions});
  final bool visible;
  final int count, total;
  final VoidCallback onAll, onNone;
  final List<SelectionAction> actions;

  @override
  Widget build(BuildContext context) => Presence(
        from: const Offset(0, 1),
        child: visible ? _bar(context) : null,
      );

  Widget _bar(BuildContext context) {
    final all = total > 0 && count >= total;
    return Material(
      key: const ValueKey('selection-bar'),
      color: Neon.panelHi.withValues(alpha: 0.97),
      shape: Border(top: BorderSide(color: Neon.ink.withValues(alpha: 0.12))),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          child: Row(children: [
            const SizedBox(width: Space.m),
            Expanded(
              child: Text('$count selected', key: const ValueKey('selection-count'), maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: TypeScale.label, fontWeight: FontWeight.w600)),
            ),
            IconButton(
              key: const ValueKey('select-all'),
              tooltip: all ? 'Select none' : 'Select all',
              onPressed: total == 0 ? null : (all ? onNone : onAll),
              icon: Icon(all ? Icons.deselect : Icons.select_all, size: 20),
            ),
            for (final a in actions)
              IconButton(
                key: ValueKey('selection-${a.key}'),
                tooltip: a.label,
                onPressed: count == 0 ? null : a.onPressed,
                icon: Icon(a.icon, size: 20, color: count == 0 ? Neon.line : (a.danger ? Neon.pink : Neon.text)),
              ),
            const SizedBox(width: Space.xs),
          ]),
        ),
      ),
    );
  }
}

/// Asks once before deleting [count] items ([what]: "projects", "items"); says what Undo can bring back.
Future<bool> confirmDelete(BuildContext context, int count, String what, {String? detail}) async {
  final ok = await showDialog<bool>(
    context: context,
    animationStyle: dialogAnimation(context),
    builder: (context) => AlertDialog(
      title: Text('Delete $count $what?'),
      content: Text(detail ?? 'You can undo this from the message that follows.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('confirm-delete'),
          style: FilledButton.styleFrom(backgroundColor: Neon.pink),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Shows "[message]" with Undo for a few seconds: [onUndo] when Undo is pressed, else [onGone] once it closes.
void showUndoSnack(BuildContext context, String message, {required VoidCallback onUndo, required VoidCallback onGone}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) {
    onGone();
    return;
  }
  var undone = false;
  messenger.hideCurrentSnackBar();
  messenger
      .showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(label: 'Undo', onPressed: () {
          undone = true;
          onUndo();
        }),
      ))
      .closed
      .then((_) {
    if (!undone) onGone();
  });
}
