// The output's platform events for Settings › Sound (#244): headphones or a Bluetooth device unplugged (Android's ACTION_AUDIO_BECOMING_NOISY over "caw/audio_noisy"; a removed output found in the audio status on desktop), and keeping the screen awake (Android's FLAG_KEEP_SCREEN_ON over "caw/display", Windows' SetThreadExecutionState over "caw/window").
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../engine/engine.dart' show AudioStatus;

/// Tells the app when the output was unplugged, so playback can pause (Settings.pauseOnUnplug).
abstract class OutputUnplug {
  /// Fires when the platform says the output is about to become the speaker (headphones out, Bluetooth gone).
  Stream<void> get unplugged;

  /// Whether the platform sends no such event, so the app looks for a removed output in the audio status instead
  /// ([outputRemoved]) while playing.
  bool get watchesStatus;

  /// The app's (tests swap it).
  static OutputUnplug current = Platform.isAndroid ? AndroidOutputUnplug() : const StatusOutputUnplug();
}

/// Android: AudioManager.ACTION_AUDIO_BECOMING_NOISY, a receiver registered in code while the app listens
/// (AudioRoute.kt's AudioNoisy). [Fact, developer.android.com AudioManager reference, read 2026-11-18] "a hint for
/// applications that audio is about to become 'noisy' due to a change in audio outputs", for example a wired
/// headset unplugged or an A2DP sink disconnected, before the route switches to the speaker; apps "may consider
/// pausing". [Assumption] a receiver registered with Context.registerReceiver gets it (no manifest entry).
class AndroidOutputUnplug implements OutputUnplug {
  AndroidOutputUnplug({EventChannel? events}) : _events = events ?? const EventChannel('caw/audio_noisy');
  final EventChannel _events;

  @override
  Stream<void> get unplugged => _events.receiveBroadcastStream().map((_) {}).handleError((Object _) {});

  @override
  bool get watchesStatus => false;
}

/// Windows and the desktop builds: no event; the audio status shows the output gone instead ([outputRemoved]).
class StatusOutputUnplug implements OutputUnplug {
  const StatusOutputUnplug();

  @override
  Stream<void> get unplugged => const Stream.empty();

  @override
  bool get watchesStatus => true;
}

/// Whether the output playing [lastDevice] (its name at the last look, while playing) is gone in [now]: the device
/// stopped, fell back to the default, or another one plays (a removed default the system replaced).
bool outputRemoved(String lastDevice, AudioStatus now) =>
    lastDevice.isNotEmpty && (!now.running || now.fallback || (now.device.isNotEmpty && now.device != lastDevice));

/// Keeps the screen on while asked (Settings.keepAwake).
abstract class ScreenAwake {
  /// Asks the platform to keep the screen on ([on]) or to let it sleep again.
  Future<void> keepOn(bool on);

  /// The app's (tests swap it).
  static ScreenAwake current = Platform.isAndroid || Platform.isWindows ? ChannelScreenAwake() : const NoScreenAwake();
}

/// Android: the window's WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON ("caw/display", DisplayRate.kt); Windows:
/// SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED) on the window's thread ("caw/window",
/// flutter_window.cpp). [Fact, developer.android.com "Keep the screen on" and learn.microsoft.com
/// SetThreadExecutionState, read 2026-11-18] the flag is set on the activity's window, stops holding once the app
/// is in the background, and is cleared with clearFlags; ES_CONTINUOUS keeps the state "until the next call that
/// uses ES_CONTINUOUS and one of the other state flags is cleared", and ES_DISPLAY_REQUIRED keeps the display on.
class ChannelScreenAwake implements ScreenAwake {
  ChannelScreenAwake({MethodChannel? channel})
      : _channel = channel ?? MethodChannel(Platform.isAndroid ? 'caw/display' : 'caw/window');
  final MethodChannel _channel;

  @override
  Future<void> keepOn(bool on) async {
    try {
      await _channel.invokeMethod<void>('keepScreenOn', {'on': on});
    } on PlatformException {
      // The screen sleeps as usual.
    } on MissingPluginException {
      // An older runner: as above.
    }
  }
}

class NoScreenAwake implements ScreenAwake {
  const NoScreenAwake();

  @override
  Future<void> keepOn(bool on) async {}
}
