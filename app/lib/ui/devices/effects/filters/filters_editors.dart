// The EQ & Filter group's plugin UIs by component id, and the decoding of their display floats (docs/engine.md, "Display data").
import 'package:flutter/material.dart';

import '../../device_registry.dart';
import '../../kit/device_style.dart';
import '../effect_page.dart';
import 'comb_pages.dart';
import 'eq_pages.dart';
import 'filter_pages.dart';
import 'formant_pages.dart';

/// Every editor of the group, by id.
final Map<String, DeviceEditorEntry> filtersEditors = {
  'org.caw.ladder': singlePage('ladder', 'LADDER', Icons.stairs_outlined, DeviceFamily.filter, () => const LadderPage()),
  'org.caw.nlfilter': singlePage('nlfilter', 'NONLINEAR', Icons.waves_outlined, DeviceFamily.filter, () => const NonlinearPage()),
  'org.caw.comb': singlePage('comb', 'COMB', Icons.view_week_outlined, DeviceFamily.filter, () => const CombFilterPage()),
  'org.caw.resonator': singlePage('resonator', 'RESONATOR', Icons.music_note_outlined, DeviceFamily.filter, () => const ResonatorPage()),
  'org.caw.formant': singlePage('formant', 'FORMANT', Icons.record_voice_over_outlined, DeviceFamily.filter, () => const FormantPage()),
  'org.caw.disperser': singlePage('disperser', 'DISPERSER', Icons.blur_linear, DeviceFamily.filter, () => const DisperserPage()),
  'org.caw.eq.dj': singlePage('eq.dj', '3-BAND', Icons.tune, DeviceFamily.eq, () => const Eq3Page()),
  'org.caw.tilt': singlePage('tilt', 'TILT', Icons.trending_up, DeviceFamily.eq, () => const TiltPage()),
  'org.caw.geq': singlePage('geq', 'GRAPHIC EQ', Icons.equalizer, DeviceFamily.eq, () => const GraphicEqPage()),
};

