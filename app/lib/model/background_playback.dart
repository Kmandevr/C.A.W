// Background playback (owner, 2026-11-12): the platform's playback service runs while the transport plays or a recording
// runs, so Android keeps the app going behind other apps; its notification's Play/Pause and Stop drive the transport.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/playback_service.dart';
import 'app_state.dart';
import 'audio_record.dart';

class BackgroundPlayback {
  BackgroundPlayback(this.state, this.service, {AudioRecorder? Function()? recorder})
      : _recorder = recorder ?? (() => AudioRecorder.current) {
    state.addListener(_sync);
    state.foreground.addListener(_onForeground);
    _actions = service.actions.listen(_onAction);
    _sync();
  }

  /// The app's one (main.dart), for Settings › Audio and the hint.
  static BackgroundPlayback? current;

  final AppState state;
  final PlaybackService service;
  final AudioRecorder? Function() _recorder;
  late final StreamSubscription<PlaybackAction> _actions;
  AudioRecorder? _watched;

  /// While the app is behind and the service runs, the device is checked this often (a disconnect miniaudio could
  /// not reopen stops it; the meter poll that checks it in front sleeps behind).
  static Duration checkEvery = const Duration(seconds: 2);

  /// Whether the service runs, and what its notification says.
  bool get shown => _shown != null;
  ({bool playing, bool recording})? _shown;

  // Paused from the notification while behind: the notification stays (with Play) until Stop or the app's return.
  bool _heldPaused = false;
  bool _askedNotifications = false;
  bool _disposed = false;
  Timer? _check;
  Future<void>? _queue;  // starts and stops in order; null until the first (made in the caller's zone)

  bool get _recording => _recorder()?.recording ?? false;

  void _watchRecorder() {
    final r = _recorder();
    if (identical(r, _watched)) return;
    _watched?.removeListener(_sync);
    _watched = r;
    r?.addListener(_sync);
  }

  /// The one-time hint (owner, 2026-11-12): playback went behind the app while Android restricts C.A.W's battery, so
  /// on return the app suggests Unrestricted, with Open settings and Don't show again. Once a run at most.
  final hint = ValueNotifier<bool>(false);
  bool _hintDue = false, _hintGiven = false;

  void _onForeground() {
    if (state.foreground.value) {
      _heldPaused = false;
      if (_hintDue) {
        _hintDue = false;
        _hintGiven = true;
        hint.value = true;
      }
    } else if (_shown != null && !_hintGiven && !_hintDue && !state.settings.backgroundHintOff) {
      unawaited(service.batteryUnrestricted().then((unrestricted) {
        if (unrestricted != false || _disposed || _hintGiven || state.settings.backgroundHintOff) return;
        if (state.foreground.value) {  // back already
          _hintGiven = true;
          hint.value = true;
        } else {
          _hintDue = true;
        }
      }));
    }
    _sync();
  }

  /// The hint answered: closed for now, or [forever] ("Don't show again", saved in settings).
  void dismissHint({bool forever = false}) {
    hint.value = false;
    if (forever) unawaited(state.settings.update((s) => s.backgroundHintOff = true));
  }

  /// Opens Android's battery page for C.A.W (Settings › Audio's row and the hint).
  Future<bool> openBatterySettings() => service.openBatterySettings();

  /// Whether C.A.W's battery is unrestricted; null where there is no such setting.
  Future<bool?> batteryUnrestricted() => service.batteryUnrestricted();

  // The transport, the recording or the lifecycle changed: start, update or stop the service.
  void _sync() {
    if (_disposed) return;
    _watchRecorder();
    final playing = state.transportOn;
    final recording = _recording;
    final want = playing || recording || (_heldPaused && !state.foreground.value);
    final next = want ? (playing: playing, recording: recording) : null;
    _updateCheck();
    if (next == _shown) return;
    // Android lets a foreground service start only while the app is in front (Android 12+): from behind, only a
    // running one is updated or stopped.
    if (next != null && _shown == null && !state.foreground.value) return;
    _shown = next;
    final before = _queue;
    _queue = () async {
      if (before != null) await before;
      if (_disposed) return;
      if (next == null) {
        await service.hide();
        return;
      }
      if (!_askedNotifications && state.foreground.value) {
        // Android 13+: the notification shows in the drawer only with POST_NOTIFICATIONS; asked once a run, the
        // first time something plays (the service runs either way).
        _askedNotifications = true;
        if (!await service.notificationsAllowed()) await service.requestNotifications();
      }
      if (!await service.show(playing: next.playing, recording: next.recording) && identical(_shown, next)) {
        _shown = null;  // refused: tried again on the next change while in front
      }
    }();
  }

  void _updateCheck() {
    final on = _shown != null && !state.foreground.value;
    if (on && _check == null) {
      _check = Timer.periodic(checkEvery, (_) => state.checkAudioDevice());
    } else if (!on) {
      _check?.cancel();
      _check = null;
    }
  }

  void _onAction(PlaybackAction a) {
    if (_disposed) return;
    switch (a) {
      case PlaybackAction.playPause:
        // Held before the pause notifies, so the service is updated to "paused", not stopped.
        _heldPaused = state.transportOn && !state.foreground.value;
        state.togglePlay();  // pausing ends a take, as the transport's own pause does
        if (state.transportOn) _heldPaused = false;
        _sync();
      case PlaybackAction.stop:
        _heldPaused = false;
        state.stopPlayback();  // stopping ends a take
        _sync();
        state.releaseAudioBehind();  // behind the app, the device closes as it does when the app goes behind stopped
    }
  }

  /// Settles pending starts and stops (tests).
  @visibleForTesting
  Future<void> settled() => _queue ?? Future<void>.value();

  void dispose() {
    _disposed = true;
    state.removeListener(_sync);
    state.foreground.removeListener(_onForeground);
    _watched?.removeListener(_sync);
    _check?.cancel();
    hint.dispose();
    unawaited(_actions.cancel());
    if (_shown != null) unawaited(service.hide());
  }
}
