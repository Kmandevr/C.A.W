# Development-time preparation of Rook's recorded kit parts from Karoryfer's CC0 drum libraries: cuts stick and beater transients, snare-wire noise, hi-hat and cymbal hits and the kick pedal's noise, and writes engine/assets/rook/kit.flac and src/rook_bank.inc.
#
# Not part of the build or CI: it needs two checkouts (github.com/sfzinstruments/karoryfer.unruly-drums and
# karoryfer.big-rusty-drums, CC0 1.0, about 2.8 GB together) and Python 3 with numpy, scipy and soundfile (BSD
# licences; development tools only, nothing of them ships). Run it again only to change what is recorded; the build
# reads its two outputs.
#
#   python3 -I engine/tools/rook_assets.py <unruly-drums checkout> <big-rusty-drums checkout> <engine dir>
#
# What it keeps (docs/engine.md, "Recorded parts (1.1.3)"): the close mics only (the kit is dry and close-miked; the
# engine's own mics place it), mono, 16-bit at the recordings' 44.1 kHz.
# - drums (kick, snare, toms): the first 150..180 ms of each hit, high-passed over the head's lowest modes (the
#   engine synthesizes the heads), so what is left is the stick or beater, the shell and the rim. Cross-sticks keep
#   their full band (the hand damps the head; the rim is the sound).
# - snare wires: the snare-side mic, high-passed at 1.5 kHz (the wires' band), 450 ms.
# - hi-hat (closed, half open, open, foot) and cymbals (crash edge, ride bow and bell): the whole hit to a short
#   tail (0.4..3.5 s), faded out over its last 40 %.
# - the kick pedal's own noise (its spring and cam going down), 300 ms.
# Each part's layers keep their recorded balance, the loudest normalised to 0.9; a layer's "velocity" is its peak
# against the loudest one to the power 1 / 1.6 (the engine's velocity-to-level curve), so a hit's layer and gain
# follow the recordings.
import os
import sys

import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt

SR = 44100
PRE = 0.0005  # kept before the onset (s), faded in

# (name, source, files, seconds, fade_from (s), high-pass (Hz, 0: none; 'tom': 1.6 x the measured fundamental))
U, R = 'unruly', 'rusty'
PARTS = [
    ('kick', U, ['k20/in/rr1/kick_clean_vl2_rr1.flac', 'k20/in/rr1/kick_clean_vl5_rr1.flac',
                 'k20/in/rr1/kick_clean_vl8_rr1.flac', 'k20/in/rr2/kick_clean_vl8_rr2.flac'], 0.15, 0.07, 160),
    ('snare', U, ['s14/top/rr1/s14_center_vl2_rr1.flac', 's14/top/rr1/s14_center_vl5_rr1.flac',
                  's14/top/rr1/s14_center_vl8_rr1.flac', 's14/top/rr2/s14_center_vl8_rr2.flac'], 0.18, 0.09, 330),
    ('snare_edge', U, ['s14/top/rr1/s14_edge_vl3_rr1.flac', 's14/top/rr1/s14_edge_vl7_rr1.flac'], 0.18, 0.09, 330),
    ('snare_rimshot', U, ['s14/top/rr1/s14_rimshot_vl3_rr1.flac', 's14/top/rr1/s14_rimshot_vl6_rr1.flac'], 0.18, 0.09, 330),
    ('snare_xstick', U, ['s14/top/rr1/s14_sstick_vl3_rr1.flac', 's14/top/rr1/s14_sstick_vl6_rr1.flac'], 0.25, 0.12, 0),
    ('wires', U, ['s14/btm/rr1/s14_b_center_vl2_rr1.flac', 's14/btm/rr1/s14_b_center_vl4_rr1.flac',
                  's14/btm/rr1/s14_b_center_vl6_rr1.flac'], 0.45, 0.2, 1500),
    ('tom_high', R, ['tom_14/center/cl/t14_vl2_rr1.flac', 'tom_14/center/cl/t14_vl4_rr1.flac',
                     'tom_14/center/cl/t14_vl6_rr1.flac'], 0.15, 0.07, 'tom'),
    ('tom_low', R, ['tom_18/center/cl/t18_vl2_rr1.flac', 'tom_18/center/cl/t18_vl4_rr1.flac',
                    'tom_18/center/cl/t18_vl6_rr1.flac'], 0.15, 0.07, 'tom'),
    ('hat_closed', U, ['h14/cl/rr1/hh_closed_tip_vl3_rr1.flac', 'h14/cl/rr1/hh_closed_tip_vl7_rr1.flac'], 0.4, 0.25, 0),
    ('hat_half', U, ['h14/cl/rr1/hh_half_tip_vl3_rr1.flac', 'h14/cl/rr1/hh_half_tip_vl6_rr1.flac'], 1.2, 0.75, 0),
    ('hat_open', U, ['h14/cl/rr1/hh_open_tip_vl3_rr1.flac', 'h14/cl/rr1/hh_open_tip_vl7_rr1.flac'], 2.2, 1.3, 0),
    ('hat_foot', U, ['h14/cl/rr1/hh_footchik_vl5_rr1.flac'], 0.3, 0.18, 0),
    ('crash', U, ['c16/cl/rr1/cr_edge_vl2_rr1.flac', 'c16/cl/rr1/cr_edge_vl4_rr1.flac'], 3.5, 2.1, 0),
    ('ride', U, ['r20/cl/rr1/ride_bow_vl4_rr1.flac', 'r20/cl/rr1/ride_bow_vl8_rr1.flac'], 3.0, 1.8, 0),
    ('ride_bell', U, ['r20/cl/rr1/ride_bell_vl5_rr1.flac'], 2.5, 1.5, 0),
    ('kick_pedal', U, ['ns/cl/rr1/kick_pedal_down_rr1.flac'], 0.3, 0.18, 0),
]


