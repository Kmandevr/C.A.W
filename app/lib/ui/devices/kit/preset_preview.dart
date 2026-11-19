// The preset browser's live Preview: loops the song over the loop, the time selection or the clip under the device's track while each tapped preset plays; Cancel puts everything back, OK keeps the preset as one undo step.
import 'dart:math' as math;

import '../../../model/device_target.dart';
import 'presets.dart';

/// One preview session of [target]'s presets. While it runs the project's history is held open, so whatever the
/// tapped presets change ends as one undo step on [keep], and as none on [cancel].
class PresetPreview {
  PresetPreview._(this.target, this._values, this._params, this._state, this._stateVersion, this._preset, this._remembered,
      this._loop, this._startedPlaying);

  final DeviceTarget target;
  final Map<String, double> _values;
  final Map<String, double> _params; // the entry's own map, as saved (defaults left out)
  final String? _state;
  final int _stateVersion;
  final String? _preset;
  final (String, String)? _remembered;
  final (bool, int, int)? _loop; // the loop range before, when the preview set one
  final bool _startedPlaying;
  bool _done = false;

  bool get running => !_done;

  /// What the preview loops: the loop range when it is on, else the time selection, else the clip under the
  /// playhead on the device's track (or its first clip). Null: the song as it plays.
  static (int, int)? rangeFor(DeviceTarget t) {
    final s = t.state, p = s.project;
    if (p.loopsRange) return null;
    final a = s.timeSelectionStart, b = s.timeSelectionEnd;
    if (a != null && b != null && a != b) return (math.min(a, b), math.max(a, b));
    final layer = t.layer;
    if (layer == null) return null;
    final spans = <(int, int)>[
      for (final c in layer.clips) (c.startSteps, c.startSteps + c.lengthSteps),
      for (final c in layer.audioClips) (c.startSteps.floor(), (c.startSteps + c.lengthAt(p.bpm)).ceil()),
    ]..removeWhere((r) => r.$2 <= r.$1);
    if (spans.isEmpty) return null;
    spans.sort((x, y) => x.$1.compareTo(y.$1));
    final at = s.pausedStep ?? 0;
    return spans.where((r) => r.$1 <= at && at < r.$2).firstOrNull ?? spans.first;
  }

  /// Starts previewing: holds the history, sets the loop it plays and starts playback when stopped.
  static PresetPreview start(DeviceTarget t) {
    final s = t.state;
    final info = t.info;
    final use = t.use;
    s.holdHistory(true);
    final values = {
      if (info != null) for (final p in info.parameters) p.id: t.value(p.id),
    };
    final range = rangeFor(t);
    (bool, int, int)? loop;
    if (range != null) {
      final p = s.project;
      loop = (p.loopRange, p.loopStartSteps, p.loopEndSteps);
      s.editProject((p) {
        p.loopStartSteps = range.$1;
        p.loopEndSteps = range.$2;
        p.loopRange = true;
      });
      s.seekTo(range.$1.toDouble());
    }
    final play = !s.transportOn && s.engine != null;
    if (play) s.togglePlay();
    return PresetPreview._(t, values, Map.of(use?.params ?? const {}), use?.state, use?.stateVersion ?? 1, use?.preset, DevicePresets.remembered(t),
        loop, play);
  }

  /// Loads [preset] live (no undo step of its own while the preview runs).
  void apply(DevicePreset preset) {
    if (!_done) DevicePresets.apply(target, preset);
  }

  /// Puts the device's values, its loop and the transport back as they were: no undo step.
  void cancel() {
    if (_done) return;
    final use = target.use;
    if (use != null) {
      use.state = _state;
      use.stateVersion = _stateVersion;
      use.preset = _preset;
    }
    target.setAll(_values);
    // The values the engine plays are back; the entry's map too, key for key, so the project is as it was.
    target.use?.params
      ?..clear()
      ..addAll(_params);
    target.commit();
    DevicePresets.restoreRemembered(target, _remembered);
    _finish();
  }

  /// Keeps the preset now loaded: the session's edits settle as one undo step.
  void keep() {
    if (_done) return;
    _finish();
  }

  void _finish() {
    _done = true;
    final s = target.state;
    if (_startedPlaying && s.transportOn) s.stopPlayback();
    final loop = _loop;
    if (loop != null) {
      s.editProject((p) {
        p.loopRange = loop.$1;
        p.loopStartSteps = loop.$2;
        p.loopEndSteps = loop.$3;
      });
    }
    s.holdHistory(false);
  }
}
