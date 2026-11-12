// Settings › Look: theme family and Mode (dark, light, follow system), the theme editor, density, layout, glass and blur, reactive glow, meter fall and the arrangement's sizes.
import 'package:flutter/material.dart';

import '../../model/settings.dart';
import '../glass.dart';
import '../panel_motion.dart';
import '../theme.dart';
import '../theme_editor.dart';
import 'settings_deps.dart';
import 'settings_widgets.dart';

class LookSettings extends StatelessWidget {
  const LookSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final s = deps.settings;
    String px(double v) => v == 0 ? 'Default' : '${v.round()} px';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      settingDropdown<String>('look.family', s.themeName, [for (final t in s.themes) (t.name, t.name)],
          (v) => s.chooseTheme(v),
          icon: Icons.palette_outlined,
          subtitle: s.isStarter(s.themeName) ? 'A built-in family, light and dark' : 'Your own theme'),
      settingChoice<LookMode>('look.mode', s.lookMode, [for (final m in LookMode.values) (m, m.label)],
          (v) => s.setLookMode(v),
          icon: Icons.contrast,
          subtitle: s.lookMode == LookMode.system
              ? 'Follows the system: ${s.platformBrightness == Brightness.light ? 'light' : 'dark'} now'
              : 'Only the palette changes; the look, layout and behaviour stay'),
      settingAction('look.theme',
          icon: Icons.palette, iconColor: Neon.pink, subtitle: s.themeName,
          onTap: () => Navigator.of(context)
              .push(panelRoute<void>(context, (_) => GlassPage(child: ThemeEditor(settings: s))))),
      settingChoice<Density>('look.density', s.density,
          const [(Density.comfortable, 'Comfortable'), (Density.compact, 'Compact')],
          (v) => s.update((x) => x.density = v),
          icon: Icons.density_medium,
          subtitle: s.compact ? 'Compact: more on screen' : 'Comfortable: 48 dp touch targets'),
      settingChoice<LayoutMode>('look.layout', s.layoutMode, [for (final m in LayoutMode.values) (m, m.label)],
          (v) => s.update((x) => x.layoutMode = v),
          icon: Icons.desktop_windows,
          subtitle: switch (s.layoutMode) {
            LayoutMode.auto => 'Auto: the desktop layout on a big window (DeX, an external display, a tablet)',
            LayoutMode.phone => 'Phone: always the phone layout',
            LayoutMode.desktop => 'Desktop: the rail, docking panels and floating windows, even on a phone',
          }),
      settingSwitch('look.glass', s.glass, (v) => s.update((x) => x.glass = v),
          icon: Icons.blur_on,
          subtitle: s.activeTheme.flat
              ? 'Off in the Flat theme'
              : Neon.performanceMode >= 3
              ? 'Off while the Minimal profile is on'
              : 'See-through panels, tracks and controls over a soft background'),
      settingSwitch('look.blur', s.glassBlur, s.glass ? (v) => s.update((x) => x.glassBlur = v) : null,
          icon: Icons.blur_linear,
          subtitle: Neon.performanceMode >= 2
              ? 'Off while the Lightweight or Minimal profile is on'
              : 'Blur behind sheets and menus; off keeps the glass look and costs far less'),
      settingSlider('look.glow', s,
          value: s.reactiveGlow, min: 0, max: 1, divisions: 20, icon: Icons.graphic_eq,
          show: (v) => v == 0 ? 'Off' : '${(v * 100).round()}%', set: (x, v) => x.reactiveGlow = v, reset: 0.35),
      settingDropdown<double>(
        'look.meterFall',
        Settings.meterFalls.contains(s.meterFall) ? s.meterFall : null,
        const [(48.0, 'Slow'), (96.0, 'Medium'), (144.0, 'Fast'), (192.0, 'Very fast')],
        (v) => s.update((x) => x.meterFall = v),
        icon: Icons.align_vertical_bottom,
        subtitle: '${s.meterFall.round()} dB per second',
      ),
      settingHeading('Arrangement'),
      settingSlider('look.trackGap', s,
          value: s.trackGap, min: 0, max: Settings.maxTrackGap, divisions: 24, icon: Icons.format_line_spacing,
          show: (v) => '${v.round()} px', set: (x, v) => x.trackGap = v.roundToDouble(), reset: 6),
      settingSlider('look.headerWidth', s,
          value: s.headerWidth == 0 ? Settings.minHeaderWidth - 8 : s.headerWidth,
          min: Settings.minHeaderWidth - 8, max: Settings.maxHeaderWidth, icon: Icons.view_sidebar_outlined,
          show: (v) => px(v < Settings.minHeaderWidth ? 0 : v),
          set: (x, v) => x.headerWidth = v < Settings.minHeaderWidth ? 0 : v.roundToDouble(), reset: 0,
          subtitle: 'Also dragged from the headers\' right edge; all the way left is the screen\'s default'),
      settingSlider('look.trackHeight', s,
          value: s.trackHeight == 0 ? Settings.minTrackHeight - 4 : s.trackHeight,
          min: Settings.minTrackHeight - 4, max: Settings.maxTrackHeight, icon: Icons.height,
          show: (v) => px(v < Settings.minTrackHeight ? 0 : v),
          set: (x, v) => x.trackHeight = v < Settings.minTrackHeight ? 0 : v.roundToDouble(), reset: 0,
          subtitle: 'Also dragged from a row\'s bottom edge; all the way left is the screen\'s default'),
      settingSlider('look.focusShare', s,
          value: s.focusPanelShare, min: Settings.minFocusPanelShare, max: Settings.maxFocusPanelShare,
          icon: Icons.vertical_split_outlined, show: (v) => '${(v * 100).round()}%',
          set: (x, v) => x.focusPanelShare = v, reset: Settings.defaultFocusPanelShare),
    ]);
  }
}
