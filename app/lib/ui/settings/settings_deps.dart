// What Settings' pages read besides the settings: the app (engine, device, storage), the hardware profile and keys.
import 'package:flutter/widgets.dart';

import '../../engine/execution.dart';
import '../../model/app_state.dart';
import '../../model/settings.dart';

/// Handed to every section page. [state] is null where Settings opens without the app (goldens, tests).
class SettingsDeps {
  const SettingsDeps({required this.settings, this.state, this.engineProfile, this.executionPlan, this.onEditKeys});
  final Settings settings;
  final AppState? state;
  final EngineHardwareProfile? engineProfile;
  final EngineExecutionPlan? executionPlan;

  /// Opens the key bindings editor; null hides its row (no key router above).
  final Future<void> Function(BuildContext context)? onEditKeys;
}
