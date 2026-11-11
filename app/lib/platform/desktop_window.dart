// The desktop app window: its title, and files opened with the app or dropped on it (Windows: `caw/window`, flutter_window.cpp).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The app's own window on a desktop: a title to set, and paths the system hands the app (a file given on the
/// command line, files dropped from Explorer). Elsewhere it does nothing.
abstract class DesktopWindow {
  /// Shows "C.A.W — [projectName]" as the window's title.
  void setProjectTitle(String projectName);

  /// Files to open: each event is the paths of one launch or one drop.
  Stream<List<String>> get openedFiles;

  /// The window for this platform, set at start (main.dart); tests can replace it.
  static DesktopWindow current = const NoDesktopWindow();
}

/// The window title shown for [projectName].
String windowTitleFor(String projectName) => projectName.trim().isEmpty ? 'C.A.W' : 'C.A.W — ${projectName.trim()}';

/// Phones and platforms without a window channel.
class NoDesktopWindow implements DesktopWindow {
  const NoDesktopWindow();

  @override
  void setProjectTitle(String projectName) {}

  @override
  Stream<List<String>> get openedFiles => const Stream.empty();
}

/// Windows: the runner answers `setTitle` and `takeLaunchFiles` (the paths given on the command line), and calls
/// `openFiles` with the paths of files dropped on the window.
class WindowsDesktopWindow implements DesktopWindow {
  WindowsDesktopWindow({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('caw/window') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openFiles') _add(call.arguments);
      return null;
    });
    // The launch's files, asked for once Dart listens (the runner keeps them until then).
    scheduleMicrotask(() async {
      try {
        _add(await _channel.invokeMethod<List<Object?>>('takeLaunchFiles'));
      } catch (_) {
        // An old runner without the channel: no launch files.
      }
    });
  }

  final MethodChannel _channel;
  final StreamController<List<String>> _files = StreamController.broadcast();
  final List<List<String>> _early = []; // files that came before anyone listened
  String? _title;

  void _add(Object? args) {
    final paths = [if (args is List) for (final p in args) if (p is String && p.isNotEmpty) p];
    if (paths.isEmpty) return;
    if (_files.hasListener) {
      _files.add(paths);
    } else {
      _early.add(paths);
    }
  }

  @override
  void setProjectTitle(String projectName) {
    final t = windowTitleFor(projectName);
    if (t == _title) return;
    _title = t;
    _channel.invokeMethod<void>('setTitle', {'title': t}).catchError((Object _) {});
  }

  @override
  Stream<List<String>> get openedFiles {
    if (_early.isNotEmpty) {
      final early = List.of(_early);
      _early.clear();
      // Handed to the first listener after it subscribes.
      scheduleMicrotask(() => early.forEach(_files.add));
    }
    return _files.stream;
  }
}

/// The window for this platform.
DesktopWindow platformDesktopWindow() =>
    !kIsWeb && Platform.isWindows ? WindowsDesktopWindow() : const NoDesktopWindow();
