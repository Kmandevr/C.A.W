// The EQ & Filter group's plugin UIs by component id: the merged EQ's and Filter's one page each (every old id of their variants), comb, resonator, formant and disperser.
import 'package:flutter/material.dart';

import '../../device_registry.dart';
import '../../kit/device_style.dart';
import '../effect_page.dart';
import '../eqfilter/eq_device.dart';
import '../eqfilter/filter_device.dart';
import 'comb_pages.dart';
import 'formant_pages.dart';

/// A merged device's one page: its section keyed by the variant, so a variant change builds the mode's page
/// afresh; the page has its own mode cards ([DeviceEditorEntry.ownsVariant]).
DeviceEditorEntry _merged(String id, String label, IconData icon, DeviceFamily family, Widget Function() page) =>
    DeviceEditorEntry((t) => [DeviceSection('$id-${t.info?.variantIndex ?? 0}', label, icon, (_) => page())],
        family: family, ownsVariant: true);

final _eq = _merged('eq', 'EQ', Icons.graphic_eq, DeviceFamily.eq, () => const EqDevicePage());
final _filter = _merged('filter', 'FILTER', Icons.filter_alt_outlined, DeviceFamily.filter, () => const FilterDevicePage());

/// Every editor of the group, by id (a merged variant is found by its old id: [MergedDevices.pageId]).
final Map<String, DeviceEditorEntry> filtersEditors = {
  'org.caw.eq': _eq, 'org.caw.geq': _eq, 'org.caw.eq.dj': _eq, 'org.caw.tilt': _eq, 'org.caw.eq.linear': _eq,
  'org.caw.eq.match': _eq,
  'org.caw.filter': _filter, 'org.caw.ladder': _filter, 'org.caw.nlfilter': _filter, 'org.caw.filter.wah': _filter,
  'org.caw.comb': singlePage('comb', 'COMB', Icons.view_week_outlined, DeviceFamily.filter, () => const CombFilterPage()),
  'org.caw.resonator': singlePage('resonator', 'RESONATOR', Icons.music_note_outlined, DeviceFamily.filter, () => const ResonatorPage()),
  'org.caw.formant': singlePage('formant', 'FORMANT', Icons.record_voice_over_outlined, DeviceFamily.filter, () => const FormantPage()),
  'org.caw.disperser': singlePage('disperser', 'DISPERSER', Icons.blur_linear, DeviceFamily.filter, () => const DisperserPage()),
};
