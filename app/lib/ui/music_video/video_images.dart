// The music video's images (owner, 2026-11-12): one picked with the system file picker is copied into the project's
// video assets and decoded with limits (file size, sides and pixels checked before decoding, kept at most 2048 px
// on its long side); the images in use are kept decoded, within a memory budget, for the preview and the render.
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

/// Whether [bytes] are a JPEG or a WebP, the formats decoded straight at a reduced size. Other formats (PNG, GIF,
/// BMP) are decoded at full size and then scaled, so their whole pixel count is in memory for a moment
/// (an assumption from Skia's SkCodec, where only the JPEG and WebP codecs report scaled dimensions; not measured).
bool decodesScaled(Uint8List bytes) =>
    (bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) ||
    (bytes.length >= 12 && String.fromCharCodes(bytes, 0, 4) == 'RIFF' && String.fromCharCodes(bytes, 8, 12) == 'WEBP');

/// [bytes] decoded as an image within [VideoImageAsset]'s limits: the encoded size, its sides and pixel count are
/// checked from its header before any pixels are decoded (a lower pixel count for formats decoded at full size), and
/// it is decoded at most [keepSide] on its long side. Throws a [FormatException] saying what is wrong.
Future<ui.Image> decodeVideoImage(Uint8List bytes, {int keepSide = VideoImageAsset.keepSide}) async {
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
    final scaled = decodesScaled(bytes);
    final maxPixels = scaled ? VideoImageAsset.maxPixels : VideoImageAsset.maxPixelsFullDecode;
    if (w > VideoImageAsset.maxSide || h > VideoImageAsset.maxSide || w * h > maxPixels) {
      throw FormatException('The image is $w × $h; at most ${VideoImageAsset.maxSide} on a side and '
          '${maxPixels ~/ 1000000} megapixels${scaled ? '' : ' (JPEG and WebP may be larger)'}.');
    }
    final k = math.min(1.0, keepSide / math.max(w, h));
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

/// A new asset id (`img<n>`) never given out in [dir] before: one past the highest number among [assets] and the
/// files in the folder, so a file still there (an asset an undo can bring back) is never overwritten.
Future<String> nextVideoAssetId(List<VideoImageAsset> assets, Directory dir) async {
  final number = RegExp(r'^img(\d{1,9})(\.|$)');
  var top = 0;
  void see(String name) {
    final m = number.firstMatch(name);
    if (m != null) top = math.max(top, int.parse(m.group(1)!));
  }

  for (final a in assets) {
    see(a.id);
    see(a.file);
  }
  try {
    if (await dir.exists()) {
      await for (final e in dir.list(followLinks: false)) {
        see(e.uri.pathSegments.lastWhere((x) => x.isNotEmpty, orElse: () => ''));
      }
    }
  } on FileSystemException {
    // Unreadable: the assets alone decide.
  }
  return 'img${top + 1}';
}

/// Deletes the image files in [dir] (only names [VideoImageAsset.fileName] takes, only files directly in it) that no
/// asset of [keep] uses: the ones whose asset was removed. Run when the video's editing ends, as an undo could bring
/// an asset back before then.
Future<void> sweepVideoAssets(Directory dir, List<VideoImageAsset> keep) async {
  final used = {for (final a in keep) a.file};
  try {
    if (!await dir.exists()) return;
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!VideoImageAsset.fileName.hasMatch(name) || used.contains(name)) continue;
      try {
        await File('${dir.path}${Platform.pathSeparator}$name').delete();
      } on FileSystemException {
        // Left for the next sweep.
      }
    }
  } on FileSystemException {
    // The folder can't be read: nothing to clear.
  }
}

/// The decoded images of a video, by asset id, loaded from its assets folder: only the assets the video's layers
/// use, and all of them within [budgetBytes] together (each decoded at its share of it, at most
/// [VideoImageAsset.keepSide] on its long side; re-decoded smaller when more come into use, larger when fewer).
class VideoImageStore extends ChangeNotifier {
  VideoImageStore(this.dir, {this.budgetBytes = defaultBudget});
  final Directory dir;
  final int budgetBytes;

  /// 128 MB of decoded pixels: eight images at the full 2048 × 2048.
  static const defaultBudget = 128 << 20;

  final Map<String, ui.Image> images = {};

  /// Assets that couldn't be read, with why (a missing or damaged file).
  final Map<String, String> problems = {};

  /// The long-side limit each image was decoded with.
  final Map<String, int> _sides = {};
  Future<void> _last = Future.value();
  int _running = 0;
  bool _disposed = false;

  /// The long side each of [count] images is decoded at to keep them within [budget] bytes together.
  static int sideFor(int count, int budget) =>
      math.min(VideoImageAsset.keepSide, math.max(64, math.sqrt(budget / math.max(1, count) / 4).floor()));

  /// Decodes the assets of [assets] in [used] (every one when null) that aren't loaded at their share of the budget,
  /// and drops the rest. Loads run one after another; the future completes when this one has.
  Future<void> load(List<VideoImageAsset> assets, {Set<String>? used}) {
    // With none running it starts now (not chained on a finished future, which keeps the zone it was made in).
    final run = _running == 0 ? _load(assets, used) : _last.then((_) => _load(assets, used));
    _running++;
    return _last = run.catchError((Object _) {}).whenComplete(() => _running--);
  }

  Future<void> _load(List<VideoImageAsset> assets, Set<String>? used) async {
    if (_disposed) return;
    final listed = {for (final a in assets) a.id};
    final want = [for (final a in assets) if (used == null || used.contains(a.id)) a];
    final wanted = {for (final a in want) a.id};
    var changed = false;
    for (final id in [...images.keys]) {
      if (!wanted.contains(id)) {
        images.remove(id)?.dispose();
        _sides.remove(id);
        changed = true;
      }
    }
    final before = problems.length;
    problems.removeWhere((id, _) => !listed.contains(id));
    changed |= problems.length != before;
    final side = sideFor(want.length, budgetBytes);
    for (final a in want) {
      if (problems.containsKey(a.id)) continue;
      final have = images[a.id];
      if (have != null) {
        final long = math.max(have.width, have.height);
        final was = _sides[a.id] ?? side;
        // Kept unless too large for its share now, or cut by a smaller share than it has now.
        if (long <= side && !(long >= was && side > was)) continue;
      }
      try {
        if (!VideoImageAsset.fileName.hasMatch(a.file)) throw const FormatException('not an image name');
        final f = File('${dir.path}${Platform.pathSeparator}${a.file}');
        if (await f.length() > VideoImageAsset.maxBytes) throw const FormatException('too large');
        final bytes = await f.readAsBytes();
        if (_disposed) return;
        final image = await decodeVideoImage(bytes, keepSide: side);
        if (_disposed) {
          // The store went while this decoded: the late image is let go here.
          image.dispose();
          return;
        }
        images.remove(a.id)?.dispose();
        images[a.id] = image;
        _sides[a.id] = side;
      } catch (e) {
        if (_disposed) return;
        problems[a.id] = e is FormatException ? e.message : 'missing';
      }
      changed = true;
    }
    if (changed && !_disposed) notifyListeners();
  }

  /// Takes an image already decoded (just imported); the next [load] fits it to its share.
  void put(String id, ui.Image image) {
    if (_disposed) {
      image.dispose();
      return;
    }
    images.remove(id)?.dispose();
    images[id] = image;
    _sides[id] = VideoImageAsset.keepSide;
    problems.remove(id);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final i in images.values) {
      i.dispose();
    }
    images.clear();
    super.dispose();
  }
}
