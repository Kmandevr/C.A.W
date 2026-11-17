// The sample browser's engine calls (C API 33): the preview voice and the key estimate. SamplePreviewIo is what the model uses; tests fake it.
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'audio_bindings.dart' show AudioBindings, CEngine, CStr;
import 'bindings.dart' show engineLibraryPath;
import 'engine.dart';

final class CawSamplePreviewState extends Struct {
  @Int32()
  external int playing;
  @Int32()
  external int waiting;
  @Double()
  external double seconds;
  @Double()
  external double length;
  @Int64()
  external int seq;
}

/// The API 33 functions, looked up once per isolate.
class SampleBindings {
  SampleBindings._(DynamicLibrary lib)
      : assetKey = lib.lookupFunction<CStr Function(CEngine, CStr, CStr), CStr Function(CEngine, CStr, CStr)>('caw_asset_key'),
        preview = lib.lookupFunction<CStr Function(CEngine, CStr, CStr), CStr Function(CEngine, CStr, CStr)>(
            'caw_engine_preview_sample'),
        stop = lib.lookupFunction<Void Function(CEngine), void Function(CEngine)>('caw_engine_preview_sample_stop'),
        seek = lib.lookupFunction<Void Function(CEngine, Double), void Function(CEngine, double)>(
            'caw_engine_preview_sample_seek'),
        volume = lib.lookupFunction<Void Function(CEngine, Double), void Function(CEngine, double)>(
            'caw_engine_preview_sample_volume'),
        state = lib.lookupFunction<Int32 Function(CEngine, Pointer<CawSamplePreviewState>),
            int Function(CEngine, Pointer<CawSamplePreviewState>)>('caw_engine_preview_sample_state');

  static SampleBindings? _instance;
  static SampleBindings get instance => _instance ??= SampleBindings._(DynamicLibrary.open(engineLibraryPath()));

  final CStr Function(CEngine, CStr, CStr) assetKey;
  final CStr Function(CEngine, CStr, CStr) preview;
  final void Function(CEngine) stop;
  final void Function(CEngine, double) seek;
  final void Function(CEngine, double) volume;
  final int Function(CEngine, Pointer<CawSamplePreviewState>) state;
}

/// What the preview plays, as of the audio thread's last callback.
class PreviewState {
  const PreviewState({this.playing = false, this.waiting = false, this.seconds = 0, this.length = 0, this.seq = 0});
  final bool playing, waiting;
  final double seconds, length;
  final int seq;
}

/// The preview voice and the key estimate as the sample browser uses them.
abstract class SamplePreviewIo {
  /// Loads [path] (and stretches it by [ratio]) off the UI isolate and starts it. The engine's JSON comes back
  /// (`{"ok", "error", "seconds", "stretch_ratio"}`).
  Future<Map<String, dynamic>> play(String path,
      {double startSeconds = 0, double ratio = 1, String sync = 'now', bool loop = false, double? volume});
  void stop();
  void seek(double seconds);
  void setVolume(double volume);
  PreviewState state();

  /// `caw_asset_key` off the UI isolate: `{"ok", "sure", "tonic", "mode", "confidence", …}`.
  Future<Map<String, dynamic>> key(String path);
}

Map<String, dynamic> _decode(String text) {
  try {
    final j = jsonDecode(text);
    return j is Map<String, dynamic> ? j : {'ok': false, 'error': 'bad answer'};
  } catch (_) {
    return {'ok': false, 'error': 'bad answer'};
  }
}

/// [SamplePreviewIo] over the running engine (read on every call: the app makes a new one on a rate change).
class EngineSamplePreviewIo implements SamplePreviewIo {
  EngineSamplePreviewIo(this.engine);
  final Engine? Function() engine;
  Pointer<CawSamplePreviewState>? _state;

  @override
  Future<Map<String, dynamic>> play(String path,
      {double startSeconds = 0, double ratio = 1, String sync = 'now', bool loop = false, double? volume}) async {
    final e = engine();
    if (e == null) return {'ok': false, 'error': 'no engine'};
    final options = jsonEncode({
      'start_seconds': startSeconds < 0 ? 0 : startSeconds, 'stretch_ratio': ratio.clamp(0.25, 4.0), 'sync': sync,
      'loop': loop, if (volume != null) 'volume': volume.clamp(0.0, 1.0),
    });
    return await e.withNative((a) => _call(a, path, options, false)) ?? {'ok': false, 'error': 'no engine'};
  }

  @override
  Future<Map<String, dynamic>> key(String path) async =>
      await engine()?.withNative((a) => _call(a, path, '', true)) ?? {'ok': false, 'error': 'no engine'};

  CEngine? get _e {
    final a = engine()?.nativeAddress;
    return a == null ? null : Pointer<Void>.fromAddress(a);
  }

  @override
  void stop() {
    if (_e case final e?) SampleBindings.instance.stop(e);
  }

  @override
  void seek(double seconds) {
    if (_e case final e?) SampleBindings.instance.seek(e, seconds);
  }

  @override
  void setVolume(double volume) {
    if (_e case final e?) SampleBindings.instance.volume(e, volume.clamp(0.0, 1.0));
  }

  @override
  PreviewState state() {
    final e = _e;
    if (e == null) return const PreviewState();
    final s = _state ??= calloc<CawSamplePreviewState>();
    if (SampleBindings.instance.state(e, s) != 0) return const PreviewState();
    final r = s.ref;
    return PreviewState(playing: r.playing != 0, waiting: r.waiting != 0, seconds: r.seconds, length: r.length, seq: r.seq);
  }
}

// Top-level, so the isolate's closure carries only sendable values.
Future<Map<String, dynamic>> _call(int address, String path, String options, bool key) => Isolate.run(() {
      final b = SampleBindings.instance;
      final p = path.toNativeUtf8();
      final o = options.toNativeUtf8();
      try {
        final e = Pointer<Void>.fromAddress(address);
        return _decode(AudioBindings.instance.take(key ? b.assetKey(e, p, o) : b.preview(e, p, o)));
      } finally {
        calloc.free(p);
        calloc.free(o);
      }
    });
