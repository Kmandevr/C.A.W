# Development-time estimate of the realistic instruments' bodies from VSCO 2 Community Edition (CC0): each instrument's recorded spectrum over the model's at the same notes, as peaking bands in src/<family>_bodies.inc.
#
# Not part of the build or CI. Needs Python 3 with numpy and soundfile (BSD; development only) and:
#   - a checkout of github.com/sgossner/VSCO-2-CE (CC0 1.0) with the folders FAMILIES names;
#   - the model's renders, body off, at every semitone (float32 mono at 48 kHz, <instrument>_<key>.f32: written by
#     `caw_tests <family>_body_renders` with CAW_<FAMILY>_RENDERS=<dir>; docs/engine.md, "Nightingale", "Curlew").
#
#   python3 engine/tools/instrument_bodies.py <family> <VSCO-2-CE> <renders dir> <engine dir>
#   python3 engine/tools/instrument_bodies.py refit <family> <engine dir>
#
# `refit` (2026-11-25) refits the committed bands without the recordings: their own response, held within +-9 dB and its
# power mean over the instrument's range brought to 0 dB, fitted again with bounded bands (+-9 dB, Q 0.4..3, each at
# least a third of an octave above the last). The first fits sat at their +-20 dB bounds in cancelling pairs (the
# trumpet's -19.9 dB at 695 Hz and +20 dB at 705 Hz), an ill-conditioned cascade whose sharp peaks rang.
#
# The method (no free body or radiation response for these instruments exists under CC0 or CC-BY; the owner,
# 2026-11-24: "estimated from CC0/CC-BY recordings of the instruments"): for every recorded note (its key measured,
# not read from the file name, whose octaves are not always right), the levels of its partials
# over 0.4..2 s (Welch-averaged spectra, the strongest bin within 3 % of each harmonic) against the model's
# partials at the same note, the note's own mean taken off (its loudness and the microphone are not the body);
# pooled over every note, in twelfths of an octave (the median of each), smoothed over a sixth of an octave, held
# within +-18 dB, its level change over the notes 0 dB on average (Body changes the colour, not the level), then fitted with 8
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
FAMILIES = {  # family: (instrument index, folder, the model's range, the array's name)
    'nightingale': [
        (0, 'Strings/Solo Violin/Arco Vib', 55, 100, 'kViolin'),
        (1, 'Strings/Viola Section/susvib', 48, 88, 'kViola'),
        (2, 'Strings/Cello Section/susvib', 36, 76, 'kCello'),
        (3, 'Strings/Solo Contrabass/SusNV', 28, 60, 'kBass'),
    ],
    'curlew': [
        (0, 'Woodwinds/Flute/susNV', 60, 96, 'kFlute'),
        (1, 'Woodwinds/Clarinet/susLong', 50, 89, 'kClarinet'),
        (3, 'Brass/Trumpet/sus', 54, 82, 'kTrumpet'),
        (4, 'Brass/Tenor Trombone/sus', 40, 72, 'kTrombone'),
        (5, 'Brass/F Horn/sus', 41, 77, 'kHorn'),
    ],
}
BANDS = 8
TOP_HZ = 16000.0  # no band above this: it holds its shape at 44.1 kHz and up
GAIN, QLO, QHI, SPACING = 9.0, 0.4, 3.0, 2 ** (1 / 3)
RANGES = {'kViolin': (55, 100), 'kViola': (48, 88), 'kCello': (36, 76), 'kBass': (28, 60), 'kFlute': (60, 96),
          'kClarinet': (50, 89), 'kTrumpet': (54, 82), 'kTrombone': (40, 72), 'kHorn': (41, 77)}


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


def shelf_db(f, hz, q, db, high, sr=SR):
    # The RBJ low or high shelf's magnitude in dB at frequencies f (as the engine's Biquad::lowShelf / highShelf).
    w0 = 2 * np.pi * hz / sr
    A = 10 ** (db / 40)
    al = np.sin(w0) / (2 * q)
    c = np.cos(w0)
    r = 2 * np.sqrt(A) * al
    s = -1 if high else 1
    b = np.array([A * ((A + 1) - s * (A - 1) * c + r), s * 2 * A * ((A - 1) - s * (A + 1) * c), A * ((A + 1) - s * (A - 1) * c - r)])
    a = np.array([(A + 1) + s * (A - 1) * c + r, -s * 2 * ((A - 1) + s * (A + 1) * c), (A + 1) + s * (A - 1) * c - r])
    z = np.exp(-1j * 2 * np.pi * f / sr)
    H = (b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z)
    return 20 * np.log10(np.abs(H))


