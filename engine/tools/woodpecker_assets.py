# Development-time preparation of Woodpecker's recorded mallet attacks and measured bars from VCSL (CC0): cuts the attacks, measures each bar's modes, and writes engine/assets/woodpecker/mallets.flac and src/woodpecker_bank.inc.
#
# Not part of the build or CI: it needs the Versilian Community Sample Library's struck idiophones and timpani
# (github.com/sgossner/VCSL, CC0 1.0; about 310 MB of those folders) and Python 3 with numpy, scipy and soundfile
# (BSD licences; development tools only, nothing of them ships). Run it again only to change what is recorded; the
# build reads its two outputs.
#
#   python3 -I engine/tools/woodpecker_assets.py <VCSL checkout> <engine dir>
#
# What it keeps and measures (docs/engine.md, "Woodpecker"):
# - attacks: the first 174 ms (the timpani's 358) of every recorded key of each instrument (its zones), two dynamic
#   layers each, and for the xylophone three mallets (soft, medium, hard) and the vibraphone two (yarn, hard). Folded
#   to mono (the right channel shifted onto the left by their cross-correlation's lag, then averaged), the last 10 ms
#   faded, normalised to its own peak, stored as 16-bit at the recordings' 44.1 kHz. The voice crossfades from these
#   into the model over 30..130 ms (the timpani's 80..280).
# - each zone's modes, from its loudest recording (the hardest mallet): the reference mode (the bar's fundamental;
#   the chime's 4th mode, an octave over its strike note; the timpani's (1,1) mode) found near the key's pitch on a
#   zero-padded FFT of 50 ms .. 1.55 s, then the strongest other peaks over 30..330 ms (up to 12 in all, within 45 dB
#   of the strongest, at least 1.5 % and 1.2 / crossfade apart: a bar's close pairs beat, so they are kept where the
#   fit can tell them apart), each frequency refined on the log spectrum; each mode's T60 by a line through its level
#   in 100 ms windows until it falls 40 dB or 4 s, held to the instrument's longest believable.
# - each clip's modes in the middle of its crossfade: a least-squares fit of the zone's modes (each decaying at its
#   T60) to the clip over the whole crossfade, as complex amplitudes. The model starts every mode at what the
#   recording holds there, so recording and model are the same partials in the same phase across the crossfade
#   (they cannot cancel).
# Levels: each instrument is scaled so the median peak of its loud layer is 0.5; the balance between its keys and
# layers is the recordings' own.
import glob
import os
import sys

import numpy as np
import soundfile as sf
from scipy.signal import lfilter

SR = 44100
FADE_S, PRE_S = 0.010, 0.002
# The recording alone, then the crossfade into the model (seconds): 30 ms and 100 ms, the timpani 80 and 200 (its
# stick's noise and the kettle's many modes take longer to settle into the few the model plays).
TIMING = (0.030, 0.100)
MAX_MODES = 12
NOTES = {'C': 0, 'C#': 1, 'D': 2, 'D#': 3, 'E': 4, 'F': 5, 'F#': 6, 'G': 7, 'G#': 8, 'A': 9, 'A#': 10, 'B': 11}

