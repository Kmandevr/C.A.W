# Development-time preparation of Starling's plucked strings (classical guitar: FreePats, CC0; concert harp: VCSL, CC0): cuts the attacks, measures each string, fits the bodies, and writes engine/assets/starling/{guitar,harp}.flac, src/starling_strings_bank.inc and src/starling_bodies.inc.
#
# Not part of the build or CI. It needs Python 3 with numpy, scipy and soundfile (BSD licences; development tools
# only, nothing of them ships) and:
#   - FreePats' Spanish Classical Guitar, SFZ+FLAC 2019-06-18 (freepats.zenvoid.org/Guitar/acoustic-guitar.html, CC0
#     1.0), unpacked: the folder that holds samples/;
#   - the Versilian Community Sample Library's concert harp (github.com/sgossner/VCSL, CC0 1.0: Chordophones/
#     Composite Chordophones/Concert Harp, 74 MB).
# Two steps (docs/engine.md, "Starling"):
#
#   python3 -I engine/tools/starling_strings_assets.py assets <guitar folder> <VCSL checkout> <engine dir>
#       the clips, the measured strings, and each clip's string history with the body taken off (by the bands in
#       src/starling_bodies.inc; flat if there are none yet);
#   python3 -I engine/tools/starling_strings_assets.py body <guitar folder> <VCSL checkout> <engine dir> <renders>
#       the bodies: each instrument's recorded partials over the model's (renders written by `caw_tests
#       starling_strings_body_renders` with CAW_STARLING_RENDERS=<dir>: every semitone, the string alone, no body),
#       as 8 peaking bands, by instrument_bodies.py's method (partials within 50 dB of the strongest, under 8 kHz,
#       the curve held within +-12 dB). Then run `assets` again (the histories use the body).
#
# What it keeps and measures:
# - attacks: from 2 ms before the onset, hold + fade long (in its own time, whatever the pitch it is played at), plus a 10 ms
#   fade: the guitar every third semitone E2..C6 (FreePats has one layer, peak-normalised), the harp every recorded
#   string E1..F7 (two layers: f and the softer one VCSL has, mf, mp or p). Folded to mono (the right channel shifted
#   onto the left by their cross-correlation's lag, then averaged), normalised to its own peak, 16-bit at 44.1 kHz.
# - each clip's string history: the clip up to the end of its hold with the body taken off (the bands' exact
#   inverse: an RBJ peak of -dB undoes one of +dB), normalised, after the clips in the same file. The model's loop
#   is filled with it at the hold, so the string carries on exactly where the recording is (docs/engine.md).
# - each zone's string, from its loudest layer: the fundamental (a zero-padded FFT of 0.1..1.0 s), the inharmonicity
#   B (f_n^2 / n^2 = f1^2 (1 + B n^2), a line through the partials within 40 dB of the strongest; then a median over
#   each zone and its neighbours, held to 1e-6..1e-3), and the decay (T60) of the fundamental and of the partial
#   nearest 2 kHz (a line through each one's level in 50 ms windows until it falls 35 dB, held to believable
#   limits, then a median over neighbours).
# Levels: each instrument is scaled so the median peak of its loudest layer is 0.5; the harp's balance between its
# strings and layers is the recording's own (the guitar's recordings are each normalised to their peak).
import glob
import os
import re
import sys

import numpy as np
import soundfile as sf
from scipy.signal import lfilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import instrument_bodies as ib  # noqa: E402 (the body fit: same method as Nightingale's and Curlew's)

SR = 44100
FADE_S, PRE_S = 0.010, 0.002
NOTES = {'C': 0, 'C#': 1, 'D': 2, 'D#': 3, 'E': 4, 'F': 5, 'F#': 6, 'G': 7, 'G#': 8, 'A': 9, 'A#': 10, 'B': 11}
HARP_DIR = 'Chordophones/Composite Chordophones/Concert Harp'
# Each instrument: its playable range (MIDI, inclusive: the C++ kLow/kHigh), hold and fade (seconds: the recording
# alone, then the crossfade), T60 limits, the layers' MIDI velocities, [Assumption] the pluck position and
# hardness the recordings stand for (the knobs' defaults), and how to find each zone's files.
INSTRUMENTS = [
    dict(name='guitar', array='kGuitarBody', low=40, high=86, hold=0.030, fade=0.090, t60max=(10.0, 4.0)),
    dict(name='harp', array='kHarpBody', low=24, high=103, hold=0.045, fade=0.090, t60max=(25.0, 6.0)),
]
# [Assumption] the layers' velocities (MIDI): FreePats' one layer a mezzo-forte; VCSL's dynamics as marked.
VEL = {'f': 100.0, 'mf': 75.0, 'mp': 60.0, 'p': 45.0, 'guitar': 90.0}


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


