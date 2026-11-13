// Background playback in the UI (owner, 2026-11-12): Settings › Audio's "Background playback" row (whether Android
// restricts C.A.W's battery, with Open), and the one-time hint on return to set it to Unrestricted.
import 'dart:async';

import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/background_playback.dart';
import 'haptics.dart';
import 'motion.dart';
import 'settings/settings_widgets.dart';
import 'theme.dart';

/// What the hint says (owner, 2026-11-12).
const backgroundHintText = 'For uninterrupted background playback, set C.A.W\'s battery to Unrestricted';

/// Settings › Audio: whether C.A.W's battery is restricted, with Open (Android's page for it). Hidden where there is
/// no such setting (Windows, Linux); re-read when the app comes back from that page.
class BackgroundPlaybackRow extends StatefulWidget {
  const BackgroundPlaybackRow({super.key, required this.state, this.playback});
  final AppState? state;

  /// The controller to ask ([BackgroundPlayback.current] by default).
  final BackgroundPlayback? playback;

  @override
  State<BackgroundPlaybackRow> createState() => _BackgroundPlaybackRowState();
}

class _BackgroundPlaybackRowState extends State<BackgroundPlaybackRow> {
  BackgroundPlayback? get b => widget.playback ?? BackgroundPlayback.current;
  bool? _unrestricted;
  bool _read = false;

  @override
  void initState() {
    super.initState();
    widget.state?.foreground.addListener(_reread);
    _reread();
  }

  @override
  void dispose() {
    widget.state?.foreground.removeListener(_reread);
    super.dispose();
  }

  void _reread() {
    if (widget.state != null && !widget.state!.foreground.value) return;
    final bp = b;
    if (bp == null) return;
    unawaited(bp.batteryUnrestricted().then((v) {
      if (mounted) {
        setState(() {
          _unrestricted = v;
          _read = true;
        });
      }
    }));
  }

  @override
  Widget build(BuildContext context) {
    final bp = b;
    final Widget row = bp == null || !_read || _unrestricted == null
        ? const SizedBox(key: ValueKey('background-row-none'), width: double.infinity)
        : KeyedSubtree(
            key: ValueKey('background-row-${_unrestricted! ? 'free' : 'restricted'}'),
            child: settingAction('audio.background',
                icon: _unrestricted! ? Icons.play_circle_outline : Icons.battery_alert_outlined,
                iconColor: _unrestricted! ? Neon.blue : Neon.yellow,
                subtitle: _unrestricted!
                    ? 'Unrestricted: C.A.W plays on behind other apps'
                    : 'Battery-restricted: Android may interrupt playback behind other apps',
                trailing: FilledButton.tonal(
                  key: const ValueKey('background-open'),
                  onPressed: () {
                    Haptics.tap();
                    unawaited(bp.openBatterySettings());
                  },
                  child: const Text('Open'),
                )),
          );
    return AnimatedSize(duration: Motion.fade(Motion.standard, Motion.of(context)), child: row);
  }
}

/// Shows the one-time hint as a banner when [BackgroundPlayback.hint] turns on: Open settings, Don't show again.
class BackgroundHintFeedback extends StatefulWidget {
  const BackgroundHintFeedback({super.key, required this.child, this.playback});
  final Widget child;
  final BackgroundPlayback? playback;

  @override
  State<BackgroundHintFeedback> createState() => _BackgroundHintFeedbackState();
}

class _BackgroundHintFeedbackState extends State<BackgroundHintFeedback> {
  BackgroundPlayback? get b => widget.playback ?? BackgroundPlayback.current;

  @override
  void initState() {
    super.initState();
    b?.hint.addListener(_hint);
    WidgetsBinding.instance.addPostFrameCallback((_) => _hint());
  }

  @override
  void dispose() {
    b?.hint.removeListener(_hint);
    super.dispose();
  }

  void _hint() {
    final bp = b;
    final messenger = mounted ? ScaffoldMessenger.maybeOf(context) : null;
    if (bp == null || messenger == null) return;
    if (!bp.hint.value) {
      messenger.hideCurrentMaterialBanner();
      return;
    }
    messenger
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(MaterialBanner(
        key: const ValueKey('background-hint'),
        leading: const Icon(Icons.battery_alert_outlined, color: Neon.yellow),
        content: const Text(backgroundHintText),
        actions: [
          TextButton(
            key: const ValueKey('background-hint-never'),
            onPressed: () => bp.dismissHint(forever: true),
            child: const Text('Don\'t show again'),
          ),
          TextButton(
            key: const ValueKey('background-hint-open'),
            onPressed: () {
              bp.dismissHint();
              unawaited(bp.openBatterySettings());
            },
            child: const Text('Open settings'),
          ),
        ],
      ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