ID = 'Idiophones/Struck Idiophones/'
# Each instrument: its folder; zones (the file names' note, or the timpani's drum and its (1,1) mode's rough Hz);
# the names' octave offset (VCSL names these instruments an octave under their sounding pitch: measured, the
# marimba's "C2" sounds at 130.8 Hz); its mallet sets (name, the hardness 0..1 its recording stands for, file
# pattern per layer, {n} the zone); the layers' MIDI velocities; how its reference mode is found; the lowest mode
# kept, as a ratio to the reference pitch.
VARIANTS = [
    dict(name='Marimba', sep=0.015, t60max=12, dir=ID + 'Marimba', oct=1, ref='bar', minr=0.9, vel=(60, 105),
         zones=['F1', 'C2', 'G2', 'B2', 'F3', 'C4', 'G4', 'B4', 'F5', 'C6'],
         sets=[('Outrigger', 0.5, ['Marimba_hit_Outrigger_{n}_med_01.wav', 'Marimba_hit_Outrigger_{n}_loud_01.wav'])]),
    dict(name='Xylophone', sep=0.015, t60max=5, dir=ID + 'Xylophone', oct=1, ref='bar', minr=0.9, vel=(40, 105),
         zones=['G3', 'C4', 'G4', 'C5', 'G5', 'C6', 'G6', 'C7'],
         sets=[('Soft', 0.2, ['Soft Mallets/Xylo_Soft_{n}_pp_01_far.wav', 'Soft Mallets/Xylo_Soft_{n}_ff_01_far.wav']),
               ('Medium', 0.5, ['Medium Mallets/Xylo_Medium_{n}_pp_01_far.wav', 'Medium Mallets/Xylo_Medium_{n}_ff_01_far.wav']),
               ('Hard', 0.85, ['Hard Mallets/Xylo_Hard_{n}_pp_01_far.wav', 'Hard Mallets/Xylo_Hard_{n}_ff_01_far.wav'])]),
    dict(name='Glockenspiel', sep=0.015, t60max=25, dir=ID + 'Glockenspiel', oct=1, ref='bar', minr=0.9, vel=(45, 90),
         zones=['G4', 'C5', 'G5', 'C6', 'G6', 'C7'],
         sets=[('Brass', 0.7, ['glock_soft_{n}_*.wav', 'glock_medium_{n}_*.wav'])]),
    dict(name='Vibraphone', sep=0.015, t60max=30, dir=ID + 'Vibraphone', oct=1, ref='bar', minr=0.9, vel=(45, 100),
         zones=['F2', 'A2', 'C3', 'E3', 'G3', 'B3', 'D4', 'F4', 'A4', 'C5', 'E5'],
         sets=[('Yarn', 0.3, ['Soft Mallets/Vibes_soft_{n}_v1_*_Main.wav', 'Soft Mallets/Vibes_soft_{n}_v2_*_Main.wav']),
               ('Hard', 0.75, ['Hard Mallets/Vibes_hard_{n}_v2_*_Main.wav', 'Hard Mallets/Vibes_hard_{n}_v3_*_Main.wav'])]),
    dict(name='Tubular bells', sep=0.015, t60max=45, dir=ID + 'Tubular Bells 1', oct=1, ref='chime', minr=0.55, vel=(45, 110),
         zones=['C3', 'D3', 'E3', 'F#3', 'G#3', 'A#3', 'C4', 'D4', 'E4'],
         sets=[('Hammer', 0.8, ['chimes_{n}_p*_rr*.wav', 'chimes_{n}_f*_rr*.wav'])]),
    dict(name='Timpani', timing=(0.080, 0.200), sep=0.015, t60max=8, dir='Membranophones/Struck Membranophones/Timpani 1/Hit', oct=0, ref='drum', minr=0.9, vel=(50, 110),
         zones=[('1', 91.0), ('2', 121.0), ('3', 142.7), ('4', 169.0), ('5', 190.6)],
         sets=[('Felt', 0.35, ['Timpani{n}_Hit_v2_rr1_Sum.wav', 'Timpani{n}_Hit_v4_rr1_Sum.wav'])]),
]
# Recordings that are not what their name says, and what stands in for them. [Measured 2026-11-24] Xylo_Hard_G3_pp
# sounds at 372.8 Hz (F#4 -87 ct), not G4. The marimba's soft layer is VCSL's "med": its "soft" F5 and C6 peak
# 45 dB under the loud ones (at the noise floor).
OVERRIDES = {'Hard Mallets/Xylo_Hard_G3_pp_01_far.wav': 'Medium Mallets/Xylo_Medium_G3_pp_01_far.wav'}


def midi(name):
    return 12 * (int(name[-1]) + 1) + NOTES[name[:-1]]


def hz(key):
    return 440.0 * 2.0 ** ((key - 69.0) / 12.0)


def mono(x):
    if x.ndim == 1 or x.shape[1] == 1:
        return x.reshape(-1)
    l, r = x[:, 0], x[:, 1]
    n = min(len(l), 8192)
    best, lag = -1e30, 0
    for d in range(-24, 25):
        a = l[max(0, d):n + min(0, d)]
        b = r[max(0, -d):n - max(0, d)]
        m = min(len(a), len(b))
        c = float(np.dot(a[:m], b[:m]))
        if c > best:
            best, lag = c, d
    return 0.5 * (l + np.roll(r, lag))


