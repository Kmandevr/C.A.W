// Settings › Feel: motion, edit animations (style and kinds), haptics and their strength, the quick actions bar and
// how long-press menus open.
import 'package:flutter/material.dart';

import '../../model/settings.dart';
import '../haptics.dart';
import '../motion.dart';
import 'settings_deps.dart';
import 'settings_widgets.dart';

class FeelSettings extends StatelessWidget {
  const FeelSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final s = deps.settings;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      settingChoice<MotionLevel>('feel.motion', s.motion,
          const [(MotionLevel.full, 'Full'), (MotionLevel.reduced, 'Reduced'), (MotionLevel.off, 'Off')],
          (v) => s.update((x) => x.motion = v),
          icon: Icons.animation,
          subtitle: Motion.minimalProfile
              ? 'Off while the Minimal profile is on (drags, snapping and presses still move)'
              : switch (s.motion) {
                  MotionLevel.full => 'Smooth, distance-aware animations and snapping',
                  MotionLevel.reduced => 'Fades only: nothing slides, grows or springs',
                  MotionLevel.off => 'Only what helps: drag ghosts, snapping and press feedback',
                }),
      settingChoice<EditMotionStyle>('feel.editStyle', s.editMotionStyle,
          [for (final v in EditMotionStyle.values) (v, v.label)],
          s.motion == MotionLevel.off ? null : (v) => s.update((x) => x.editMotionStyle = v),
          icon: Icons.auto_awesome_motion,
          subtitle: s.motion == MotionLevel.off
              ? 'Off with Motion off'
              : s.editMotionStyle == EditMotionStyle.subtle
                  ? 'Subtle: short, quiet eases'
                  : 'Playful: a little longer, with a small overshoot'),
      for (final k in EditMotionKind.values)
        settingSwitch('feel.edit.${k.name}', s.editMotionKinds.contains(k),
            s.motion == MotionLevel.off
                ? null
                : (v) => s.update((x) => x.editMotionKinds = v ? {...x.editMotionKinds, k} : ({...x.editMotionKinds}..remove(k))),
            icon: Icons.animation_outlined),
      settingSwitch('feel.haptics', s.haptics, (v) => s.update((x) => x.haptics = v), icon: Icons.vibration),
      SettingRow(
        id: 'feel.hapticStrength',
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: const Icon(Icons.vibration, size: 20),
          title: Text('Haptic strength: ${(s.hapticStrength * 100).round()}%'),
          subtitle: Slider(
            key: const ValueKey('settings-haptic-strength'),
            value: s.hapticStrength,
            divisions: 10,
            onChanged: s.haptics ? (v) => s.adjust((x) => x.hapticStrength = v) : null,
            // A tick at the new strength, so it can be felt.
            onChangeEnd: (_) {
              s.save();
              Haptics.reset();
              Haptics.tap();
            },
          ),
        ),
      ),
      settingSwitch('feel.quickActions', s.quickActions, (v) => s.update((x) => x.quickActions = v),
          icon: Icons.touch_app),
      settingChoice<LongPressMenuStyle>('feel.longPress', s.longPressMenu,
          const [(LongPressMenuStyle.list, 'List'), (LongPressMenuStyle.ring, 'Ring')],
          (v) => s.update((x) => x.longPressMenu = v),
          icon: Icons.radio_button_checked),
    ]);
  }
}
