# Development-time estimate of Nightingale's bodies from VSCO 2 Community Edition (CC0): each instrument's recorded spectrum over the model's at the same notes, as a minimum-phase filter in src/nightingale_bodies.inc.
#
# Not part of the build or CI. Needs Python 3 with numpy and soundfile (BSD; development only) and:
#   - a checkout of github.com/sgossner/VSCO-2-CE (CC0 1.0) with Strings/Solo Violin/Arco Vib, Strings/Viola
#     Section/susvib, Strings/Cello Section/susvib and Strings/Solo Contrabass/SusNV;
#   - the model's renders, body off, at every semitone (float32 mono at 48 kHz, <instrument>_<key>.f32: written by
#     engine/tests' probe in the commit that added this script; see docs/engine.md, "Nightingale").
#
#   python3 engine/tools/nightingale_bodies.py <VSCO-2-CE> <renders dir> <engine dir>
#
# The method (no free violin, viola, cello or bass body response exists under CC0 or CC-BY; the owner, 2026-11-24:
# "estimated from CC0/CC-BY recordings of the instruments"): for every recorded note, the levels of its partials
# over 0.4..2 s (Welch-averaged spectra, the strongest bin within 3 % of each harmonic) against the model's
# partials at the same note, the note's own mean taken off (its loudness and the microphone are not the body);
# pooled over every note, in twelfths of an octave (the median of each), smoothed over a sixth of an octave, held
# within +-18 dB, 0 dB on average over 200..4000 Hz (Body changes the colour, not the level), then fitted with 8
# peaking filters (least squares in dB over 60 Hz..14 kHz): minimum phase, no latency, and a fraction of a
# convolution's cost (a 512-tap one cost twice the strings themselves).
import glob
import os
import re
import sys

import numpy as np
import soundfile as sf
from scipy.optimize import least_squares

SR = 48000
SETS = [  # instrument index, folder, the model's range
    (0, 'Strings/Solo Violin/Arco Vib', 55, 100),
    (1, 'Strings/Viola Section/susvib', 48, 88),
    (2, 'Strings/Cello Section/susvib', 36, 76),
    (3, 'Strings/Solo Contrabass/SusNV', 28, 60),
]
NAMES = ['kViolin', 'kViola', 'kCello', 'kBass']
BANDS = 8


def peak_db(f, hz, q, db, sr=SR):
    # The RBJ peaking filter's magnitude in dB at frequencies f (as the engine's Biquad::peak designs it).
    w0 = 2 * np.pi * hz / sr
    A = 10 ** (db / 40)
    al = np.sin(w0) / (2 * q)
    c = np.cos(w0)
    b = np.array([1 + al * A, -2 * c, 1 - al * A])
    a = np.array([1 + al / A, -2 * c, 1 - al / A])
    z = np.exp(-1j * 2 * np.pi * f / sr)
    H = (b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z)
    return 20 * np.log10(np.abs(H))


def fit_bands(edges, curve):
    # BANDS peaking filters fitted to the curve over 60 Hz..14 kHz (least squares in dB, log-spaced starts).
    m = (edges >= 60) & (edges <= 14000)
    f, target = edges[m], curve[m]
    hz0 = np.geomspace(80, 12000, BANDS)
    x0 = np.concatenate([np.log(hz0), np.zeros(BANDS), np.log(np.full(BANDS, 1.2))])
    def resid(x):
        hz, db, q = np.exp(x[:BANDS]), x[BANDS:2 * BANDS], np.exp(x[2 * BANDS:])
        return sum(peak_db(f, hz[k], q[k], db[k]) for k in range(BANDS)) - target
    lo = np.concatenate([np.log(np.full(BANDS, 40.0)), np.full(BANDS, -20.0), np.log(np.full(BANDS, 0.3))])
    hi = np.concatenate([np.log(np.full(BANDS, 16000.0)), np.full(BANDS, 20.0), np.log(np.full(BANDS, 6.0))])
    r = least_squares(resid, x0, bounds=(lo, hi))
    e = resid(r.x)
    hz, db, q = np.exp(r.x[:BANDS]), r.x[BANDS:2 * BANDS], np.exp(r.x[2 * BANDS:])
    return sorted(zip(hz, q, db)), (float(np.sqrt(np.mean(e * e))), float(np.abs(e).max()))


