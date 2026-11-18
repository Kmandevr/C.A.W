// What follows the audio on screen (playhead, meters, clip highlights, the piano-roll cursor, the video preview) is
// drawn for the moment its frame lights up, a little early (owner, 2026-11-17, #236: "lean early"): the frame's
// display latency plus a small early bias, on top of the output latency the playhead already subtracts.
import 'dart:math' as math;
import 'dart:ui' as ui;

/// The early bias in µs: what the screen shows leads what is heard by this much (owner, 2026-11-17: 0 to 10 ms,
/// early rather than late). 5 ms covers what stays uncertain after the compensation: the output latency is read
/// at a random point of the audio callback's cycle (half a burst either way: about 1 to 2 ms on a phone's
/// low-latency path, **[Assumption]**, more on Bluetooth) and a frame's display latency is a whole number of
/// refreshes (half of a 120 Hz frame is 4.2 ms). Visuals ahead of the sound are the side people forgive:
/// **[Fact]** ITU-R BT.1359-1 (1998) puts detectability at about 45 ms of sound ahead of the picture but 125 ms
/// behind it (secondary sources, e.g. Wikipedia "Audio-to-video synchronization", read 2026-11-17).
const earlyBiasUs = 5000;

/// Refresh periods from a Flutter frame's build to its light on the screen. **[Assumption]** about two on Android
/// (Choreographer's vsync starts the build, the raster thread draws it, SurfaceFlinger latches it at the next vsync
/// and the panel scans it out after that), not measured on the owner's S22+.
const displayFrames = 2.0;

/// The display latency in µs at [hz] (60 Hz when unknown or out of range).
int displayLatencyUs(double hz) {
  final rate = hz.isFinite && hz >= 20 && hz <= 500 ? hz : 60.0;
  return (displayFrames * 1e6 / rate).round();
}

/// How far ahead of now what follows the audio is drawn: the display latency plus [earlyBiasUs].
int visualLeadUs(double hz) => displayLatencyUs(hz) + earlyBiasUs;

/// The screen's rate and the lead it gives. The app hands in the rate it asks for while things move (the
/// frame-rate setting, main.dart); tests set their own.
class AvSync {
  AvSync({double Function()? refreshHz}) : refreshHz = refreshHz ?? screenHz;

  double Function() refreshHz;

  /// The first display's rate as `dart:ui` reports it (0 when there is none).
  static double screenHz() {
    final displays = ui.PlatformDispatcher.instance.displays;
    return displays.isEmpty ? 0 : displays.first.refreshRate;
  }

  /// The lead in µs ([visualLeadUs] at [refreshHz]).
  int get leadUs => visualLeadUs(refreshHz());
}

/// The heard moment a meter shows best at [nowUs]: [leadUs] ahead, moved back by the output latency to when that
/// sound was rendered. A meter read stands for what was rendered since the read before it, so the read to show is
/// the first one taken at or after this moment (MeterTimeline.covering).
int meterRenderUs({required int nowUs, required int leadUs, required int outputLatencyUs}) =>
    nowUs + leadUs - outputLatencyUs;

/// Where to draw something that only moves on the engine's reads (about every [readIntervalUs]): the moment half
/// an interval on, so the error between reads is as early as it is late, plus the lead.
int heldDrawUs({required int nowUs, required int leadUs, required int readIntervalUs}) =>
    nowUs + leadUs + readIntervalUs ~/ 2;

/// A frame's start on the app's clock: the vsync that began it, not whenever its build got to run (#241). A playhead
/// worked out from the build's own time moves on by however late the UI thread started the frame, so at 120 Hz a
/// late frame jumps it ahead and the next lags; from the vsync it moves an even step a frame, and the display
/// latency ([displayFrames]) is counted from there.
///
/// The vsync time is on the engine's clock, not the app's: the offset between them is the smallest gap seen (a
/// build never starts before its vsync), allowed to creep up by [creepUs] a frame so a slow drift between the clocks
/// is followed.
class FrameTime {
  /// How far the offset may rise each frame.
  static const creepUs = 20;

  /// A vsync further back than this is not this frame's (a call between frames): now is used.
  static const staleUs = 50000;

  int? _offset; // app clock minus vsync clock
  int? _vsync, _start; // the last frame's vsync and its start, for every call in that frame

  /// The frame's start for a call at [nowUs] (the app's clock) in a frame whose vsync came at [vsyncUs] (its own
  /// clock; null outside a frame). Every call in one frame gets the same answer.
  int at({required int nowUs, required int? vsyncUs}) {
    if (vsyncUs == null) return nowUs;
    if (vsyncUs == _vsync) return _start!;
    final gap = nowUs - vsyncUs;
    final o = _offset;
    final next = o == null ? gap : math.min(o + creepUs, gap);
    _offset = next;
    final t = vsyncUs + next;
    _vsync = vsyncUs;
    return _start = nowUs - t > staleUs || t > nowUs ? nowUs : t;
  }
}