def zones_of(inst, guitar, vcsl):
    # [(name, nominal key, [(path, velocity), ...] soft to loud)]
    out = []
    if inst['name'] == 'guitar':
        have = {}
        for p in glob.glob(os.path.join(guitar, 'samples', '*.flac')):
            have[midi(os.path.basename(p)[:-5])] = p
        # Every third semitone from E2 (FreePats' lowest notes, G1..D#2, are under the guitar's E2: not used).
        for k in range(40, 86, 3):
            pick = min((abs(h - k), h) for h in have if h >= 40)[1]
            if abs(pick - k) <= 1 and pick not in [z[1] for z in out]:
                out.append((os.path.basename(have[pick])[:-5], pick, [(have[pick], VEL['guitar'])]))
        return out
    folder = os.path.join(vcsl, HARP_DIR)
    by = {}
    for p in glob.glob(os.path.join(folder, 'KSHarp_*.wav')):
        m = re.match(r'KSHarp_([A-G]#?\d)_([a-z]+)\d\.wav', os.path.basename(p))
        by.setdefault(m.group(1), []).append((VEL[m.group(2)], p))
    for name in sorted(by, key=midi):
        layers = sorted(by[name])
        soft, loud = layers[0], layers[-1]
        out.append((name, midi(name), [(soft[1], soft[0]), (loud[1], loud[0])]))  # E1 has only f: it stands for both
    return out


def spectrum(m, a, b):
    seg = m[a:b] * np.hanning(b - a)
    N = 1 << 21
    return np.abs(np.fft.rfft(seg, N)) + 1e-12, SR / N


def refine(S, df, i):
    a, b, c = np.log(S[i - 1]), np.log(S[i]), np.log(S[i + 1])
    return (i + 0.5 * (a - c) / (a - 2 * b + c)) * df


def string_of(m, on, key):
    # The fundamental, B and the partials (Hz, dB) of one recording.
    a, b = on + int(0.1 * SR), on + int(min(1.0, (len(m) - on) / SR - 0.05) * SR)
    S, df = spectrum(m, a, b)

    def peak(lo, hi):
        i0, i1 = int(lo / df), int(hi / df)
        i = i0 + int(np.argmax(S[i0:i1]))
        return refine(S, df, i), 20 * np.log10(S[i])
    f1, _ = peak(hz(key) * 0.94, hz(key) * 1.06)
    ns, fs, ls = [], [], []
    B = 0.0
    for n in range(1, 31):
        g = n * f1 * np.sqrt(1 + B * n * n)
        if g > 0.4 * SR:
            break
        f, L = peak(g * 0.985, g * 1.015)
        ns.append(n), fs.append(f), ls.append(L)
        if n >= 4:
            nn, ff, ll = np.array(ns), np.array(fs), np.array(ls)
            w = ll > ll.max() - 40
            if w.sum() >= 3:
                c = np.polyfit(nn[w] ** 2, (ff[w] / nn[w]) ** 2, 1)
                B = max(0.0, c[0] / c[1])
    nn, ff, ll = np.array(ns), np.array(fs), np.array(ls)
    w = ll > ll.max() - 40
    B = 0.0
    if w.sum() >= 3:
        c = np.polyfit(nn[w] ** 2, (ff[w] / nn[w]) ** 2, 1)
        B = c[0] / c[1]
    return f1, B, list(zip(fs, ls))


def t60_of(m, on, f, cap):
    w, hop = int(0.05 * SR), int(0.025 * SR)
    win = np.hanning(w)
    t = np.arange(w) / SR
    start = on + int(0.06 * SR)
    out = []
    k = 0
    while start + k * hop + w < len(m) and k * hop < 6 * SR:
        seg = m[start + k * hop:start + k * hop + w]
        out.append(abs(np.sum(seg * win * np.exp(-2j * np.pi * f * t))))
        k += 1
    L = 20 * np.log10(np.array(out) + 1e-12)
    tt = np.arange(len(L)) * hop / SR
    last = 0
    for i in range(len(L)):
        if L[i] < L[:3].max() - 35:
            break
        last = i
    if last < 3:
        return 0.1
    sl = np.polyfit(tt[:last + 1], L[:last + 1], 1)[0]
    return float(np.clip(-60.0 / sl if sl < 0 else cap, 0.05, cap))


