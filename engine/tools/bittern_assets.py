# Development-time measurement of Bittern's pipe organ from VCSL's (CC0) recorded organ: fits each pipe family's steady and speaking spectra, cuts the recorded speech noise, and writes engine/assets/bittern/speech.flac and src/bittern_bank.inc.
#
# Not part of the build or CI: it needs the Versilian Community Sample Library's pipe organ
# (github.com/sgossner/VCSL, CC0 1.0: "Aerophones/Edge-blown Aerophones/Pipe Organ", 66 files, about 140 MB) and
# Python 3 with numpy, scipy and soundfile (BSD licences; development tools only, nothing of them ships). Run it again
# only to change what is measured; the build reads its two outputs.
#
#   python3 -I engine/tools/bittern_assets.py <VCSL checkout> <engine dir>
#
# What it measures (docs/engine.md, "Bittern"; the names are an octave under the 8' pitch, measured: "C1" sounds
# 65.4 Hz in every folder):
# - the registrations: Quiet (manual 3, a stopped flute 8': odd harmonics), Loud (manual 3's chorus on a stopped 16':
#   integer harmonics of the 8' plus the 16''s odd ones), Quiet Pedal (an open flute 8': every harmonic, falling fast)
#   and Loud Pedal (16', 8', 4');
# - each recorded key's steady spectrum (3..8 s: the power within 0.6 % of each harmonic of the 8' pitch, so detuned
#   ranks are summed), its speech (each harmonic's level over the first 600 ms, by heterodyning: the harmonic times
#   e^{-i w t}, low-passed by a Hann window of about 40 ms), its pitch and level wander (3..8 s), its release and its
#   noise (what is left when every harmonic's envelope is taken out);
# - each family's spectrum as a smooth surface over harmonic number and the pipe's pitch: a quadratic in log2 n and
#   log2 f0 (the stopped flute with its even harmonics on their own surface), fitted in dB to every key at once, so
#   one microphone's room colouring of single partials averages out. The principal is fitted to the Loud chorus as
#   three equal ranks (8', 4', 2' summed in power) [assumption: the recording holds them together];
# - each family's speaking spectrum: the level of each harmonic over the first 50 % of its rise against its steady
#   level, as a smooth tilt over the harmonic's frequency (upper harmonics speak first or last);
# - the recorded speech: the residual (the recording less every harmonic's envelope) over the first 400 ms of every
#   recorded key, faded, normalised per clip and stored as 16-bit at 44.1 kHz.
import glob
import os
import sys

import numpy as np
import soundfile as sf
from scipy.optimize import least_squares
from scipy.signal import fftconvolve, lfilter

SR = 44100
NOTES = {'C': 0, 'C#': 1, 'D': 2, 'D#': 3, 'E': 4, 'F': 5, 'F#': 6, 'G': 7, 'G#': 8, 'A': 9, 'A#': 10, 'B': 11}
ORGAN = 'Aerophones/Edge-blown Aerophones/Pipe Organ'
# The registrations: folder, the family it measures (bittern_organ.h's Family), whether it has the 16''s odd harmonics.
REGS = [('Quiet', 'stopped', False), ('Loud', 'principal', True), ('Quiet Pedal', 'open', False), ('Loud Pedal', 'pedal', True)]
CLIP_S, PRE_S, FADE_S = 0.40, 0.004, 0.040
HARM = 32            # harmonics measured per pipe
ZONES, ZONE_ST, ZONE_LO = 18, 6, 12.0  # the tables' zones: 6 semitones of sounding pitch each from MIDI 12


def keyof(path):
    n = os.path.basename(path).replace('.wav', '').replace('_rr1', '').split('_')[-1]
    return 12 * (int(n[-1]) + 1) + NOTES[n[:-1]] + 12, n  # +12: the names are an octave under the 8' pitch


def hz(key):
    return 440.0 * 2.0 ** ((key - 69.0) / 12.0)


def lowpass(z, bw):
    L = int(SR / bw) | 1
    w = np.hanning(L)
    return fftconvolve(z, w / w.sum(), mode='same')


