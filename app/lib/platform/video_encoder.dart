// The music video's encoder behind one small interface: the platform's H.264 + AAC MP4 encoder over `caw/video`
// (Android MediaCodec + MediaMuxer, Windows Media Foundation), or a frame-hash list where there is none (Linux, tests).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../model/music_video.dart';

/// What to encode: the frame size and rate, the bitrate, the audio (a 16-bit PCM WAV) and where the file goes.
class VideoEncodeConfig {
  const VideoEncodeConfig({required this.width, required this.height, required this.fps, required this.bitrate,
      required this.audioPath, required this.outputPath});
  final int width, height, fps, bitrate;
  final String audioPath, outputPath;

  Map<String, Object> toMap() => {'width': width, 'height': height, 'fps': fps, 'bitrate': bitrate,
      'audio': audioPath, 'output': outputPath};
}

/// Takes frames one at a time (RGBA, width × height × 4 bytes, top row first) and writes the file on [finish].
/// Frames are streamed: only one [addFrame] is in flight at a time (the caller waits for each before sending the next;
/// Android copies frames into two reused buffers), so memory stays bounded.
abstract class VideoEncoder {
  /// The file the encoder writes: its extension and type, for the save picker.
  String get extension;
  String get mimeType;

  /// What sizes it takes.
  Future<VideoEncoderCaps> caps();
  Future<void> start(VideoEncodeConfig config);
  Future<void> addFrame(Uint8List rgba);
  Future<void> finish();

  /// Stops and deletes the partial file. Safe to call at any time, and more than once.
  Future<void> cancel();
}

/// The platform's encoder: MP4 through `caw/video` on Android and Windows, the frame list elsewhere.
VideoEncoder platformVideoEncoder() => Platform.isAndroid || Platform.isWindows
    ? ChannelVideoEncoder(binaryFrames: Platform.isAndroid)
    : FrameHashEncoder();

/// Whether this platform writes a real MP4.
bool get platformWritesMp4 => Platform.isAndroid || Platform.isWindows;

/// The native encoder (VideoEncoder.kt, windows/runner/video_encoder.cpp).
class ChannelVideoEncoder implements VideoEncoder {
  ChannelVideoEncoder({MethodChannel? channel, this.binaryFrames = false, BinaryMessenger? messenger})
      : _channel = channel ?? const MethodChannel('caw/video'),
        _messenger = messenger; // ignore: prefer_initializing_formals
  final MethodChannel _channel;

  /// Frames as raw bytes on `caw/video_frame` (Android, VideoEncoder.kt): no codec copy on either side. The reply is
  /// one byte, 0, or 1 and the error's text.
  final bool binaryFrames;
  final BinaryMessenger? _messenger;
  static const frameChannel = 'caw/video_frame';

  @override
  String get extension => 'mp4';
  @override
  String get mimeType => 'video/mp4';

  @override
  Future<VideoEncoderCaps> caps() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('caps');
      final long = m?['maxLong'], short = m?['maxShort'];
      if (long is int && short is int && long > 0 && short > 0) return VideoEncoderCaps(maxLong: long, maxShort: short);
    } on PlatformException {
      // fall through
    } on MissingPluginException {
      // fall through
    }
    return VideoEncoderCaps.fallback;
  }

  @override
  Future<void> start(VideoEncodeConfig config) => _channel.invokeMethod<void>('start', config.toMap());
  @override
  Future<void> addFrame(Uint8List rgba) async {
    if (!binaryFrames) return _channel.invokeMethod<void>('frame', {'rgba': rgba});
    final messenger = _messenger ?? ServicesBinding.instance.defaultBinaryMessenger;
    final reply = await messenger.send(frameChannel, ByteData.sublistView(rgba));
    if (reply == null) throw MissingPluginException('no handler on $frameChannel');
    if (reply.lengthInBytes >= 1 && reply.getUint8(0) == 0) return;
    final text = reply.lengthInBytes > 1
        ? utf8.decode(reply.buffer.asUint8List(reply.offsetInBytes + 1, reply.lengthInBytes - 1), allowMalformed: true)
        : 'the frame failed';
    throw PlatformException(code: 'video', message: text);
  }
  @override
  Future<void> finish() => _channel.invokeMethod<void>('finish');
  @override
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on PlatformException {
      // nothing was running
    } on MissingPluginException {
      // nothing was running
    }
  }
}