def crossfade_key(y, f1, B, t0, t1):
    # The clip's own pitch over its crossfade (a plucked string starts sharp and settles): the fundamental whose first
    # partial holds the most (under 150 Hz its first 4) of a Hann-windowed DFT of the crossfade, searched +-40 cents in 0.25
    # cent steps, then refined to 0.01 cent. The player is played at the ratio that puts it at the note's pitch, so
    # the string carries on in tune with what is sounding then.
    a, b = int(t0 * SR), int(t1 * SR)
    x = y[a:b] * np.hanning(b - a)
    t = np.arange(b - a) / SR

    def score(f):
        sc = 0.0
        for n in range(1, 2 if f1 >= 150 else 5):  # the bass: 4 partials (a 90 ms window holds few of its periods)
            fn = n * f * np.sqrt(1 + B * n * n)
            if fn > 0.45 * SR:
                break
            sc += abs(np.sum(x * np.exp(-2j * np.pi * fn * t)))
        return sc
    cs = np.arange(-40, 40.01, 0.25)
    best = cs[int(np.argmax([score(f1 * 2 ** (c / 1200)) for c in cs]))]
    lo, hi = best - 0.25, best + 0.25
    for _ in range(30):
        u, v = hi - (hi - lo) * 0.618, lo + (hi - lo) * 0.618
        if score(f1 * 2 ** (u / 1200)) > score(f1 * 2 ** (v / 1200)):
            hi = v
        else:
            lo = u
    return 69.0 + 12.0 * np.log2(f1 * 2 ** (0.5 * (lo + hi) / 1200) / 440.0)


def early_t60(m, on, f, hold, fade, late):
    # A line through the level at f in 20 ms windows every 5 ms over the crossfade and 60 ms after it.
    w, hop = int(0.020 * SR), int(0.005 * SR)
    win = np.hanning(w)
    t = np.arange(w) / SR
    L = []
    for a in range(on + int(hold * SR), on + int((hold + fade + 0.06) * SR) - w, hop):
        L.append(20 * np.log10(abs(np.sum(m[a:a + w] * win * np.exp(-2j * np.pi * f * t))) + 1e-12))
    sl = np.polyfit(np.arange(len(L)) * hop / SR, L, 1)[0]
    T = -60.0 / sl if sl < 0 else late
    return float(np.clip(T, late / 3.0, late))


def median3(xs):
    xs = list(xs)
    return [float(np.median(xs[max(0, i - 1):i + 2])) for i in range(len(xs))]


def bodies(eng):
    # {array name: [(hz, q, db)]} from src/starling_bodies.inc; none if it is not there or flat.
    path = os.path.join(eng, 'src', 'starling_bodies.inc')
    out = {}
    if not os.path.exists(path):
        return out
    name = None
    for line in open(path):
        m = re.match(r'inline constexpr BodyBand (\w+)\[\]', line)
        if m:
            name = m.group(1)
            out[name] = []
            continue
        m = re.match(r'\s*\{([-\d.e]+)f, ([-\d.e]+)f, ([-\d.e]+)f\},', line)
        if m and name:
            out[name].append(tuple(float(x) for x in m.groups()))
    return out


def peak_coefs(hz_, q, db):
    # timber::Biquad::peak (RBJ), normalised; at the bank's rate.
    w = 2 * np.pi * min(max(hz_, 10.0), 0.45 * SR) / SR
    A = 10 ** (db / 40)
    al = np.sin(w) / (2 * q)
    c = np.cos(w)
    b = np.array([1 + al * A, -2 * c, 1 - al * A])
    a = np.array([1 + al / A, -2 * c, 1 - al / A])
    return b / a[0], a / a[0]


def unbody(x, bands):
    for hz_, q, db in bands:
        b, a = peak_coefs(hz_, q, -db)
        x = lfilter(b, a, x)
    return x


def flt(x):  # a C++ float literal: always with a point or exponent
    t = '%.7g' % x
    return t + ('f' if ('.' in t or 'e' in t) else '.0f')


