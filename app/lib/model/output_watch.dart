// Settings › Sound and App's output watches (#244): pause when the output is unplugged, and keep the screen awake while playing or always.
import 'dart:async';

import '../platform/output_events.dart';
import 'app_state.dart';
import 'settings.dart';

/// Owned by the app state: listens for the output being unplugged (Android's broadcast, or a removed output in the
/// audio status on desktop, looked at once a second while playing) and pauses when Settings.pauseOnUnplug says so;
/// asks the platform to keep the screen on as Settings.keepAwake says, while the app is in front.
class OutputWatch {
  OutputWatch(this.state, {OutputUnplug? unplug, ScreenAwake? awake})
      : unplug = unplug ?? OutputUnplug.current,
        awake = awake ?? ScreenAwake.current {
    _sub = this.unplug.unplugged.listen((_) => unplugged());
  }

  final AppState state;
  final OutputUnplug unplug;
  final ScreenAwake awake;
  StreamSubscription<void>? _sub;

  /// Times the output was unplugged while playing and playback paused (the transport says so once).
  int pauses = 0;

  String? _device;
  int _readUs = 0;
  bool? _awakeAsked;

  /// The output went away: pauses a playback or recording when the setting is on.
  void unplugged() {
    if (!state.settings.pauseOnUnplug || !state.transportOn) return;
    pauses++;
    state.togglePlay();
  }

  /// From the meter poll: on a platform with no event, the audio status about once a second while playing.
  void poll(int nowUs, {required bool playing}) {
    if (!unplug.watchesStatus) return;
    if (!playing) {
      _device = null;
      return;
    }
    if (nowUs - _readUs < 1000000) return;
    _readUs = nowUs;
    final st = state.audioStatus;
    if (st == null) return;
    final last = _device;
    _device = st.running ? st.device : '';
    if (last != null && outputRemoved(last, st)) unplugged();
  }

  /// Whether the screen should stay on now.
  bool get wantsAwake => state.foreground.value &&
      switch (state.settings.keepAwake) {
        KeepAwake.off => false,
        KeepAwake.playing => state.transportOn || state.meters.playing,
        KeepAwake.always => true,
      };

  /// Asks the platform when [wantsAwake] changed.
  void update() {
    final on = wantsAwake;
    if (_awakeAsked == on) return;
    _awakeAsked = on;
    unawaited(awake.keepOn(on));
  }

  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
    if (_awakeAsked == true) unawaited(awake.keepOn(false));
  }
}
