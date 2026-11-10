// Which editor a device opens with: a custom one by component id (or by parameter shape for built-in effects), else the fallback page.
import 'package:flutter/material.dart';

import '../../engine/component_info.dart';
import '../../model/arrange_fx.dart' show isBuiltinComponent;
import '../../model/device_target.dart';
import 'effects/effect_editors.dart';
import 'flagship/flagship_editor.dart';
import 'generic_device_page.dart';
import 'kit/device_style.dart';

/// One tab of a device editor.
class DeviceSection {
  const DeviceSection(this.id, this.label, this.icon, this.builder);
  final String id, label;
  final IconData icon;
  final WidgetBuilder builder;
}

/// A custom editor: its tabs, its family (its colours and badge) and an accent that overrides the family's (both
/// null: the track's colour).
class DeviceEditorEntry {
  const DeviceEditorEntry(this.sections, {this.accent, this.family});
  final List<DeviceSection> Function(DeviceTarget target) sections;
  final Color? accent;
  final DeviceFamily? family;
}

class DeviceEditors {
  DeviceEditors._();

  static final Map<String, DeviceEditorEntry> _byId = {
    flagshipComponentId: const DeviceEditorEntry(flagshipSections),
  };

  /// Editors chosen by a built-in effect's parameters (an EQ by its `bandN_` knobs, and so on), so the stock
  /// effects being defined on the engine side get theirs as soon as their ids exist.
  static final List<DeviceEditorEntry? Function(NativeComponentInfo info)> _matchers = [effectEditorFor];

  /// Adds or replaces the editor of component [id].
  static void register(String id, DeviceEditorEntry entry) => _byId[id] = entry;

  /// [id]'s custom editor, or null (the fallback page). Shape matching applies only to the engine's built-ins,
  /// never to a project's own C++ code.
  static DeviceEditorEntry? custom(String id, NativeComponentInfo? info) {
    final exact = _byId[id];
    if (exact != null || info == null || !(isBuiltinComponent(id) || info.builtin)) return exact;
    for (final m in _matchers) {
      if (m(info) case final e?) return e;
    }
    return null;
  }

  /// The fallback: one page of the generic knobs.
  static const DeviceEditorEntry fallback = DeviceEditorEntry(_fallbackSections);

  static List<DeviceSection> _fallbackSections(DeviceTarget target) =>
      [DeviceSection('controls', 'Controls', Icons.tune, (_) => const GenericDevicePage())];

  static DeviceEditorEntry of(String id, NativeComponentInfo? info) => custom(id, info) ?? fallback;
}