def mono(path):
    x, sr = sf.read(path, always_2d=True, dtype='float64')
    if sr != SR:
        raise SystemExit(f'{path}: {sr} Hz, expected {SR}')
    return x.mean(axis=1)


def onset(x):
    env = np.abs(x)
    thr = env.max() * 0.03
    i = int(np.argmax(env > thr))
    return max(0, i - int(PRE * SR))


def fundamental(x):
    # The strongest peak 40..400 Hz over 30..400 ms (a tom's (0,1) mode).
    seg = x[int(0.03 * SR):int(0.4 * SR)]
    spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg)), 1 << 16))
    f = np.fft.rfftfreq(1 << 16, 1 / SR)
    band = (f > 40) & (f < 400)
    return float(f[band][np.argmax(spec[band])])


def cut(x, seconds, fade_from, hp):
    x = x[onset(x):]
    n = int(seconds * SR)
    x = np.concatenate([x, np.zeros(max(0, n - len(x)))])[:n].copy()
    if hp:
        sos = butter(2, hp, 'highpass', fs=SR, output='sos')
        x = sosfilt(sos, x)
    pre = int(PRE * SR)
    x[:pre] *= np.linspace(0, 1, pre, endpoint=False)
    f0 = int(fade_from * SR)
    t = np.linspace(0, 1, n - f0)
    x[f0:] *= 0.5 + 0.5 * np.cos(np.pi * t)  # a raised-cosine fade to exact silence
    return x


def main(unruly, rusty, engine):
    roots = {U: os.path.join(unruly, 'Samples'), R: os.path.join(rusty, 'Samples')}
    pcm, rows, manifest, part_rows = [], [], [], []
    at = 0
    for name, src, files, seconds, fade_from, hp in PARTS:
        clips = []
        for f in files:
            path = os.path.join(roots[src], f)
            x = mono(path)
            h = hp
            if hp == 'tom':
                h = 1.6 * fundamental(x)
            clips.append(cut(x, seconds, fade_from, h))
            manifest.append((src, f, os.path.getsize(path)))
        top = max(np.abs(c).max() for c in clips)
        first = len(rows)
        for c in clips:
            c = c * (0.9 / top)
            peak = float(np.abs(c).max())
            vel = (peak / 0.9) ** (1 / 1.6)
            rows.append((at, len(c), peak, vel))
            pcm.append(c)
            at += len(c)
        part_rows.append((name, first, len(clips)))
    audio = np.concatenate(pcm)
    out = os.path.join(engine, 'assets', 'rook', 'kit.flac')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    sf.write(out, audio, SR, subtype='PCM_16', format='FLAC')
    inc = os.path.join(engine, 'src', 'rook_bank.inc')
    with open(inc, 'w') as o:
        o.write('// Rook\'s recorded parts: where each clip of engine/assets/rook/kit.flac starts (frames at 44.1 kHz), its\n')
        o.write('// length, peak and the velocity it stands for; and each part\'s clips. Generated by engine/tools/rook_assets.py.\n')
        o.write(f'inline constexpr uint32_t kBankRate = {SR};\n')
        o.write('inline constexpr Clip kClips[] = {\n')
        for a, n, p, v in rows:
            o.write(f'    {{{a}u, {n}u, {p:.6f}f, {v:.6f}f}},\n')
        o.write('};\n')
        o.write('inline constexpr PartClips kParts[kPartCount] = {\n')
        for name, first, count in part_rows:
            o.write(f'    {{{first}u, {count}u}},  // {name}\n')
        o.write('};\n')
    print(f'{out}: {os.path.getsize(out)} bytes, {len(audio) / SR:.1f} s, {len(rows)} clips')
    for src, f, size in manifest:
        print(f'  {src} {f} {size}')


if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit(__doc__ if __doc__ else 'usage: rook_assets.py <unruly> <rusty> <engine>')
    main(*sys.argv[1:])