def measure(inst, guitar, vcsl):
    zs = zones_of(inst, guitar, vcsl)
    rows = []
    for name, key, layers in zs:
        m, on = load(layers[-1][0])
        f1, B, parts = string_of(m, on, key)
        nh = max(2, int(round(2000.0 / f1)))
        if nh * f1 > 0.4 * SR:
            nh = 1
        fh = nh * f1 * np.sqrt(1 + max(B, 0) * nh * nh)
        lo, hi = inst['t60max']
        rows.append(dict(name=name, key=69.0 + 12.0 * np.log2(f1 / 440.0), nominal=key, B=B, layers=layers,
                         t60lo=t60_of(m, on, f1, lo), t60hi=t60_of(m, on, fh, hi), fh=fh, parts=parts, path=layers[-1][0]))
    Bs = median3([r['B'] for r in rows])
    los = median3([np.log(r['t60lo']) for r in rows])
    his = median3([np.log(r['t60hi']) for r in rows])
    for r, B, lo, hi in zip(rows, Bs, los, his):
        r['B'] = float(np.clip(B, 1e-6, 1e-3))
        r['t60lo'] = float(np.exp(lo))
        r['t60hi'] = float(min(np.exp(hi), np.exp(lo)))
        if abs(r['key'] - r['nominal']) > 0.5:
            raise SystemExit('%s: measured %.2f, not its name\'s %d' % (r['path'], r['key'], r['nominal']))
    return rows


