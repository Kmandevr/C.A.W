// Offline signal measurements for the component testing suite: levels, FFT spectra, THD+N, IR length, latency.
#pragma once

#include <complex>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace caw::analysis {

// 20 * log10(linear); minus infinity for 0 (JSON writers print it as null).
double toDb(double linear) noexcept;

// In-place radix-2 FFT (size must be a power of two, at least 1). The inverse is scaled by 1/size.
void fft(std::vector<std::complex<double>>& data, bool inverse);
std::size_t nextPowerOfTwo(std::size_t n) noexcept;

// One channel's levels. Non-finite samples are counted and read as 0; a denormal is a non-zero
// subnormal float. dB values are dBFS by amplitude (a full-scale sine: peak 0 dB, RMS -3.01 dB).
struct Levels {
    double peak = 0, rms = 0, dc = 0;  // linear
    double peakDb = 0, rmsDb = 0, crestDb = 0;
    uint64_t nan = 0, inf = 0, denormal = 0;
};
Levels levels(const float* x, std::size_t n) noexcept;

// Correlation of left and right (1 identical, 0 unrelated, -1 inverted; 0 when either is silent)
// and width = rms(side) / (rms(mid) + rms(side)) with mid = (l + r) / 2 and side = (l - r) / 2:
// 0 mono, 0.5 equal mid and side, 1 fully out of phase; 0 when both are silent.
struct Stereo {
    double correlation = 0, width = 0;
};
Stereo stereo(const float* l, const float* r, std::size_t n) noexcept;

// A least-squares fit of a sine of known frequency (plus DC) to x: what is left is distortion and
// noise. thdN = rms(residual) / rms(fitted sine); thd = sqrt(sum of harmonics 2..maxHarmonic below
// Nyquist, each fitted the same way) / fundamental amplitude. Ratios, not percent. valid is false
// when the fundamental is silent or n is too short for a cycle.
struct SineDistortion {
    bool valid = false;
    double fundamental = 0;  // fitted amplitude, linear
    double thd = 0, thdN = 0;
};
SineDistortion sineDistortion(const float* x, std::size_t n, double frequency, double sampleRate,
                              int maxHarmonic = 10);

// One past the last index whose |x| exceeds threshold; 0 when none does.
std::size_t endAbove(const float* x, std::size_t n, double threshold) noexcept;

// The lag (0..maxLag frames) at which sig best matches ref, by FFT cross-correlation (largest
// |correlation|). -1 when either is silent.
int64_t findLag(const float* ref, const float* sig, std::size_t n, std::size_t maxLag);

// A level per frequency band, the bands spaced bandsPerOctave to the octave from 20 Hz up to Nyquist.
struct Band {
    double hz = 0, db = 0;
};
// Magnitude spectrum of x's first fftSize frames (a power of two; zero-padded if n is shorter), Hann
// window over the frames there are (not the padding), scaled so a full-scale sine reads 0 dB: each band
// gives its loudest bin.
std::vector<Band> spectrumBands(const float* x, std::size_t n, std::size_t fftSize, double sampleRate,
                                double bandsPerOctave);
// Transfer magnitude out/in per band: 10 * log10(sum |Out|^2 / sum |In|^2) over the band's bins, of
// the first n frames (zero-padded to a power of two). Bands where the input has under -60 dB of its
// loudest band's power are left out (a sweep's ends, a sine's empty bands).
std::vector<Band> frequencyResponse(const float* in, const float* out, std::size_t n, double sampleRate,
                                    double bandsPerOctave);

}  // namespace caw::analysis
