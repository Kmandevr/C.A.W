// The music video's images (owner, 2026-11-12): one picked with the system file picker is copied into the project's
// video assets and decoded with limits (file size, sides and pixels checked before decoding, kept at most 2048 px
// on its long side); decoded images are kept per asset for the preview and the render.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../model/app_state.dart';
import '../../model/music_video_overlay.dart';

/// The folder [s]'s project keeps its video images in (a temporary one without storage, as in tests).
Directory videoAssetsDir(AppState s) =>
    s.storage?.videoAssetsDirectory(s.project.id) ??
    Directory('${Directory.systemTemp.path}${Platform.pathSeparator}caw-video-assets${Platform.pathSeparator}'
        '${s.project.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}');

/// [bytes] decoded as an image within [VideoImageAsset]'s limits: the encoded size, its sides and pixel count are
/// checked from its header before any pixels are decoded, and it is decoded at most [VideoImageAsset.keepSide]
/// on its long side. Throws a [FormatException] saying what is wrong.
Future<ui.Image> decodeVideoImage(Uint8List bytes) async {
  if (bytes.length > VideoImageAsset.maxBytes) {
    throw FormatException('The image is over ${VideoImageAsset.maxBytes >> 20} MB.');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
  } catch (_) {
    buffer.dispose();
    throw const FormatException('This file is not an image C.A.W can read.');
  }
  try {
    final w = descriptor.width, h = descriptor.height;
    if (w <= 0 || h <= 0) throw const FormatException('The image has no pixels.');
    if (w > VideoImageAsset.maxSide || h > VideoImageAsset.maxSide || w * h > VideoImageAsset.maxPixels) {
      throw FormatException('The image is $w × $h; at most ${VideoImageAsset.maxSide} on a side and '
          '${VideoImageAsset.maxPixels ~/ 1000000} megapixels.');
    }
    final k = math.min(1.0, VideoImageAsset.keepSide / math.max(w, h));
    final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (w * k).round()), targetHeight: math.max(1, (h * k).round()));
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
}

/// Copies the image at [source] into [dir] as `<id>.<ext>` after checking it decodes within the limits; the asset,
/// with its decoded size. Throws a [FormatException] for a file that isn't a usable image.
Future<(VideoImageAsset, ui.Image)> importVideoImage(String source, Directory dir, String id) async {
  final file = File(source);
  final ext = source.split('.').last.toLowerCase();
  if (!VideoImageAsset.extensions.contains(ext)) {
    throw FormatException('Pick a ${VideoImageAsset.extensions.join(', ')} image.');
  }
  final length = await file.length();
  if (length > VideoImageAsset.maxBytes) throw FormatException('The image is over ${VideoImageAsset.maxBytes >> 20} MB.');
  final bytes = await file.readAsBytes();
  final image = await decodeVideoImage(bytes);
  await dir.create(recursive: true);
  final name = '$id.$ext';
  await File('${dir.path}${Platform.pathSeparator}$name').writeAsBytes(bytes, flush: true);
  final base = source.split(RegExp(r'[/\\]')).last;
  return (VideoImageAsset(id: id, file: name, name: base, width: image.width, height: image.height), image);
}

/// Asks for an image with the system file picker; its path, or null when none was picked.
Future<String?> pickVideoImage() async {
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: VideoImageAsset.extensions);
  return f?.path;
}

/// The decoded images of a video, by asset id, loaded from its assets folder (bounded by the asset limits).
class VideoImageStore extends ChangeNotifier {
  VideoImageStore(this.dir);
  final Directory dir;
  final Map<String, ui.Image> images = {};

  /// Assets that couldn't be read, with why (a missing or damaged file).
  final Map<String, String> problems = {};
  final Set<String> _loading = {};

  /// Decodes every asset of [assets] not loaded yet; drops the ones no longer listed.
  Future<void> load(List<VideoImageAsset> assets) async {
    final ids = {for (final a in assets) a.id};
    for (final id in [...images.keys]) {
      if (!ids.contains(id)) images.remove(id)?.dispose();
    }
    for (final a in assets) {
      if (images.containsKey(a.id) || problems.containsKey(a.id) || !_loading.add(a.id)) continue;
      try {
        if (!VideoImageAsset.fileName.hasMatch(a.file)) throw const FormatException('not an image name');
        final f = File('${dir.path}${Platform.pathSeparator}${a.file}');
        if (await f.length() > VideoImageAsset.maxBytes) throw const FormatException('too large');
        images[a.id] = await decodeVideoImage(await f.readAsBytes());
      } catch (e) {
        problems[a.id] = e is FormatException ? e.message : 'missing';
      } finally {
        _loading.remove(a.id);
      }
    }
    notifyListeners();
  }

  /// Takes an image already decoded (just imported).
  void put(String id, ui.Image image) {
    images.remove(id)?.dispose();
    images[id] = image;
    problems.remove(id);
    notifyListeners();
  }

  @override
  void dispose() {
    for (final i in images.values) {
      i.dispose();
    }
    images.clear();
    super.dispose();
  }
}
