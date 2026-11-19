// The Dynamics and Drive families' merged device pages (1.0.8) by device id, for effect_editors.dart.
import 'package:flutter/material.dart';

import '../../device_registry.dart';
import '../../kit/device_style.dart';
import '../effect_page.dart';
import 'bits_device.dart';
import 'compressor_device.dart';
import 'drive_device.dart';
import 'limiter_device.dart';
import 'transient_device.dart';

/// One page per merged device, whatever its variant (each page switches on the variant itself).
final Map<String, DeviceEditorEntry> dynDriveEditors = {
  'org.caw.compressor': _cards('comp', 'COMP', Icons.compress, DeviceFamily.dynamics, () => const CompressorDevice()),
  'org.caw.limiter': singlePage('limit', 'LIMIT', Icons.vertical_align_top, DeviceFamily.dynamics, () => const LimiterDevice()),
  'org.caw.transient': singlePage('transient', 'SHAPE', Icons.show_chart, DeviceFamily.dynamics, () => const TransientDevice()),
  'org.caw.drive': _cards('drive', 'DRIVE', Icons.whatshot_outlined, DeviceFamily.drive, () => const DriveDevice()),
  'org.caw.bits': singlePage('bits', 'BITS', Icons.grain, DeviceFamily.drive, () => const BitsDevice()),
};

/// A page that shows its variants as cards ([DeviceEditorEntry.ownsVariant]: the shell's Variant pill stays away).
DeviceEditorEntry _cards(String id, String label, IconData icon, DeviceFamily family, Widget Function() page) =>
    DeviceEditorEntry((_) => [DeviceSection(id, label, icon, (_) => page())], family: family, ownsVariant: true);