def load(path):
    x, sr = sf.read(path, always_2d=True)
    assert sr == SR, path
    m = mono(x)
    m = lfilter([1, -1], [1, -0.9995], m)  # DC and rumble out (a 3.5 Hz high-pass)
    pk = np.max(np.abs(m))
    on = int(np.argmax(np.abs(m) > 0.1 * pk))
    stop = max(0, on - int(0.010 * SR))
    while on > stop and abs(m[on]) > 0.01 * pk:
        on -= 1
    return m, max(0, on - int(PRE_S * SR))


def spectrum(m, at, seconds):
    n = int(min(seconds, (len(m) - at) / SR - 0.01) * SR)
    seg = m[at:at + n] * np.hanning(n)
    N = 1 << 21
    S = np.abs(np.fft.rfft(seg, N)) + 1e-12
    return S, SR / N


def refine(S, df, i):
    a, b, c = np.log(S[i - 1]), np.log(S[i]), np.log(S[i + 1])
    d = 0.5 * (a - c) / (a - 2 * b + c)
    return (i + d) * df


def peak_in(S, df, lo, hi):
    i0, i1 = int(lo / df), int(hi / df)
    i = i0 + int(np.argmax(S[i0:i1]))
    return i


def tone_track(m, at, f):
    w = int(0.100 * SR)
    hop = int(0.050 * SR)
    win = np.hanning(w)
    t = np.arange(w) / SR
    out = []
    k = 0
    while at + k * hop + w < len(m):
        seg = m[at + k * hop:at + k * hop + w]
        out.append(abs(np.sum(seg * win * np.exp(-2j * np.pi * f * t))) * 2 / np.sum(win))
        k += 1
    return np.array(out), (np.arange(len(out)) * hop + w / 2) / SR


def t60_of(m, on, f):
    a, t = tone_track(m, on + int(0.03 * SR), f)
    if len(a) < 4:
        return 1.0
    L = 20 * np.log10(a + 1e-12)
    top = L[:4].max()
    sel = []
    for i in range(len(L)):
        if t[i] > 4.0 or L[i] < top - 40:
            break
        if t[i] >= 0.05:
            sel.append(i)
    if len(sel) < 3:
        return 0.1
    sl = np.polyfit(t[sel], L[sel], 1)[0]
    return float(np.clip(-60.0 / sl if sl < 0 else 60.0, 0.05, 60.0))


def modes_of(v, m, on, approx):
    S, df = spectrum(m, on + int(0.05 * SR), 1.5)
    ref = v['ref']
    if ref == 'bar':
        lo, hi, mult = approx * 2 ** (-60 / 1200), approx * 2 ** (60 / 1200), 1.0
    elif ref == 'chime':
        lo, hi, mult = 2 * approx * 2 ** (-60 / 1200), 2 * approx * 2 ** (60 / 1200), 2.0
    else:
        lo, hi, mult = approx * 0.94, approx * 1.06, 1.0
    i = peak_in(S, df, lo, hi)
    fref = refine(S, df, i)
    root = fref / mult
    # The other modes from what sounds over the crossfade (30..330 ms): a bar's high modes die within it.
    S, df = spectrum(m, on + int(0.03 * SR), 0.3)
    top = min(16000.0, 0.45 * SR)
    lo_i = int(v['minr'] * root / df)
    hi_i = int(top / df)
    seg = S[lo_i:hi_i]
    d = np.diff(seg)
    cand = np.where((d[:-1] > 0) & (d[1:] <= 0))[0] + 1 + lo_i
    mx = S[cand].max()
    cand = [c for c in cand if S[c] > mx * 10 ** (-45 / 20)]
    cand = sorted(cand, key=lambda c: -S[c])
    keep = [fref]
    for c in cand:
        f = refine(S, df, c)
        if all(abs(f - k) > max(v['sep'] * k, 1.2 / v.get('timing', TIMING)[1]) for k in keep):  # resolvable in the fit
            keep.append(f)
        if len(keep) >= MAX_MODES:
            break
    t60 = [min(v['t60max'], t60_of(m, on, f)) for f in keep]
    return root, keep, t60


