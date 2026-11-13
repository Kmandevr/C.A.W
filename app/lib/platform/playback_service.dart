// Background playback: Android's foreground service of type mediaPlayback (PlaybackService.kt) with its notification
// ("C.A.W is playing" or "recording", Play/Pause and Stop) and the battery choice, over "caw/playback_service"; others have none.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// What the notification's buttons ask for.
enum PlaybackAction { playPause, stop }

abstract class PlaybackService {
  /// Starts the service, or updates its notification: [playing] (else paused) and [recording] (the microphone is
  /// in use, so the service also takes the microphone type). True when it runs.
  Future<bool> show({required bool playing, required bool recording});

  /// Stops the service and removes its notification.
  Future<void> hide();

  /// Whether the notification can be shown in the drawer (Android 13+ asks for POST_NOTIFICATIONS); true elsewhere.
  Future<bool> notificationsAllowed();

  /// Asks for the notification permission (Android 13+); answers whether it is allowed now.
  Future<bool> requestNotifications();

  /// The notification's buttons, as they are pressed.
  Stream<PlaybackAction> get actions;

  /// Whether the system leaves C.A.W's battery use unrestricted (Android: on the power allowlist,
  /// `PowerManager.isIgnoringBatteryOptimizations`); null where there is no such setting (the row is hidden).
  Future<bool?> batteryUnrestricted();

  /// Opens the system page closest to C.A.W's own battery choice (Android: the app's details page, else the
  /// battery-optimization list); false when none opened.
  Future<bool> openBatterySettings();
}

/// Windows and the desktop test builds: the app keeps playing behind other windows anyway, with no notification.
class NoPlaybackService implements PlaybackService {
  const NoPlaybackService();
  @override
  Future<bool> show({required bool playing, required bool recording}) async => false;
  @override
  Future<void> hide() async {}
  @override
  Future<bool> notificationsAllowed() async => true;
  @override
  Future<bool> requestNotifications() async => true;
  @override
  Stream<PlaybackAction> get actions => const Stream.empty();
  @override
  Future<bool?> batteryUnrestricted() async => null;
  @override
  Future<bool> openBatterySettings() async => false;
}

class AndroidPlaybackService implements PlaybackService {
  AndroidPlaybackService({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('caw/playback_service') {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'action') return null;
      final a = switch (call.arguments) { 'playPause' => PlaybackAction.playPause, 'stop' => PlaybackAction.stop, _ => null };
      if (a != null) _actions.add(a);
      return null;
    });
  }
  final MethodChannel _channel;
  final _actions = StreamController<PlaybackAction>.broadcast();

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> show({required bool playing, required bool recording}) async =>
      await _call<bool>('show', {'playing': playing, 'recording': recording}) ?? false;
  @override
  Future<void> hide() async => _call<void>('hide');
  @override
  Future<bool> notificationsAllowed() async => await _call<bool>('notificationsAllowed') ?? false;
  @override
  Future<bool> requestNotifications() async => await _call<bool>('requestNotifications') ?? false;
  @override
  Stream<PlaybackAction> get actions => _actions.stream;
  @override
  Future<bool?> batteryUnrestricted() => _call<bool>('batteryUnrestricted');
  @override
  Future<bool> openBatterySettings() async => await _call<bool>('openBatterySettings') ?? false;
}

PlaybackService platformPlaybackService() => Platform.isAndroid ? AndroidPlaybackService() : const NoPlaybackService();