def load(path):
    x, sr = sf.read(path, always_2d=True)
    assert sr == SR, path
    m = x.mean(axis=1)
    m = lfilter([1, -1], [1, -0.9995], m)  # DC and rumble out
    return np.concatenate([np.zeros(SR // 10), m])  # 100 ms of silence first, so every attack has its lead-in


def analyse(path, sixteen):
    key, name = keyof(path)
    m = load(path)
    f0n = hz(key)
    s0, s1 = int(3 * SR), int(8 * SR)
    st = m[s0:s1]
    rms = np.sqrt(np.mean(st ** 2))
    env = np.sqrt(np.maximum(lowpass(m * m, 200), 0))
    on = int(np.argmax(env > rms * 0.01))
    N = 1 << 22
    S = np.abs(np.fft.rfft(st * np.hanning(len(st)), N)) ** 2
    df = SR / N
    # The 8' pitch: the strongest of harmonics 1..8 under 3 kHz, its peak refined.
    best = (0, f0n)
    for h in range(1, 9):
        if f0n * h > 3000:
            break
        i0, i1 = int(f0n * h * 0.985 / df), int(f0n * h * 1.015 / df)
        j = i0 + int(np.argmax(S[i0:i1]))
        if S[j] > best[0]:
            best = (S[j], j * df / h)
    f0 = best[1]

    def power(fh):
        tol = max(1.5, fh * 0.006)
        i0, i1 = int((fh - tol) / df), int((fh + tol) / df) + 1
        return float(np.sum(S[i0:i1])) if i1 < len(S) else 0.0
    steady = np.array([power(f0 * h) for h in range(1, HARM + 1)])
    half = np.array([power(f0 * (h - 0.5)) for h in range(1, HARM + 1)]) if sixteen else None
    # Each harmonic's envelope over the first 600 ms (and its steady level from 3..4 s), by heterodyne.
    bw = min(40.0, 0.4 * f0)
    lo, hi = max(0, on - int(0.05 * SR)), on + int(0.6 * SR)
    t = np.arange(len(m)) / SR
    a0, a1 = s0, s0 + SR
    freqs = [f0 * h for h in range(1, 400) if f0 * h < 18000]
    if sixteen:
        freqs += [f0 * (h - 0.5) for h in range(1, 400) if f0 * (h - 0.5) < 18000]
    harm = np.zeros(hi - lo)
    harmS = np.zeros(a1 - a0)
    rise, early = {}, {}
    for f in freqs:
        z = lowpass(m[lo:hi] * np.exp(-2j * np.pi * f * t[lo:hi]), bw) * 2
        harm += np.real(z * np.exp(2j * np.pi * f * t[lo:hi]))
        zs = lowpass(m[a0:a1] * np.exp(-2j * np.pi * f * t[a0:a1]), bw) * 2
        harmS += np.real(zs * np.exp(2j * np.pi * f * t[a0:a1]))
        h = f / f0
        if abs(h - round(h)) < 1e-6 and round(h) <= 8:
            a = np.abs(z[on - lo:])
            ss = np.median(np.abs(zs[int(0.1 * SR):-int(0.1 * SR)]))
            rise[int(round(h))] = (ss, a)
    res = m[lo:hi] - harm
    resS = (m[a0:a1] - harmS)[int(0.1 * SR):-int(0.1 * SR)]
    noise = float(np.sqrt(np.mean(resS ** 2)) / max(1e-12, np.sqrt(np.mean(harmS[int(0.1 * SR):-int(0.1 * SR)] ** 2))))
    # The noise's spectrum (its centroid, over the steady part).
    R = np.abs(np.fft.rfft(resS * np.hanning(len(resS)))) ** 2
    fr = np.fft.rfftfreq(len(resS), 1 / SR)
    centroid = float(np.sum(R * fr) / np.sum(R))
    # The rise: the strongest harmonic's 10/50/90 % times; each harmonic's level over the first half of its rise.
    hb = max(rise, key=lambda h: rise[h][0])
    ssb, ab = rise[hb]
    t10, t50, t90 = [int(np.argmax(ab > f * ssb)) / SR for f in (0.1, 0.5, 0.9)]
    n50 = max(int(t50 * SR), int(0.01 * SR))
    for h, (ss, a) in rise.items():
        if ss > 0.03 * ssb:
            early[h] = float(np.mean(a[:n50]) / ss)
    # The wander: the strongest harmonic's pitch and level, 3..8 s.
    z = lowpass(m[s0:s1] * np.exp(-2j * np.pi * hb * f0 * t[s0:s1]), min(25.0, 0.4 * f0)) * 2
    ph = np.unwrap(np.angle(z))
    inst = np.gradient(ph) * SR / (2 * np.pi) / hb
    cents = 1200 * np.log2((f0 + inst) / f0)[SR // 10:-SR // 10]
    lvl = 20 * np.log10(np.abs(z) / np.median(np.abs(z)))[SR // 10:-SR // 10]

    def rate(v):
        v = v[::441] - np.mean(v[::441])
        P = np.abs(np.fft.rfft(v * np.hanning(len(v)))) ** 2
        f = np.fft.rfftfreq(len(v), 0.01)
        P[f < 0.1] = 0
        return float(f[np.argmax(P)])
    # The release: the key's last frame over half the steady level, then -20 dB.
    za = np.abs(lowpass(m * np.exp(-2j * np.pi * hb * f0 * t), min(25.0, 0.4 * f0)))
    ref = np.median(za[s0:s1])
    off = int(np.where(za > 0.5 * ref)[0][-1])
    r20 = int(np.argmax(za[off:] < 0.1 * ref)) / SR
    # The speech clip: the residual from 4 ms before the onset, faded in over 4 ms and out over 40 ms.
    c0 = on - lo - int(PRE_S * SR)
    clip = res[c0:c0 + int(CLIP_S * SR)].copy()
    # Only what the speech adds over the steady residual (the pipe's wind and what of the other ranks the envelopes
    # missed): each 10 ms's energy less the steady part's, so the clip ends where the speech does (the model plays
    # the steady wind itself) and never stops audibly.
    e = np.maximum(lowpass(clip * clip, 100), 1e-20)
    steadyE = float(np.mean(resS ** 2))
    clip *= np.sqrt(np.maximum(0.0, e - 1.5 * steadyE) / e)
    fi, fo = int(PRE_S * SR), int(FADE_S * SR)
    clip[:fi] *= 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, fi))
    clip[-fo:] *= 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, fo))
    toneRms = float(np.sqrt(np.mean(harmS ** 2)))
    return dict(key=key, name=name, f0=f0, cents=1200 * np.log2(f0 / f0n), steady=steady, half=half, t10=t10, t50=t50,
                t90=t90, early=early, noise=noise, centroid=centroid, wanderCt=float(np.std(cents)),
                wanderDb=float(np.std(lvl)), rateCt=rate(cents), rateDb=rate(lvl), release20=r20, clip=clip,
                clipRms=float(np.sqrt(np.mean(clip[:int(0.1 * SR)] ** 2))), toneRms=toneRms, path=path)


def surface(p, u, v):
    return p[0] + p[1] * u + p[2] * u * u + p[3] * v + p[4] * u * v + p[5] * v * v


def fit_family(rows, ranks, parity):
    # Fit L(h, f0) in dB: harmonic h of a key of 8' pitch f0 is the power sum over the ranks m (the 8' pitch's
    # multiples, e.g. 1, 2, 4) of the pipe surface at its own harmonic h / m and pitch m f0. `parity`: the stopped
    # flute's even harmonics on their own surface.
    data = []
    for r in rows:
        s = r['steady']
        top = s.max()
        for h in range(1, HARM + 1):
            f = r['f0'] * h
            if f > 12000 or s[h - 1] < top * 1e-6:
                continue
            data.append((h, r['f0'], 10 * np.log10(s[h - 1] / top), r['key']))
    data = np.array(data)
    keys = sorted(set(data[:, 3]))

    def model(p, h, f0):
        tot = np.zeros(len(h))
        for m in ranks:
            n = h / m
            ok = np.abs(n - np.round(n)) < 1e-6
            u, v = np.log2(np.maximum(n, 1)), np.log2(m * f0 / 440.0)
            db = surface(p[:6], u, v)
            if parity:
                db = np.where((np.round(n) % 2 == 0), surface(p[6:12], u, v), db)
            tot += np.where(ok, 10 ** (db / 10), 0)
        return 10 * np.log10(tot + 1e-30)
    off = {k: i for i, k in enumerate(keys)}
    npar = 12 if parity else 6

    def resid(q):
        p, g = q[:npar], q[npar:]
        pred = model(p, data[:, 0], data[:, 1]) + np.array([g[off[k]] for k in data[:, 3]])
        e = pred - data[:, 2]
        w = np.where(data[:, 2] > -50, 1.0, 0.3)  # partials near the floor count less
        return e * w
    q0 = np.zeros(npar + len(keys))
    q0[1] = -12
    if parity:
        q0[6] = -30
    sol = least_squares(resid, q0, loss='soft_l1', f_scale=6.0)
    rmsErr = float(np.sqrt(np.mean(resid(sol.x) ** 2)))
    return sol.x[:npar], rmsErr


def pipe_db(p, parity, h, f0):
    u, v = np.log2(h), np.log2(f0 / 440.0)
    if parity and h % 2 == 0:
        return surface(p[6:12], u, v)
    return surface(p[:6], u, v)


def flt(x):
    t = '%.6g' % x
    return t + ('f' if ('.' in t or 'e' in t) else '.0f')


def main():
    src, eng = sys.argv[1], sys.argv[2]
    folder = os.path.join(src, ORGAN)
    out = {}
    for reg, fam, sixteen in REGS:
        rows = [analyse(p, sixteen) for p in sorted(glob.glob(os.path.join(folder, reg, '*.wav')), key=lambda p: keyof(p)[0])]
        out[reg] = rows
        print('== %s (%s)' % (reg, fam))
        for r in rows:
            e = ' '.join('%d:%+.0f' % (h, 20 * np.log10(r['early'][h] + 1e-9)) for h in sorted(r['early']))
            print('  %-4s key %d %7.2f Hz %+5.1f ct  rise %3.0f/%3.0f/%3.0f ms  wander %.2f ct @%.1f Hz, %.2f dB @%.1f Hz  '
                  'release -20 dB %3.0f ms  noise %5.1f dB (centroid %4.0f Hz)  speech %5.1f dB  early %s' % (
                      r['name'], r['key'], r['f0'], r['cents'], 1e3 * r['t10'], 1e3 * r['t50'], 1e3 * r['t90'],
                      r['wanderCt'], r['rateCt'], r['wanderDb'], r['rateDb'], 1e3 * r['release20'], 20 * np.log10(r['noise']),
                      r['centroid'], 20 * np.log10(r['clipRms'] / r['toneRms']), e))
        med = lambda k: float(np.median([r[k] for r in rows]))
        print('  median: tuning %+.1f ct, t50 %.0f ms, wander %.2f ct %.2f dB, noise %.1f dB, release -20 dB %.0f ms, speech %.1f dB' % (
            med('cents'), 1e3 * med('t50'), med('wanderCt'), med('wanderDb'), 20 * np.log10(med('noise')), 1e3 * med('release20'),
            float(np.median([20 * np.log10(r['clipRms'] / r['toneRms']) for r in rows]))))
    # The families' surfaces.
    fams = {}
    fams['stopped'] = fit_family(out['Quiet'], [1], True), True
    fams['open'] = fit_family(out['Quiet Pedal'], [1], False), False
    fams['principal'] = fit_family(out['Loud'], [1, 2, 4], False), False
    for k, ((p, err), par) in fams.items():
        print('%s surface rms error %.1f dB: %s' % (k, err, ' '.join('%.2f' % x for x in p)))
    # The pitch range each family was measured over (the surface is held at its ends outside it).
    rng = {'stopped': (min(r['f0'] for r in out['Quiet']), max(r['f0'] for r in out['Quiet'])),
           'open': (min(r['f0'] for r in out['Quiet Pedal']), max(r['f0'] for r in out['Quiet Pedal'])),
           'principal': (min(r['f0'] for r in out['Loud']), 4 * max(r['f0'] for r in out['Loud']))}
    # The speaking tilt per family: early/steady (dB) of each harmonic less the strongest's, against log2 of the
    # harmonic's frequency, a line.
    tilts = {}
    for reg, fam in (('Quiet', 'stopped'), ('Loud', 'principal'), ('Quiet Pedal', 'open')):
        xs, ys = [], []
        for r in out[reg]:
            if not r['early']:
                continue
            ref = max(r['early'].values())
            for h, e in r['early'].items():
                xs.append(np.log2(r['f0'] * h / 1000.0)), ys.append(20 * np.log10(e / ref))
        k, c = np.polyfit(xs, ys, 1)
        tilts[fam] = (float(k), float(c))
        print('%s speaking tilt: %+.1f dB per octave of the partial (at 1 kHz %+.1f dB)' % (fam, k, c))
    # The rise time against the pipe's pitch (a line in log-log, all flue registrations), and the other measures.
    xs, ys = [], []
    for reg in ('Quiet', 'Quiet Pedal'):
        for r in out[reg]:
            xs.append(np.log2(r['f0'] / 440.0)), ys.append(np.log2(max(0.01, r['t50'])))
    rk, rc = np.polyfit(xs, ys, 1)
    print('t50 = %.0f ms * (f / 440)^%.2f' % (1e3 * 2 ** rc, rk))
    # The tables' spectra: per family and zone (sounding pitch), harmonics 1..HARM in linear amplitude.
    lines = []
    for fam in ('stopped', 'open', 'principal'):
        (p, err), par = fams[fam]
        lo, hi = rng[fam]
        rows = []
        for z in range(ZONES):
            f0 = hz(ZONE_LO + ZONE_ST * (z + 0.5))
            fc = min(max(f0, lo), hi)
            db = np.array([pipe_db(p, par, h, fc) for h in range(1, HARM + 1)])
            db -= db.max()
            db = np.maximum(db, -90)
            rows.append('{' + ', '.join(flt(10 ** (d / 20)) for d in db) + '}')
        lines.append('    {  // %s (surface rms error %.1f dB, measured %.0f..%.0f Hz)\n        %s},' % (fam, err, lo, hi, ',\n        '.join(rows)))
    # The clips: Quiet (flutes), Loud (principals), the pedals.
    data, clips, manifest = [], [], []
    at = 0
    for gi, (reg, fam, _) in enumerate(REGS):
        for r in out[reg]:
            c = r['clip']
            peak = float(np.max(np.abs(c))) or 1.0
            q = np.round(c / peak * 32767.0).astype(np.int16)
            data.append(q)
            # scale: the clip's peak against the steady tone's RMS (the model's rank at level 1 is that RMS).
            clips.append('    {%d, %s, %du, %du, %s},' % (gi, flt(r['key']), at, len(q), flt(peak / r['toneRms'])))
            manifest.append((reg, os.path.basename(r['path']), os.path.getsize(r['path'])))
            at += len(q)
    os.makedirs(os.path.join(eng, 'assets', 'bittern'), exist_ok=True)
    flac = os.path.join(eng, 'assets', 'bittern', 'speech.flac')
    sf.write(flac, np.concatenate(data), SR, subtype='PCM_16', format='FLAC')
    st = {fam: tilts[fam] for fam in tilts}
    with open(os.path.join(eng, 'src', 'bittern_bank.inc'), 'w') as f:
        f.write('// Generated by tools/bittern_assets.py from the Versilian Community Sample Library\'s pipe organ (VCSL, CC0 1.0):\n')
        f.write('// the measured families\' spectra and the speech clips in assets/bittern/speech.flac. Included by bittern_tables.cpp\n')
        f.write('// and bittern_organ.h. Spectra: [family][zone][harmonic 1..32], linear, the strongest 1. Clips: {group (0 Quiet,\n')
        f.write('// 1 Loud, 2 Quiet Pedal, 3 Loud Pedal), its key (MIDI, the 8\' pitch), first frame, frames, peak over the tone\'s RMS}.\n')
        f.write('// clang-format off\n')
        f.write('inline constexpr int kMeasuredHarmonics = %d, kMeasuredZones = %d;\n' % (HARM, ZONES))
        f.write('inline constexpr float kMeasured[3][kMeasuredZones][kMeasuredHarmonics] = {\n' + '\n'.join(lines) + '\n};\n')
        f.write('// The speaking tilt (dB per octave of the partial over 1 kHz, and at 1 kHz): stopped, open, principal.\n')
        f.write('inline constexpr float kTilt[3][2] = {{%s, %s}, {%s, %s}, {%s, %s}};\n' % (
            flt(st['stopped'][0]), flt(st['stopped'][1]), flt(st['open'][0]), flt(st['open'][1]), flt(st['principal'][0]), flt(st['principal'][1])))
        f.write('// The rise to half the steady level: kRise0 seconds at 440 Hz times (f / 440)^kRiseExp.\n')
        f.write('inline constexpr double kRise0 = %s, kRiseExp = %s;\n' % (flt(2 ** rc), flt(rk)))
        flue = out['Quiet'] + out['Loud'] + out['Quiet Pedal']
        f.write('// The steady wind noise against the tone (dB, the median of the three flue registrations), and a single pipe\'s\n')
        f.write('// wander (the stopped flute\'s medians: pitch in cents, level in dB, standard deviations over 3..8 s).\n')
        f.write('inline constexpr double kNoiseDb = %s, kWanderCents = %s, kWanderDb = %s;\n' % (
            flt(float(np.median([20 * np.log10(r['noise']) for r in flue]))), flt(float(np.median([r['wanderCt'] for r in out['Quiet']]))),
            flt(float(np.median([r['wanderDb'] for r in out['Quiet']])))))
        f.write('struct SpeechClip {\n    int group;\n    float key;\n    uint32_t first, frames;\n    float scale;\n};\n')
        f.write('inline constexpr SpeechClip kClips[] = {\n' + '\n'.join(clips) + '\n};\n')
        f.write('// clang-format on\n')
    print('%d clips, %d frames (%.2f s), %d bytes' % (len(clips), at, at / SR, os.path.getsize(flac)))
    print('manifest:')
    for reg, name, size in manifest:
        print('  %s/%s/%s %d' % (ORGAN, reg, name, size))


if __name__ == '__main__':
    main()
