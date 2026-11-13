// The microphone permission audio input needs: Android asks for RECORD_AUDIO over "caw/permissions" (MicPermission.kt)
// when the user turns input on or arms a track; other platforms have no such prompt here.
import 'dart:io';

import 'package:flutter/services.dart';

abstract class MicPermission {
  /// Whether input may open now, without asking.
  Future<bool> granted();

  /// Asks the user (once the system lets it) and answers whether input may open.
  Future<bool> request();

  /// Whether the system is giving our open input silence because another app has the microphone (Android 10+'s
  /// concurrent capture policy). False where the platform does not say.
  Future<bool> inputSilenced() async => false;
}

/// Windows and the desktop test builds: the system's own privacy settings decide; the app does not ask.
class NoMicPrompt implements MicPermission {
  const NoMicPrompt();
  @override
  Future<bool> granted() async => true;
  @override
  Future<bool> request() async => true;
  @override
  Future<bool> inputSilenced() async => false;
}

class AndroidMicPermission implements MicPermission {
  AndroidMicPermission({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('caw/permissions');
  final MethodChannel _channel;

  @override
  Future<bool> granted() async {
    try {
      return await _channel.invokeMethod<bool>('recordAudioGranted') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> request() async {
    try {
      return await _channel.invokeMethod<bool>('requestRecordAudio') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> inputSilenced() async {
    try {
      return await _channel.invokeMethod<bool>('inputSilenced') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

MicPermission platformMicPermission() => Platform.isAndroid ? AndroidMicPermission() : const NoMicPrompt();