def check_pitch(m, on, f, path, limit):
    S, df = spectrum(m, on + int(0.03 * SR), 0.3)
    got = refine(S, df, peak_in(S, df, f * 2 ** (-100 / 1200), f * 2 ** (100 / 1200)))
    c = 1200 * np.log2(got / f)
    if abs(c) > limit:
        raise SystemExit('%s: its reference mode is %.0f cents from its zone\'s' % (path, c))


def fit(clip, freqs, t60s, hold, fade):
    ref = hold + fade / 2
    n0, n1 = int(hold * SR), int((hold + fade) * SR)
    t = np.arange(n0, n1) / SR - ref
    cols = [np.ones_like(t)]
    for f, T in zip(freqs, t60s):
        e = np.exp(-6.907755 / T * t)
        cols += [e * np.cos(2 * np.pi * f * t), e * np.sin(2 * np.pi * f * t)]
    A = np.stack(cols, axis=1)
    y = clip[n0:n1]
    coef, *_ = np.linalg.lstsq(A, y, rcond=None)
    model = A @ coef
    resid = float(np.sum((y - model) ** 2) / (np.sum(y * y) + 1e-30))
    c = [complex(coef[2 + 2 * k], coef[1 + 2 * k]) for k in range(len(freqs))]  # x = Im(c e^{iw(t - ref)})
    # What the modes do not hold (the timpani's other modes and stick noise, a bar's faint ones) is given to the modes
    # as level, so the model carries the recording's loudness on (at most +6 dB).
    k = min(2.0, 1.0 / np.sqrt(max(1e-6, 1.0 - resid)))
    return [x * k for x in c], resid


def cut(m, on, seconds):
    n = int(round(seconds * SR))
    y = np.zeros(n)
    seg = m[on:on + n]
    y[:len(seg)] = seg
    f = int(round(FADE_S * SR))
    y[n - f:] *= 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, f))
    return y


def flt(x):  # a C++ float literal: always with a point or exponent, so 1 is 1.0f, never 1f
    t = '%.7g' % x
    return t + ('f' if ('.' in t or 'e' in t) else '.0f')


def arr(xs, n):
    xs = list(xs) + [0.0] * (n - len(xs))
    return '{' + ', '.join(flt(x) for x in xs) + '}'