SHELF_GAIN, PEAKS = 18.0, 9


def highpass_db(f, hz, q=0.707, sr=SR):
    # The RBJ high-pass's magnitude in dB (as the engine's Biquad::highpass).
    w0 = 2 * np.pi * hz / sr
    al = np.sin(w0) / (2 * q)
    c = np.cos(w0)
    b = np.array([(1 + c) / 2, -(1 + c), (1 + c) / 2])
    a = np.array([1 + al, -2 * c, 1 - al])
    z = np.exp(-1j * 2 * np.pi * f / sr)
    H = (b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z)
    return 20 * np.log10(np.abs(H))


def fit_shaped(edges, target, lo, hi, hp):
    # A low and a high shelf (within +-SHELF_GAIN dB: the broad tilt a body puts on the string, its low end and its
    # top) and PEAKS peaking filters within +-GAIN dB, Q QLO..QHI, each SPACING or more above the last (its
    # resonances), over a fixed high-pass at `hp` Hz (0.7 times the instrument's lowest note: nothing radiates under
    # its lowest string, and without it a low shelf lifted the bowed model's sub-bass push at the note's start into a
    # thump 15 dB over the tone). Bounded, so no two bands cancel each other into a ringing pair (fit_bounded's reason).
    m = (edges >= lo) & (edges <= hi)
    f, t = edges[m], target[m]
    n = PEAKS
    span = np.log(hi / lo)
    step = max(np.exp(span / n) / SPACING - 1.0, 1e-3)

    def unpack(x):
        # Every band under TOP_HZ (2026-11-26, the audio review: three violin peaks sat at the old 20 kHz cap, beyond
        # the fitted data, where an RBJ peak's shape moves with the sample rate: 96 kHz was 8 dB darker at 14 kHz).
        hz = np.minimum(lo / SPACING * np.cumprod(SPACING * (1.0 + np.exp(x[:n]))), TOP_HZ)
        return hz, x[n:2 * n], np.exp(x[2 * n:3 * n]), x[3 * n:]

    def resid(x):
        hz, db, q, sh = unpack(x)
        y = highpass_db(f, hp) + shelf_db(f, np.exp(sh[0]), 0.707, sh[1], False) + shelf_db(f, np.exp(sh[2]), 0.707, sh[3], True)
        # (and a light cost on each peak's gain, 0.1 dB a dB: a band the data does not need goes to 0 dB instead of
        # sitting at the cap in a cancelling pair)
        return np.concatenate([y + sum(peak_db(f, hz[k], q[k], db[k]) for k in range(n)) - t, 0.1 * db])
    x0 = np.concatenate([np.full(n, np.log(step)), np.zeros(n), np.zeros(n), [np.log(200.0), 0.0, np.log(4000.0), 0.0]])
    lob = np.concatenate([np.full(n, -6.0), np.full(n, -GAIN), np.full(n, np.log(QLO)),
                          [np.log(60.0), -SHELF_GAIN, np.log(1500.0), -SHELF_GAIN]])
    hib = np.concatenate([np.full(n, 2.0), np.full(n, GAIN), np.full(n, np.log(QHI)),
                          [np.log(600.0), SHELF_GAIN, np.log(12000.0), SHELF_GAIN]])
    r = least_squares(resid, np.clip(x0, lob + 1e-6, hib - 1e-6), bounds=(lob, hib))
    e = resid(r.x)[:len(f)]
    hz, db, q, sh = unpack(r.x)
    bands = [(float(hp), 0.707, 0.0, 'kHighPass'), (float(np.exp(sh[0])), 0.707, float(sh[1]), 'kLowShelf'),
             (float(np.exp(sh[2])), 0.707, float(sh[3]), 'kHighShelf')]
    bands += [(float(h), float(qq), float(d), None) for h, qq, d in zip(hz, q, db)]
    return bands, (float(np.sqrt(np.mean(e * e))), float(np.abs(e).max()))


def fit_bands(edges, curve, lo=60.0, hi=14000.0):
    # BANDS peaking filters fitted to the curve over lo..hi (least squares in dB, log-spaced starts).
    m = (edges >= lo) & (edges <= hi)
    f, target = edges[m], curve[m]
    hz0 = np.geomspace(max(80, lo), min(12000, hi), BANDS)
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