/// The stand-in encoder: a text file with the size, rate, the audio's length and one FNV-1a 64-bit hash per frame,
/// so a render can be checked frame for frame without a video codec.
class FrameHashEncoder implements VideoEncoder {
  FrameHashEncoder({this.maxSide = 8192});
  final int maxSide;
  VideoEncodeConfig? _config;
  IOSink? _out;
  int frames = 0;
  final List<String> hashes = [];

  /// The audio's length in seconds, read from its WAV header on [start].
  double audioSeconds = 0;

  @override
  String get extension => 'txt';
  @override
  String get mimeType => 'text/plain';

  @override
  Future<VideoEncoderCaps> caps() async => VideoEncoderCaps(maxLong: maxSide, maxShort: maxSide);

  @override
  Future<void> start(VideoEncodeConfig config) async {
    _config = config;
    frames = 0;
    hashes.clear();
    final audio = File(config.audioPath);
    if (await audio.exists()) {
      final f = await audio.open();
      try {
        final b = await f.read(64);
        audioSeconds = _wavSeconds(b, await f.length());
      } finally {
        await f.close();
      }
    }
    _out = File(config.outputPath).openWrite()
      ..writeln('caw-frames 1')
      ..writeln('size ${config.width}x${config.height} fps ${config.fps} audio ${audioSeconds.toStringAsFixed(6)}');
  }

  @override
  Future<void> addFrame(Uint8List rgba) async {
    final c = _config;
    if (c == null) throw StateError('not started');
    if (rgba.length != c.width * c.height * 4) throw ArgumentError('frame is ${rgba.length} bytes');
    final h = fnv1a64(rgba);
    hashes.add(h);
    _out!.writeln(h);
    frames++;
  }

  @override
  Future<void> finish() async {
    await _out?.flush();
    await _out?.close();
    _out = null;
  }

  @override
  Future<void> cancel() async {
    final out = _out;
    _out = null;
    if (out != null) {
      await out.close();
      final c = _config;
      if (c != null) {
        try {
          await File(c.outputPath).delete();
        } catch (_) {}
      }
    }
  }
}

/// A 16-byte-or-more WAV head's duration (the first `fmt ` and `data` chunks, if they are in [head]).
double _wavSeconds(Uint8List head, int fileLength) {
  if (head.length < 44) return 0;
  final b = ByteData.sublistView(head);
  var pos = 12;
  var byteRate = 0;
  while (pos + 8 <= head.length) {
    final id = String.fromCharCodes(head, pos, pos + 4);
    final size = b.getUint32(pos + 4, Endian.little);
    if (id == 'fmt ' && pos + 20 <= head.length) byteRate = b.getUint32(pos + 16, Endian.little);
    if (id == 'data') {
      final bytes = size.clamp(0, fileLength - pos - 8);
      return byteRate == 0 ? 0 : bytes / byteRate;
    }
    pos += 8 + size + (size & 1);
  }
  return 0;
}

/// FNV-1a 64-bit over [bytes], as 16 hex digits (in 32-bit halves so it runs the same on the web's numbers too).
String fnv1a64(Uint8List bytes) {
  // offset basis 0xcbf29ce484222325, prime 0x100000001b3
  var hi = 0xcbf29ce4, lo = 0x84222325;
  for (final x in bytes) {
    lo ^= x;
    // (hi:lo) * 0x100000001b3 = (hi:lo) * 0x1b3 + (lo << 40)
    final loMul = lo * 0x1b3;
    final newLo = loMul & 0xffffffff;
    final carry = (loMul - newLo) ~/ 0x100000000;
    final newHi = (hi * 0x1b3 + carry + ((lo << 8) & 0xffffffff)) & 0xffffffff;
    hi = newHi;
    lo = newLo;
  }
  return hi.toRadixString(16).padLeft(8, '0') + lo.toRadixString(16).padLeft(8, '0');
}