def midi(note):
    n = {'C': 0, 'C#': 1, 'D': 2, 'D#': 3, 'E': 4, 'F': 5, 'F#': 6, 'G': 7, 'G#': 8, 'A': 9, 'A#': 10, 'B': 11}
    return 12 * (int(note[-1]) + 1) + n[note[:-1]]


def psd(x, sr):
    win = 8192 if sr <= 48000 else 16384
    w = np.hanning(win)
    acc, k = None, 0
    for a in range(0, len(x) - win, win // 4):
        s = np.abs(np.fft.rfft(x[a:a + win] * w)) ** 2
        acc = s if acc is None else acc + s
        k += 1
    return np.fft.rfftfreq(win, 1 / sr), acc / max(k, 1)


def partials(x, sr, f0):
    f, p = psd(x, sr)
    out = []
    n = 1
    while n * f0 < min(16000, 0.45 * sr):
        m = (f > n * f0 * 0.97) & (f < n * f0 * 1.03)
        if m.any():
            out.append((n * f0, 10 * np.log10(p[m].max() + 1e-20)))
        n += 1
    return out


def main():
    vsco, renders, eng = sys.argv[1], sys.argv[2], sys.argv[3]
    edges = 50.0 * 2 ** (np.arange(0, 12 * np.log2(16000 / 50.0) + 1) / 12.0)
    arrays = {}
    for inst, folder, lo, hi in SETS:
        pts = []
        for path in sorted(glob.glob(os.path.join(vsco, folder, '*.wav'))):
            m = re.search(r'_([A-G]#?\d)_', os.path.basename(path))
            if not m:
                continue
            key = midi(m.group(1))
            mod = os.path.join(renders, '%d_%d.f32' % (inst, key))
            if not (lo <= key <= hi and os.path.exists(mod)):
                continue
            x, sr = sf.read(path)
            if x.ndim > 1:
                x = x.mean(axis=1)
            y = np.fromfile(mod, dtype=np.float32).astype(np.float64)
            f0 = 440.0 * 2 ** ((key - 69) / 12.0)
            a = partials(x[int(0.4 * sr):int(2.0 * sr)], sr, f0)
            b = dict(partials(y[int(0.4 * SR):int(2.0 * SR)], SR, f0))
            d = [(f, la - b[f]) for f, la in a if f in b and np.isfinite(la - b[f])]
            if len(d) < 3:
                continue
            mean = np.mean([v for _, v in d])
            pts += [(f, v - mean) for f, v in d]
        pts = np.array(pts)
        curve = np.full(len(edges), np.nan)
        for i, e in enumerate(edges):
            m = (pts[:, 0] >= e * 2 ** (-1 / 24)) & (pts[:, 0] < e * 2 ** (1 / 24))
            if m.sum() >= 3:
                curve[i] = np.median(pts[m, 1])
        good = np.isfinite(curve)
        curve = np.interp(np.arange(len(edges)), np.flatnonzero(good), curve[good])
        k = np.exp(-0.5 * (np.arange(-4, 5) / 2.0) ** 2)  # a sixth of an octave (2 twelfths as sigma)
        curve = np.convolve(np.pad(curve, 4, mode='edge'), k / k.sum(), mode='valid')
        curve = np.clip(curve, -18, 18)
        band = (edges >= 200) & (edges <= 4000)
        curve -= curve[band].mean()
        bands, err = fit_bands(edges, curve)
        arrays[NAMES[inst]] = bands
        print('%s: fit within %.2f dB rms, %.2f dB worst' % (NAMES[inst], err[0], err[1]))
        print('%s: %d points from %s; curve %.1f..%.1f dB' % (NAMES[inst], len(pts), folder, curve.min(), curve.max()))
    with open(os.path.join(eng, 'src', 'nightingale_bodies.inc'), 'w') as f:
        f.write('// Generated by tools/nightingale_bodies.py from VSCO 2 Community Edition (CC0 1.0): each instrument\'s recorded\n')
        f.write('// spectrum over the model\'s at the same notes, as %d peaking bands {Hz, Q, dB} (RBJ, designed at the rate).\n' % BANDS)
        f.write('// clang-format off\n')
        for name in NAMES:
            f.write('const BodyBand %s[] = {\n' % name)
            for hz, q, db in arrays[name]:
                f.write('    {%.2ff, %.4ff, %.3ff},\n' % (hz, q, db))
            f.write('};\n')
        f.write('// clang-format on\n')


if __name__ == '__main__':
    main()
