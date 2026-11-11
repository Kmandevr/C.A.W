// fx-dynamics: the curves the Dynamics, Multiband, Clipper and Phase distortion UIs draw (the engine's maths, for drawing).
import 'dart:math' as math;

/// The gain in dB of a soft-knee segment [over] dB past its threshold, changing [slope] dB per dB past it, with a
/// quadratic across a knee [knee] dB wide (builtin_fx_dynamics.cpp's kneeGain).
double kneeGain(double over, double slope, double knee) {
  if (2 * over <= -knee) return 0;
  if (2 * over < knee) {
    final t = over + 0.5 * knee;
    return slope * t * t / (2 * knee);
  }
  return slope * over;
}

/// The Dynamics' steady gain change in dB at [level] dB: upward compression or expansion below the low threshold,
/// compression or upward expansion above the high one, held within ±[range].
double dynamicsGainDb(double level,
    {required double lowThr, required double lowRatio, required double highThr, required double highRatio,
    double knee = 6, double range = 24}) {
  final lo = math.min(lowThr, highThr);
  final g = kneeGain(lo - level, 1 - 1 / lowRatio, knee) + kneeGain(level - highThr, 1 / highRatio - 1, knee);
  return g.clamp(-range, range).toDouble();
}

/// A ratio as the UI writes it: 4:1, 1:2 below 1, ∞ at the top.
String ratioLabel(double r, {double infinite = 49.9}) {
  if (r >= infinite) return '∞:1';
  if (r >= 1) return '${r.toStringAsFixed(r < 10 ? 1 : 0)}:1';
  final inv = 1 / r;
  return '1:${inv.toStringAsFixed(inv < 10 ? 1 : 0)}';
}

double _tanh(double x) {
  final e = math.exp(2 * x.clamp(-20.0, 20.0));
  return (e - 1) / (e + 1);
}

/// The clipper's curve for u = input / ceiling (output / ceiling): 0 hard, 1 soft (a quadratic knee [softness]
/// wide), 2 analog (an asymmetric tanh) — builtin_fx_drive.cpp's clipCurve.
double clipCurve(int mode, double u, double softness) {
  final a = u.abs(), s = u < 0 ? -1.0 : 1.0;
  switch (mode) {
    case 1:
      if (softness < 1e-6) return a >= 1 ? s : u;
      final t = 1 - softness;
      if (a <= t) return u;
      if (a >= 1 + softness) return s;
      final d = a - t;
      return s * (t + d - d * d / (4 * softness));
    case 2:
      const tb = 0.09966799462495582;
      return (_tanh(u + 0.1) - tb) / (1 + tb);
    default:
      return a >= 1 ? s : u;
  }
}

/// One cycle of a sine through the phase distortion at [drive] (0..1) and [bias], for drawing: the input read late
/// or early by its own (normalized) value. [phase] 0..1.
double phaseDistorted(double phase, double drive, double bias) {
  final swing = drive * 0.25; // a quarter cycle at full drive: the look, exaggerated (the engine's swing is in frames)
  final m = (math.sin(2 * math.pi * phase) + bias).clamp(-1.0, 1.0);
  return math.sin(2 * math.pi * (phase - swing * m));
}
