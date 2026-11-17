// "Automate" on any automatable control's hold menu (#230): the one item every knob, fader and slider offers, which
// opens the parameter's lane under its track, armed and scrolled into view, with a point at the playhead.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/automation_edit.dart';
import '../../model/automation_writer.dart' show AutomationTarget;
import '../../model/device_target.dart';
import '../../model/mixer_fx.dart' show masterLayerId;
import '../haptics.dart';
import 'long_press_menu.dart';

/// A control's parameter as the arranger's lanes name it: [state] and its [target].
class ControlAutomation {
  const ControlAutomation(this.state, this.target);
  final AppState state;
  final AutomationTarget target;

  /// A device's parameter [paramId] ([t]: a track's instrument or one of its effects). Null where it can't have a lane
  /// under a track: the master's chain, a modulator, a parameter that isn't automatable.
  static ControlAutomation? of(DeviceTarget t, String paramId) {
    if (t.runtimeType != DeviceTarget || t.layerId == masterLayerId) return null;
    final p = t.param(paramId);
    if (p == null || !p.automatable) return null;
    return ControlAutomation(t.state, t.isInstrument
        ? AutomationTarget('instrument', paramId, layerId: t.layerId)
        : AutomationTarget('component', paramId, layerId: t.layerId, component: t.slot));
  }

  /// A track's volume or pan ([target]: `volume` or `pan`).
  static ControlAutomation track(AppState state, String layerId, String target) =>
      ControlAutomation(state, AutomationTarget('track', target, layerId: layerId));

  /// The menu entry.
  static const action = MenuAction<String>('automate', 'Automate', Icons.timeline, section: 'Automation');

  /// Opens (or reveals) the lane; says so when there is nothing to show.
  void automate(BuildContext context) {
    final key = state.automate(target);
    if (key == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(duration: Duration(seconds: 2),
          content: Text('This control has no lane under a track')));
      return;
    }
    Haptics.drop();
  }

  /// The control's hold (or right-click) menu, at [at]: Automate.
  Future<void> menu(BuildContext context, Offset at) async {
    final v = await showLongPressMenu<String>(context, at: at, style: state.settings.longPressMenu, actions: const [action]);
    if (v == 'automate' && context.mounted) automate(context);
  }
}

/// Wraps a control so a hold or a right-click opens its menu with Automate (a fader, a pan slider).
class AutomateHold extends StatelessWidget {
  const AutomateHold({super.key, required this.automation, required this.child});
  final ControlAutomation? automation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final a = automation;
    if (a == null) return child;
    return GestureDetector(
      onLongPressStart: (d) => a.menu(context, d.globalPosition),
      onSecondaryTapUp: (d) => a.menu(context, d.globalPosition),
      child: child);
  }
}

/// "Automate" in a device knob's hold sheet or value dialog, beside Learn MIDI CC: closes the sheet and opens the
/// lane. Nothing where the parameter can't have a lane.
class AutomateButton extends StatelessWidget {
  const AutomateButton({super.key, required this.target, required this.paramId, this.color});
  final DeviceTarget target;
  final String paramId;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final a = ControlAutomation.of(target, paramId);
    if (a == null) return const SizedBox.shrink();
    return TextButton.icon(
      key: const ValueKey('automate-param'),
      style: color == null ? null : TextButton.styleFrom(foregroundColor: color),
      onPressed: () {
        final messenger = ScaffoldMessenger.maybeOf(context);
        Navigator.of(context).maybePop();
        final key = a.state.automate(a.target);
        if (key == null) {
          messenger?.showSnackBar(const SnackBar(duration: Duration(seconds: 2),
              content: Text('This control has no lane under a track')));
        } else {
          Haptics.drop();
        }
      },
      icon: const Icon(Icons.timeline, size: 16),
      label: const Text('Automate'));
  }
}
