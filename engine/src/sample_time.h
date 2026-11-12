// Where steps and seconds land in samples, worked out the same way on every platform (built strict: sample_time.cpp).
#pragma once

#include <cstdint>

// Note, clip, loop and automation timing is exact to the sample on every platform (docs/decisions.md, 2026-11-12),
// but the engine's own code is built with -ffp-contract=fast and -fassociative-math (CMakeLists.txt): Arm64 would
// fuse `at + part * sub` or `x * stepFrames + 0.5` into one rounding where x86-64 and MSVC round twice, and a repeat
// on a half sample would move by one. So every position the engine turns into a sample index comes from here:
// sample_time.cpp is compiled with the strict flags (no contraction, no reassociation), and the functions are kept
// out of line so link-time optimisation can't merge them into fast code. They run per event or per chunk, not per
// sample (the metronome's beatOffset, once per sample while it clicks, is the exception).
#if defined(_MSC_VER) && !defined(__clang__)
#define CAW_STRICT_FN __declspec(noinline)
#else
#define CAW_STRICT_FN __attribute__((noinline))
#endif

namespace caw::sampletime {

// Samples per sixteenth step: 60 * rate / (bpm * 4).
CAW_STRICT_FN double stepFrames(double sampleRate, double bpm) noexcept;
// The step where repeat `sub` of a note at `at`, `len` steps long, cut into `ratchet` repeats, starts:
// at + (len / ratchet) * sub.
CAW_STRICT_FN double ratchetStep(double at, double len, int ratchet, int sub) noexcept;
// floor(x * scale + 0.5): a step count times samples per step, or seconds times a rate, to the nearest sample (as a
// double, so a caller can range-check it before converting).
CAW_STRICT_FN double roundFrames(double x, double scale) noexcept;
// floor(k * (steps * stepFrames) + 0.5): where pass `k` of a layer `steps` long starts.
CAW_STRICT_FN double roundRepeat(int64_t k, double steps, double stepFrames) noexcept;
// timeline + (step - from): a source step `step` moved to a clip placed at `timeline` that starts at source step `from`.
CAW_STRICT_FN double clipStep(double timeline, double step, double from) noexcept;
// pos - beat * beatFrames: how far past the start of beat `beat` sample `pos` is.
CAW_STRICT_FN double beatOffset(double pos, double beat, double beatFrames) noexcept;

}  // namespace caw::sampletime