def assets(guitar, vcsl, eng):
    body = bodies(eng)
    zones, clips, lays, manifest = [], [], [], []
    for ii, inst in enumerate(INSTRUMENTS):
        rows = measure(inst, guitar, vcsl)
        bands = body.get(inst['array'], [])
        hold, fade = inst['hold'], inst['fade']
        first_zone, first_clip = len(zones), len(clips)
        layers = len(rows[0]['layers'])
        data, hist = [], []
        cut = []
        # In the recording's own time at any pitch (the player and the model's gate scale with the pitch ratio).
        clip_s = round(hold + fade + FADE_S + 0.004, 3)
        for zi, r in enumerate(rows):
            for li, (path, vel) in enumerate(r['layers']):
                m, on = load(path)
                n = int(round(clip_s * SR))
                y = np.zeros(n)
                seg = m[on:on + n]
                y[:len(seg)] = seg
                f = int(round(FADE_S * SR))
                y[n - f:] *= 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, f))
                # The history: the recording up to its hold, plus 4 frames, the body off.
                h = unbody(y[:int(np.ceil(hold * SR)) + 4], bands) if bands else y[:int(np.ceil(hold * SR)) + 4].copy()
                w = y[int(hold * SR):int((hold + fade) * SR)]
                key = crossfade_key(y, hz(r['key']), r['B'], hold, hold + fade)
                # The string's first decay, over the crossfade (a plucked string's prompt sound dies faster than its
                # aftersound): the fundamental's and the partial at fh, held between a third of the late ones and them.
                e0 = early_t60(m, on, hz(key), hold, fade, r['t60lo'])
                eh = min(e0, early_t60(m, on, r['fh'] * hz(key) / hz(r['key']), hold, fade, r['t60hi']))
                cut.append(dict(zone=zi, layer=li, vel=vel, y=y, h=h, rms=float(np.sqrt(np.mean(w * w))), key=key, e0=e0, eh=eh,
                                peak=float(np.max(np.abs(y))) or 1.0, hpeak=float(np.max(np.abs(h))) or 1.0, path=path))
        # A soft layer the string cannot carry on (not periodic over its crossfade: VCSL's G1 mp is mostly the room's
        # noise, its one-period correlation 0.19) is replaced by the loud one, as E1's missing one is.
        for c in cut:
            if c['layer'] == 0 and layers == 2:
                f1 = hz(c['key'])
                a, b = int(hold * SR), int((hold + fade / 2) * SR)
                d = np.interp(np.arange(a, b) - SR / f1, np.arange(len(c['y'])), c['y'])
                k = c['y'][a:b]
                cc = float(np.dot(k, d) / np.sqrt(np.dot(k, k) * np.dot(d, d) + 1e-30))
                if cc < 0.6:
                    loud_c = next(x for x in cut if x['zone'] == c['zone'] and x['layer'] == 1)
                    print('    %s: periodicity %.2f over its crossfade; the loud layer stands for it' % (os.path.basename(c['path']), cc))
                    for key in ('y', 'h', 'rms', 'key', 'e0', 'eh', 'peak', 'hpeak', 'path'):
                        c[key] = loud_c[key]
        loud = [c['peak'] for c in cut if c['layer'] == layers - 1]
        gain = 0.5 / float(np.median(loud))
        at = 0
        for c in cut:
            q = np.round(c['y'] / c['peak'] * 32767.0).astype(np.int16)
            c['first'], c['frames'] = at, len(q)
            data.append(q)
            at += len(q)
        for c in cut:
            q = np.round(c['h'] / c['hpeak'] * 32767.0).astype(np.int16)
            c['hfirst'], c['hframes'] = at, len(q)
            hist.append(q)
            at += len(q)
        for zi, r in enumerate(rows):
            zones.append('{%d, %s, %s, %s, %s, %s},' % (ii, flt(r['key']), flt(r['B']), flt(r['t60lo']), flt(r['t60hi']), flt(r['fh'])))
            print('%-6s %-4s key %7.2f (%+5.1f ct) B %.2e T60 %.2f s at f1, %.2f s at %.0f Hz' % (
                inst['name'], r['name'], r['key'], 100 * (r['key'] - r['nominal']), r['B'], r['t60lo'], r['t60hi'], r['fh']))
        for c in cut:
            clips.append('{%d, %d, %s, %s, %du, %du, %s, %s, %du, %du, %s, %s, %s},' % (
                c['zone'], c['layer'], flt(c['vel']), flt(c['key']), c['first'], c['frames'], flt(c['peak'] * gain), flt(c['rms'] * gain),
                c['hfirst'], c['hframes'], flt(c['hpeak'] * gain), flt(c['e0']), flt(c['eh'])))
            base = os.path.relpath(c['path'], vcsl if inst['name'] == 'harp' else guitar)
            manifest.append((inst['name'], base, os.path.getsize(c['path'])))
            print('    %s: crossfade at %+.1f ct from the zone; first decay %.2f s, %.2f s at fh' % (
                base, 100 * (c['key'] - rows[c['zone']]['key']), c['e0'], c['eh']))
        vs = sorted(set(c['vel'] for c in cut))
        lays.append('{%d, %d, %d, %d, %s, %s, %s, %s},' % (first_zone, len(rows), first_clip, layers, flt(vs[0]), flt(vs[-1]),
                                                       flt(hold), flt(fade)))
        os.makedirs(os.path.join(eng, 'assets', 'starling'), exist_ok=True)
        out = os.path.join(eng, 'assets', 'starling', '%s.flac' % inst['name'])
        sf.write(out, np.concatenate(data + hist), SR, subtype='PCM_16', format='FLAC')
        print('%s: %d zones, %d clips, %d frames (%.2f s), %d bytes; gain %.2f; body %s' % (
            inst['name'], len(rows), len(cut), at, at / SR, os.path.getsize(out), gain, 'off' if bands else 'flat'))
    with open(os.path.join(eng, 'src', 'starling_strings_bank.inc'), 'w') as f:
        f.write('// Generated by tools/starling_strings_assets.py from FreePats\' Spanish Classical Guitar and VCSL\'s concert harp\n')
        f.write('// (CC0 1.0): the measured strings and the clips in assets/starling/{guitar,harp}.flac. Included by starling_strings.h.\n')
        f.write('// Zones: {instrument, key (MIDI, fractional: the fundamental as recorded), B, T60 at the fundamental, T60 at fh, fh}.\n')
        f.write('// Clips: {zone (in its instrument), layer, velocity (MIDI), key over the crossfade, first frame, frames, scale, the crossfade\'s RMS,\n')
        f.write('// the history\'s first frame, frames and scale, the first decay\'s T60 at the fundamental and at fh}. Layouts: {first zone, zones, first clip, layers, velocities, hold, fade}.\n')
        f.write('// clang-format off\n')
        f.write('inline constexpr Zone kZones[] = {\n' + '\n'.join(zones) + '\n};\n')
        f.write('inline constexpr Clip kClips[] = {\n' + '\n'.join(clips) + '\n};\n')
        f.write('inline constexpr Layout kLayouts[kInstruments] = {\n' + '\n'.join(lays) + '\n};\n')
        f.write('// clang-format on\n')
    print('manifest:')
    for name, base, size in manifest:
        print('  %s %s %d' % (name, base, size))