def fit_bounded(edges, target, lo, hi):
    # BANDS peaking filters within +-GAIN dB and Q QLO..QHI, each SPACING or more above the last (the first from lo).
    m = (edges >= lo) & (edges <= hi)
    f, t = edges[m], target[m]
    span = np.log(hi / lo)
    step = max(np.exp(span / BANDS) / SPACING - 1.0, 1e-3)
    x0 = np.concatenate([np.full(BANDS, np.log(step)), np.zeros(BANDS), np.log(np.full(BANDS, 1.0))])

    def unpack(x):
        hz = lo / SPACING * np.cumprod(SPACING * (1.0 + np.exp(x[:BANDS])))
        return hz, x[BANDS:2 * BANDS], np.exp(x[2 * BANDS:])

    def resid(x):
        hz, db, q = unpack(x)
        return sum(peak_db(f, min(hz[k], 20000.0), q[k], db[k]) for k in range(BANDS)) - t
    lob = np.concatenate([np.full(BANDS, -6.0), np.full(BANDS, -GAIN), np.log(np.full(BANDS, QLO))])
    hib = np.concatenate([np.full(BANDS, 2.0), np.full(BANDS, GAIN), np.log(np.full(BANDS, QHI))])
    r = least_squares(resid, np.clip(x0, lob + 1e-6, hib - 1e-6), bounds=(lob, hib))
    e = resid(r.x)
    hz, db, q = unpack(r.x)
    return [(min(h, 20000.0), qq, d) for h, qq, d in zip(hz, q, db)], (float(np.sqrt(np.mean(e * e))), float(np.abs(e).max()))


def refit(family, eng):
    path = os.path.join(eng, 'src', '%s_bodies.inc' % family)
    text = open(path).read()
    edges = 50.0 * 2 ** (np.arange(0, 24 * np.log2(16000 / 50.0) + 1) / 24.0)
    names, arrays = [], {}
    for name, body in re.findall(r'const BodyBand (\w+)\[\] = \{(.*?)\};', text, re.S):
        bands = [tuple(float(v) for v in b) for b in re.findall(r'\{([\d.e+-]+)f, ([\d.e+-]+)f, ([\d.e+-]+)f\}', body)]
        curve = sum(peak_db(edges, hz, q, db) for hz, q, db in bands)
        k0, k1 = RANGES[name]
        lo, hi = 440.0 * 2 ** ((k0 - 69) / 12.0), min(14000.0, 40 * 440.0 * 2 ** ((k1 - 69) / 12.0))
        m = (edges >= lo) & (edges <= hi)
        curve = np.clip(curve, -GAIN, GAIN)
        for _ in range(4):  # the power mean over the instrument's partials' range 0 dB (Body is colour, not level)
            curve -= 10 * np.log10(np.mean(10 ** (curve[m] / 10)))
            curve = np.clip(curve, -GAIN, GAIN)
        fit, err = fit_bounded(edges, curve, lo, hi)
        names.append(name)
        arrays[name] = fit
        print('%s: refit within %.2f dB rms, %.2f dB worst; old %.1f..%.1f dB' % (name, err[0], err[1],
              min(b[2] for b in bands), max(b[2] for b in bands)))
    with open(path, 'w') as f:
        f.write('// Generated by tools/instrument_bodies.py %s from VSCO' % family + ' 2 Community Edition (CC0 1.0): each instrument\'s recorded\n')
        f.write('// spectrum over the model\'s at the same notes, as %d peaking bands {Hz, Q, dB} (RBJ, designed at the rate);\n' % BANDS)
        f.write('// refit (`refit`, 2026-11-25) within +-%.0f dB, Q %.1f..%.1f, a third of an octave apart, its power mean 0 dB.\n' % (GAIN, QLO, QHI))
        f.write('// clang-format off\n')
        for name in names:
            f.write('const BodyBand %s[] = {\n' % name)
            for hz, q, db in arrays[name]:
                f.write('    {%.2ff, %.4ff, %.3ff},\n' % (hz, q, db))
            f.write('};\n')
        f.write('// clang-format on\n')


def midi(note):
    n = {'C': 0, 'C#': 1, 'D': 2, 'D#': 3, 'E': 4, 'F': 5, 'F#': 6, 'G': 7, 'G#': 8, 'A': 9, 'A#': 10, 'B': 11}
    return 12 * (int(note[-1]) + 1) + n[note[:-1]]


