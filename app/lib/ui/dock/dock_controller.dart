// Keeps the docking layout per screen shape, saves it in Settings, and lets any screen show a panel (reveal) or ask
// which panel was touched last (the keyboard's area).
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../model/settings.dart';
import 'layout.dart';

class DockController extends ChangeNotifier {
  /// Reads the saved layouts from [settings]; a missing or damaged one falls back to its preset.
  DockController(this.settings) {
    for (final f in FormFactor.values) {
      final saved = DockLayout.fromJson(settings.dockLayouts[f.name]);
      if (saved != null) _layouts[f] = saved;
    }
  }

  final Settings settings;
  final _layouts = <FormFactor, DockLayout>{};
  Timer? _saveTimer;

  /// How long after the last change the layouts are written, so a divider drag saves once.
  static const saveDelay = Duration(milliseconds: 600);

  /// The current screen shape. The shell sets it from its size on every layout, without a notification.
  FormFactor form = FormFactor.desktop;

  /// The layout for the current screen shape.
  DockLayout get layout => _layouts[form] ??= DockLayout.preset(form);

  /// The panel touched last; null until one is.
  String? get focused => _focused != null && layout.visible.contains(_focused) ? _focused : null;
  String? _focused;

  /// The panel whose keys apply: the one touched last, or the first on screen.
  String get keyPanel => focused ?? layout.visible.first;

  void set(DockLayout next) {
    if (identical(next, layout)) return;
    _layouts[form] = next;
    // Settings gets the change at once, so a controller made before this one is disposed (the shell remounts on a
    // theme change) reads it; only the write to disk waits.
    settings.dockLayouts = {...settings.dockLayouts, form.name: next.toJson()};
    notifyListeners();
    _saveSoon();
  }

  /// Shows [id]: in its group, or added to the main group.
  void reveal(String id) {
    _focused = id;
    set(layout.reveal(id));
  }

  /// Replaces the current shape's layout with [preset].
  void usePreset(DockPreset preset) => set(DockLayout.preset(form, preset));

  /// Records a touch on [id]'s panel.
  void touch(String id) {
    if (_focused == id) return;
    _focused = id;
    notifyListeners();
  }

  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, flush);
  }

  /// Writes the settings (with the layouts) to disk now.
  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    return settings.save();
  }

  @override
  void dispose() {
    if (_saveTimer != null) unawaited(flush());
    super.dispose();
  }

  /// The controller above [context]. Screens call `DockController.of(context).reveal(Panels.builder)`.
  static DockController of(BuildContext context) => maybeOf(context)!;

  static DockController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockScope>()?.notifier;
}

/// Puts a [DockController] in reach of the panels.
class DockScope extends InheritedNotifier<DockController> {
  const DockScope({super.key, required DockController controller, required super.child}) : super(notifier: controller);
}
