// When an editor's view may follow the playhead (owner, 2026-11-11): never while the user is zooming, scrolling or
// dragging, and only once a quiet spell (Settings › Editing › Resume after, 2.5 s by default) has passed since the
// last interaction or selection change; "Never" waits for the next Play.
import 'package:flutter/gestures.dart';

import '../model/settings.dart';

/// One editor's follow rule. Feed it the user's interactions ([hold] and [release] around fingers or buttons down,
/// [touch] for a wheel turn, a scroll or a changed selection) and ask [allows] before moving the view.
class FollowGate {
  FollowGate(this.settings);
  final Settings settings;

  /// The quiet spell before following resumes, by default.
  static const resumeDefault = Duration(milliseconds: 2500);

  int _held = 0;
  DateTime? _last;
  bool _stuck = false, _wasPlaying = false, _wasOn = true;

  // The gesture binding's clock: the wall clock, and a test's fake clock under test.
  static DateTime get _now => GestureBinding.instance.samplingClock.now();

  /// The quiet spell the settings ask for; null for Never.
  Duration? get resume => settings.followResume <= 0
      ? null : Duration(milliseconds: (settings.followResume * 1000).round());

  /// An interaction just now (a wheel turn, a scroll, a selection changed).
  void touch() {
    _last = _now;
    if (resume == null) _stuck = true;
  }

  /// An interaction starts (a finger or button down); it lasts until [release].
  void hold() {
    _held++;
    touch();
  }

  void release() {
    if (_held > 0) _held--;
    touch();
  }

  /// Whether an interaction is under way now.
  bool get busy => _held > 0;

  /// Whether the view may follow the playhead now. Following starts again with the next Play, or when the setting
  /// is turned back on.
  bool allows({required bool playing}) {
    final on = settings.followPlayhead;
    if ((playing && !_wasPlaying) || (on && !_wasOn)) _stuck = false;
    _wasPlaying = playing;
    _wasOn = on;
    if (!on || !playing || _held > 0 || _stuck) return false;
    final last = _last, wait = resume;
    return last == null || wait == null || _now.difference(last) >= wait;
  }
}