def main():
    src, eng = sys.argv[1], sys.argv[2]
    zones, clips, banks, data, manifest = [], [], [], [], []
    at = 0
    for vi, v in enumerate(VARIANTS):
        folder = os.path.join(src, v['dir'])
        first_zone, first_clip = len(zones), len(clips)
        rows = []  # per (set, zone, layer): (clip samples, c, resid, rms, peak, vel)
        hold, fade = v.get('timing', TIMING)
        # Long enough for the crossfade's end at a pitch 3.5 semitones over the zone's (the farthest a key plays it).
        clip_s = round((hold + fade) * 2 ** (3.5 / 12) + FADE_S + 0.005, 3)
        zinfo = []
        for z in v['zones']:
            name, approx = (z if isinstance(z, tuple) else (z, hz(midi(z) + 12 * v['oct'])))
            # The modes from the loudest layer of the hardest mallet.
            pattern = v['sets'][-1][2][1].replace('{n}', name)
            path = sorted(glob.glob(os.path.join(folder, pattern)))[0]
            m, on = load(path)
            root, freqs, t60 = modes_of(v, m, on, approx)
            key = 69.0 + 12.0 * np.log2(root / 440.0)
            zinfo.append((name, key, root, freqs, t60, os.path.basename(path)))
        for s, (sname, hrec, pats) in enumerate(v['sets']):
            for zi, (name, key, root, freqs, t60, _) in enumerate(zinfo):
                for layer, pat in enumerate(pats):
                    rel = pat.replace('{n}', name)
                    path = sorted(glob.glob(os.path.join(folder, OVERRIDES.get(rel, rel))))[0]
                    m, on = load(path)
                    check_pitch(m, on, freqs[0], path, 70 if v['ref'] == 'drum' else 20)  # a drum's pitch glides down after a loud stroke
                    y = cut(m, on, clip_s)
                    c, resid = fit(y, freqs, t60, hold, fade)
                    w = y[int(hold * SR):int((hold + fade) * SR)]
                    rows.append(dict(set=s, zone=zi, layer=layer, y=y, c=c, resid=resid, rms=float(np.sqrt(np.mean(w * w))),
                                     peak=float(np.max(np.abs(y))) or 1.0, vel=v['vel'][layer], path=path))
        loud = [r['peak'] for r in rows if r['layer'] == 1]
        gain = 0.5 / float(np.median(loud))
        for zi, (name, key, root, freqs, t60, ref) in enumerate(zinfo):
            ratios = [f / root for f in freqs]
            zones.append('{%d, %s, %d, %s, %s},' % (vi, flt(key), len(freqs), arr(ratios, MAX_MODES), arr(t60, MAX_MODES)))
            print('%-13s %-4s key %7.2f (%+5.1f ct vs %s) ref %s' % (v['name'], name, key, 100 * (key - round(key)), name, ref))
            print('    modes ' + ' '.join('%.3f/%.2fs' % (r, T) for r, T in zip(ratios, t60)))
        for r in rows:
            q = np.round(r['y'] / r['peak'] * 32767.0).astype(np.int16)
            data.append(q)
            cs = [x * gain for x in r['c']]
            clips.append('{%d, %d, %d, %s, %du, %du, %s, %s, %s, %s},' % (
                r['zone'], r['set'], r['layer'], flt(r['vel']), at, len(q), flt(r['peak'] * gain), flt(r['rms'] * gain),
                arr([x.real for x in cs], MAX_MODES), arr([x.imag for x in cs], MAX_MODES)))
            manifest.append((v['dir'], os.path.basename(r['path']), os.path.getsize(r['path']), r['resid']))
            at += len(q)
        hr = [s[1] for s in v['sets']] + [0.0] * (3 - len(v['sets']))
        banks.append('{%d, %d, %d, %d, {%s}, %s, %s, %s, %s},' % (first_zone, len(v['zones']), first_clip, len(v['sets']),
                                                                 ', '.join(flt(h) for h in hr), flt(v['vel'][0]), flt(v['vel'][1]),
                                                                 flt(hold), flt(fade)))
        res = [r['resid'] for r in rows]
        for r in sorted(rows, key=lambda r: -r['resid'])[:3]:
            print('    worst fit %.3f peak %.4f %s' % (r['resid'], r['peak'], os.path.basename(r['path'])))
        print('%s: gain %.2f, fit residual median %.3f, worst %.3f' % (v['name'], gain, np.median(res), max(res)))
    os.makedirs(os.path.join(eng, 'assets', 'woodpecker'), exist_ok=True)
    out = os.path.join(eng, 'assets', 'woodpecker', 'mallets.flac')
    sf.write(out, np.concatenate(data), SR, subtype='PCM_16', format='FLAC')
    with open(os.path.join(eng, 'src', 'woodpecker_bank.inc'), 'w') as f:
        f.write('// Generated by tools/woodpecker_assets.py from the Versilian Community Sample Library (VCSL, CC0 1.0): the measured\n')
        f.write('// zones and the clips in assets/woodpecker/mallets.flac. Included by woodpecker_bars.h. Zones: {instrument,\n')
        f.write('// reference key (MIDI, fractional), modes, ratios to the reference pitch, T60s}. Clips: {zone (in its instrument),\n')
        f.write('// mallet set, layer, velocity (MIDI), first frame, frames, scale, the crossfade\'s RMS, modes in its middle (re, im)}.\n')
        f.write('// clang-format off\n')
        f.write('inline constexpr Zone kZones[] = {\n' + '\n'.join(zones) + '\n};\n')
        f.write('inline constexpr Clip kClips[] = {\n' + '\n'.join(clips) + '\n};\n')
        f.write('inline constexpr Layout kLayouts[kInstruments] = {\n' + '\n'.join(banks) + '\n};\n')
        f.write('// clang-format on\n')
    print('%d zones, %d clips, %d frames (%.2f s), %d bytes' % (len(zones), len(clips), at, at / SR, os.path.getsize(out)))
    print('manifest:')
    for d, name, size, resid in manifest:
        print('  %s/%s %d' % (d, name, size))


if __name__ == '__main__':
    main()
