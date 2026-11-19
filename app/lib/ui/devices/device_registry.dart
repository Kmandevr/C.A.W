// Which editor a device opens with: a custom one by component id (or by parameter shape for built-in effects), else the fallback page.
import 'package:flutter/material.dart';

import '../../engine/component_info.dart';
import '../../model/arrange_fx.dart' show isBuiltinComponent;
import '../../model/device_target.dart';
import '../../model/merged_devices.dart';
import 'drums/drums_editor.dart';
import 'effects/effect_editors.dart';
import 'flagship/flagship_editor.dart';
import 'flagship/flagship_inline.dart';
import 'flagship/flagship_presets.dart';
import 'flagship/flagship_tools.dart' show flagshipRandomKeeps, initFlagship;
import 'generic_device_page.dart';
import 'kit/device_style.dart';
import 'kit/presets.dart';
import 'sampler/sampler_editor.dart';

/// One tab of a device editor.
class DeviceSection {
  const DeviceSection(this.id, this.label, this.icon, this.builder, {this.showsSources = false, this.stripAtBottom = false});
  final String id, label;
  final IconData icon;
  final WidgetBuilder builder;

  /// The page shows the mod sources' own controls (a source opened from the strip goes there).
  final bool showsSources;

  /// The full editor pins the mod-source strip at the bottom of this page (under the page, above the footer) instead
  /// of above it, so it stays put while the page swipes.
  final bool stripAtBottom;
}

/// A custom editor: its tabs, its family (its colours and badge) and an accent that overrides the family's (both
/// null: the track's colour).
class DeviceEditorEntry {
  const DeviceEditorEntry(this.sections, {this.accent, this.family, this.presets = const [], this.inline, this.randomKeeps,
    this.reset, this.ownsVariant = false});
  final List<DeviceSection> Function(DeviceTarget target) sections;

  /// The parameters the header's ⋯ › Randomize leaves alone besides the usual ones (the device's own random patch
  /// keeps them too); null: none.
  final bool Function(String paramId)? randomKeeps;

  /// What the header's ⋯ › Reset does when the device has its own (Flagship: its Init); null: every knob to its
  /// default.
  final void Function(DeviceTarget target)? reset;

  /// What the FX stack shows of the device inline ([DeviceInline]); null: its first section, laid out compact.
  final WidgetBuilder? inline;
  final Color? accent;
  final DeviceFamily? family;

  /// The page picks a merged device's variant itself (its mode cards), so the shell's "Variant:" pill
  /// ([VariantBar]) is not shown.
  final bool ownsVariant;

  /// Presets written in Dart for the device (its preset browser lists them after Init and the engine's own).
  final List<DevicePreset> presets;
}

class DeviceEditors {
  DeviceEditors._();

  static final Map<String, DeviceEditorEntry> _byId = {
    flagshipComponentId: const DeviceEditorEntry(flagshipSections, family: DeviceFamily.synth, presets: flagshipStarterPresets,
        inline: flagshipInline, randomKeeps: flagshipRandomKeeps, reset: initFlagship),
    ...drumEditors,
    ...samplerEditors,
  };

  /// Editors chosen by a built-in effect's parameters (an EQ by its `bandN_` knobs, and so on), so the stock
  /// effects being defined on the engine side get theirs as soon as their ids exist.
  static final List<DeviceEditorEntry? Function(NativeComponentInfo info)> _matchers = [effectEditorFor];

  /// Adds or replaces the editor of component [id].
  static void register(String id, DeviceEditorEntry entry) => _byId[id] = entry;

  /// [id]'s custom editor, or null (the fallback page). Shape matching applies only to the engine's built-ins,
  /// never to a project's own C++ code.
  static DeviceEditorEntry? custom(String id, NativeComponentInfo? info) {
    // A merged device (FX consolidation) opens its variant's old effect's page for now (the new device UI is a
    // later part): the page of the old id that variant was.
    if (info != null && MergedDevices.isMerged(id)) id = MergedDevices.pageId(id, info.variantIndex);
    if (MergedDevices.pagesToCome.contains(id)) return null;  // a 1.1.0 mode without a page yet: the fallback
    final exact = _byId[id];
    if (exact != null || info == null) return exact;
    if (isBuiltinComponent(id) || info.builtin) {
      for (final m in _matchers) {
        if (m(info) case final e?) return e;
      }
    }
    // A component that declares UI controls (#10) gets them as its editor, inline in the FX stack too.
    return info.uiControls.isNotEmpty ? generated : null;
  }

  /// The editor generated from a component's declared UI controls ([GeneratedControls]).
  static const DeviceEditorEntry generated = DeviceEditorEntry(_fallbackSections);

  /// The fallback: one page of the generic knobs.
  static const DeviceEditorEntry fallback = DeviceEditorEntry(_fallbackSections);

  static List<DeviceSection> _fallbackSections(DeviceTarget target) =>
      [DeviceSection('controls', 'Controls', Icons.tune, (_) => const GenericDevicePage())];

  static DeviceEditorEntry of(String id, NativeComponentInfo? info) => custom(id, info) ?? fallback;
}