def measured_key(x, sr):
    # The note's key from its spectrum: the key whose first 8 harmonics hold the most (log) energy, E0..D#7.
    f, p = psd(x, sr)
    a = np.sqrt(p)
    keys = np.arange(16, 100)
    score = []
    for k in keys:
        fk = 440.0 * 2 ** ((k - 69) / 12.0)
        s = 0.0
        for n in range(1, 9):
            m = (f > n * fk * 0.985) & (f < n * fk * 1.015)
            if m.any():
                s += np.log10(a[m].max() + 1e-12)
        score.append(s)
    return int(keys[int(np.argmax(score))])


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
    if sys.argv[1] == 'refit':
        refit(sys.argv[2], sys.argv[3])
        return
    family, vsco, renders, eng = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    edges = 50.0 * 2 ** (np.arange(0, 12 * np.log2(16000 / 50.0) + 1) / 12.0)
    arrays = {}
    names = []
    for inst, folder, lo, hi, name in FAMILIES[family]:
        names.append(name)
        pts, notes = [], []
        for path in sorted(glob.glob(os.path.join(vsco, folder, '*.wav'))):
            x, sr = sf.read(path)
            if x.ndim > 1:
                x = x.mean(axis=1)
            m = re.search(r'_([A-G]#?\d)_', os.path.basename(path))
            named = midi(m.group(1)) if m else None
            key = measured_key(x[int(0.4 * sr):int(2.0 * sr)], sr)
            if named is not None and key % 12 != named % 12:  # the harmonic sum chose a fifth or so: trust the name's
                key = named + 12 * round((key - named) / 12.0)  # pitch class, the measured octave
            mod = os.path.join(renders, '%d_%d.f32' % (inst, key))
            if not (lo <= key <= hi and os.path.exists(mod)):
                continue
            y = np.fromfile(mod, dtype=np.float32).astype(np.float64)
            f0 = 440.0 * 2 ** ((key - 69) / 12.0)
            a = partials(x[int(0.4 * sr):int(2.0 * sr)], sr, f0)
            b = dict(partials(y[int(0.4 * SR):int(2.0 * SR)], SR, f0))
            d = [(f, la - b[f], b[f]) for f, la in a if f in b and np.isfinite(la - b[f])]
            if len(d) < 3:
                continue
            mean = np.mean([v for _, v, _ in d])
            notes.append([(f, mp) for f, _, mp in d])  # the model's partials (Hz, dB): what the level check weighs
            pts += [(f, v - mean) for f, v, _ in d]
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
        # Body changes the colour, not the level: the mean over the notes of each one's level change, its model partials
        # weighted by their own power, is 0 dB (a plain mean of the curve, over a band or over the partials, let the
        # strong low partials of a flute or a horn move its level up to 18 dB).
        def shift(c):
            ch = []
            for nt in notes:
                f = np.array([x for x, _ in nt]); w = 10 ** (np.array([y for _, y in nt]) / 10)
                g = 10 ** (np.interp(np.log2(f), np.log2(edges), c) / 10)
                ch.append(10 * np.log10((w * g).sum() / w.sum()))
            return float(np.mean(ch))
        for _ in range(3):
            curve -= shift(curve)
        # Fitted only where the instrument has partials (the curve's ends beyond them are extrapolated).
        flo, fhi = max(60.0, np.percentile(pts[:, 0], 1)), min(14000.0, np.percentile(pts[:, 0], 99))
        if family == 'nightingale':  # 2026-11-25: shelves and peaks, so the low end the recordings have is kept
            bands, err = fit_shaped(edges, curve, flo, fhi, 0.7 * 440.0 * 2 ** ((lo - 69) / 12.0))
        else:
            bands, err = fit_bands(edges, curve, flo, fhi)
            bands = [(hz, q, db, None) for hz, q, db in bands]
        arrays[name] = bands
        print('%s: fit within %.2f dB rms, %.2f dB worst' % (name, err[0], err[1]))
        print('%s: %d points from %s; curve %.1f..%.1f dB' % (name, len(pts), folder, curve.min(), curve.max()))
    with open(os.path.join(eng, 'src', '%s_bodies.inc' % family), 'w') as f:
        f.write('// Generated by tools/instrument_bodies.py %s from VSCO' % family + ' 2 Community Edition (CC0 1.0): each instrument\'s recorded\n')
        f.write('// spectrum over the model\'s at the same notes, as bands {Hz, Q, dB} (RBJ peaks; for the strings first a high-pass\n')
        f.write('// at 0.7 times the lowest note, a low and a high shelf: fit_shaped), designed at the rate.\n')
        f.write('// clang-format off\n')
        for name in names:
            f.write('const BodyBand %s[] = {\n' % name)
            for hz, q, db, kind in arrays[name]:
                if kind:
                    f.write('    {%.2ff, %.4ff, %.3ff, BodyBand::%s},\n' % (hz, q, db, kind))
                else:
                    f.write('    {%.2ff, %.4ff, %.3ff},\n' % (hz, q, db))
            f.write('};\n')
        f.write('// clang-format on\n')


if __name__ == '__main__':
    main()
