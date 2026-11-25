// The 1.1.3 instruments' editors by component id (Starling, Nightingale, Curlew, Bittern, Woodpecker), for the device registry.
import '../device_registry.dart';
import 'bittern_page.dart';
import 'curlew_page.dart';
import 'instrument_page.dart';
import 'nightingale_page.dart';
import 'starling_page.dart';
import 'woodpecker_page.dart';

/// Every 1.1.3 instrument's page.
final List<InstrumentSpec> instrumentSpecs = [starlingSpec, nightingaleSpec, curlewSpec, bitternSpec, woodpeckerSpec];

final Map<String, DeviceEditorEntry> instrumentEditors = {for (final s in instrumentSpecs) s.id: s.entry()};
