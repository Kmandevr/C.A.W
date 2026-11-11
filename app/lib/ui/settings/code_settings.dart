// Settings › Code editor: live coding (auto-update, delay, swap timing), font size, tabs, line numbers, wrap, and the
// pattern editor's buttons, scope and Run bar.
import 'package:flutter/material.dart';

import '../../model/settings.dart';
import 'settings_deps.dart';
import 'settings_widgets.dart';

class CodeSettings extends StatelessWidget {
  const CodeSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final s = deps.settings;
    final e = s.editor;
    Widget toggle(String id, bool value, EditorLook Function(bool) set, IconData icon, {String? subtitle}) =>
        settingSwitch(id, value, (v) => s.update((x) => x.editor = set(v)), icon: icon, subtitle: subtitle);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      settingHeading('Live coding'),
      settingSwitch('code.autoUpdate', s.liveUpdate, (v) => s.update((x) => x.liveUpdate = v), icon: Icons.bolt),
      settingSlider('code.delay', s,
          value: s.liveDelayMs.clamp(100, 2000).toDouble(), min: 100, max: 2000, divisions: 38,
          enabled: s.liveUpdate, icon: Icons.timer_outlined,
          show: (v) => '${v.round()} ms', set: (x, v) => x.liveDelayMs = v.round(), reset: 400),
      settingChoice<SwapTiming>('code.swap', s.swapTiming,
          const [(SwapTiming.now, 'Now'), (SwapTiming.beat, 'Beat'), (SwapTiming.bar, 'Bar')],
          (v) => s.update((x) => x.swapTiming = v),
          icon: Icons.av_timer),
      settingHeading('Text'),
      settingSlider('code.fontSize', s,
          value: s.codeFontSize, min: Settings.minCodeFontSize, max: Settings.maxCodeFontSize, divisions: 14,
          icon: Icons.format_size, show: (v) => '${v.round()} pt', set: (x, v) => x.codeFontSize = v.roundToDouble(),
          reset: 15, subtitle: 'The pattern editor\'s size; the C++ editor\'s follows it (12.5 at 15)'),
      settingChoice<int>('code.tabWidth', s.codeTabWidth, const [(2, '2'), (4, '4'), (8, '8')],
          (v) => s.update((x) => x.codeTabWidth = v),
          icon: Icons.keyboard_tab, subtitle: 'Spaces per indent in the C++ editor (files opened from now on)'),
      settingSwitch('code.lineNumbers', s.codeLineNumbers, (v) => s.update((x) => x.codeLineNumbers = v),
          icon: Icons.format_list_numbered),
      settingSwitch('code.wrap', s.codeWrap, (v) => s.update((x) => x.codeWrap = v),
          icon: Icons.wrap_text, subtitle: 'The C++ editor wraps long lines (the pattern editor always does)'),
      settingHeading('Editor'),
      toggle('code.solo', e.soloButton, (v) => e.copyWith(soloButton: v), Icons.hearing,
          subtitle: 'Also in the pattern\'s ⋮ menu when hidden'),
      toggle('code.scope', e.scope, (v) => e.copyWith(scope: v), Icons.show_chart, subtitle: 'Light mode hides it too'),
      toggle('code.barOnTop', e.barOnTop, (v) => e.copyWith(barOnTop: v), Icons.vertical_align_top),
    ]);
  }
}
