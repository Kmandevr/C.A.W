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
      final floats = settings.dockLayouts['${f.name}_floating'];
      if (floats is List) {
        _floating[f] = [
          for (final j in floats)
            if (FloatingPanel.fromJson(j) case final p? when !(_layouts[f]?.contains(p.id) ?? false)) p,
        ];
      }
    }
  }

  final _floating = <FormFactor, List<FloatingPanel>>{};

  /// The panels floating over the layout on this screen shape, front last.
  List<FloatingPanel> get floating => List.unmodifiable(_floating[form] ?? const []);

  bool isFloating(String id) => floating.any((p) => p.id == id);

  /// Takes [id] out of the layout into a floating window (the last docked panel stays docked).
  void float(String id) {
    if (isFloating(id) || !layout.contains(id) || layout.panels.length == 1) return;
    final list = _floating[form] ??= [];
    list.add(FloatingPanel(id, Rect.fromLTWH(0.3 + 0.03 * list.length, 0.2 + 0.03 * list.length, 0.4, 0.5)));
    _layouts[form] = layout.remove(id);
    _saveAll();
  }

  /// Docks a floating [id] back into the layout's main group.
  void unfloat(String id) {
    final list = _floating[form];
    if (list == null || !list.any((p) => p.id == id)) return;
    list.removeWhere((p) => p.id == id);
    _layouts[form] = layout.reveal(id);
    _saveAll();
  }

  /// Moves or resizes a floating window; [rect] is in fractions of the dock's area.
  void placeFloating(String id, Rect rect, {bool save = true}) {
    final list = _floating[form];
    final i = list?.indexWhere((p) => p.id == id) ?? -1;
    if (i < 0) return;
    list![i] = FloatingPanel(id, FloatingPanel.clampRect(rect));
    notifyListeners();
    if (save) _saveAll();
  }

  /// Brings a floating window to the front.
  void raise(String id) {
    final list = _floating[form];
    final i = list?.indexWhere((p) => p.id == id) ?? -1;
    if (i < 0 || i == list!.length - 1) return;
    list.add(list.removeAt(i));
    notifyListeners();
  }

  void _saveAll() {
    settings.dockLayouts = {
      ...settings.dockLayouts,
      form.name: layout.toJson(),
      '${form.name}_floating': [for (final p in floating) p.toJson()],
    };
    notifyListeners();
    _saveSoon();
  }

  final Settings settings;
  final _layouts = <FormFactor, DockLayout>{};
  Timer? _saveTimer;

  /// How long after the last change the layouts are written, so a divider drag saves once.
  static const saveDelay = Duration(milliseconds: 600);

  /// The current screen shape. The shell sets it from its size on every layout, without a notification.
  FormFactor form = FormFactor.desktop;

  /// The desktop frame on a small window (Settings › Layout › Desktop on a phone): until a layout is saved, every
  /// panel starts as a tab of one full-size group instead of side by side.
  bool narrow = false;

  /// The layout for the current screen shape.
  DockLayout get layout => _layouts[form] ??= form == FormFactor.desktop && narrow
      ? DockLayout(TabsNode([Panels.arrangement, for (final p in Panels.all) if (p != Panels.arrangement) p]))
      : DockLayout.preset(form);

  /// The panel touched last; null until one is.
  String? get focused =>
      _focused != null && (layout.visible.contains(_focused) || isFloating(_focused!)) ? _focused : null;
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
    if (isFloating(id)) return raise(id);
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

/// A panel in a floating window: its id and its place, in fractions of the dock's area.
class FloatingPanel {
  const FloatingPanel(this.id, this.rect);
  final String id;
  final Rect rect;

  /// Keeps a window at least a fifth of the area and its title bar on screen.
  static Rect clampRect(Rect r) {
    final w = r.width.clamp(0.2, 1.0), h = r.height.clamp(0.2, 1.0);
    return Rect.fromLTWH(r.left.clamp(-w + 0.1, 0.9), r.top.clamp(0.0, 0.92), w, h);
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'rect': [for (final v in [rect.left, rect.top, rect.width, rect.height]) double.parse(v.toStringAsFixed(4))],
      };

  static FloatingPanel? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], r = j['rect'];
    if (id is! String || !Panels.known(id) || r is! List || r.length != 4 || r.any((v) => v is! num)) return null;
    final v = [for (final x in r) (x as num).toDouble()];
    if (v.any((x) => !x.isFinite)) return null;
    return FloatingPanel(Panels.canonical(id)!, clampRect(Rect.fromLTWH(v[0], v[1], v[2], v[3])));
  }
}