def body_fit(guitar, vcsl, eng, renders):
    arrays = {}
    for ii, inst in enumerate(INSTRUMENTS):
        rows = measure(inst, guitar, vcsl)
        pts, notes = [], []
        for r in rows:
            for path, _ in r['layers'][-1:]:
                m, on = load(path)
                key = int(round(r['key']))
                mod = os.path.join(renders, '%d_%d.f32' % (ii, key))
                if not os.path.exists(mod):
                    continue
                y = np.fromfile(mod, dtype=np.float32).astype(np.float64)
                f0 = hz(r['key'])
                x = m[on + int(0.1 * SR):on + int(min(1.0, (len(m) - on) / SR - 0.05) * SR)]
                a = ib.partials(x, SR, f0)
                b = dict(ib.partials(y[int(0.1 * ib.SR):int(1.0 * ib.SR)], ib.SR, f0))
                # Only partials both hold over their floors (within 50 dB of each one's strongest) and under 8 kHz: a plucked
                # string's top partials die within the window, and what is left there is the recording's noise.
                top_a, top_b = max(la for _, la in a), max(b.values())
                d = [(f, la - b[f], b[f]) for f, la in a
                     if f in b and f < 8000 and la > top_a - 50 and b[f] > top_b - 50 and np.isfinite(la - b[f])]
                if len(d) < 3:
                    continue
                mean = np.mean([v for _, v, _ in d])
                notes.append([(f, mp) for f, _, mp in d])
                pts += [(f, v - mean) for f, v, _ in d]
        pts = np.array(pts)
        edges = 50.0 * 2 ** (np.arange(0, 12 * np.log2(16000 / 50.0) + 1) / 12.0)
        curve = np.full(len(edges), np.nan)
        for i, e in enumerate(edges):
            m = (pts[:, 0] >= e * 2 ** (-1 / 24)) & (pts[:, 0] < e * 2 ** (1 / 24))
            if m.sum() >= 3:
                curve[i] = np.median(pts[m, 1])
        good = np.isfinite(curve)
        curve = np.interp(np.arange(len(edges)), np.flatnonzero(good), curve[good])
        k = np.exp(-0.5 * (np.arange(-4, 5) / 2.0) ** 2)
        curve = np.convolve(np.pad(curve, 4, mode='edge'), k / k.sum(), mode='valid')
        curve = np.clip(curve, -12, 12)

        def shift(c):
            ch = []
            for nt in notes:
                f = np.array([x for x, _ in nt])
                w = 10 ** (np.array([y for _, y in nt]) / 10)
                g = 10 ** (np.interp(np.log2(f), np.log2(edges), c) / 10)
                ch.append(10 * np.log10((w * g).sum() / w.sum()))
            return float(np.mean(ch))
        for _ in range(3):
            curve -= shift(curve)
        bands, err = ib.fit_bands(edges, curve, max(60.0, np.percentile(pts[:, 0], 1)), min(8000.0, np.percentile(pts[:, 0], 99)))
        arrays[inst['array']] = bands
        print('%s: %d points over %d notes; curve %.1f..%.1f dB; fit within %.2f dB rms, %.2f dB worst' % (
            inst['name'], len(pts), len(notes), curve.min(), curve.max(), err[0], err[1]))
    write_bodies(eng, arrays, 'fitted')


def write_bodies(eng, arrays, how):
    with open(os.path.join(eng, 'src', 'starling_bodies.inc'), 'w') as f:
        f.write('// Generated by tools/starling_strings_assets.py body (%s): each instrument\'s recorded partials (FreePats\' classical\n' % how)
        f.write('// guitar, VCSL\'s concert harp; CC0 1.0) over the model\'s string alone at the same notes, as peaking bands\n')
        f.write('// {Hz, Q, dB} (RBJ, designed at the rate). Included by starling_strings.h.\n')
        f.write('// clang-format off\n')
        for inst in INSTRUMENTS:
            f.write('inline constexpr BodyBand %s[] = {\n' % inst['array'])
            for hz_, q, db in arrays.get(inst['array'], [(1000.0, 1.0, 0.0)]):
                f.write('    {%.2ff, %.4ff, %.3ff},\n' % (hz_, q, db))
            f.write('};\n')
        f.write('// clang-format on\n')


def main():
    mode = sys.argv[1]
    if mode == 'assets':
        if not os.path.exists(os.path.join(sys.argv[4], 'src', 'starling_bodies.inc')):
            write_bodies(sys.argv[4], {}, 'flat, before the fit')
        assets(sys.argv[2], sys.argv[3], sys.argv[4])
    elif mode == 'body':
        body_fit(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    else:
        raise SystemExit('assets or body')


if __name__ == '__main__':
    main()
