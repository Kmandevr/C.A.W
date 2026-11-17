// Fakes for the sample library tests: linked folders on a plain directory (counting metadata reads) and the preview voice.
import 'package:caw/engine/sample_preview_io.dart';
import 'package:caw/model/sample_meta.dart';
import 'package:caw/platform/linked_folders.dart';

/// Desktop folder access without isolates or pickers: lists and reads synchronously, counts what it read.
class FakeFolderAccess extends DesktopFolderAccess {
  PickedFolder? nextPick;
  final List<String> metaReads = [];
  final List<String> released = [];
  bool reach = true;

  @override
  Future<PickedFolder?> pick() async => nextPick;

  @override
  Future<void> release(String location) async => released.add(location);

  @override
  Future<FolderListing> list(String location) async => listDirectorySync(location);

  @override
  Future<List<SampleMeta?>> readMeta(String location, List<ListedFile> files) async {
    metaReads.addAll(files.map((f) => f.rel));
    return [
      for (final f in files)
        switch (joinInside(location, f.rel)) {
          final p? => readSampleMetaFile(p),
          null => null,
        },
    ];
  }

  @override
  Future<bool> reachable(String location) async => reach && await super.reachable(location);
}

class FakePreview implements SamplePreviewIo {
  final List<Map<String, Object?>> plays = [];
  int stops = 0;
  final List<double> seeks = [];
  double volume = 0.8;
  PreviewState now = const PreviewState();
  Map<String, dynamic> keyAnswer = {'ok': true, 'sure': true, 'tonic': 9, 'mode': 'minor', 'confidence': 0.6};
  final List<String> keyAsked = [];

  @override
  Future<Map<String, dynamic>> play(String path,
      {double startSeconds = 0, double ratio = 1, String sync = 'now', bool loop = false, double? volume}) async {
    plays.add({'path': path, 'start': startSeconds, 'ratio': ratio, 'sync': sync, 'loop': loop, 'volume': volume});
    now = PreviewState(playing: true, seconds: startSeconds, length: 2, seq: plays.length);
    return {'ok': true, 'seconds': 2.0, 'stretch_ratio': ratio};
  }

  @override
  void stop() {
    stops++;
    now = PreviewState(seq: now.seq);
  }

  @override
  void seek(double seconds) => seeks.add(seconds);

  @override
  void setVolume(double v) => volume = v;

  @override
  PreviewState state() => now;

  @override
  Future<Map<String, dynamic>> key(String path) async {
    keyAsked.add(path);
    return keyAnswer;
  }
}
